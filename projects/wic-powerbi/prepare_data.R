# prepare_data.R
# Turns the USDA WIC state agency files (one Excel file per fiscal year, one sheet per measure)
# into three tidy CSV files for the Power BI dashboard.
#
# Input:  raw/wicagencies<YEAR>ytd.xlsx, downloaded from https://www.fna.usda.gov/pd/wic-program
#         ("Monthly Data - State Level Participation by Category and Program Costs")
# Output: data/WIC_Monthly.csv  one row per WIC agency and month: participants by category, food costs, rebates
#         data/WIC_NSA.csv      one row per WIC agency and fiscal year: nutrition services and administration costs
#         data/Agencies.csv     one row per WIC agency: type, state and USDA region
#
# Run it from this folder: Rscript prepare_data.R

library(readxl)
library(dplyr)
library(tidyr)
library(purrr)
library(readr)
library(stringr)

files <- list.files("raw", pattern = "^wicagencies\\d{4}ytd\\.xlsx$", full.names = TRUE)

# Sheets with monthly values and the column name each one gets
monthly_sheets <- c(
  "Pregnant Women Participating"   = "Pregnant",
  "Total Breastfeeding Women"      = "Breastfeeding",
  "Postpartum Women Participating" = "Postpartum",
  "Total Women"                    = "Women",
  "Infants Fully Breastfed"        = "Infants Fully Breastfed",
  "Infants Partially Breastfed"    = "Infants Partially Breastfed",
  "Infants Fully Formula-fed"      = "Infants Formula Fed",
  "Total Infants"                  = "Infants",
  "Children Participating"         = "Children",
  "Total Number of Participants"   = "Participants",
  "Food Costs"                     = "Food Cost",
  "Rebates Received"               = "Rebates"
)

# Each sheet lists the agencies of one USDA region and then a subtotal row for that region,
# and ends with a national TOTAL row. These are the subtotal rows.
is_subtotal <- function(x) str_detect(x, "Region$") | x %in% c("Mountain Plains", "TOTAL")

# Reads one sheet: agency names in the first column, then one column per month.
# The month headers are Excel date numbers (45566 = Oct 1, 2024).
read_monthly <- function(file, sheet, measure) {
  read_excel(file, sheet = sheet, skip = 4) %>%
    rename(Agency = 1) %>%
    select(Agency, matches("^\\d{5}$")) %>%
    filter(!is.na(Agency), !str_detect(Agency, "^All data"), !is_subtotal(Agency)) %>%
    pivot_longer(-Agency, names_to = "Month", values_to = "value") %>%
    filter(!is.na(value)) %>%
    mutate(Month = as.Date(as.numeric(Month), origin = "1899-12-30"),
           measure = measure)
}

monthly <- map_dfr(files, function(f) {
  imap_dfr(monthly_sheets, function(measure, sheet) read_monthly(f, sheet, measure))
}) %>%
  mutate(Agency = str_squish(Agency)) %>%
  pivot_wider(names_from = measure, values_from = value) %>%
  arrange(Agency, Month)

# Checks: the totals in the USDA sheets should equal the sum of their parts
check <- monthly %>%
  summarise(
    women_diff        = sum(abs(Women - (Pregnant + Breastfeeding + Postpartum)), na.rm = TRUE),
    infants_diff      = sum(abs(Infants - (`Infants Fully Breastfed` + `Infants Partially Breastfed` + `Infants Formula Fed`)), na.rm = TRUE),
    participants_diff = sum(abs(Participants - (Women + Infants + Children)), na.rm = TRUE)
  )
print(check)

# Nutrition services and administration (NSA) costs are reported once per fiscal year
# (October to the last month in the file), not by month.
nsa <- map_dfr(files, function(f) {
  fy <- as.integer(str_extract(basename(f), "\\d{4}"))
  read_excel(f, sheet = "Nut. Services & Admin. Costs", skip = 4) %>%
    rename(Agency = 1, `NSA Cost` = 2) %>%
    filter(!is.na(Agency), !str_detect(Agency, "^All data"), !is_subtotal(Agency)) %>%
    mutate(`Fiscal Year` = fy,
           `FY Start` = as.Date(paste0(fy - 1, "-10-01")),
           `NSA Cost` = round(as.numeric(`NSA Cost`)))
}) %>%
  mutate(Agency = str_squish(Agency)) %>%
  # months covered by each fiscal year's file (12, or fewer for the current year)
  left_join(monthly %>%
              mutate(`Fiscal Year` = as.integer(format(Month, "%Y")) + (as.integer(format(Month, "%m")) >= 10)) %>%
              distinct(`Fiscal Year`, Month) %>%
              count(`Fiscal Year`, name = "Months Reported"),
            by = "Fiscal Year") %>%
  select(Agency, `Fiscal Year`, `FY Start`, `Months Reported`, `NSA Cost`)

# Agencies: USDA region (taken from the subtotal row that follows each group of agencies),
# type of agency, and the state it is in
read_regions <- function(file) {
  rows <- read_excel(file, sheet = "Total Number of Participants", skip = 4) %>%
    rename(Agency = 1) %>%
    filter(!is.na(Agency), !str_detect(Agency, "^All data"), Agency != "TOTAL") %>%
    mutate(Agency = str_squish(Agency))
  region <- character(nrow(rows))
  current <- NA_character_
  for (i in rev(seq_len(nrow(rows)))) {        # walk up from the bottom: each agency takes the next subtotal below it
    if (is_subtotal(rows$Agency[i])) current <- rows$Agency[i]
    region[i] <- current
  }
  tibble(Agency = rows$Agency, `USDA Region` = region) %>% filter(!is_subtotal(Agency))
}
# every file, because a few small agencies appear only in some years
regions <- map_dfr(files, read_regions) %>%
  distinct(Agency, .keep_all = TRUE) %>%
  mutate(`USDA Region` = str_remove(`USDA Region`, " Region$"))

states <- tibble(`State Name` = c(state.name, "District of Columbia"),
                 `State Code` = c(state.abb, "DC"))
territories <- tibble(`State Name` = c("Puerto Rico", "Virgin Islands", "Guam", "American Samoa", "Northern Marianas"),
                      `State Code` = c("PR", "VI", "GU", "AS", "MP"))

agencies <- monthly %>%
  distinct(Agency) %>%
  left_join(regions, by = "Agency") %>%
  mutate(
    `Agency Type` = case_when(
      Agency %in% states$`State Name`      ~ "State",
      Agency %in% territories$`State Name` ~ "Territory",
      TRUE                                 ~ "Indian Tribal Organization"
    ),
    # tribal organizations end in their state's code, e.g. "Choctaw Indians, MS"
    `State Code` = case_when(
      `Agency Type` == "State"     ~ states$`State Code`[match(Agency, states$`State Name`)],
      `Agency Type` == "Territory" ~ territories$`State Code`[match(Agency, territories$`State Name`)],
      TRUE                         ~ str_extract(Agency, "[A-Z]{2}$")
    ),
    `State Name` = coalesce(states$`State Name`[match(`State Code`, states$`State Code`)],
                            territories$`State Name`[match(`State Code`, territories$`State Code`)])
  ) %>%
  arrange(`Agency Type`, Agency)

stopifnot(sum(agencies$`Agency Type` == "State") == 51, !anyNA(agencies$`State Code`), !anyNA(agencies$`USDA Region`))

write_csv(monthly %>% mutate(Month = format(Month, "%Y-%m-%d")), "data/WIC_Monthly.csv", na = "")
write_csv(nsa %>% mutate(`FY Start` = format(`FY Start`, "%Y-%m-%d")), "data/WIC_NSA.csv", na = "")
write_csv(agencies, "data/Agencies.csv", na = "")

cat("WIC_Monthly:", nrow(monthly), "rows,", n_distinct(monthly$Agency), "agencies,",
    format(min(monthly$Month)), "to", format(max(monthly$Month)), "\n")
cat("WIC_NSA:", nrow(nsa), "rows\nAgencies:", nrow(agencies), "rows\n")

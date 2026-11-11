# get_data.R
# Downloads the two data files the dashboard uses and saves them in data/.
# Run it once from this folder (or again when CDC publishes a new PLACES release).

library(readr)
library(dplyr)
library(jsonlite)

dir.create("data", showWarnings = FALSE)

# 1. CDC PLACES: County Data (GIS Friendly Format), 2025 release, dataset "i46a-9kgh" on data.cdc.gov.
#    One row per county. I keep Georgia and six measures: the age-adjusted prevalence
#    ("_adjprev") and its 95% confidence interval ("_adj95ci") for each one.
measures <- c("obesity", "diabetes", "bphigh", "chd", "lpa", "foodinsecu")
fields   <- c("countyname", "countyfips", "totalpop18plus",
              paste0(rep(measures, each = 2), c("_adjprev", "_adj95ci")))

places_url <- paste0(
  "https://data.cdc.gov/resource/i46a-9kgh.csv?",
  "$select=", paste(fields, collapse = ","),
  "&$where=stateabbr='GA'&$order=countyfips&$limit=500"
)

places <- read_csv(URLencode(places_url), show_col_types = FALSE) %>%
  # CDC writes each interval as "( 32.5,  49.0)"; I rewrite it as "32.5–49.0"
  mutate(across(ends_with("_adj95ci"), ~ sub(",", "–", gsub("[() ]", "", .x))))

write_csv(places, "data/places_ga_2025.csv")

# 2. County boundaries for the map: the US counties GeoJSON published by plotly.
#    I keep only Georgia counties (their FIPS codes start with 13).
counties <- read_json("https://raw.githubusercontent.com/plotly/datasets/master/geojson-counties-fips.json")
counties$features <- Filter(function(f) startsWith(f$id, "13"), counties$features)
write_json(counties, "data/ga_counties.geojson", auto_unbox = TRUE, digits = NA)

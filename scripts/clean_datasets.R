#!/usr/bin/env Rscript

# ------------------------------------------------------------------------------
# clean_datasets.R
#
# Updates `data/cleaned/merged_standardized_dataset.csv` in place (no new file).
#
# 1) Adds `DATASET_YEAR` (string): paste of `DATA_YEAR` and `SOURCE_FILE`.
#
# 2) Drops variables per project rules (MEPS codebook):
#    - Section 2.5.11: utilization and expenditures (charges, visits, payments
#      by source) for totals, office, outpatient, ER, inpatient, dental, home
#      health, other medical, and prescription blocks. Year suffixes 19–23 are
#      already removed in merge, so names are base forms (e.g. ERTOT).
#      Aggregate variants in the merged file (ERT*, IPT*, OPT*, OBD*, OPS*, …)
#      are dropped under the same rule.
#    - Section 4.2: PERWTF, VARSTR, VARPSU; any column containing "BRR" or
#      matching RWT + digits (replicate weights).
#
#    Protected (never dropped): DATA_YEAR, SOURCE_FILE, DATASET_YEAR, DUID,
#    PID, DUPERSID, PANEL, TOTEXP.
#
# Writes `data/cleaned/dropped_variables.csv`: one column `variable`, sorted.
# ------------------------------------------------------------------------------

get_script_path <- function() {
  file_arg <- "--file="
  args <- commandArgs(trailingOnly = FALSE)
  match <- grep(file_arg, args)

  if (length(match) > 0) {
    return(normalizePath(sub(file_arg, "", args[match[1]]), mustWork = TRUE))
  }

  normalizePath(getwd(), mustWork = TRUE)
}

NEG_CODES <- c(
  "-1"  = "INAPPLICABLE",
  "-2"  = "PREV_ROUND",
  "-7"  = "REFUSED",
  "-8"  = "DK",
  "-10" = "TOP_CODED",
  "-15" = "CANNOT_COMPUTE"
)

POS_CODE_MAPS <- list(
  REGION = c(`1` = "Northeast", `2` = "Midwest", `3` = "South", `4` = "West"),
  MARRYX = c(
    `1` = "Married",
    `2` = "Widowed",
    `3` = "Divorced",
    `4` = "Separated",
    `5` = "NeverMarried",
    `6` = "Under16"
  ),
  HIDEG = c(
    `1` = "NoDegree",
    `2` = "GED",
    `3` = "HS",
    `4` = "Bachelors",
    `5` = "Masters",
    `6` = "Doctorate",
    `7` = "Other"
  ),
  RACETHX = c(
    `1` = "Hispanic",
    `2` = "NH_White",
    `3` = "NH_Black",
    `4` = "NH_Asian",
    `5` = "NH_Other"
  ),
  EMPST = c(
    `1` = "Employed",
    `2` = "JobToReturn",
    `3` = "NotEmpLooking",
    `4` = "NotLooking"
  ),
  INSCOP = c(
    `1` = "Whole",
    `2` = "StartOnly",
    `3` = "EndOnly",
    `5` = "OOS",
    `7` = "JoinedLater"
  ),
  RTHLTH = c(
    `1` = "Excellent",
    `2` = "VeryGood",
    `3` = "Good",
    `4` = "Fair",
    `5` = "Poor"
  ),
  MNHLTH = c(
    `1` = "Excellent",
    `2` = "VeryGood",
    `3` = "Good",
    `4` = "Fair",
    `5` = "Poor"
  ),
  SEX = c(`1` = "Male", `2` = "Female"),
  ASTHDX = c(`1` = "Yes", `2` = "No"),
  ANYLMI = c(`1` = "Yes", `2` = "No"),
  BORNUSA = c(`1` = "Yes", `2` = "No"),
  HAVEUS = c(`1` = "Yes", `2` = "No"),
  FILEDR = c(`1` = "Yes", `2` = "No")
)

MULTICLASS_PATTERNS <- c(
  "^REGION$",
  "^MARRYX$",
  "^HIDEG$",
  "^RACETHX$",
  "^INSCOP$",
  "^EMPST[0-9]+H?$",
  "^RTHLTH[0-9]+$",
  "^MNHLTH[0-9]+$"
)

BINARY_PATTERNS <- c(
  "^SEX$",
  "^ASTHDX$",
  "^ANYLMI$",
  "^BORNUSA$",
  "^HAVEUS[0-9]+$",
  "^FILEDR$"
)

CONTINUOUS_PATTERNS <- c(
  "^AGEX$",
  "^TTLPX$",
  "^TOTEXP$",
  "^ADBMI[0-9]+$",
  "^POVLEV$",
  "^OBTOTV$",
  "^FAMINC$"
)

ID_COLUMNS <- c(
  "DUID",
  "PID",
  "DUPERSID",
  "PANEL",
  "DATA_YEAR",
  "SOURCE_FILE",
  "DATASET_YEAR"
)

MAX_CATEGORICAL_CARDINALITY <- 20L

matches_any_pattern <- function(name, patterns) {
  any(vapply(patterns, function(p) grepl(p, name, perl = TRUE), logical(1)))
}

pos_map_for <- function(name) {
  if (name %in% names(POS_CODE_MAPS)) {
    return(POS_CODE_MAPS[[name]])
  }

  stem_matches <- vapply(
    names(POS_CODE_MAPS),
    function(stem) grepl(paste0("^", stem, "[0-9]+H?$"), name, perl = TRUE),
    logical(1)
  )

  if (any(stem_matches)) {
    return(POS_CODE_MAPS[[names(POS_CODE_MAPS)[which(stem_matches)[1]]]])
  }

  NULL
}

label_variable <- function(x, pos_map) {
  numeric_x <- suppressWarnings(as.numeric(x))
  labels <- rep(NA_character_, length(numeric_x))

  for (code in names(pos_map)) {
    match_mask <- !is.na(numeric_x) & numeric_x == as.numeric(code)
    labels[match_mask] <- pos_map[[code]]
  }

  for (code in names(NEG_CODES)) {
    match_mask <- !is.na(numeric_x) & numeric_x == as.numeric(code)
    labels[match_mask] <- NEG_CODES[[code]]
  }

  leftover_mask <- !is.na(numeric_x) & is.na(labels)
  neg_leftover <- leftover_mask & numeric_x < 0
  labels[neg_leftover] <- "NEG_OTHER"

  pos_leftover <- leftover_mask & numeric_x >= 0
  if (any(pos_leftover)) {
    labels[pos_leftover] <- as.character(numeric_x[pos_leftover])
  }

  labels
}

one_hot <- function(labels, var_name) {
  observed_levels <- sort(unique(labels[!is.na(labels)]))
  has_na <- any(is.na(labels))

  columns <- list()

  for (level in observed_levels) {
    columns[[paste0(var_name, "_", level)]] <- as.integer(
      !is.na(labels) & labels == level
    )
  }

  if (has_na) {
    columns[[paste0(var_name, "_NA")]] <- as.integer(is.na(labels))
  }

  if (length(columns) == 0) {
    return(
      data.frame(row.names = seq_along(labels), stringsAsFactors = FALSE)
    )
  }

  as.data.frame(columns, check.names = FALSE, stringsAsFactors = FALSE)
}

classify_column <- function(name) {
  if (name %in% ID_COLUMNS) {
    return("id")
  }

  if (matches_any_pattern(name, CONTINUOUS_PATTERNS)) {
    return("continuous")
  }

  "categorical"
}

should_drop_column <- function(col) {
  if (col %in% c(
    "DATA_YEAR",
    "SOURCE_FILE",
    "DATASET_YEAR",
    "DUID",
    "PID",
    "DUPERSID",
    "PANEL",
    "TOTEXP"
  )) {
    return(FALSE)
  }

  if (grepl(
    "^(TOTTCH|TOTSLF|TOTMCR|TOTMCD|TOTPRV|TOTVA|TOTTRI|TOTOFD|TOTSTL|TOTWCP|TOTOSR|TOTPTR|TOTOTH)$",
    col,
    perl = TRUE
  )) {
    return(TRUE)
  }

  if (grepl(
    "^OB(TOTV|DRV|OTHV|CHIR|NURS|OPTO|ASST|THER|VTCH)$",
    col,
    perl = TRUE
  )) {
    return(TRUE)
  }

  if (grepl("^OBV", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^OBD", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^OPT", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^OPF", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^OPD", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^OPV", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^OPS", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^AM(CHIR|NURS|OPT|ASST|THER)", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^ERT", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^ERF", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^ERD", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^ERV", col, perl = TRUE)) {
    return(TRUE)
  }

  if (col %in% c("IPDIS", "IPNGTD", "IPZERO")) {
    return(TRUE)
  }

  if (grepl("^IPF", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^IPD", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^IPT", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^DV(TOT|GEN|ORTH|VTCH)$", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^DVV", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^DVT", col, perl = TRUE) && nchar(col) > 3L) {
    return(TRUE)
  }

  if (grepl("^HH", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl("^OME", col, perl = TRUE)) {
    return(TRUE)
  }

  if (grepl(
    "^RX(TOT|EXP|SLF|MCR|MCD|PRV|VA|TRI|OFD|STL|WCP|OSR|PTR|OTH)$",
    col,
    perl = TRUE
  )) {
    return(TRUE)
  }

  if (col %in% c("PERWTF", "VARSTR", "VARPSU")) {
    return(TRUE)
  }

  if (grepl("BRR", col, fixed = TRUE)) {
    return(TRUE)
  }

  if (grepl("^RWT[0-9]+$", col, perl = TRUE)) {
    return(TRUE)
  }

  FALSE
}

script_path <- get_script_path()
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
cleaned_dir <- file.path(project_root, "data", "cleaned")
input_path <- file.path(cleaned_dir, "merged_standardized_dataset.csv")
dropped_path <- file.path(cleaned_dir, "dropped_variables.csv")
encoded_path <- file.path(cleaned_dir, "merged_encoded_dataset.csv")
manifest_path <- file.path(cleaned_dir, "encoded_variable_manifest.csv")

if (!file.exists(input_path)) {
  stop(
    sprintf(
      "Merged dataset not found at %s. Run scripts/merge_raw_datasets.R first.",
      input_path
    ),
    call. = FALSE
  )
}

dataset <- utils::read.csv(
  input_path,
  check.names = FALSE,
  stringsAsFactors = FALSE
)

required_columns <- c("DATA_YEAR", "SOURCE_FILE")
missing_columns <- setdiff(required_columns, names(dataset))

if (length(missing_columns) > 0) {
  stop(
    sprintf(
      "Merged dataset is missing required columns: %s",
      paste(missing_columns, collapse = ", ")
    ),
    call. = FALSE
  )
}

n_before <- ncol(dataset)

dataset$DATASET_YEAR <- paste0(dataset$DATA_YEAR, "_", dataset$SOURCE_FILE)
dataset$DATASET_YEAR <- as.character(dataset$DATASET_YEAR)

column_names <- names(dataset)
drop_mask <- vapply(column_names, should_drop_column, logical(1))
columns_to_drop <- sort(column_names[drop_mask])

if (length(columns_to_drop) > 0) {
  dataset[columns_to_drop] <- NULL
}

utils::write.csv(
  data.frame(variable = columns_to_drop, stringsAsFactors = FALSE),
  dropped_path,
  row.names = FALSE,
  na = ""
)

utils::write.csv(dataset, input_path, row.names = FALSE, na = "")

remaining_columns <- names(dataset)
roles <- vapply(remaining_columns, classify_column, character(1))

id_cols <- remaining_columns[roles == "id"]
id_cols <- c(
  intersect(ID_COLUMNS, id_cols),
  setdiff(id_cols, ID_COLUMNS)
)

continuous_cols <- remaining_columns[roles == "continuous"]
categorical_cols <- remaining_columns[roles == "categorical"]

encoded_parts <- list()
high_cardinality_parts <- list()

if (length(id_cols) > 0) {
  encoded_parts[["__ids__"]] <- dataset[, id_cols, drop = FALSE]
}

if (length(continuous_cols) > 0) {
  continuous_frame <- dataset[, continuous_cols, drop = FALSE]
  for (col in continuous_cols) {
    continuous_frame[[col]] <- suppressWarnings(as.numeric(continuous_frame[[col]]))
  }
  encoded_parts[["__continuous__"]] <- continuous_frame
}

manifest_rows <- list()

record_manifest <- function(source_name, role, n_output_columns, output_names) {
  manifest_rows[[length(manifest_rows) + 1]] <<- data.frame(
    source_variable = source_name,
    role = role,
    n_output_columns = n_output_columns,
    output_columns = paste(output_names, collapse = "|"),
    stringsAsFactors = FALSE
  )
}

for (col in id_cols) {
  record_manifest(col, "id", 1L, col)
}

for (col in continuous_cols) {
  record_manifest(col, "continuous", 1L, col)
}

encode_categorical <- function(cols) {
  categorical_mapped_count <- 0L
  categorical_raw_count <- 0L
  high_cardinality_count <- 0L

  for (col in cols) {
    numeric_x <- suppressWarnings(as.numeric(dataset[[col]]))
    unique_vals <- unique(numeric_x[!is.na(numeric_x)])
    n_unique <- length(unique_vals)

    if (n_unique > MAX_CATEGORICAL_CARDINALITY) {
      passthrough_frame <- data.frame(x = numeric_x, stringsAsFactors = FALSE)
      names(passthrough_frame) <- col
      high_cardinality_parts[[col]] <<- passthrough_frame
      record_manifest(
        col,
        "high_cardinality_passthrough",
        1L,
        sprintf("%s (unique=%d)", col, n_unique)
      )
      high_cardinality_count <- high_cardinality_count + 1L
      next
    }

    explicit_map <- pos_map_for(col)
    if (!is.null(explicit_map)) {
      pos_map <- explicit_map
      this_role <- "categorical_mapped"
      categorical_mapped_count <- categorical_mapped_count + 1L
    } else {
      non_negative_vals <- sort(unique_vals[unique_vals >= 0])
      if (length(non_negative_vals) == 0) {
        pos_map <- character(0)
      } else {
        pos_map <- setNames(
          as.character(non_negative_vals),
          as.character(non_negative_vals)
        )
      }
      this_role <- "categorical_raw"
      categorical_raw_count <- categorical_raw_count + 1L
    }

    labels <- label_variable(numeric_x, pos_map)
    ohe <- one_hot(labels, col)
    encoded_parts[[paste0("__categorical__", col)]] <<- ohe
    record_manifest(col, this_role, ncol(ohe), names(ohe))
  }

  list(
    categorical_mapped = categorical_mapped_count,
    categorical_raw = categorical_raw_count,
    high_cardinality = high_cardinality_count
  )
}

categorical_summary <- encode_categorical(categorical_cols)

if (length(high_cardinality_parts) > 0) {
  encoded_parts[["__high_cardinality__"]] <- do.call(
    cbind,
    c(high_cardinality_parts, list(stringsAsFactors = FALSE))
  )
}

encoded_dataset <- do.call(
  cbind,
  c(encoded_parts, list(stringsAsFactors = FALSE))
)

rownames(encoded_dataset) <- NULL

manifest <- if (length(manifest_rows) > 0) {
  do.call(rbind, manifest_rows)
} else {
  data.frame(
    source_variable = character(),
    role = character(),
    n_output_columns = integer(),
    output_columns = character(),
    stringsAsFactors = FALSE
  )
}

utils::write.csv(encoded_dataset, encoded_path, row.names = FALSE, na = "")
utils::write.csv(manifest, manifest_path, row.names = FALSE, na = "")

message("Cleaned dataset updated in place.")
message(sprintf("Updated file: %s", input_path))
message(sprintf("Rows written: %s", nrow(dataset)))
message(sprintf("Columns before: %s", n_before))
message(sprintf("Columns after: %s", ncol(dataset)))
message(sprintf("Columns dropped: %s", length(columns_to_drop)))
message(sprintf("Dropped-variable list: %s", dropped_path))
message(sprintf("Unique DATASET_YEAR categories: %s", length(unique(dataset$DATASET_YEAR))))
message("")
message("Encoded dataset written.")
message(sprintf("Encoded file: %s", encoded_path))
message(sprintf("Encoded rows: %s", nrow(encoded_dataset)))
message(sprintf("Encoded columns: %s", ncol(encoded_dataset)))
message(sprintf("ID / key columns: %s", length(id_cols)))
message(sprintf("Continuous columns: %s", length(continuous_cols)))
message(sprintf(
  "Categorical source variables encoded (mapped): %s",
  categorical_summary$categorical_mapped
))
message(sprintf(
  "Categorical source variables encoded (raw codes): %s",
  categorical_summary$categorical_raw
))
message(sprintf(
  "High-cardinality (>%d unique) pass-through columns: %s",
  MAX_CATEGORICAL_CARDINALITY,
  categorical_summary$high_cardinality
))
message(sprintf("Encoding manifest: %s", manifest_path))

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
#      already removed in merge, so names are base forms (e.g. TOTEXP, ERTOT).
#      Aggregate variants in the merged file (ERT*, IPT*, OPT*, OBD*, OPS*, …)
#      are dropped under the same rule.
#    - Section 4.2: PERWTF, VARSTR, VARPSU; any column containing "BRR" or
#      matching RWT + digits (replicate weights).
#
#    Protected (never dropped): DATA_YEAR, SOURCE_FILE, DATASET_YEAR, DUID,
#    PID, DUPERSID, PANEL.
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

should_drop_column <- function(col) {
  if (col %in% c(
    "DATA_YEAR",
    "SOURCE_FILE",
    "DATASET_YEAR",
    "DUID",
    "PID",
    "DUPERSID",
    "PANEL"
  )) {
    return(FALSE)
  }

  if (grepl(
    "^(TOTTCH|TOTEXP|TOTSLF|TOTMCR|TOTMCD|TOTPRV|TOTVA|TOTTRI|TOTOFD|TOTSTL|TOTWCP|TOTOSR|TOTPTR|TOTOTH)$",
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

message("Cleaned dataset updated in place.")
message(sprintf("Updated file: %s", input_path))
message(sprintf("Rows written: %s", nrow(dataset)))
message(sprintf("Columns before: %s", n_before))
message(sprintf("Columns after: %s", ncol(dataset)))
message(sprintf("Columns dropped: %s", length(columns_to_drop)))
message(sprintf("Dropped-variable list: %s", dropped_path))
message(sprintf("Unique DATASET_YEAR categories: %s", length(unique(dataset$DATASET_YEAR))))

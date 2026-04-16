#!/usr/bin/env Rscript

get_script_path <- function() {
  file_arg <- "--file="
  args <- commandArgs(trailingOnly = FALSE)
  match <- grep(file_arg, args)

  if (length(match) > 0) {
    return(normalizePath(sub(file_arg, "", args[match[1]]), mustWork = TRUE))
  }

  normalizePath(getwd(), mustWork = TRUE)
}

ensure_package <- function(package_name) {
  if (!requireNamespace(package_name, quietly = TRUE)) {
    stop(
      sprintf(
        "Package '%s' is required. Install it with install.packages('%s') and run the script again.",
        package_name,
        package_name
      ),
      call. = FALSE
    )
  }
}

standardize_name <- function(name, manual_map) {
  standardized <- toupper(trimws(name))

  if (standardized %in% names(manual_map)) {
    standardized <- manual_map[[standardized]]
  }

  standardized <- sub(
    "^(.*?)(19|20|21|22|23)(_.+)$",
    "\\1\\3",
    standardized,
    perl = TRUE
  )
  standardized <- sub(
    "^(.*?)(19|20|21|22|23)([A-Z]?)$",
    "\\1\\3",
    standardized,
    perl = TRUE
  )

  standardized
}

coalesce_duplicate_columns <- function(data, source_file) {
  duplicate_names <- unique(names(data)[duplicated(names(data))])
  if (length(duplicate_names) == 0) {
    return(
      list(
        data = data,
        duplicate_audit = data.frame(
          source_file = character(),
          standardized_name = character(),
          duplicate_count = integer(),
          conflict_rows = integer(),
          stringsAsFactors = FALSE
        )
      )
    )
  }

  rebuilt_columns <- list()
  rebuilt_names <- character()
  duplicate_audit <- list()

  for (column_name in unique(names(data))) {
    indices <- which(names(data) == column_name)
    values <- data[indices]

    if (length(indices) == 1) {
      rebuilt_columns[[length(rebuilt_columns) + 1]] <- values[[1]]
      rebuilt_names <- c(rebuilt_names, column_name)
      next
    }

    merged <- values[[1]]
    conflict_rows <- 0L

    for (i in 2:length(values)) {
      candidate <- values[[i]]
      conflicts <- !is.na(merged) & !is.na(candidate) & merged != candidate
      conflict_rows <- conflict_rows + sum(conflicts, na.rm = TRUE)
      merged[is.na(merged)] <- candidate[is.na(merged)]
    }

    rebuilt_columns[[length(rebuilt_columns) + 1]] <- merged
    rebuilt_names <- c(rebuilt_names, column_name)
    duplicate_audit[[length(duplicate_audit) + 1]] <- data.frame(
      source_file = source_file,
      standardized_name = column_name,
      duplicate_count = length(indices),
      conflict_rows = conflict_rows,
      stringsAsFactors = FALSE
    )
  }

  rebuilt_data <- as.data.frame(rebuilt_columns, check.names = FALSE, stringsAsFactors = FALSE)
  names(rebuilt_data) <- rebuilt_names

  list(
    data = rebuilt_data,
    duplicate_audit = do.call(rbind, duplicate_audit)
  )
}

align_columns <- function(data_list) {
  all_columns <- unique(unlist(lapply(data_list, names), use.names = FALSE))

  lapply(data_list, function(dataset) {
    missing_columns <- setdiff(all_columns, names(dataset))
    if (length(missing_columns) > 0) {
      for (column_name in missing_columns) {
        dataset[[column_name]] <- NA
      }
    }

    dataset[all_columns]
  })
}

ensure_package("readxl")

script_path <- get_script_path()
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
raw_dir <- file.path(project_root, "Data", "raw")
output_dir <- file.path(project_root, "data", "cleaned")

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

file_specs <- data.frame(
  file_name = c("h216.xlsx", "H224.xlsx", "h233.xlsx", "h243.xlsx", "h251.xlsx"),
  data_year = c(2019L, 2020L, 2021L, 2022L, 2023L),
  stringsAsFactors = FALSE
)

manual_rename_map <- c(
  PROVSEX42 = "GENDRP42",
  TRIST19X = "TRI19X",
  TRIST20X = "TRI20X"
)

datasets <- list()
rename_audits <- list()
duplicate_audits <- list()
row_count_summary <- list()

for (i in seq_len(nrow(file_specs))) {
  spec <- file_specs[i, ]
  input_path <- file.path(raw_dir, spec$file_name)

  if (!file.exists(input_path)) {
    stop(sprintf("Missing input file: %s", input_path), call. = FALSE)
  }

  message(sprintf("Reading %s ...", spec$file_name))

  dataset <- readxl::read_excel(input_path, .name_repair = "minimal")
  dataset <- as.data.frame(dataset, check.names = FALSE, stringsAsFactors = FALSE)

  original_names <- names(dataset)
  standardized_names <- vapply(
    original_names,
    standardize_name,
    character(1),
    manual_map = manual_rename_map
  )
  names(dataset) <- standardized_names

  if (!"DATAYEAR" %in% names(dataset)) {
    dataset$DATAYEAR <- spec$data_year
  }

  dataset$DATA_YEAR <- spec$data_year
  dataset$SOURCE_FILE <- spec$file_name

  duplicate_result <- coalesce_duplicate_columns(dataset, spec$file_name)
  dataset <- duplicate_result$data
  duplicate_audits[[length(duplicate_audits) + 1]] <- duplicate_result$duplicate_audit

  rename_audits[[length(rename_audits) + 1]] <- data.frame(
    source_file = spec$file_name,
    original_name = original_names,
    standardized_name = standardized_names,
    changed = original_names != standardized_names,
    stringsAsFactors = FALSE
  )

  row_count_summary[[length(row_count_summary) + 1]] <- data.frame(
    source_file = spec$file_name,
    data_year = spec$data_year,
    rows = nrow(dataset),
    columns_after_standardization = ncol(dataset),
    stringsAsFactors = FALSE
  )

  datasets[[length(datasets) + 1]] <- dataset
}

aligned_datasets <- align_columns(datasets)
merged_dataset <- do.call(rbind, aligned_datasets)

row_count_summary <- do.call(rbind, row_count_summary)
rename_audit <- do.call(rbind, rename_audits)
duplicate_audit <- do.call(rbind, duplicate_audits)
rename_audit <- rename_audit[rename_audit$changed, c("source_file", "original_name", "standardized_name")]

merged_path <- file.path(output_dir, "merged_standardized_dataset.csv")
row_count_path <- file.path(output_dir, "merge_row_counts.csv")
rename_audit_path <- file.path(output_dir, "rename_audit.csv")
duplicate_audit_path <- file.path(output_dir, "duplicate_name_audit.csv")

utils::write.csv(merged_dataset, merged_path, row.names = FALSE, na = "")
utils::write.csv(row_count_summary, row_count_path, row.names = FALSE, na = "")
utils::write.csv(rename_audit, rename_audit_path, row.names = FALSE, na = "")
utils::write.csv(duplicate_audit, duplicate_audit_path, row.names = FALSE, na = "")

message("")
message("Merge complete.")
message(sprintf("Merged file: %s", merged_path))
message(sprintf("Rows written: %s", nrow(merged_dataset)))
message(sprintf("Columns written: %s", ncol(merged_dataset)))
message(sprintf("Expected rows from inputs: %s", sum(row_count_summary$rows)))
message(sprintf("Rename audit: %s", rename_audit_path))
message(sprintf("Duplicate-name audit: %s", duplicate_audit_path))

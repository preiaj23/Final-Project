#!/usr/bin/env Rscript
# Score new rows with the trained XGBoost model from the model bundle.
#
# Required: the same encoded feature columns as training — i.e. rows must come
# from `merged_encoded_dataset.csv` (or equivalent) after merge/clean, not raw
# MEPS Excel. Column names should match training after:
#   names(df) <- sub("^[^.]+\\.", "", names(df))
#
# Usage:
#   Rscript scripts/predict_xgboost_newdata.R path/to/encoded_newdata.csv
#   Rscript scripts/predict_xgboost_newdata.R path/to/file.xlsx path/to/out.csv
#
# If TOTEXP is present, prints RMSE and RMSLE on rows with valid targets and
# adds an `actual` column to the output. If TOTEXP is absent, writes predictions only.

get_script_path <- function() {
  file_arg <- "--file="
  args <- commandArgs(trailingOnly = FALSE)
  match <- grep(file_arg, args)
  if (length(match) > 0) {
    return(normalizePath(sub(file_arg, "", args[match[1]]), mustWork = TRUE))
  }
  normalizePath(getwd(), mustWork = TRUE)
}

coerce_numeric <- function(x) {
  if (is.factor(x)) x <- as.character(x)
  if (is.character(x)) suppressWarnings(x <- as.numeric(x))
  x
}

clip_nonnegative <- function(pred) pmax(pred, 0)

rmse <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  sqrt(mean((actual - pred)^2))
}

rmsle <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  sqrt(mean((log1p(pred) - log1p(actual))^2))
}

prepare_numeric_frame <- function(df, columns, medians) {
  out <- data.frame(row.names = seq_len(nrow(df)))
  for (nm in columns) {
    vals <- coerce_numeric(df[[nm]])
    med <- medians[[nm]]
    if (!is.finite(med)) {
      med <- suppressWarnings(stats::median(vals, na.rm = TRUE))
      if (!is.finite(med)) med <- 0
    }
    vals[is.na(vals)] <- med
    out[[nm]] <- vals
  }
  out
}

script_path <- get_script_path()
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(project_root, "src", "paths.R"))
source(file.path(project_root, "src", "download_packages.R"))

paths <- build_project_paths(project_root)
ensure_project_dirs(paths)
bootstrap_model_packages(project_root)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L) {
  stop(
    "Usage: Rscript scripts/predict_xgboost_newdata.R <encoded.csv|xlsx> [output.csv]",
    call. = FALSE
  )
}

data_path <- normalizePath(args[[1]], mustWork = TRUE)
out_path <- if (length(args) >= 2L) {
  normalizePath(args[[2]], mustWork = FALSE)
} else {
  file.path(paths$metrics_dir, "xgboost_newdata_predictions.csv")
}

if (!file.exists(paths$model_bundle)) {
  stop(sprintf("Model bundle not found at %s. Run training first.", paths$model_bundle), call. = FALSE)
}

bundle <- readRDS(paths$model_bundle)
target_name <- bundle$metadata$target_name

if (grepl("\\.xlsx$|\\.xls$", data_path, ignore.case = TRUE)) {
  suppressPackageStartupMessages(library(readxl))
  new_df <- as.data.frame(readxl::read_excel(data_path), stringsAsFactors = FALSE)
} else {
  new_df <- utils::read.csv(data_path, check.names = FALSE, stringsAsFactors = FALSE)
}
names(new_df) <- sub("^[^.]+\\.", "", names(new_df))

xgb_features <- bundle$artifacts$xgboost$features
xgb_medians <- bundle$artifacts$xgboost$medians
missing <- setdiff(xgb_features, names(new_df))
if (length(missing) > 0) {
  stop(
    sprintf(
      paste0(
        "New data is missing %d XGBoost feature columns.\n",
        "First ~25: %s\n",
        "Encode new rows with the same pipeline as `merged_encoded_dataset.csv`."
      ),
      length(missing),
      paste(head(missing, 25), collapse = ", ")
    ),
    call. = FALSE
  )
}

xgb_frame <- prepare_numeric_frame(new_df, xgb_features, xgb_medians)
dmat <- xgboost::xgb.DMatrix(data = as.matrix(xgb_frame))
pred <- clip_nonnegative(stats::predict(bundle$models$xgboost, newdata = dmat))

out <- data.frame(
  row_index = seq_len(nrow(new_df)),
  pred_xgboost = pred,
  stringsAsFactors = FALSE
)

has_target <- target_name %in% names(new_df)
if (has_target) {
  actual <- coerce_numeric(new_df[[target_name]])
  out[[target_name]] <- actual
  ok <- is.finite(actual) & actual >= 0
  if (any(ok)) {
    message(sprintf("RMSE (XGBoost, valid %s rows): %.6f", target_name, rmse(actual[ok], pred[ok])))
    message(sprintf("RMSLE (XGBoost, valid %s rows): %.6f", target_name, rmsle(actual[ok], pred[ok])))
  } else {
    message(sprintf("Column %s present but no valid non-negative rows for metrics.", target_name))
  }
}

utils::write.csv(out, out_path, row.names = FALSE, na = "")
message(sprintf("Predictions written to: %s", out_path))

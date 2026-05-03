# Evaluate saved models on a holdout file (Excel or CSV).
#
# IMPORTANT — feature alignment
# Models expect the SAME columns as `merged_encoded_dataset.csv` (or whatever
# `train_models.R` read): one-hot columns, same names as after
# `names(df) <- sub("^[^.]+\\.", "", names(df))`. Raw `test.xlsx` MEPS extract
# will NOT match; run those rows through your merge/clean pipeline first, then
# pass the encoded CSV path here.
#
# Usage:
#   Rscript test_analysis.R                          # uses ./test.xlsx
#   Rscript test_analysis.R path/to/encoded_test.csv
#
# How to improve RMSE (on a properly encoded test set):
# - Retune / retrain: run `scripts/train_models.R` after adding data or features.
# - Match population: same survey years / sampling as training reduces shift.
# - More test rows: RMSE on ~10 rows is very noisy; interpret with caution.
# - If preprocessing differs between train and test, RMSE will look worse until
#   the test file uses identical cleaning and encoding as training.

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
project_root <- normalizePath(dirname(script_path), mustWork = TRUE)
source(file.path(project_root, "src", "paths.R"))
source(file.path(project_root, "src", "download_packages.R"))

paths <- build_project_paths(project_root)
ensure_project_dirs(paths)
bootstrap_model_packages(project_root)

args <- commandArgs(trailingOnly = TRUE)
data_path <- if (length(args) >= 1L) {
  normalizePath(args[[1]], mustWork = TRUE)
} else {
  file.path(project_root, "test.xlsx")
}

if (!file.exists(paths$model_bundle)) {
  stop("Train models first: ", paths$model_bundle, call. = FALSE)
}
if (!file.exists(data_path)) {
  stop("Data file not found: ", data_path, call. = FALSE)
}

bundle <- readRDS(paths$model_bundle)
target_name <- bundle$metadata$target_name

if (grepl("\\.xlsx$|\\.xls$", data_path, ignore.case = TRUE)) {
  suppressPackageStartupMessages(library(readxl))
  test_df <- as.data.frame(readxl::read_excel(data_path), stringsAsFactors = FALSE)
} else {
  test_df <- utils::read.csv(data_path, check.names = FALSE, stringsAsFactors = FALSE)
}
names(test_df) <- sub("^[^.]+\\.", "", names(test_df))

if (!target_name %in% names(test_df)) {
  stop("Target ", target_name, " not found after loading test data.", call. = FALSE)
}

actual <- coerce_numeric(test_df[[target_name]])
ok <- is.finite(actual) & actual >= 0
if (!any(ok)) {
  stop("No rows with valid non-negative ", target_name, ".", call. = FALSE)
}
test_df <- test_df[ok, , drop = FALSE]
actual <- actual[ok]

need_cols <- unique(c(
  target_name,
  bundle$artifacts$random_forest$features,
  bundle$artifacts$xgboost$features,
  bundle$artifacts$piecewise_spline$selected
))
missing <- setdiff(need_cols, names(test_df))
if (length(missing) > 0) {
  stop(
    sprintf(
      paste0(
        "Test data is missing %d model columns (training used encoded/merged features).\n",
        "First ~20: %s\n",
        "Run your rows through the same clean/merge pipeline as training, then pass that CSV.\n",
        "Raw MEPS-style Excel columns do not match one-hot feature names."
      ),
      length(missing),
      paste(head(missing, 20), collapse = ", ")
    ),
    call. = FALSE
  )
}

pred_intercept <- clip_nonnegative(stats::predict(bundle$models$intercept, newdata = test_df))

rf_features <- bundle$artifacts$random_forest$features
rf_medians <- bundle$artifacts$random_forest$medians
rf_frame <- prepare_numeric_frame(test_df, rf_features, rf_medians)
pred_rf <- clip_nonnegative(stats::predict(bundle$models$random_forest, newdata = rf_frame))

xgb_features <- bundle$artifacts$xgboost$features
xgb_medians <- bundle$artifacts$xgboost$medians
xgb_test <- prepare_numeric_frame(test_df, xgb_features, xgb_medians)
dtest <- xgboost::xgb.DMatrix(data = as.matrix(xgb_test))
pred_xgb <- clip_nonnegative(stats::predict(bundle$models$xgboost, newdata = dtest))

spline_features <- bundle$artifacts$piecewise_spline$selected
spline_degree <- bundle$artifacts$piecewise_spline$degree
spline_medians <- bundle$artifacts$piecewise_spline$medians
spline_test <- prepare_numeric_frame(test_df, spline_features, spline_medians)
spline_rhs <- paste(
  vapply(
    spline_features,
    function(nm) sprintf("splines::bs(%s, degree = %d, df = 5)", nm, spline_degree),
    character(1)
  ),
  collapse = " + "
)
spline_formula <- stats::as.formula(sprintf("%s ~ %s", target_name, spline_rhs))
spline_newdata <- cbind(spline_test, setNames(data.frame(actual), target_name))
pred_spline <- clip_nonnegative(
  stats::predict(bundle$models$piecewise_spline, newdata = spline_newdata)
)

metrics <- data.frame(
  model = c(
    "intercept",
    "random_forest",
    "xgboost",
    "piecewise_polynomial_spline"
  ),
  rmse = c(
    rmse(actual, pred_intercept),
    rmse(actual, pred_rf),
    rmse(actual, pred_xgb),
    rmse(actual, pred_spline)
  ),
  rmsle = c(
    rmsle(actual, pred_intercept),
    rmsle(actual, pred_rf),
    rmsle(actual, pred_xgb),
    rmsle(actual, pred_spline)
  ),
  stringsAsFactors = FALSE
)
metrics <- metrics[order(metrics$rmse), , drop = FALSE]
metrics$rank_rmse <- seq_len(nrow(metrics))

message(sprintf("Rows evaluated: %d", length(actual)))
message(sprintf("Data: %s", data_path))
print(metrics)

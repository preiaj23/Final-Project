#!/usr/bin/env Rscript

# Re-score the saved in-sample test split with every trained model and write
# comparable error metrics plus the best-model pointer.

# Resolve this script's path so project-relative paths work from any launch
# directory.
get_script_path <- function() {
  file_arg <- "--file="
  args <- commandArgs(trailingOnly = FALSE)
  match <- grep(file_arg, args)

  if (length(match) > 0) {
    return(normalizePath(sub(file_arg, "", args[match[1]]), mustWork = TRUE))
  }

  normalizePath(getwd(), mustWork = TRUE)
}

# Convert factors and numeric-looking strings into numeric vectors before metric
# calculation or model scoring.
coerce_numeric <- function(x) {
  if (is.factor(x)) {
    x <- as.character(x)
  }
  if (is.character(x)) {
    suppressWarnings(x <- as.numeric(x))
  }
  x
}

# Keep spending predictions in the valid non-negative range.
clip_nonnegative <- function(pred) {
  pmax(pred, 0)
}

# Root mean squared log error is used to rank models because spending is highly
# skewed.
rmsle <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  sqrt(mean((log1p(pred) - log1p(actual))^2))
}

# Standard error metrics are reported alongside RMSLE for interpretation.
rmse <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  sqrt(mean((actual - pred)^2))
}

mse <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  mean((actual - pred)^2)
}

mae <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  mean(abs(actual - pred))
}

# Recreate each model's numeric feature frame using the medians learned during
# training.
prepare_numeric_frame <- function(df, columns, medians) {
  out <- data.frame(row.names = seq_len(nrow(df)))
  for (nm in columns) {
    vals <- coerce_numeric(df[[nm]])
    med <- medians[[nm]]
    if (!is.finite(med)) {
      med <- suppressWarnings(stats::median(vals, na.rm = TRUE))
      if (!is.finite(med)) {
        med <- 0
      }
    }
    vals[is.na(vals)] <- med
    out[[nm]] <- vals
  }
  out
}

# Package all metrics for one model into a single-row data frame.
compute_metrics <- function(actual, pred) {
  data.frame(
    rmsle = rmsle(actual, pred),
    mse = mse(actual, pred),
    rmse = rmse(actual, pred),
    mae = mae(actual, pred),
    stringsAsFactors = FALSE
  )
}

script_path <- get_script_path()
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(project_root, "src", "paths.R"))
source(file.path(project_root, "src", "download_packages.R"))

paths <- build_project_paths(project_root)
ensure_project_dirs(paths)
bootstrap_model_packages(project_root)

if (!file.exists(paths$model_bundle)) {
  stop(
    sprintf("Model bundle not found at %s. Run scripts/train_models.R first.", paths$model_bundle),
    call. = FALSE
  )
}

if (!file.exists(paths$in_sample_test_data)) {
  stop(
    sprintf("In-sample test data not found at %s. Run scripts/train_models.R first.", paths$in_sample_test_data),
    call. = FALSE
  )
}

bundle <- readRDS(paths$model_bundle)
test_df <- utils::read.csv(paths$in_sample_test_data, check.names = FALSE, stringsAsFactors = FALSE)
target_name <- bundle$metadata$target_name

# Validate that the saved test split still contains the target needed for
# scoring.
if (!target_name %in% names(test_df)) {
  stop(sprintf("Target column %s not found in in-sample test data.", target_name), call. = FALSE)
}

actual <- coerce_numeric(test_df[[target_name]])
if (any(!is.finite(actual))) {
  stop("In-sample test target contains non-finite values.", call. = FALSE)
}

# Generate predictions from each saved model family using its training artifacts.
pred_intercept <- clip_nonnegative(stats::predict(bundle$models$intercept, newdata = test_df))

rf_features <- bundle$artifacts$random_forest$features
rf_medians <- bundle$artifacts$random_forest$medians
rf_test <- prepare_numeric_frame(test_df, rf_features, rf_medians)
pred_rf <- clip_nonnegative(stats::predict(bundle$models$random_forest, newdata = rf_test))

xgb_features <- bundle$artifacts$xgboost$features
xgb_medians <- bundle$artifacts$xgboost$medians
xgb_test <- prepare_numeric_frame(test_df, xgb_features, xgb_medians)
dtest <- xgboost::xgb.DMatrix(data = as.matrix(xgb_test))
pred_xgb <- clip_nonnegative(stats::predict(bundle$models$xgboost, newdata = dtest))

spline_features <- bundle$artifacts$piecewise_spline$selected
spline_degree <- bundle$artifacts$piecewise_spline$degree
spline_medians <- bundle$artifacts$piecewise_spline$medians
spline_test <- prepare_numeric_frame(test_df, spline_features, spline_medians)
spline_formula_rhs <- paste(
  vapply(
    spline_features,
    function(nm) sprintf("splines::bs(%s, degree = %d, df = 5)", nm, spline_degree),
    character(1)
  ),
  collapse = " + "
)
spline_formula <- stats::as.formula(sprintf("%s ~ %s", target_name, spline_formula_rhs))
spline_newdata <- cbind(spline_test, setNames(data.frame(actual), target_name))
pred_spline <- clip_nonnegative(stats::predict(bundle$models$piecewise_spline, newdata = spline_newdata))

# Save row-level predictions for residual inspection.
predictions <- data.frame(
  actual = actual,
  pred_intercept = pred_intercept,
  pred_random_forest = pred_rf,
  pred_xgboost = pred_xgb,
  pred_piecewise_spline = pred_spline,
  stringsAsFactors = FALSE
)

# Rank all model families by RMSLE and write the full metric table.
metrics <- rbind(
  cbind(model = "intercept", compute_metrics(actual, pred_intercept)),
  cbind(model = "random_forest", compute_metrics(actual, pred_rf)),
  cbind(model = "xgboost", compute_metrics(actual, pred_xgb)),
  cbind(model = "piecewise_polynomial_spline", compute_metrics(actual, pred_spline))
)
metrics <- metrics[order(metrics$rmsle), , drop = FALSE]
metrics$rank <- seq_len(nrow(metrics))
metrics <- metrics[, c("rank", "model", "rmsle", "rmse", "mse", "mae")]

utils::write.csv(metrics, paths$test_metrics, row.names = FALSE, na = "")
utils::write.csv(predictions, paths$test_predictions, row.names = FALSE, na = "")

best_model <- metrics$model[[1]]
best_model_file <- switch(
  best_model,
  intercept = bundle$model_paths$intercept,
  random_forest = bundle$model_paths$random_forest,
  xgboost = bundle$model_paths$xgboost,
  piecewise_polynomial_spline = bundle$model_paths$piecewise_spline,
  bundle$model_paths$intercept
)

# Later evaluation scripts read this pointer to know which saved model won.
writeLines(best_model_file, con = paths$best_model_pointer, sep = "\n")

message("Model testing complete.")
message(sprintf("Model metrics: %s", paths$test_metrics))
message(sprintf("Model predictions: %s", paths$test_predictions))
message(sprintf("Best model by RMSLE: %s", best_model))
message(sprintf("Best model path pointer: %s", paths$best_model_pointer))

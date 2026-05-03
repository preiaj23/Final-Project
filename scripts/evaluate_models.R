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

coerce_numeric <- function(x) {
  if (is.factor(x)) {
    x <- as.character(x)
  }
  if (is.character(x)) {
    suppressWarnings(x <- as.numeric(x))
  }
  x
}

clip_nonnegative <- function(pred) {
  pmax(pred, 0)
}

rmsle <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  sqrt(mean((log1p(pred) - log1p(actual))^2))
}

rmse <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  sqrt(mean((actual - pred)^2))
}

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

script_path <- get_script_path()
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(project_root, "src", "paths.R"))
source(file.path(project_root, "src", "download_packages.R"))

paths <- build_project_paths(project_root)
ensure_project_dirs(paths)
bootstrap_model_packages(project_root)

cli_args <- commandArgs(trailingOnly = TRUE)
force_xgboost <- length(cli_args) >= 1L && tolower(trimws(cli_args[[1]])) == "xgboost"

if (!file.exists(paths$model_bundle)) {
  stop(sprintf("Model bundle not found at %s. Run training first.", paths$model_bundle), call. = FALSE)
}

if (!force_xgboost && !file.exists(paths$best_model_pointer)) {
  stop(sprintf("Best model path file not found at %s. Run test_models first.", paths$best_model_pointer), call. = FALSE)
}

if (!file.exists(paths$future_out_of_sample_data)) {
  stop(
    sprintf("Future out-of-sample test data not found at %s.", paths$future_out_of_sample_data),
    call. = FALSE
  )
}

bundle <- readRDS(paths$model_bundle)
future_df <- utils::read.csv(paths$future_out_of_sample_data, check.names = FALSE, stringsAsFactors = FALSE)
names(future_df) <- sub("^[^.]+\\.", "", names(future_df))

target_name <- bundle$metadata$target_name
if (!target_name %in% names(future_df)) {
  stop(sprintf("Target column %s missing in future out-of-sample dataset.", target_name), call. = FALSE)
}

actual <- coerce_numeric(future_df[[target_name]])
if (any(!is.finite(actual) | actual < 0)) {
  stop("Out-of-sample target has invalid values; expected non-negative finite target.", call. = FALSE)
}

if (force_xgboost) {
  best_model_key <- "xgboost"
} else {
  best_model_path <- trimws(readLines(paths$best_model_pointer, warn = FALSE)[1])
  if (!nzchar(best_model_path) || !file.exists(best_model_path)) {
    stop("Best model path pointer is missing or points to a non-existent file.", call. = FALSE)
  }

  best_model_key <- switch(
    basename(best_model_path),
    "intercept_model.rds" = "intercept",
    "random_forest_model.rds" = "random_forest",
    "xgboost_model.rds" = "xgboost",
    "piecewise_spline_model.rds" = "piecewise_polynomial_spline",
    NA_character_
  )

  if (is.na(best_model_key)) {
    stop(sprintf("Unrecognized best model file: %s", best_model_path), call. = FALSE)
  }
}

pred <- switch(
  best_model_key,
  intercept = {
    clip_nonnegative(stats::predict(bundle$models$intercept, newdata = future_df))
  },
  random_forest = {
    rf_features <- bundle$artifacts$random_forest$features
    rf_medians <- bundle$artifacts$random_forest$medians
    rf_frame <- prepare_numeric_frame(future_df, rf_features, rf_medians)
    clip_nonnegative(stats::predict(bundle$models$random_forest, newdata = rf_frame))
  },
  xgboost = {
    xgb_features <- bundle$artifacts$xgboost$features
    xgb_medians <- bundle$artifacts$xgboost$medians
    xgb_frame <- prepare_numeric_frame(future_df, xgb_features, xgb_medians)
    dmat <- xgboost::xgb.DMatrix(data = as.matrix(xgb_frame))
    clip_nonnegative(stats::predict(bundle$models$xgboost, newdata = dmat))
  },
  piecewise_polynomial_spline = {
    spline_features <- bundle$artifacts$piecewise_spline$selected
    spline_degree <- bundle$artifacts$piecewise_spline$degree
    spline_medians <- bundle$artifacts$piecewise_spline$medians
    spline_frame <- prepare_numeric_frame(future_df, spline_features, spline_medians)
    spline_rhs <- paste(
      vapply(
        spline_features,
        function(nm) sprintf("splines::bs(%s, degree = %d, df = 5)", nm, spline_degree),
        character(1)
      ),
      collapse = " + "
    )
    spline_formula <- stats::as.formula(sprintf("%s ~ %s", target_name, spline_rhs))
    spline_newdata <- cbind(spline_frame, setNames(data.frame(actual), target_name))
    clip_nonnegative(stats::predict(bundle$models$piecewise_spline, newdata = spline_newdata))
  }
)

score_rmsle <- rmsle(actual, pred)
score_rmse <- rmse(actual, pred)
result <- data.frame(
  model = best_model_key,
  evaluation_dataset = paths$future_out_of_sample_data,
  rmsle = score_rmsle,
  rmse = score_rmse,
  stringsAsFactors = FALSE
)

utils::write.csv(result, paths$evaluate_metrics, row.names = FALSE, na = "")
message(sprintf("Out-of-sample metrics written to: %s", paths$evaluate_metrics))
message(sprintf("Model evaluated: %s", best_model_key))
message(sprintf("RMSLE: %.6f", score_rmsle))
message(sprintf("RMSE: %.6f", score_rmse))

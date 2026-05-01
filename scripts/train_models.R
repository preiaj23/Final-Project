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

impute_with_median <- function(x, fallback = 0) {
  x <- coerce_numeric(x)
  med <- suppressWarnings(stats::median(x, na.rm = TRUE))

  if (!is.finite(med)) {
    med <- fallback
  }

  x[is.na(x)] <- med
  x
}

build_feature_matrix <- function(df, columns, medians = NULL) {
  if (length(columns) == 0) {
    return(list(matrix = matrix(numeric(), nrow = nrow(df), ncol = 0), medians = numeric()))
  }

  out <- matrix(0, nrow = nrow(df), ncol = length(columns))
  colnames(out) <- columns

  if (is.null(medians)) {
    medians <- stats::setNames(rep(NA_real_, length(columns)), columns)
  }

  for (i in seq_along(columns)) {
    nm <- columns[[i]]
    vals <- coerce_numeric(df[[nm]])
    med <- medians[[nm]]

    if (!is.finite(med)) {
      med <- suppressWarnings(stats::median(vals, na.rm = TRUE))
      if (!is.finite(med)) {
        med <- 0
      }
    }

    vals[is.na(vals)] <- med
    out[, i] <- vals
    medians[[nm]] <- med
  }

  list(matrix = out, medians = medians)
}

clip_nonnegative <- function(pred) {
  pmax(pred, 0)
}

rmsle <- function(actual, pred) {
  pred <- clip_nonnegative(pred)
  sqrt(mean((log1p(pred) - log1p(actual))^2))
}

sanitize_level <- function(level) {
  out <- gsub("[^A-Za-z0-9]+", "_", level)
  out <- gsub("^_+|_+$", "", out)
  if (!nzchar(out)) {
    out <- "blank"
  }
  out
}

enforce_low_cardinality_ohe <- function(df, exclude_columns, max_levels = 20L) {
  transformed <- df
  cols <- setdiff(names(transformed), exclude_columns)
  encoded_sources <- character()

  for (col in cols) {
    x <- transformed[[col]]
    if (!(is.character(x) || is.factor(x) || is.logical(x))) {
      next
    }

    x_chr <- as.character(x)
    levels <- sort(unique(x_chr[!is.na(x_chr)]))
    if (length(levels) == 0) {
      transformed[[col]] <- 0
      next
    }

    if (length(levels) <= max_levels) {
      for (lv in levels) {
        encoded_name <- sprintf("%s_%s", col, sanitize_level(lv))
        transformed[[encoded_name]] <- as.integer(!is.na(x_chr) & x_chr == lv)
      }

      if (any(is.na(x_chr))) {
        transformed[[sprintf("%s_NA", col)]] <- as.integer(is.na(x_chr))
      }

      transformed[[col]] <- NULL
      encoded_sources <- c(encoded_sources, col)
    } else {
      transformed[[col]] <- as.numeric(factor(x_chr, levels = levels))
    }
  }

  list(data = transformed, encoded_sources = encoded_sources)
}

prepare_numeric_frame <- function(df, columns, medians = NULL) {
  out <- data.frame(row.names = seq_len(nrow(df)))
  if (is.null(medians)) {
    medians <- stats::setNames(rep(NA_real_, length(columns)), columns)
  }

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
    medians[[nm]] <- med
  }

  list(data = out, medians = medians)
}

cv_rmsle <- function(df, target_name, feature_names, degree, n_folds = 5L, seed = 2026L) {
  if (length(feature_names) == 0) {
    return(Inf)
  }

  set.seed(seed)
  n <- nrow(df)
  fold_id <- sample(rep(seq_len(n_folds), length.out = n))
  fold_scores <- numeric(n_folds)

  rhs <- paste(
    vapply(
      feature_names,
      function(nm) sprintf("splines::bs(%s, degree = %d, df = 5)", nm, degree),
      character(1)
    ),
    collapse = " + "
  )
  form <- stats::as.formula(sprintf("%s ~ %s", target_name, rhs))

  for (f in seq_len(n_folds)) {
    valid_idx <- fold_id == f
    train_df <- df[!valid_idx, , drop = FALSE]
    valid_df <- df[valid_idx, , drop = FALSE]

    fit <- stats::lm(form, data = train_df)
    pred <- stats::predict(fit, newdata = valid_df)
    fold_scores[f] <- rmsle(valid_df[[target_name]], pred)
  }

  mean(fold_scores)
}

forward_select_spline <- function(train_df, target_name, candidates, max_features = 8L, n_folds = 5L) {
  selected <- character()
  remaining <- candidates
  best_cv <- Inf

  while (length(remaining) > 0 && length(selected) < max_features) {
    trial_scores <- lapply(remaining, function(candidate) {
      trial_features <- c(selected, candidate)
      sapply(1:3, function(deg) {
        cv_rmsle(train_df, target_name, trial_features, deg, n_folds = n_folds)
      })
    })

    best_per_feature <- vapply(trial_scores, min, numeric(1))
    best_degree <- vapply(trial_scores, function(scores) which.min(scores), integer(1))
    idx <- which.min(best_per_feature)

    if (best_per_feature[[idx]] + 1e-7 < best_cv) {
      selected <- c(selected, remaining[[idx]])
      best_cv <- best_per_feature[[idx]]
      remaining <- remaining[-idx]
      attr(selected, "degree") <- best_degree[[idx]]
    } else {
      break
    }
  }

  list(
    selected = selected,
    degree = if (length(selected) > 0) attr(selected, "degree") else 1L,
    cv_rmsle = best_cv
  )
}

script_path <- get_script_path()
project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(project_root, "src", "paths.R"))
source(file.path(project_root, "src", "download_packages.R"))

paths <- build_project_paths(project_root)
ensure_project_dirs(paths)
bootstrap_model_packages(project_root)

input_path <- paths$merged_encoded_dataset
if (!file.exists(input_path)) {
  input_path <- paths$merged_standardized_dataset
}

if (!file.exists(input_path)) {
  stop(
    sprintf("Input dataset not found at %s. Run merge/clean scripts first.", input_path),
    call. = FALSE
  )
}

message(sprintf("Reading %s", input_path))
dataset <- utils::read.csv(input_path, check.names = FALSE, stringsAsFactors = FALSE)
names(dataset) <- sub("^[^.]+\\.", "", names(dataset))

target_name <- "TOTEXP"
if (!target_name %in% names(dataset)) {
  stop(
    sprintf("%s was not found. Ensure clean_datasets.R retains TOTEXP.", target_name),
    call. = FALSE
  )
}

dataset[[target_name]] <- coerce_numeric(dataset[[target_name]])
dataset <- dataset[is.finite(dataset[[target_name]]) & dataset[[target_name]] >= 0, , drop = FALSE]

if (nrow(dataset) < 100) {
  stop("Not enough rows after filtering non-finite target values.", call. = FALSE)
}

exclude_columns <- c(
  target_name,
  "DUID",
  "PID",
  "DUPERSID",
  "SOURCE_FILE",
  "DATASET_YEAR"
)

ohe_result <- enforce_low_cardinality_ohe(
  df = dataset,
  exclude_columns = exclude_columns,
  max_levels = 20L
)
dataset <- ohe_result$data

candidate_columns <- setdiff(names(dataset), exclude_columns)

candidate_numeric <- candidate_columns[vapply(dataset[candidate_columns], function(x) {
  x_num <- coerce_numeric(x)
  stats::sd(x_num, na.rm = TRUE) > 0 && mean(is.na(x_num)) < 0.95
}, logical(1))]

if (length(candidate_numeric) < 10) {
  stop("Insufficient numeric candidate predictors after preprocessing.", call. = FALSE)
}

set.seed(2026)
train_idx <- sample.int(nrow(dataset), size = floor(0.8 * nrow(dataset)))
train_df <- dataset[train_idx, , drop = FALSE]
test_df <- dataset[-train_idx, , drop = FALSE]

y_train <- train_df[[target_name]]
y_test <- test_df[[target_name]]

message(sprintf("Training rows: %d", nrow(train_df)))
message(sprintf("Testing rows: %d", nrow(test_df)))

# Intercept-only baseline
intercept_fit <- stats::lm(stats::as.formula(sprintf("%s ~ 1", target_name)), data = train_df)
pred_intercept <- clip_nonnegative(stats::predict(intercept_fit, newdata = test_df))
rmsle_intercept <- rmsle(y_test, pred_intercept)

# Rank predictors by absolute correlation with target on train set for tractability
train_target <- y_train
cor_scores <- vapply(candidate_numeric, function(nm) {
  vals <- coerce_numeric(train_df[[nm]])
  suppressWarnings(abs(stats::cor(vals, train_target, use = "pairwise.complete.obs")))
}, numeric(1))
cor_scores[!is.finite(cor_scores)] <- 0
top_features <- names(sort(cor_scores, decreasing = TRUE))[seq_len(min(80, length(cor_scores)))]

# Random forest
set.seed(2026)
rf_rows <- sample.int(nrow(train_df), size = min(30000L, nrow(train_df)))
rf_train <- train_df[rf_rows, c(top_features, target_name), drop = FALSE]
rf_train_prepped <- prepare_numeric_frame(rf_train, top_features)
rf_train_features <- rf_train_prepped$data
rf_medians <- rf_train_prepped$medians
rf_test_prepped <- prepare_numeric_frame(test_df, top_features, medians = rf_medians)
rf_test <- rf_test_prepped$data
rf_fit <- randomForest::randomForest(
  x = rf_train_features[top_features],
  y = rf_train[[target_name]],
  ntree = 400,
  mtry = max(1, floor(sqrt(length(top_features))))
)
pred_rf <- clip_nonnegative(stats::predict(rf_fit, newdata = rf_test))
rmsle_rf <- rmsle(y_test, pred_rf)

# xgboost
xgb_features <- names(sort(cor_scores, decreasing = TRUE))[seq_len(min(150, length(cor_scores)))]
set.seed(2027)
xgb_rows <- sample.int(nrow(train_df), size = min(50000L, nrow(train_df)))
xgb_train_df <- train_df[xgb_rows, , drop = FALSE]
xgb_train_y <- y_train[xgb_rows]
xgb_train_build <- build_feature_matrix(xgb_train_df, xgb_features)
xgb_test_build <- build_feature_matrix(test_df, xgb_features, medians = xgb_train_build$medians)
dtrain <- xgboost::xgb.DMatrix(data = xgb_train_build$matrix, label = xgb_train_y)
dtest <- xgboost::xgb.DMatrix(data = xgb_test_build$matrix, label = y_test)
xgb_fit <- xgboost::xgb.train(
  params = list(
    objective = "reg:squarederror",
    eval_metric = "rmse",
    eta = 0.05,
    max_depth = 6,
    subsample = 0.8,
    colsample_bytree = 0.8
  ),
  data = dtrain,
  nrounds = 150,
  watchlist = list(train = dtrain, test = dtest),
  verbose = 0
)
pred_xgb <- clip_nonnegative(stats::predict(xgb_fit, newdata = dtest))
rmsle_xgb <- rmsle(y_test, pred_xgb)

# Piecewise polynomial with smoothing splines and 5-fold CV
spline_candidates <- names(sort(cor_scores, decreasing = TRUE))[seq_len(min(12, length(cor_scores)))]
set.seed(2028)
spline_rows <- sample.int(nrow(train_df), size = min(15000L, nrow(train_df)))
spline_train <- train_df[spline_rows, c(spline_candidates, target_name), drop = FALSE]
spline_train_prepped <- prepare_numeric_frame(spline_train, spline_candidates)
spline_train[spline_candidates] <- spline_train_prepped$data
spline_medians <- spline_train_prepped$medians
spline_test_prepped <- prepare_numeric_frame(test_df, spline_candidates, medians = spline_medians)
spline_test <- spline_test_prepped$data

spline_select <- forward_select_spline(
  train_df = spline_train,
  target_name = target_name,
  candidates = spline_candidates,
  max_features = 5L,
  n_folds = 5L
)

if (length(spline_select$selected) == 0) {
  stop("Spline forward selection did not select any features.", call. = FALSE)
}

spline_rhs <- paste(
  vapply(
    spline_select$selected,
    function(nm) sprintf("splines::bs(%s, degree = %d, df = 5)", nm, spline_select$degree),
    character(1)
  ),
  collapse = " + "
)
spline_formula <- stats::as.formula(sprintf("%s ~ %s", target_name, spline_rhs))
spline_fit <- stats::lm(spline_formula, data = spline_train)
pred_spline <- clip_nonnegative(stats::predict(spline_fit, newdata = spline_test))
rmsle_spline <- rmsle(y_test, pred_spline)

compact_test_columns <- unique(c(target_name, top_features, xgb_features, spline_select$selected))
compact_test_columns <- compact_test_columns[compact_test_columns %in% names(test_df)]

utils::write.csv(
  data.frame(row_index = train_idx, stringsAsFactors = FALSE),
  paths$in_sample_train_data,
  row.names = FALSE,
  na = ""
)
utils::write.csv(
  test_df[, compact_test_columns, drop = FALSE],
  paths$in_sample_test_data,
  row.names = FALSE,
  na = ""
)

comparison <- data.frame(
  model = c("intercept", "random_forest", "xgboost", "piecewise_polynomial_spline"),
  rmsle = c(rmsle_intercept, rmsle_rf, rmsle_xgb, rmsle_spline),
  stringsAsFactors = FALSE
)
comparison <- comparison[order(comparison$rmsle), , drop = FALSE]
comparison$rank <- seq_len(nrow(comparison))
comparison <- comparison[, c("rank", "model", "rmsle")]

predictions <- data.frame(
  row_index = as.integer(rownames(test_df)),
  actual = y_test,
  pred_intercept = pred_intercept,
  pred_random_forest = pred_rf,
  pred_xgboost = pred_xgb,
  pred_piecewise_spline = pred_spline,
  stringsAsFactors = FALSE
)

comparison_path <- paths$train_metrics
predictions_path <- paths$test_predictions
spline_meta_path <- paths$spline_selection

utils::write.csv(comparison, comparison_path, row.names = FALSE, na = "")
utils::write.csv(predictions, predictions_path, row.names = FALSE, na = "")
utils::write.csv(
  data.frame(
    selected_feature = spline_select$selected,
    spline_degree = spline_select$degree,
    cv_rmsle = spline_select$cv_rmsle,
    stringsAsFactors = FALSE
  ),
  spline_meta_path,
  row.names = FALSE,
  na = ""
)

intercept_model_path <- file.path(paths$models_dir, "intercept_model.rds")
rf_model_path <- file.path(paths$models_dir, "random_forest_model.rds")
xgb_model_path <- file.path(paths$models_dir, "xgboost_model.rds")
spline_model_path <- file.path(paths$models_dir, "piecewise_spline_model.rds")

saveRDS(intercept_fit, intercept_model_path)
saveRDS(rf_fit, rf_model_path)
saveRDS(xgb_fit, xgb_model_path)
saveRDS(spline_fit, spline_model_path)

bundle <- list(
  metadata = list(
    target_name = target_name,
    split_seed = 2026L,
    one_hot_max_levels = 20L,
    source_dataset = input_path,
    encoded_in_training = ohe_result$encoded_sources
  ),
  models = list(
    intercept = intercept_fit,
    random_forest = rf_fit,
    xgboost = xgb_fit,
    piecewise_spline = spline_fit
  ),
  model_paths = list(
    intercept = intercept_model_path,
    random_forest = rf_model_path,
    xgboost = xgb_model_path,
    piecewise_spline = spline_model_path
  ),
  artifacts = list(
    random_forest = list(features = top_features, medians = rf_medians),
    xgboost = list(features = xgb_features, medians = xgb_train_build$medians),
    piecewise_spline = list(
      selected = spline_select$selected,
      degree = spline_select$degree,
      medians = spline_medians
    )
  ),
  training_comparison = comparison
)

saveRDS(bundle, paths$model_bundle)

message("")
message("Model training complete.")
message(sprintf("Best model: %s (RMSLE %.6f)", comparison$model[[1]], comparison$rmsle[[1]]))
message(sprintf("Comparison file: %s", comparison_path))
message(sprintf("Predictions file: %s", predictions_path))
message(sprintf("Piecewise spline selection: %s", spline_meta_path))
message(sprintf("In-sample train split: %s", paths$in_sample_train_data))
message(sprintf("In-sample test split: %s", paths$in_sample_test_data))
message(sprintf("Model bundle: %s", paths$model_bundle))

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

rmse_raw <- function(actual, pred) {
  sqrt(mean((actual - pred)^2))
}

xgb_best_tree_count <- function(fit) {
  bi <- fit$best_iteration
  if (!is.null(bi) && length(bi) == 1L && is.finite(bi) && bi >= 1L) {
    return(as.integer(bi))
  }
  ni <- fit$niter
  if (!is.null(ni) && length(ni) == 1L && is.finite(ni) && ni >= 1L) {
    return(as.integer(ni))
  }
  1L
}

tune_xgboost_rmse <- function(
  dsub,
  dval,
  y_val,
  param_grid,
  nrounds_max = 800L,
  early_stopping_rounds = 35L,
  seed = 2027L
) {
  results <- data.frame(
    val_rmse = NA_real_,
    best_nrounds = NA_integer_,
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(param_grid))) {
    set.seed(seed + i)
    pg <- param_grid[i, , drop = FALSE]
    params <- list(
      objective = "reg:squarederror",
      eval_metric = "rmse",
      max_depth = as.integer(pg$max_depth),
      eta = as.numeric(pg$eta),
      min_child_weight = as.numeric(pg$min_child_weight),
      subsample = as.numeric(pg$subsample),
      colsample_bytree = as.numeric(pg$colsample_bytree)
    )
    if ("gamma" %in% names(pg)) {
      params$gamma <- as.numeric(pg$gamma)
    }
    if ("reg_alpha" %in% names(pg)) {
      params$reg_alpha <- as.numeric(pg$reg_alpha)
    }
    if ("reg_lambda" %in% names(pg)) {
      params$reg_lambda <- as.numeric(pg$reg_lambda)
    }

    fit <- xgboost::xgb.train(
      params = params,
      data = dsub,
      nrounds = nrounds_max,
      watchlist = list(train = dsub, val = dval),
      early_stopping_rounds = early_stopping_rounds,
      verbose = 0
    )

    bi <- xgb_best_tree_count(fit)
    pred <- stats::predict(fit, newdata = dval, iterationrange = c(1L, bi))
    results$val_rmse[[i]] <- rmse_raw(y_val, clip_nonnegative(pred))
    results$best_nrounds[[i]] <- bi
  }

  cbind(param_grid, results, row.names = NULL)
}

tune_random_forest_rmse <- function(
  x_train,
  y_train,
  x_val,
  y_val,
  mtry_grid,
  ntree = 400L,
  seed = 2026L
) {
  best_rmse <- Inf
  best_mtry <- mtry_grid[[1L]]

  for (mtry in mtry_grid) {
    set.seed(seed)
    fit <- randomForest::randomForest(
      x = x_train,
      y = y_train,
      ntree = ntree,
      mtry = as.integer(mtry)
    )
    pred <- stats::predict(fit, newdata = x_val)
    val_rmse <- rmse_raw(y_val, clip_nonnegative(pred))
    if (val_rmse < best_rmse) {
      best_rmse <- val_rmse
      best_mtry <- as.integer(mtry)
    }
  }

  list(val_rmse = best_rmse, mtry = best_mtry)
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

p_rf <- length(top_features)
mtry_grid <- unique(
  pmin(
    p_rf,
    sort(
      c(
        1L,
        max(1L, floor(sqrt(p_rf))),
        max(1L, floor(p_rf / 3)),
        max(1L, floor(p_rf / 2)),
        p_rf
      )
    )
  )
)

nv_rf <- nrow(rf_train_features)
n_rf_val <- min(
  max(50L, floor(0.2 * nv_rf)),
  nv_rf - max(50L, floor(0.65 * nv_rf))
)
n_rf_val <- max(30L, n_rf_val)
n_rf_val <- min(n_rf_val, nv_rf - 1L)
set.seed(2026)
rf_val_idx <- sample.int(nv_rf, size = n_rf_val)
rf_sub_idx <- setdiff(seq_len(nv_rf), rf_val_idx)

rf_tune <- tune_random_forest_rmse(
  x_train = rf_train_features[rf_sub_idx, top_features, drop = FALSE],
  y_train = rf_train[[target_name]][rf_sub_idx],
  x_val = rf_train_features[rf_val_idx, top_features, drop = FALSE],
  y_val = rf_train[[target_name]][rf_val_idx],
  mtry_grid = mtry_grid,
  ntree = 450L,
  seed = 2026L
)

set.seed(2026)
rf_fit <- randomForest::randomForest(
  x = rf_train_features[top_features],
  y = rf_train[[target_name]],
  ntree = 500L,
  mtry = rf_tune$mtry
)
pred_rf <- clip_nonnegative(stats::predict(rf_fit, newdata = rf_test))
rmsle_rf <- rmsle(y_test, pred_rf)

# xgboost: validation RMSE grid search + early stopping, then refit on full xgb sample
xgb_features <- names(sort(cor_scores, decreasing = TRUE))[seq_len(min(150, length(cor_scores)))]
set.seed(2027)
xgb_rows <- sample.int(nrow(train_df), size = min(50000L, nrow(train_df)))
xgb_train_df <- train_df[xgb_rows, , drop = FALSE]
xgb_train_y <- xgb_train_df[[target_name]]
xgb_train_build <- build_feature_matrix(xgb_train_df, xgb_features)
xgb_test_build <- build_feature_matrix(test_df, xgb_features, medians = xgb_train_build$medians)
dtest <- xgboost::xgb.DMatrix(data = xgb_test_build$matrix, label = y_test)

val_frac <- 0.15
n_xgb <- nrow(xgb_train_df)
n_val <- max(50L, floor(val_frac * n_xgb))
set.seed(2027)
val_idx <- sample.int(n_xgb, size = n_val)
sub_idx <- setdiff(seq_len(n_xgb), val_idx)
if (length(sub_idx) < 100L) {
  stop("XGBoost tuning split produced too few training rows.", call. = FALSE)
}

xgb_sub_df <- xgb_train_df[sub_idx, , drop = FALSE]
xgb_val_df <- xgb_train_df[val_idx, , drop = FALSE]
dsub <- xgboost::xgb.DMatrix(
  data = build_feature_matrix(xgb_sub_df, xgb_features, medians = xgb_train_build$medians)$matrix,
  label = xgb_sub_df[[target_name]]
)
dval <- xgboost::xgb.DMatrix(
  data = build_feature_matrix(xgb_val_df, xgb_features, medians = xgb_train_build$medians)$matrix,
  label = xgb_val_df[[target_name]]
)
dfull <- xgboost::xgb.DMatrix(data = xgb_train_build$matrix, label = xgb_train_y)

xgb_param_space <- expand.grid(
  max_depth = c(4L, 5L, 6L, 7L, 8L, 10L),
  eta = c(0.02, 0.03, 0.05, 0.07, 0.1),
  min_child_weight = c(1, 2, 3, 5, 7, 10),
  subsample = c(0.65, 0.75, 0.85, 0.95, 1),
  colsample_bytree = c(0.65, 0.75, 0.85, 0.95, 1),
  gamma = c(0, 0.1, 0.5),
  reg_alpha = c(0, 0.01, 0.1),
  reg_lambda = c(1, 5, 10),
  stringsAsFactors = FALSE
)
set.seed(2028L)
n_xgb_tune <- min(55L, nrow(xgb_param_space))
xgb_param_grid <- xgb_param_space[sample.int(nrow(xgb_param_space), n_xgb_tune), , drop = FALSE]
rownames(xgb_param_grid) <- NULL

xgb_tune_results <- tune_xgboost_rmse(
  dsub = dsub,
  dval = dval,
  y_val = xgb_val_df[[target_name]],
  param_grid = xgb_param_grid,
  nrounds_max = 1500L,
  early_stopping_rounds = 50L,
  seed = 2027L
)
xgb_tune_results <- xgb_tune_results[order(xgb_tune_results$val_rmse), , drop = FALSE]
xgb_tune_results$rank <- seq_len(nrow(xgb_tune_results))
xgb_tune_path <- file.path(paths$metrics_dir, "xgboost_hyperparameter_tune.csv")
utils::write.csv(xgb_tune_results, xgb_tune_path, row.names = FALSE, na = "")

best_xgb_row <- xgb_tune_results[1, , drop = FALSE]
xgb_final_params <- list(
  objective = "reg:squarederror",
  eval_metric = "rmse",
  max_depth = as.integer(best_xgb_row$max_depth),
  eta = as.numeric(best_xgb_row$eta),
  min_child_weight = as.numeric(best_xgb_row$min_child_weight),
  subsample = as.numeric(best_xgb_row$subsample),
  colsample_bytree = as.numeric(best_xgb_row$colsample_bytree)
)
if ("gamma" %in% names(best_xgb_row)) {
  xgb_final_params$gamma <- as.numeric(best_xgb_row$gamma)
}
if ("reg_alpha" %in% names(best_xgb_row)) {
  xgb_final_params$reg_alpha <- as.numeric(best_xgb_row$reg_alpha)
}
if ("reg_lambda" %in% names(best_xgb_row)) {
  xgb_final_params$reg_lambda <- as.numeric(best_xgb_row$reg_lambda)
}
set.seed(2027)
xgb_fit <- xgboost::xgb.train(
  params = xgb_final_params,
  data = dfull,
  nrounds = as.integer(best_xgb_row$best_nrounds),
  verbose = 0
)
pred_xgb <- clip_nonnegative(
  stats::predict(
    xgb_fit,
    newdata = dtest,
    iterationrange = c(1L, xgb_best_tree_count(xgb_fit))
  )
)
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
  rmse = c(
    rmse_raw(y_test, pred_intercept),
    rmse_raw(y_test, pred_rf),
    rmse_raw(y_test, pred_xgb),
    rmse_raw(y_test, pred_spline)
  ),
  stringsAsFactors = FALSE
)
comparison <- comparison[order(comparison$rmsle), , drop = FALSE]
comparison$rank <- seq_len(nrow(comparison))
comparison <- comparison[, c("rank", "model", "rmsle", "rmse")]

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
    random_forest = list(
      features = top_features,
      medians = rf_medians,
      tuning = list(val_rmse = rf_tune$val_rmse, mtry = rf_tune$mtry)
    ),
    xgboost = list(
      features = xgb_features,
      medians = xgb_train_build$medians,
      tuning = list(
        validation_rmse = as.numeric(best_xgb_row$val_rmse),
        best_nrounds = as.integer(best_xgb_row$best_nrounds),
        max_depth = as.integer(best_xgb_row$max_depth),
        eta = as.numeric(best_xgb_row$eta),
        min_child_weight = as.numeric(best_xgb_row$min_child_weight),
        subsample = as.numeric(best_xgb_row$subsample),
        colsample_bytree = as.numeric(best_xgb_row$colsample_bytree),
        gamma = if ("gamma" %in% names(best_xgb_row)) as.numeric(best_xgb_row$gamma) else NA_real_,
        reg_alpha = if ("reg_alpha" %in% names(best_xgb_row)) as.numeric(best_xgb_row$reg_alpha) else NA_real_,
        reg_lambda = if ("reg_lambda" %in% names(best_xgb_row)) as.numeric(best_xgb_row$reg_lambda) else NA_real_,
        tune_results_csv = xgb_tune_path
      )
    ),
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
best_rmse_row <- comparison[which.min(comparison$rmse), , drop = FALSE]
message(sprintf(
  "Lowest test RMSE: %s (RMSE %.6f)",
  best_rmse_row$model[[1]],
  best_rmse_row$rmse[[1]]
))
message(sprintf("Comparison file: %s", comparison_path))
message(sprintf("Predictions file: %s", predictions_path))
message(sprintf("Piecewise spline selection: %s", spline_meta_path))
message(sprintf("XGBoost hyperparameter search: %s", xgb_tune_path))
message(sprintf("In-sample train split: %s", paths$in_sample_train_data))
message(sprintf("In-sample test split: %s", paths$in_sample_test_data))
message(sprintf("Model bundle: %s", paths$model_bundle))

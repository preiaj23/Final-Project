# Shared path helpers used by the project scripts so every script writes to the
# same data, model, metric, and split locations.

# Resolve the current script location when called with Rscript; fall back to the
# working directory for interactive sessions.
get_script_path <- function() {
  file_arg <- "--file="
  args <- commandArgs(trailingOnly = FALSE)
  match <- grep(file_arg, args)

  if (length(match) > 0) {
    return(normalizePath(sub(file_arg, "", args[match[1]]), mustWork = TRUE))
  }

  normalizePath(getwd(), mustWork = TRUE)
}

# Treat the parent directory of `src/` or `scripts/` as the project root.
get_project_root <- function(script_path = get_script_path()) {
  normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
}

# Build a named list of all input and output paths used across the workflow.
# The Data/data check lets the project work on case-sensitive or case-insensitive
# file systems without changing downstream script code.
build_project_paths <- function(project_root = get_project_root()) {
  data_dir_candidates <- c(file.path(project_root, "Data"), file.path(project_root, "data"))
  existing_data_dirs <- data_dir_candidates[file.exists(data_dir_candidates)]
  data_dir <- if (length(existing_data_dirs) > 0) existing_data_dirs[[1]] else data_dir_candidates[[1]]
  cleaned_dir <- file.path(data_dir, "cleaned")
  split_dir <- file.path(data_dir, "splits")
  future_dir <- file.path(data_dir, "future")
  output_dir <- file.path(project_root, "output")
  models_dir <- file.path(output_dir, "models")
  metrics_dir <- file.path(output_dir, "metrics")

  list(
    project_root = project_root,
    data_dir = data_dir,
    cleaned_dir = cleaned_dir,
    split_dir = split_dir,
    future_dir = future_dir,
    output_dir = output_dir,
    models_dir = models_dir,
    metrics_dir = metrics_dir,
    merged_standardized_dataset = file.path(cleaned_dir, "merged_standardized_dataset.csv"),
    merged_encoded_dataset = file.path(cleaned_dir, "merged_encoded_dataset.csv"),
    encoded_variable_manifest = file.path(cleaned_dir, "encoded_variable_manifest.csv"),
    dropped_variables = file.path(cleaned_dir, "dropped_variables.csv"),
    in_sample_train_data = file.path(split_dir, "in_sample_train_indices.csv"),
    in_sample_test_data = file.path(split_dir, "in_sample_test_compact.csv"),
    future_out_of_sample_data = file.path(future_dir, "future_out_of_sample_test.csv"),
    model_bundle = file.path(models_dir, "trained_model_bundle.rds"),
    best_model_pointer = file.path(models_dir, "best_model_path.txt"),
    train_metrics = file.path(metrics_dir, "train_rmsle_comparison.csv"),
    test_predictions = file.path(metrics_dir, "test_predictions_by_model.csv"),
    spline_selection = file.path(metrics_dir, "piecewise_spline_selection.csv"),
    test_metrics = file.path(metrics_dir, "model_test_metrics.csv"),
    evaluate_metrics = file.path(metrics_dir, "out_of_sample_best_model_rmsle.csv")
  )
}

# Create the directory tree expected by the merge, clean, train, and evaluation
# scripts before they attempt to write files.
ensure_project_dirs <- function(paths) {
  dir.create(paths$data_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(paths$cleaned_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(paths$split_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(paths$future_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(paths$output_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(paths$models_dir, recursive = TRUE, showWarnings = FALSE)
  dir.create(paths$metrics_dir, recursive = TRUE, showWarnings = FALSE)
}

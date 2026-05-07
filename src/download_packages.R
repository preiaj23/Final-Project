# Package setup helpers for scripts that depend on modeling libraries.

# Install any missing CRAN packages into the project-local library and prepend
# that library to `.libPaths()` for the current R session.
bootstrap_packages <- function(package_names, lib_path) {
  dir.create(lib_path, recursive = TRUE, showWarnings = FALSE)
  .libPaths(c(lib_path, .libPaths()))

  missing <- package_names[!vapply(package_names, requireNamespace, logical(1), quietly = TRUE)]

  if (length(missing) > 0) {
    message(sprintf("Installing missing packages into %s: %s", lib_path, paste(missing, collapse = ", ")))
    utils::install.packages(missing, repos = "https://cloud.r-project.org", lib = lib_path)
  }

  still_missing <- package_names[!vapply(package_names, requireNamespace, logical(1), quietly = TRUE)]
  if (length(still_missing) > 0) {
    stop(
      sprintf(
        "Failed to install required package(s): %s. Install manually and retry.",
        paste(still_missing, collapse = ", ")
      ),
      call. = FALSE
    )
  }
}

# Check for a package that should already ship with R or be installed manually.
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

# Ensure the modeling stack is available, adding optional packages for scripts
# that need extra readers such as `readxl`.
bootstrap_model_packages <- function(project_root, extra_packages = character()) {
  local_lib <- file.path(project_root, ".Rlibs")
  required <- unique(c("randomForest", "xgboost", extra_packages))
  bootstrap_packages(required, local_lib)
  ensure_package("splines")
  invisible(local_lib)
}

# Allow this helper file to be run directly as a setup script, while keeping the
# functions source-able by the modeling scripts.
if (sys.nframe() == 0) {
  file_arg <- "--file="
  args <- commandArgs(trailingOnly = FALSE)
  match <- grep(file_arg, args)

  if (length(match) > 0) {
    script_path <- normalizePath(sub(file_arg, "", args[match[1]]), mustWork = TRUE)
    project_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
  } else {
    project_root <- normalizePath(getwd(), mustWork = TRUE)
  }

  lib_path <- bootstrap_model_packages(project_root)
  message(sprintf("Modeling packages are available in %s", lib_path))
}

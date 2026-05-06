# Final-Project

## Data Merge Script

Use `scripts/merge_raw_datasets.R` to read the Excel files in `data/raw`, standardize inconsistent variable names, and combine them into one merged dataset without modifying the raw files.

Run it with:

```sh
Rscript scripts/merge_raw_datasets.R
```

The script writes these files to `data/cleaned`:

- `merged_standardized_dataset.csv`: the combined dataset
- `merge_row_counts.csv`: per-file row counts used in the merge
- `rename_audit.csv`: variables that were renamed during standardization
- `duplicate_name_audit.csv`: any duplicate standardized names that needed review

## Cleaning Script

Use `scripts/clean_datasets.R` after the merge. It **updates `merged_standardized_dataset.csv` in place** (overwrites the file). It:

1. Sets or refreshes the string variable `DATASET_YEAR` (from `DATA_YEAR` and `SOURCE_FILE`).
2. Drops utilization, expenditure, and survey-design variables per the MEPS codebook rules discussed for this project (section 2.5.11-style use/payment blocks and section 4.2 weights: `PERWTF`, `VARSTR`, `VARPSU`, plus `BRR` / `RWT`-style replicate weights if present).

Run it with:

```sh
Rscript scripts/clean_datasets.R
```

Note: `TOTEXP` is retained in the cleaned file for downstream modeling.

The cleaning script also writes an encoded companion file without modifying `merged_standardized_dataset.csv`:

- `data/cleaned/merged_encoded_dataset.csv`: identifier columns first, then continuous variables (numeric, negatives preserved as losses), then full-one-hot dummies for every categorical and binary variable in the MEPS data dictionary.
- `data/cleaned/encoded_variable_manifest.csv`: one row per source variable with its role (`id` / `continuous` / `categorical_mapped` / `categorical_raw` / `high_cardinality_passthrough`) and the list of output columns it produced. 

Encoding rules:

- Every kept column is classified as `id`, `continuous`, or `categorical` (the default). Any column that is not on the ID list and does not match the continuous patterns is treated as categorical.
- Known multiclass / binary variables from the MEPS data dictionary (`REGION`, `MARRYX`, `HIDEG`, `RACETHX`, `INSCOP`, `EMPST##H`, `RTHLTH##`, `MNHLTH##`, `SEX`, `ASTHDX`, `ANYLMI`, `BORNUSA`, `HAVEUS##`, `FILEDR`) use friendly positive-code labels (`Northeast`, `Married`, `Yes`/`No`, etc.); manifest role = `categorical_mapped`.
- All other categorical variables are auto-encoded using their raw integer codes as labels; manifest role = `categorical_raw`.
- Negative codes on any categorical variable map to `INAPPLICABLE` (-1), `PREV_ROUND` (-2), `REFUSED` (-7), `DK` (-8), `TOP_CODED` (-10), `CANNOT_COMPUTE` (-15), with any other negative becoming `NEG_OTHER`. An extra `<VAR>_NA` indicator is added only when the column has `NA` values.
- To keep the output manageable, any categorical column with more than `MAX_CATEGORICAL_CARDINALITY` (default 20) unique non-missing values is kept as a single numeric column instead of being one-hot encoded; manifest role = `high_cardinality_passthrough`.
- Continuous variables (`AGEX`, `TTLPX`, `TOTEXP`, `ADBMI##`, `POVLEV`, `OBTOTV`, `FAMINC`) are coerced to numeric and keep negative values as-is.

As a result, the only columns in `merged_encoded_dataset.csv` that are *not* 0/1 one-hot indicators are:

- `id` columns (identifiers/keys like `DUPERSID`, file/year provenance fields, etc.)
- `continuous` columns (numeric measures kept numeric, including negative values)
- `high_cardinality_passthrough` columns (numeric columns with more than 20 unique values, including some weights and other high-uniqueness numeric variables)

## Modeling Script

Use `scripts/train_models.R` after cleaning to train and compare:

- intercept-only baseline
- random forest
- xgboost
- piecewise polynomial smoothing-spline model with forward selection and 5-fold CV

The script uses an 80/20 in-sample train-test split, clips negative predictions to zero for all models, and ranks models by RMSLE. It reads shared paths from `src/paths.R`, installs modeling dependencies from `src/download_packages.R`, and defensively one-hot encodes any remaining categorical variables that have 20 or fewer categories.

`train_models.R` supports two XGBoost tuning profiles:

- `local` (default): lower-cost search for workstation runs
- `cluster`: larger search/CV settings for higher-resource environments

```sh
Rscript scripts/train_models.R
Rscript scripts/train_models.R cluster
```

XGBoost tuning behavior (latest):

- Hyperparameter configs are ranked by cross-validated RMSLE (with RMSE as tie-breaker).
- Within-fold early stopping is driven by an RMSLE custom metric.
- Final refit rounds are selected by a holdout RMSLE early-stopping pass, then the final model is fit on the full XGBoost training matrix for that selected number of rounds.

Run it with:

```sh
Rscript scripts/train_models.R
```

## Test Models Script

Use `scripts/test_models.R` after training to score all trained models on the in-sample test split and choose the best model by RMSLE.

Run it with:

```sh
Rscript scripts/test_models.R
```

`test_models.R` writes per-model metrics (`rmsle`, `mse`, `rmse`, `mae`) to `output/metrics/model_test_metrics.csv` for bar-charting and writes the best-model file path to `output/models/best_model_path.txt`.

Performance-focused output behavior:

- `train_models.R` now writes compact split artifacts instead of full split datasets:
  - `data/splits/in_sample_train_indices.csv` (row indices only)
  - `data/splits/in_sample_test_compact.csv` (only columns required for model testing)
- This avoids writing very large full-width train/test CSVs from the encoded dataset.

## Evaluate Models Script

Use `scripts/evaluate_models.R` after `test_models.R` to evaluate the selected best model on the future out-of-sample test path (`data/future/future_out_of_sample_test.csv`) using RMSLE.

Run it with:

```sh
Rscript scripts/evaluate_models.R
```

If `data/future/future_out_of_sample_test.csv` is missing, the script now falls back to an Excel file in `Data/future` (prefers `test.xlsx` when present), loads it, and writes a normalized CSV to `data/future/future_out_of_sample_test.csv` for subsequent runs.

Output:

- `output/metrics/out_of_sample_best_model_rmsle.csv`: RMSLE of the selected best model on out-of-sample test data.

## Ad-hoc Test Analysis Script

Use `scripts/test_analysis.R` to evaluate saved models against a provided encoded test file (or default to `Data/future/test.xlsx`).

Run it with:

```sh
Rscript scripts/test_analysis.R
Rscript scripts/test_analysis.R path/to/encoded_test.csv
Rscript scripts/test_analysis.R path/to/encoded_test.csv xgboost
```

## Shared src Utilities

- `src/paths.R`: central path map for cleaned data, in-sample train/test split files, future out-of-sample path (`data/future/future_out_of_sample_test.csv`), and output artifact paths.
- `src/download_packages.R`: centralized package bootstrap for modeling dependencies (`randomForest`, `xgboost`, `splines`) into `.Rlibs`.

## Pipeline Commands

```sh
make clean      # merge + clean/encode
make train      # train and persist models/artifacts
make test       # evaluate trained models and select best by RMSLE
make evaluate   # packages + evaluate current best model on out-of-sample data (no retraining)
make all        # full pipeline: merge -> clean -> train -> test
```

## Session update (May 5, 2026)

This session focused on end-to-end workflow validation and XGBoost improvements:

- Ran `make packages`, `make clean`, `make train`, `make test`, `make evaluate` and fixed pipeline blockers.
- Fixed XGBoost tuning crash and updated tuning to RMSLE-aligned selection.
- Added profile-based XGBoost training (`local`/`cluster`) and more robust tune checkpoint behavior.
- Updated evaluate logic to automatically accept future Excel input when CSV is missing.

Latest local training result (`output/metrics/train_rmsle_comparison.csv`):

- **xgboost**: RMSLE `2.8573975031` (best)
- piecewise polynomial spline: RMSLE `2.9242136793`

Outputs are now split by purpose:

- `output/models/`: model `.rds` files, `trained_model_bundle.rds`, and `best_model_path.txt`
- `output/metrics/`: train comparison, test predictions, spline metadata, cross-model metric table, and out-of-sample best-model RMSLE
- `data/splits/`: `in_sample_train_indices.csv` and `in_sample_test_compact.csv`

## Session update (April 20, 2026)

In this session we extended the pipeline from cleaning into modeling. We kept `TOTEXP` in the cleaned merged file as the prediction target, added `scripts/train_models.R`, and trained four models (intercept baseline, random forest, xgboost, and piecewise polynomial splines with forward selection + 5-fold CV) on an 80/20 train-test split. All model predictions are clipped at zero before RMSLE, outputs are written to `data/cleaned`, and the `Makefile` now includes `model` / `all` targets with local `.Rlibs` package bootstrap support.

### Latest run: columns dropped

After the most recent run of `clean_datasets.R`:

| | Count |
|---|--:|
| Columns before cleaning | 1733 |
| Columns after cleaning | 1466 |
| **Columns dropped** | **267** |

The same list is saved under `data/cleaned/dropped_variables.csv` (one column: `variable`).

### Dropped variable names (267)

```
DVTEXP
DVTMCD
DVTMCR
DVTOFD
DVTOSR
DVTOT
DVTOTH
DVTPRV
DVTPTR
DVTSLF
DVTSTL
DVTTCH
DVTTRI
DVTVA
DVTWCP
ERDEXP
ERDMCD
ERDMCR
ERDOFD
ERDOSR
ERDOTH
ERDPRV
ERDPTR
ERDSLF
ERDSTL
ERDTCH
ERDTRI
ERDVA
ERDWCP
ERFEXP
ERFMCD
ERFMCR
ERFOFD
ERFOSR
ERFOTH
ERFPRV
ERFPTR
ERFSLF
ERFSTL
ERFTCH
ERFTRI
ERFVA
ERFWCP
ERTEXP
ERTMCD
ERTMCR
ERTOFD
ERTOSR
ERTOT
ERTOTH
ERTPRV
ERTPTR
ERTSLF
ERTSTL
ERTTCH
ERTTRI
ERTVA
ERTWCP
HHAEXP
HHAGD
HHAMCD
HHAMCR
HHAOFD
HHAOSR
HHAOTH
HHAPRV
HHAPTR
HHASLF
HHASTL
HHATCH
HHATRI
HHAVA
HHAWCP
HHINDD
HHINFD
HHNEXP
HHNMCD
HHNMCR
HHNOFD
HHNOSR
HHNOTH
HHNPRV
HHNPTR
HHNSLF
HHNSTL
HHNTCH
HHNTRI
HHNVA
HHNWCP
HHTOTD
IPDEXP
IPDIS
IPDMCD
IPDMCR
IPDOFD
IPDOSR
IPDOTH
IPDPRV
IPDPTR
IPDSLF
IPDSTL
IPDTCH
IPDTRI
IPDVA
IPDWCP
IPFEXP
IPFMCD
IPFMCR
IPFOFD
IPFOSR
IPFOTH
IPFPRV
IPFPTR
IPFSLF
IPFSTL
IPFTCH
IPFTRI
IPFVA
IPFWCP
IPNGTD
IPTEXP
IPTMCD
IPTMCR
IPTOFD
IPTOSR
IPTOTH
IPTPRV
IPTPTR
IPTSLF
IPTSTL
IPTTCH
IPTTRI
IPTVA
IPTWCP
OBDEXP
OBDMCD
OBDMCR
OBDOFD
OBDOSR
OBDOTH
OBDPRV
OBDPTR
OBDRV
OBDSLF
OBDSTL
OBDTCH
OBDTRI
OBDVA
OBDWCP
OBTOTV
OBVEXP
OBVMCD
OBVMCR
OBVOFD
OBVOSR
OBVOTH
OBVPRV
OBVPTR
OBVSLF
OBVSTL
OBVTCH
OBVTRI
OBVVA
OBVWCP
OPDEXP
OPDMCD
OPDMCR
OPDOFD
OPDOSR
OPDOTH
OPDPRV
OPDPTR
OPDRV
OPDSLF
OPDSTL
OPDTCH
OPDTRI
OPDVA
OPDWCP
OPFEXP
OPFMCD
OPFMCR
OPFOFD
OPFOSR
OPFOTH
OPFPRV
OPFPTR
OPFSLF
OPFSTL
OPFTCH
OPFTRI
OPFVA
OPFWCP
OPSEXP
OPSMCD
OPSMCR
OPSOFD
OPSOSR
OPSOTH
OPSPRV
OPSPTR
OPSSLF
OPSSTL
OPSTCH
OPSTRI
OPSVA
OPSWCP
OPTEXP
OPTMCD
OPTMCR
OPTOFD
OPTOSR
OPTOTH
OPTOTV
OPTPRV
OPTPTR
OPTSLF
OPTSTL
OPTTCH
OPTTRI
OPTVA
OPTWCP
OPVEXP
OPVMCD
OPVMCR
OPVOFD
OPVOSR
OPVOTH
OPVPRV
OPVPTR
OPVSLF
OPVSTL
OPVTCH
OPVTRI
OPVVA
OPVWCP
PERWTF
RXEXP
RXMCD
RXMCR
RXOFD
RXOSR
RXOTH
RXPRV
RXPTR
RXSLF
RXSTL
RXTOT
RXTRI
RXVA
RXWCP
TOTEXP
TOTMCD
TOTMCR
TOTOFD
TOTOSR
TOTOTH
TOTPRV
TOTPTR
TOTSLF
TOTSTL
TOTTCH
TOTTRI
TOTVA
TOTWCP
VARPSU
VARSTR
```

Notes:

- The raw Excel files in `data/raw` are left unchanged.
- Variables that are clearly the same across years are standardized to a common name in the merge step.
- Variables that appear to be genuinely new in later years are kept as separate columns until dropped by the cleaning rules above.
- Row count is unchanged by cleaning (`126003` rows); only columns are removed and `DATASET_YEAR` is set.

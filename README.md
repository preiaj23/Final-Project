# Final-Project

## Data Merge Script

Use `scripts/merge_raw_datasets.R` to read the Excel files in `Data/raw`, standardize inconsistent variable names, and combine them into one merged dataset without modifying the raw files.

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

The script uses an 80/20 train-test split, clips negative predictions to zero for all models, and ranks models by RMSLE.

Run it with:

```sh
Rscript scripts/train_models.R
```

Package bootstrap helper:

- `train_models.R` auto-bootstraps required modeling packages (`randomForest`, `xgboost`) into local project library `.Rlibs`.
- `make model` and `make all` automatically point `R_LIBS_USER` to that local `.Rlibs` path.

Outputs written to `data/cleaned`:

- `model_rmsle_comparison.csv`
- `model_test_predictions.csv`
- `piecewise_spline_selection.csv`

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

- The raw Excel files in `Data/raw` are left unchanged.
- Variables that are clearly the same across years are standardized to a common name in the merge step.
- Variables that appear to be genuinely new in later years are kept as separate columns until dropped by the cleaning rules above.
- Row count is unchanged by cleaning (`126003` rows); only columns are removed and `DATASET_YEAR` is set.

R_LIBS_USER ?= $(CURDIR)/.Rlibs

.PHONY: packages clean train test evaluate model all

packages:
	R_LIBS_USER="$(R_LIBS_USER)" Rscript src/download_packages.R

clean:
	Rscript scripts/merge_raw_datasets.R && \
	Rscript scripts/clean_datasets.R

train:
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/train_models.R

test:
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/test_models.R

evaluate:
	R_LIBS_USER="$(R_LIBS_USER)" Rscript src/download_packages.R && \
	Rscript scripts/merge_raw_datasets.R && \
	Rscript scripts/clean_datasets.R && \
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/train_models.R && \
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/test_models.R && \
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/evaluate_models.R

model: train

all:
	Rscript scripts/merge_raw_datasets.R && \
	Rscript scripts/clean_datasets.R && \
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/train_models.R && \
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/test_models.R

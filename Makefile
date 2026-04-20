R_LIBS_USER ?= $(CURDIR)/.Rlibs

clean:
	Rscript scripts/merge_raw_datasets.R && \
	Rscript scripts/clean_datasets.R

model:
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/train_models.R

all:
	Rscript scripts/merge_raw_datasets.R && \
	Rscript scripts/clean_datasets.R && \
	R_LIBS_USER="$(R_LIBS_USER)" Rscript scripts/train_models.R

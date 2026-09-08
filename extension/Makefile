# PGXS makefile for the optional, self-hosted extension packaging.
#
#   make && sudo make install && psql -c 'CREATE EXTENSION volvra'
#
# Requires the PostgreSQL server dev package (pg_config on PATH).
EXTENSION   = volvra
DATA        = $(wildcard volvra--*.sql)
PG_CONFIG  ?= pg_config
PGXS       := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Regenerate the extension script from sql/volvra.sql before packaging.
all: generate
generate:
	@./build.sh
.PHONY: generate

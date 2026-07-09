SHELL := /bin/bash
HERE  := $(shell pwd)
PSQL  := /opt/homebrew/opt/postgresql@17/bin/psql -h localhost -p 5434 -U kndb_native
PY    := $(HERE)/.venv/bin/python3

.PHONY: help venv bootstrap correctness throughput results clean

help:
	@echo "Concurrency-safety experiment (pvldb-extension)."
	@echo ""
	@echo "  make -f Makefile venv         create local venv with psycopg 3"
	@echo "  make -f Makefile bootstrap    create kndb_concur DB + apply engine + register slots"
	@echo "  make -f Makefile correctness  run S1..S4 x {READ COMMITTED, SERIALIZABLE}"
	@echo "  make -f Makefile throughput   run the 48-cell throughput sweep"
	@echo "  make -f Makefile results      re-print RESULTS.md summary from disk"
	@echo "  make -f Makefile clean        wipe .venv and results/"

venv: .venv/bin/python3

.venv/bin/python3:
	python3 -m venv .venv
	.venv/bin/pip install --upgrade pip
	.venv/bin/pip install "psycopg[binary]>=3.1"

bootstrap:
	@echo "== bootstrap kndb_concur DB =="
	@$(PSQL) -d kndb_native -f $(HERE)/bootstrap.sql
	@for f in $(HERE)/../../engine/00_extensions.sql $(HERE)/../../engine/01_types.sql \
	          $(HERE)/../../engine/02_facts_schema.sql \
	          $(HERE)/../../engine/03_triggers_epistemic.sql \
	          $(HERE)/../../engine/04_triggers_conflict.sql \
	          $(HERE)/../../engine/05_bitemporal.sql \
	          $(HERE)/../../engine/06_provsql_setup.sql \
	          $(HERE)/../../engine/07_progressive_depth.sql \
	          $(HERE)/../../engine/08_use_permissions.sql; do \
	    echo "  apply $$(basename $$f)"; \
	    $(PSQL) -d kndb_concur -v ON_ERROR_STOP=1 -q -f $$f; \
	done
	@$(PSQL) -d kndb_concur -c "INSERT INTO kndb.slot_kind (attribute, required_kind) VALUES \
	    ('hba1c','MEASURED'), ('ldl','MEASURED'), ('is_diabetic','INFERRED') \
	    ON CONFLICT (attribute) DO UPDATE SET required_kind=EXCLUDED.required_kind;"
	@echo "== concurrency env ready =="

correctness: venv
	@for scen in s1_exclusion s2_lattice s3_r5; do \
	    for iso in "READ COMMITTED" "SERIALIZABLE"; do \
	        echo "=== $$scen @ $$iso ==="; \
	        $(PY) $(HERE)/scenarios/$${scen}.py --iterations 1000 --isolation "$$iso"; \
	    done; \
	done
	@for iso in "READ COMMITTED" "SERIALIZABLE"; do \
	    echo "=== s4_audit @ $$iso ==="; \
	    $(PY) $(HERE)/scenarios/s4_audit.py --iterations 500 --isolation "$$iso"; \
	done

throughput: venv
	@echo "=== throughput sweep (48 cells; expect ~5 min) ==="
	@$(PY) $(HERE)/scenarios/throughput_sweep.py --writes-per-client 1000

results:
	@head -100 RESULTS.md

clean:
	rm -rf .venv results/*.csv results/*.json

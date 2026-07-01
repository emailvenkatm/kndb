SHELL := /bin/bash
DC     := docker compose
PSQL   := $(DC) exec -T kndb-postgres psql -U kndb -d kndb -v ON_ERROR_STOP=1

.PHONY: help up down psql wait test smoke smoke-a smoke-b engine reset demo bench reproduce clean

help:
	@echo "KNDB targets:"
	@echo "  make up          start isolated Postgres + ProvSQL container"
	@echo "  make down        stop containers"
	@echo "  make psql        interactive psql shell"
	@echo "  make wait        block until Postgres is ready"
	@echo "  make smoke       run M0 empirical smoke tests (A + B)"
	@echo "  make engine      apply engine/*.sql to the DB"
	@echo "  make test        run test suite"
	@echo "  make reset       drop + recreate the kndb database"
	@echo "  make demo        run 60-second demo (M5)"
	@echo "  make bench       run benchmark harness (M6)"
	@echo "  make reproduce   full pipeline for paper figures"
	@echo "  make clean       remove containers + volumes (DESTRUCTIVE)"

up:
	$(DC) up -d
	@$(MAKE) --no-print-directory wait

down:
	$(DC) down

wait:
	@echo "waiting for Postgres..."
	@for i in $$(seq 1 60); do \
	  $(DC) exec -T kndb-postgres pg_isready -U kndb -d kndb >/dev/null 2>&1 && echo "ready" && exit 0; \
	  sleep 1; \
	done; \
	echo "Postgres did not become ready in 60s" && exit 1

psql:
	$(DC) exec kndb-postgres psql -U kndb -d kndb

smoke: smoke-a smoke-b

smoke-a:
	@echo "== M0 smoke A: ProvSQL Viterbi + LEFT JOIN monus semantics =="
	$(PSQL) -f /kndb-tests/smoke_a_viterbi_leftjoin.sql

smoke-b:
	@echo "== M0 smoke B: tstzrange GiST EXCLUDE + ProvSQL provsql UUID column =="
	$(PSQL) -f /kndb-tests/smoke_b_gist_provsql.sql

engine:
	@for f in engine/0*.sql; do \
	  echo "== apply $$f =="; \
	  $(PSQL) -f /kndb-$$f || exit 1; \
	done

test:
	@for f in tests/*.sql; do \
	  echo "== test $$f =="; \
	  $(PSQL) -f /kndb-$$f || exit 1; \
	done

reset:
	$(PSQL) -c "DROP SCHEMA IF EXISTS kndb CASCADE; CREATE SCHEMA kndb;"

demo:
	./demo/demo.sh

bench:
	python3 bench/run.py --seeds 10 --config bench/config.yaml --out bench/results/

reproduce: clean up smoke engine test demo bench
	@echo "== reproduction pipeline complete =="

clean:
	$(DC) down -v

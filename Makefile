PY ?= python
DAYS ?= 90
SCALE ?= 1.0

.PHONY: setup landing sim test lint cost render clean

setup:
	$(PY) -m pip install -r requirements-dev.txt
	pre-commit install

landing:         ## write landing files to ./landing
	$(PY) -m generator.ridgeline --out landing --days $(DAYS) --scale $(SCALE)

sim:             ## generate and run the pipeline on DuckDB; prints the summary
	$(PY) -m sim.run --days $(DAYS) --scale $(SCALE)

test:
	$(PY) -m pytest

lint:
	ruff check .
	ruff format --check .
	sqlfluff lint transform

cost:
	$(PY) -m cost.model --env prd

clean:
	rm -rf landing .pytest_cache
	find . -name __pycache__ -type d -prune -exec rm -rf {} +

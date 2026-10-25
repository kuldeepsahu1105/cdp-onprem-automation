PYTHON ?= python3
COST_INVENTORY ?= cost-inputs/inventory.json
COST_PRICES ?= cost-inputs/prices.json
COST_BILLING ?=
COST_OUTPUT_DIR ?= artifacts/cost

.PHONY: cost-report test-cost-report
cost-report:
	$(PYTHON) scripts/cost_report.py report --inventory "$(COST_INVENTORY)" --prices "$(COST_PRICES)" $(if $(COST_BILLING),--billing "$(COST_BILLING)",) --output-dir "$(COST_OUTPUT_DIR)"

test-cost-report:
	$(PYTHON) -m unittest discover -s tests/cost_reporting -p 'test_*.py' -v

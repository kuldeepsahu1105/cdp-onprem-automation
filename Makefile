PYTHON ?= python3
COST_LIVE_COLLECTION ?= true
COST_TERRAFORM_JSON ?= cost-inputs/terraform-show.json
COST_ANSIBLE_JSON ?=
COST_INVENTORY_CONTEXT ?= cost-inputs/inventory-context.json
COST_PRICE_CONTEXT ?= cost-inputs/price-context.json
COST_BILLING_CONTEXT ?= cost-inputs/billing-context.json
COST_MANUAL_PRICES ?=
COST_EVIDENCE_DIR ?= cost-inputs/live
COST_AWS_REGION ?=
COST_INVENTORY ?= cost-inputs/inventory.json
COST_PRICES ?= cost-inputs/prices.json
COST_BILLING ?=
COST_OUTPUT_DIR ?= artifacts/cost

.PHONY: cost-report test-cost-report
ifeq ($(COST_LIVE_COLLECTION),true)
cost-report:
	$(PYTHON) scripts/cost_report.py live-report $(if $(COST_ANSIBLE_JSON),--ansible-json "$(COST_ANSIBLE_JSON)",--terraform-json "$(COST_TERRAFORM_JSON)") --inventory-context "$(COST_INVENTORY_CONTEXT)" --price-context "$(COST_PRICE_CONTEXT)" --billing-context "$(COST_BILLING_CONTEXT)" $(if $(COST_MANUAL_PRICES),--prices "$(COST_MANUAL_PRICES)",) $(if $(COST_BILLING),--billing "$(COST_BILLING)",) $(if $(COST_AWS_REGION),--aws-region "$(COST_AWS_REGION)",) --evidence-dir "$(COST_EVIDENCE_DIR)" --output-dir "$(COST_OUTPUT_DIR)"
else ifeq ($(COST_LIVE_COLLECTION),false)
cost-report:
	$(PYTHON) scripts/cost_report.py report --inventory "$(COST_INVENTORY)" --prices "$(COST_PRICES)" $(if $(COST_BILLING),--billing "$(COST_BILLING)",) --output-dir "$(COST_OUTPUT_DIR)"
else
$(error COST_LIVE_COLLECTION must be true or false)
endif

test-cost-report:
	$(PYTHON) -m unittest discover -s tests/cost_reporting -p 'test_*.py' -v

import copy
import csv
import io
import json
import subprocess
import sys
import tempfile
import unittest
from decimal import Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))
import cost_reporting as cost

FIXTURES = Path(__file__).parent / "fixtures"
CLI = ROOT / "scripts" / "cost_report.py"


class CostReportingTests(unittest.TestCase):
    def setUp(self):
        self.context = cost.load(FIXTURES / "context.json")
        self.prices = cost.load(FIXTURES / "prices.json")
        self.inventory = cost.adapt_inventory(
            cost.load(FIXTURES / "terraform-show.json"), self.context, "terraform")
        self.billing = cost.adapt_cur(FIXTURES / "cur.csv", cost.load(FIXTURES / "billing-context.json"))

    def report(self):
        return cost.build_report(self.inventory, self.prices, self.billing)

    def test_estimates_quantities_decimal_and_coverage(self):
        report = self.report()
        lines = report["estimates"]["lines"]
        self.assertEqual([x["amount"] for x in lines], ["2.96", "0.33", None])
        self.assertEqual(lines[1]["quantity"], 100)
        self.assertEqual(lines[0]["hours"], "24")
        summary = report["estimates"]["summaries"][0]
        self.assertEqual(summary["priced_subtotal"], "3.29")
        self.assertIsNone(summary["total"])
        self.assertEqual(summary["coverage_percent"], "66.67")
        self.assertEqual(report["schema_version"], 1)
        self.assertFalse(report["coverage"]["inventory_complete"])

    def test_actuals_separate_credits_and_unavailable(self):
        report = self.report()
        self.assertEqual([x["amount"] for x in report["actuals"]["lines"]], ["12.35", "-2.01"])
        summary = report["actuals"]["summaries"][0]
        self.assertEqual(summary["billed_subtotal"], "10.34")
        self.assertIsNone(summary["total"])
        self.assertEqual(report["actuals"]["lines"][1]["resource_id"], "unattributed")
        absent = cost.build_report(self.inventory, self.prices)
        self.assertEqual(absent["actuals"]["status"], "unavailable")
        self.billing["lines"] = []
        self.assertEqual(self.report()["actuals"]["status"], "unavailable")
        self.assertEqual(self.report()["actuals"]["summaries"], [])

    def test_completed_total_is_listed_scope_only(self):
        self.inventory["resources"].pop()
        summary = self.report()["estimates"]["summaries"][0]
        self.assertEqual(summary["total"], "3.29")
        self.assertEqual(summary["coverage_percent"], "100.00")
        self.assertEqual(summary["total_scope"], "listed inventory components only")

    def test_cent_rounding_sum_is_displayed_line_sum(self):
        self.inventory["resources"] = self.inventory["resources"][:1]
        row = self.inventory["resources"][0]
        row["hours"] = "1"
        self.prices["rates"][0]["amount"] = "0.005"
        duplicate = {**row, "resource_id": "other", "cost_pool": "other"}
        self.inventory["resources"].append(duplicate)
        report = self.report()
        self.assertEqual([x["amount"] for x in report["estimates"]["lines"]], ["0.01", "0.01"])
        self.assertEqual(report["estimates"]["summaries"][0]["total"], "0.02")

    def test_missing_rate_and_unknown_quantity_are_not_zero(self):
        self.prices["rates"] = []
        report = self.report()
        self.assertTrue(all(x["amount"] is None for x in report["estimates"]["lines"]))
        self.assertEqual(report["estimates"]["summaries"][0]["priced_subtotal"], "0.00")
        self.assertIsNone(report["estimates"]["summaries"][0]["total"])
        self.prices = cost.load(FIXTURES / "prices.json")
        self.inventory["resources"][0]["quantity"] = None
        self.assertIsNone(self.report()["estimates"]["lines"][0]["amount"])

    def test_bad_resource_values(self):
        for field, value in (("quantity", "-1"), ("quantity", "NaN"), ("hours", "25"),
                             ("hours", 0.5), ("allocation", "1.1"), ("quantity", True),
                             ("currency", "usd"), ("state", "requested"), ("owner", ""),
                             ("as_of", "2026-10-01"), ("scope", "auto")):
            with self.subTest(field=field, value=value):
                inventory = copy.deepcopy(self.inventory)
                inventory["resources"][0][field] = value
                with self.assertRaises(cost.InputError):
                    cost.build_report(inventory, self.prices)

    def test_invalid_prices(self):
        for field, value in (("amount", "-1"), ("amount", "Infinity"),
                             ("unit_hours", "0"), ("basis", "operator_rate"),
                             ("source", ""), ("as_of", "yesterday")):
            with self.subTest(field=field):
                prices = copy.deepcopy(self.prices)
                prices["rates"][0][field] = value
                with self.assertRaises(cost.InputError):
                    cost.build_report(self.inventory, prices)
        self.prices["rates"].append(self.prices["rates"][0])
        with self.assertRaisesRegex(cost.InputError, "ambiguous"):
            self.report()

    def test_duplicates_and_shared_pools(self):
        self.inventory["resources"].append(copy.deepcopy(self.inventory["resources"][0]))
        with self.assertRaisesRegex(cost.InputError, "duplicate"):
            self.report()
        row = self.inventory["resources"].pop()
        row["resource_id"] = "alias"
        self.inventory["resources"].append(row)
        with self.assertRaisesRegex(cost.InputError, "double counting"):
            self.report()
        for resource in (row, self.inventory["resources"][0]):
            resource.update(scope="shared", allocation="0.5", allocation_basis="half shared host")
        report = self.report()
        self.assertEqual(report["estimates"]["lines"][0]["amount"], "1.48")
        row["quantity"] = "2"
        with self.assertRaisesRegex(cost.InputError, "inconsistent shared"):
            self.report()

    def test_mixed_currencies_are_separate_and_not_converted(self):
        row = copy.deepcopy(self.inventory["resources"][0])
        row.update(currency="EUR", resource_id="euro", cost_pool="euro")
        self.inventory["resources"].append(row)
        rate = {**self.prices["rates"][0], "currency": "EUR", "amount": "0.25"}
        self.prices["rates"].append(rate)
        summaries = self.report()["estimates"]["summaries"]
        self.assertEqual([x["currency"] for x in summaries], ["EUR", "USD"])
        self.assertEqual(summaries[0]["total"], "6.00")
        self.billing["lines"].append({**self.billing["lines"][0], "line_id": "eur", "currency": "EUR"})
        self.assertEqual(len(self.report()["actuals"]["summaries"]), 2)

    def test_billing_duplicate_metric_period_errors(self):
        for mutate in ("duplicate", "metric", "outside", "overlap"):
            billing = copy.deepcopy(self.billing)
            if mutate == "duplicate":
                billing["lines"].append(billing["lines"][0])
            elif mutate == "metric":
                billing["lines"][0]["metric"] = "BlendedCost"
            elif mutate == "outside":
                billing["lines"][0]["period"]["start"] = "2026-09-01T00:00:00Z"
            else:
                billing["lines"][1]["period"]["start"] = "2026-10-01T12:00:00Z"
            with self.subTest(mutate=mutate), self.assertRaises(cost.InputError):
                cost.build_report(self.inventory, self.prices, billing)

    def test_disjoint_billing_periods_are_separate(self):
        self.billing["metadata"]["period"]["end"] = "2026-10-03T00:00:00Z"
        self.billing["lines"][1]["period"] = {"start": "2026-10-02T00:00:00Z", "end": "2026-10-03T00:00:00Z"}
        self.assertEqual(len(self.report()["actuals"]["summaries"]), 2)

    def test_period_and_version_validation(self):
        self.inventory["metadata"]["period"]["end"] = "2026-09-01T00:00:00Z"
        with self.assertRaises(cost.InputError):
            self.report()
        self.inventory["schema_version"] = True
        with self.assertRaises(cost.InputError):
            self.report()

    def test_ansible_dedup_and_baremetal_capex_not_cloud(self):
        context = copy.deepcopy(self.context)
        override = {"resource_id": "asset-01", "provider": "baremetal", "sku": "asset-class",
                    "unit": "host-lifetime"}
        context["overrides"] = {"worker": override, "worker-alias": override}
        inventory = cost.adapt_inventory(cost.load(FIXTURES / "ansible-inventory.json"), context, "ansible")
        self.assertEqual(len(inventory["resources"]), 1)
        rates = {"schema_version": 1, "rates": [{
            **self.prices["rates"][0], "provider": "baremetal", "sku": "asset-class",
            "unit": "host-lifetime", "basis": "capex_allocation", "amount": "10000",
            "unit_hours": "24000", "source": "synthetic net capex/lifetime test",
        }]}
        report = cost.build_report(inventory, rates)
        self.assertEqual(report["estimates"]["summaries"][0]["total"], "10.00")
        rates["rates"][0]["basis"] = "cloud_price"
        with self.assertRaises(cost.InputError):
            cost.build_report(inventory, rates)
        context["overrides"]["worker-alias"] = {**override, "sku": "different"}
        with self.assertRaisesRegex(cost.InputError, "conflicting host aliases"):
            cost.adapt_inventory(cost.load(FIXTURES / "ansible-inventory.json"), context, "ansible")

    def test_nutanix_vm_allocation(self):
        inventory = cost.adapt_inventory(cost.load(FIXTURES / "nutanix-show.json"), self.context, "terraform")
        rates = {"schema_version": 1, "rates": [{
            **self.prices["rates"][0], "provider": "nutanix", "sku": "nutanix-vm",
            "unit": "vm-hour", "basis": "operator_rate", "amount": "0.25",
        }]}
        report = cost.build_report(inventory, rates)
        self.assertEqual(report["resources"][0]["state"], "deployed")
        self.assertEqual(report["estimates"]["summaries"][0]["total"], "6.00")

    def test_terraform_unsupported_incomplete_plan_and_output(self):
        raw = cost.load(FIXTURES / "terraform-show.json")
        raw["complete"] = False
        with self.assertRaises(cost.InputError):
            cost.adapt_inventory(raw, self.context, "terraform")
        with self.assertRaises(cost.InputError):
            cost.adapt_inventory({"public_ips": {"value": {}}}, self.context, "terraform")
        self.context["overrides"] = {"typo": {}}
        with self.assertRaisesRegex(cost.InputError, "unused context"):
            cost.adapt_inventory(cost.load(FIXTURES / "terraform-show.json"), self.context, "terraform")

    def test_terraform_volume_identity_avoids_double_count(self):
        raw = cost.load(FIXTURES / "terraform-show.json")
        resources = raw["planned_values"]["root_module"]["child_modules"][0]["resources"]
        resources[0]["values"]["root_block_device"][0]["volume_id"] = "vol-01"
        resources.append({"address": "aws_ebs_volume.duplicate", "type": "aws_ebs_volume", "mode": "managed",
                          "values": {"id": "vol-01", "type": "gp3", "size": 100}})
        inventory = cost.adapt_inventory(raw, self.context, "terraform")
        with self.assertRaisesRegex(cost.InputError, "double counting"):
            cost.build_report(inventory, self.prices)

    def test_provider_price_export_and_cli(self):
        raw, context = cost.load(FIXTURES / "aws-price-list.json"), cost.load(FIXTURES / "price-context.json")
        prices = cost.adapt_aws_prices(raw, context)
        report = cost.build_report(self.inventory, prices)
        rate = report["estimates"]["lines"][0]["rate"]
        self.assertEqual(rate["amount"], "0.12345")
        self.assertEqual(rate["attributes"]["operatingSystem"], "Linux")
        self.assertEqual(rate["effective_date"], "2026-10-01T00:00:00Z")
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "prices.json"
            result = self.run_cli("pricing", "--aws-price-list", FIXTURES / "aws-price-list.json",
                                  "--context", FIXTURES / "price-context.json", "--output", output)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(cost.load(output)["rates"][0]["input_files"]), 2)

    def test_provider_price_export_rejects_guesswork(self):
        for field, value in (("provider_sku", "missing"), ("rate_code", "missing"),
                             ("region", "different-region"), ("provider_unit", "GB-Mo"), ("currency", "EUR"),
                             ("unit", "GiB-month")):
            raw, context = cost.load(FIXTURES / "aws-price-list.json"), cost.load(FIXTURES / "price-context.json")
            context["selections"][0][field] = value
            with self.subTest(field=field), self.assertRaises(cost.InputError):
                cost.adapt_aws_prices(raw, context)
        for field, value in (("beginRange", "10"), ("endRange", "100"), ("appliesTo", ["conditional"])):
            raw, context = cost.load(FIXTURES / "aws-price-list.json"), cost.load(FIXTURES / "price-context.json")
            raw["terms"]["OnDemand"]["SYNTHETIC-SKU"]["SYNTHETIC-TERM"]["priceDimensions"]["SYNTHETIC-RATE"][field] = value
            with self.subTest(field=field), self.assertRaises(cost.InputError):
                cost.adapt_aws_prices(raw, context)

    def test_arn_context_and_mixed_state_rejected(self):
        raw = cost.load(FIXTURES / "terraform-show.json")
        resource = raw["planned_values"]["root_module"]["child_modules"][0]["resources"][0]
        resource["values"]["arn"] = "arn:aws:ec2:other-region:other-account:instance/i-01"
        with self.assertRaisesRegex(cost.InputError, "contradicts Terraform ARN"):
            cost.adapt_inventory(raw, self.context, "terraform")
        self.inventory["resources"][0]["state"] = "deployed"
        with self.assertRaisesRegex(cost.InputError, "planned and deployed"):
            self.report()

    def test_rate_validity_and_hourly_divisors(self):
        for field, value in (("effective_date", "2026-10-01T12:00:00Z"), ("valid_until", "2026-10-01T12:00:00Z")):
            prices = copy.deepcopy(self.prices)
            prices["rates"][0][field] = value
            report = cost.build_report(self.inventory, prices)
            self.assertIsNone(report["estimates"]["lines"][0]["amount"])
            self.assertTrue(any("validity" in warning for warning in report["warnings"]))
        self.prices["rates"][0]["unit_hours"] = "730"
        with self.assertRaisesRegex(cost.InputError, "hourly unit"):
            self.report()

    def test_cloud_and_operator_totals_stay_distinct(self):
        row = copy.deepcopy(self.inventory["resources"][0])
        row.update(provider="baremetal", resource_id="asset", cost_pool="asset", sku="host", unit="host-hour")
        self.inventory["resources"].append(row)
        self.prices["rates"].append({**self.prices["rates"][0], "provider": "baremetal",
                                     "sku": "host", "unit": "host-hour", "basis": "operator_rate"})
        summaries = self.report()["estimates"]["summaries"]
        self.assertEqual([s["provider"] for s in summaries], ["aws", "baremetal"])
        self.assertEqual([s["pricing_model"] for s in summaries], ["cloud_price", "operator_supplied"])

    def test_node_role_counts_specs_and_rollups_reconcile(self):
        raw = cost.load(FIXTURES / "terraform-show.json")
        resources = raw["planned_values"]["root_module"]["child_modules"][0]["resources"]
        resources[0]["values"].update(tags={"Group": "base-workers"},
                                       cpu_options=[{"core_count": 2, "threads_per_core": 2}])
        second = copy.deepcopy(resources[0])
        second["address"] = second["address"].replace("worker-1", "worker-2")
        resources.append(second)
        inventory = cost.adapt_inventory(raw, self.context, "terraform")
        report = cost.build_report(inventory, self.prices)
        nodes, groups = report["estimates"]["nodes"], report["estimates"]["groups"]
        self.assertEqual(len(nodes), 2)
        self.assertTrue(all(n["specs"]["vcpu"] == "4" and n["specs"]["memory_mib"] is None for n in nodes))
        self.assertTrue(all(n["total"] == "3.29" for n in nodes))
        workers = next(g for g in groups if g["role"] == "base-workers")
        self.assertEqual(workers["node_count"], 2)
        self.assertEqual(workers["effective_node_count"], "2")
        self.assertEqual(workers["total"], "6.58")
        self.assertEqual(workers["quantities"][0]["allocated_quantity"], "2")
        self.assertEqual(workers["quantities"][1]["allocated_quantity"], "200")
        self.assertEqual(sum(Decimal(g["priced_subtotal"]) for g in groups), Decimal("6.58"))
        disk = next(r for r in report["estimates"]["lines"] if r["component"] == "root")
        self.assertEqual(disk["specs"]["disk"]["size_gib"], 100)
        ledger = cost.flat_rows(report)
        self.assertEqual(len([r for r in ledger if r["kind"] == "node"]), 2)
        self.assertIn("GROUP USAGE", cost.render_txt(report, ledger))

    def test_shared_node_distinct_count_and_cross_provider_pools(self):
        self.inventory["resources"] = self.inventory["resources"][:1]
        node = self.inventory["resources"][0]
        node.update(scope="shared", allocation="0.5", allocation_basis="equal tenants")
        other = {**node, "owner": "second-project"}
        self.inventory["resources"].append(other)
        report = self.report()
        self.assertEqual(report["estimates"]["summaries"][0]["node_count"], 1)
        self.assertEqual(report["estimates"]["summaries"][0]["effective_node_count"], "1.0")
        self.assertEqual(len(report["estimates"]["groups"]), 2)
        other["provider"] = "baremetal"
        with self.assertRaisesRegex(cost.InputError, "inconsistent shared"):
            self.report()

    def test_inventory_specs_not_guessed(self):
        inventory = cost.adapt_inventory(cost.load(FIXTURES / "nutanix-show.json"), self.context, "terraform")
        self.assertEqual(inventory["resources"][0]["specs"]["vcpu"], "2")
        self.assertEqual(inventory["resources"][0]["specs"]["memory_mib"], 1024)
        raw = cost.load(FIXTURES / "ansible-inventory.json")
        raw["_meta"]["hostvars"]["worker"].update(ansible_processor_vcpus=16, ansible_memtotal_mb=65536)
        context = copy.deepcopy(self.context)
        override = {"resource_id": "asset", "provider": "baremetal", "sku": "host", "unit": "host-hour", "role": "worker"}
        context["overrides"] = {"worker": override, "worker-alias": override}
        inventory = cost.adapt_inventory(raw, context, "ansible")
        self.assertEqual(inventory["resources"][0]["specs"]["vcpu"], 16)
        self.assertEqual(inventory["resources"][0]["specs"]["memory_mib"], 65536)
        self.assertEqual(inventory["resources"][0]["role"], "worker")

    def test_network_base_quantities_rates_and_attributes(self):
        raw = cost.load(FIXTURES / "terraform-show.json")
        resources = raw["planned_values"]["root_module"]["child_modules"][0]["resources"]
        resources[:] = [
            {"address": "aws_nat_gateway.nat", "mode": "managed", "type": "aws_nat_gateway",
             "values": {"id": "nat-01", "connectivity_type": "public", "tags": {"Group": "network"}}},
            {"address": "aws_lb.app", "mode": "managed", "type": "aws_lb",
             "values": {"id": "lb-01", "load_balancer_type": "application", "internal": False,
                        "tags": {"Group": "network"}}},
            {"address": "aws_eip.address", "mode": "managed", "type": "aws_eip",
             "values": {"id": "eipalloc-01", "domain": "vpc", "tags": {"Group": "network"}}},
        ]
        for resource in resources:
            self.prices["rates"].append({
                **self.prices["rates"][0], "sku": resource["type"], "unit": "resource-hour", "amount": "0.125"})
        inventory = cost.adapt_inventory(raw, self.context, "terraform")
        report = cost.build_report(inventory, self.prices)
        self.assertEqual([r["amount"] for r in report["estimates"]["lines"]], ["3.00"] * 3)
        group = report["estimates"]["groups"][0]
        self.assertEqual((group["node_count"], group["resource_count"], group["total"]), (0, 3, "9.00"))
        self.assertEqual(group["quantities"][0]["allocated_quantity"], "1")
        self.assertEqual(inventory["resources"][0]["specs"]["attributes"]["connectivity_type"], "public")
        self.assertEqual(inventory["resources"][1]["specs"]["attributes"]["load_balancer_type"], "application")

    def test_malformed_export_shapes_fail_cleanly(self):
        for raw in ([], {"values": {"root_module": []}},
                    {"values": {"root_module": {"resources": [1]}}}):
            with self.subTest(raw=raw), self.assertRaises(cost.InputError):
                cost.adapt_inventory(raw, self.context, "terraform")

    def test_terraform_premium_gp3_and_relationship_exclusion(self):
        raw = cost.load(FIXTURES / "terraform-show.json")
        resources = raw["planned_values"]["root_module"]["child_modules"][0]["resources"]
        resources[0]["values"]["root_block_device"][0].update(iops=4000, throughput=250)
        resources.append({"address": "aws_eip_association.link", "mode": "managed",
                          "type": "aws_eip_association", "values": {}})
        inventory = cost.adapt_inventory(raw, self.context, "terraform")
        premiums = [r for r in inventory["resources"] if r["sku"].startswith("gp3-")]
        self.assertEqual([r["quantity"] for r in premiums], ["1000", "125"])
        self.assertFalse(any(r["sku"] == "aws_eip_association" for r in inventory["resources"]))

    def test_billing_complete_only_in_declared_scope(self):
        self.billing["metadata"]["completeness"] = "complete"
        summary = self.report()["actuals"]["summaries"][0]
        self.assertEqual(summary["total"], "10.34")
        self.assertIn("test project", summary["scope"])

    def test_component_override_can_correct_default_account(self):
        raw = cost.load(FIXTURES / "terraform-show.json")
        resource = raw["planned_values"]["root_module"]["child_modules"][0]["resources"][0]
        resource["values"]["arn"] = "arn:aws:ec2:fixture-region:actual-account:instance/i-01"
        self.context["overrides"] = {
            resource["address"] + suffix: {"account": "actual-account"} for suffix in ("#compute", "#root")}
        inventory = cost.adapt_inventory(raw, self.context, "terraform")
        self.assertEqual(inventory["resources"][0]["account"], "actual-account")

    def test_allocation_provenance_and_empty_inventory(self):
        self.inventory["resources"][0].update(scope="shared", allocation="0.5")
        with self.assertRaisesRegex(cost.InputError, "allocation_basis"):
            self.report()
        self.inventory["resources"] = []
        report = self.report()
        self.assertEqual(report["estimates"]["summaries"], [])
        self.assertTrue(any("Inventory is empty" in x for x in report["warnings"]))

    def test_malformed_cur_and_no_input_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cur = root / "cur.csv"
            cur.write_text("wrong,columns\n1,2\n")
            with self.assertRaisesRegex(cost.InputError, "CUR missing columns"):
                cost.adapt_cur(cur, cost.load(FIXTURES / "billing-context.json"))
            inventory = root / "cost-report.json"
            cost.write_json(inventory, self.inventory)
            before = inventory.read_bytes()
            result = self.run_cli("report", "--inventory", inventory, "--prices", FIXTURES / "prices.json",
                                  "--output-dir", root)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(inventory.read_bytes(), before)
            self.assertFalse((root / "cost-report.csv").exists())

    def test_ansible_cli_and_make_entrypoint(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            context = copy.deepcopy(self.context)
            override = {"resource_id": "asset01", "provider": "baremetal", "sku": "site-host", "unit": "host-hour"}
            context["overrides"] = {"worker": override, "worker-alias": override}
            cost.write_json(root / "context.json", context)
            result = self.run_cli("inventory", "--ansible-json", FIXTURES / "ansible-inventory.json",
                                  "--context", root / "context.json", "--output", root / "inventory.json")
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run(["make", "cost-report", f"PYTHON={sys.executable}",
                                     f"COST_INVENTORY={root / 'inventory.json'}",
                                     f"COST_PRICES={FIXTURES / 'prices.json'}",
                                     f"COST_OUTPUT_DIR={root / 'reports'}"], cwd=ROOT, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            report = cost.load(root / "reports" / "cost-report.json")
            self.assertIsNone(report["estimates"]["summaries"][0]["total"])
            self.assertEqual(report["actuals"]["status"], "unavailable")

    def test_txt_csv_json_have_identical_ledger_and_totals(self):
        report = self.report()
        ledger = cost.flat_rows(report)
        csv_rows = list(csv.DictReader(io.StringIO(cost.render_csv(ledger))))
        self.assertEqual(len(csv_rows), len(ledger))
        for actual, expected in zip(csv_rows, ledger):
            for key, value in expected.items():
                self.assertEqual(actual[key], cost.cell(value))
        txt = cost.render_txt(report, ledger)
        txt_rows = [json.loads(line) for line in txt.splitlines() if line.startswith("{")]
        self.assertEqual(txt_rows, ledger)
        for section, field in (("estimates", "priced_subtotal"), ("actuals", "billed_subtotal")):
            total = sum((Decimal(row["amount"]) for row in report[section]["lines"]
                         if row["amount"] is not None), Decimal(0))
            self.assertEqual(total, Decimal(report[section]["summaries"][0][field]))

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(CLI), *map(str, args)], cwd=ROOT,
                              text=True, capture_output=True)

    def test_real_cli_all_adapters_and_formats(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            inventory, billing = root / "inventory.json", root / "billing.json"
            result = self.run_cli("inventory", "--terraform-json", FIXTURES / "terraform-show.json",
                                  "--context", FIXTURES / "context.json", "--output", inventory)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.run_cli("billing", "--aws-cur", FIXTURES / "cur.csv",
                                  "--context", FIXTURES / "billing-context.json", "--output", billing)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.run_cli("report", "--inventory", inventory, "--prices", FIXTURES / "prices.json",
                                  "--billing", billing, "--output-dir", root / "reports")
            self.assertEqual(result.returncode, 0, result.stderr)
            report = cost.load(root / "reports" / "cost-report.json")
            ledger = cost.flat_rows(report)
            self.assertEqual((root / "reports" / "cost-report.csv").read_text(), cost.render_csv(ledger).replace("\r\n", "\n"))
            self.assertEqual((root / "reports" / "cost-report.txt").read_text(), cost.render_txt(report, ledger))
            self.assertEqual(len(report["metadata"]["input_files"]), 3)
            self.assertTrue(all(len(x["sha256"]) == 64 for x in report["metadata"]["input_files"]))

    def test_cli_errors_no_success_artifacts_and_duplicate_json_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bad = root / "bad.json"
            bad.write_text('{"schema_version":1,"schema_version":1}')
            result = self.run_cli("report", "--inventory", bad, "--prices", FIXTURES / "prices.json",
                                  "--output-dir", root / "reports")
            self.assertEqual(result.returncode, 2)
            self.assertIn("duplicate JSON key", result.stderr)
            self.assertFalse((root / "reports").exists())
            result = self.run_cli("report", "--inventory", root / "missing", "--prices", FIXTURES / "prices.json",
                                  "--output-dir", root / "reports")
            self.assertEqual(result.returncode, 2)
            self.assertIn("cost-report:", result.stderr)


if __name__ == "__main__":
    unittest.main()

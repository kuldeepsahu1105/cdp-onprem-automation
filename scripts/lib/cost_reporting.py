"""Evidence-based estimates and a separate, scoped billing ledger (stdlib only)."""

import argparse
import csv
import hashlib
import io
import json
import sys
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP, localcontext
from pathlib import Path


class InputError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise InputError(message)


def text(value, name):
    require(isinstance(value, str) and bool(value.strip()), f"{name}: nonempty string required")
    require(not any(ord(c) < 32 for c in value), f"{name}: control characters not allowed")
    return value


def number(value, name, minimum=None):
    require(isinstance(value, (str, int)) and not isinstance(value, bool),
            f"{name}: use a decimal string, not a float")
    try:
        result = Decimal(value)
    except InvalidOperation as exc:
        raise InputError(f"{name}: invalid decimal") from exc
    require(result.is_finite() and abs(result) <= Decimal("1e24")
            and result.as_tuple().exponent >= -18, f"{name}: invalid decimal range/precision")
    require(minimum is None or result >= minimum, f"{name}: must be >= {minimum}")
    return result


def decimal_string(value):
    return format(value, "f")


def money(value):
    return decimal_string(value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP))


def timestamp(value, name):
    text(value, name)
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise InputError(f"{name}: ISO timestamp required") from exc
    require(result.tzinfo is not None, f"{name}: timezone required")
    return result.astimezone(timezone.utc)


def period(value):
    require(isinstance(value, dict), "period: object required")
    start = timestamp(value.get("start"), "period.start")
    end = timestamp(value.get("end"), "period.end")
    require(end > start, "period.end must be after start")
    return {"start": start.isoformat(), "end": end.isoformat()}


def period_hours(value):
    delta = timestamp(value["end"], "end") - timestamp(value["start"], "start")
    return (Decimal(delta.days * 86400 + delta.seconds)
            + Decimal(delta.microseconds) / Decimal(1000000)) / Decimal(3600)


def evidence(value):
    require(isinstance(value, dict), "metadata: object required")
    text(value.get("source"), "source")
    timestamp(value.get("as_of"), "as_of")
    return value


def version(value):
    require(isinstance(value, dict) and type(value.get("schema_version")) is int
            and value["schema_version"] == 1, "schema_version must be 1")
    return value


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load(path):
    with Path(path).open(encoding="utf-8") as stream:
        return json.load(stream, object_pairs_hook=unique_object)


def currency(value):
    require(isinstance(value, str) and len(value) == 3
            and value.isascii() and value.isalpha() and value.isupper(),
            "currency must be a three-letter uppercase code")
    return value


def fields(row, names):
    require(isinstance(row, dict), "row must be an object")
    for name in names.split():
        text(row.get(name), name)


def array(value, name):
    require(isinstance(value, list), f"{name}: array required")
    return value


def mapping(value, name):
    require(isinstance(value, dict), f"{name}: object required")
    return value


def rate_key(row):
    return tuple(row[k] for k in ("provider", "region", "sku", "unit", "currency"))


def identity(row):
    return tuple(row[k] for k in ("provider", "account", "region", "resource_id", "component", "owner"))


def validate_resource(row, max_hours):
    fields(row, "provider account region resource_id component sku unit owner scope cost_pool source as_of")
    require(row["provider"] in ("aws", "nutanix", "baremetal"), "unsupported provider")
    require(row.get("state") in ("planned", "deployed"), "resource state must be planned or deployed")
    require(row["scope"] in ("dedicated", "shared"), "scope must be dedicated or shared")
    timestamp(row["as_of"], "resource.as_of")
    currency(row.get("currency"))
    require("quantity" in row and "hours" in row, "quantity and hours required (use explicit null for unknown)")
    if row.get("quantity") is not None:
        number(row["quantity"], "quantity", Decimal(0))
    if row.get("hours") is not None:
        hours = number(row["hours"], "hours", Decimal(0))
        require(hours <= max_hours, "resource hours exceed report period")
    allocation = number(row.get("allocation"), "allocation", Decimal(0))
    require(allocation <= 1, "allocation must be <= 1")
    require(row["scope"] != "dedicated" or allocation == 1,
            "dedicated resource must have allocation 1")
    if row["scope"] == "shared":
        text(row.get("allocation_basis"), "shared allocation_basis")
    if "role" in row:
        text(row["role"], "role")
    if "specs" in row:
        require(isinstance(row["specs"], dict), "specs must be an evidence-backed object")


def summarize_lines(lines):
    subtotal = sum((Decimal(x["amount"]) for x in lines if x["amount"] is not None), Decimal(0))
    priced = sum(x["amount"] is not None for x in lines)
    return {"priced_subtotal": money(subtotal),
            "total": money(subtotal) if priced == len(lines) else None,
            "priced_components": priced, "components": len(lines)}


def rollups(lines):
    """Node and ownership/role groups sum existing ledger lines, never reprice."""
    groups, nodes = defaultdict(list), defaultdict(list)
    anchors = set()
    for line in lines:
        if line["component"] in ("compute", "host", "vm"):
            anchor = tuple(line[k] for k in ("provider", "account", "region", "resource_id", "owner"))
            require(anchor not in anchors, f"multiple node anchors for canonical identity: {anchor}")
            anchors.add(anchor)
    node_keys = {tuple(line[k] for k in ("provider", "account", "region", "resource_id"))
                 for line in lines if line["component"] in ("compute", "host", "vm")}
    for line in lines:
        group_key = tuple(line[k] for k in ("provider", "account", "region", "owner", "scope", "currency", "role"))
        groups[group_key].append(line)
        node_key = tuple(line[k] for k in ("provider", "account", "region", "resource_id"))
        if node_key in node_keys:
            nodes[node_key + (line["owner"], line["currency"], line["role"])].append(line)
    node_rows = []
    for key, items in sorted(nodes.items()):
        node = next((r for r in items if r["component"] in ("compute", "host", "vm")), None)
        if node is None:
            continue
        node_rows.append({
            **{k: node[k] for k in ("provider", "account", "region", "resource_id", "owner",
                                   "scope", "currency", "role", "sku", "specs", "period", "allocation")},
            **summarize_lines(items), "node_count": 1,
            "effective_node_count": decimal_string(number(node["allocation"], "allocation")),
            "price_scope": "listed node components only",
        })
    group_rows = []
    for key, items in sorted(groups.items()):
        provider, account, region, owner, scope, code, role = key
        group_nodes = [r for r in items if r["component"] in ("compute", "host", "vm")]
        quantities = defaultdict(list)
        for item in items:
            quantities[(item["sku"], item["unit"])].append(item)
        group_rows.append({
            "provider": provider, "account": account, "region": region, "owner": owner,
            "scope": scope, "currency": code, "role": role, "period": items[0]["period"],
            **summarize_lines(items), "node_count": len({r["resource_id"] for r in group_nodes}),
            "resource_count": len({r["resource_id"] for r in items}),
            "effective_node_count": decimal_string(sum(
                (number(r["allocation"], "allocation") for r in group_nodes), Decimal(0))),
            "quantities": [{
                "sku": sku, "unit": unit,
                "allocated_quantity": (decimal_string(sum(
                    (number(r["quantity"], "quantity") * number(r["allocation"], "allocation")
                     for r in components), Decimal(0)))
                    if all(r["quantity"] is not None for r in components) else None),
                "usage": (decimal_string(sum((Decimal(r["usage"]) for r in components), Decimal(0)))
                          if all(r["usage"] is not None for r in components) else None),
                "component_hours": sorted({r["hours"] for r in components}, key=str),
                "rate": components[0]["rate"],
                **summarize_lines(components),
            } for (sku, unit), components in sorted(quantities.items())],
            "price_scope": "listed group components only; node counts across shared groups are not additive",
        })
    return node_rows, group_rows


def build_report(inventory, prices, billing=None):
    # Enough precision for bounded inputs, multiplication and summing before cent rounding.
    with localcontext() as context:
        context.prec = 120
        return _build_report(inventory, prices, billing)


def build_rate_map(prices):
    version(prices)
    rate_map = {}
    for rate in array(prices.get("rates"), "rates"):
        fields(rate, "provider region sku unit currency basis source as_of")
        require(rate["provider"] in ("aws", "nutanix", "baremetal"), "unsupported rate provider")
        currency(rate["currency"])
        timestamp(rate["as_of"], "rate.as_of")
        number(rate.get("amount"), "rate.amount", Decimal(0))
        require(number(rate.get("unit_hours"), "unit_hours", Decimal(0)) > 0,
                "unit_hours must be positive")
        if rate["unit"].endswith("-hour"):
            require(number(rate["unit_hours"], "unit_hours") == 1,
                    "hourly unit requires unit_hours=1")
        for name in ("effective_date", "valid_until"):
            if rate.get(name) is not None:
                timestamp(rate[name], f"rate.{name}")
        require(rate["basis"] in ("cloud_price", "operator_rate", "capex_allocation"), "invalid rate basis")
        require((rate["provider"] == "aws") == (rate["basis"] == "cloud_price"),
                "AWS requires cloud_price; hardware/Nutanix requires operator_rate or capex_allocation")
        key = rate_key(rate)
        require(key not in rate_map, f"duplicate/ambiguous rate: {key}")
        rate_map[key] = rate
    return rate_map


def _build_report(inventory, prices, billing):
    version(inventory)
    meta = dict(evidence(inventory.get("metadata")))
    meta["period"] = period(meta.get("period"))
    text(meta.get("quantity_basis"), "metadata.quantity_basis")
    exclusions = array(meta.get("exclusions"), "metadata.exclusions")
    for exclusion in exclusions:
        text(exclusion, "exclusion")
    warnings = list(array(inventory.get("warnings", []), "warnings"))
    for warning in warnings:
        text(warning, "warning")
    warnings.append("Estimates and billed costs are separate; neither is a complete TCO or invoice reconciliation.")
    if not inventory.get("resources"):
        warnings.append("Inventory is empty: no total is available; this is not evidence of zero cost.")
    if not exclusions:
        warnings.append("No exclusions declared; verify inventory completeness, software, tax, support and usage charges.")
    rate_map = build_rate_map(prices)
    resources = array(inventory.get("resources"), "resources")
    require(len({r.get("state") for r in resources if isinstance(r, dict)}) <= 1,
            "do not combine planned and deployed inventories")
    seen, pools = set(), {}
    estimates = []
    grouped = defaultdict(list)
    for resource in resources:
        validate_resource(resource, period_hours(meta["period"]))
        key = identity(resource)
        require(key not in seen, f"duplicate resource component: {key}")
        seen.add(key)
        pool = tuple(resource[k] for k in ("account", "region", "cost_pool"))
        basis = tuple(resource[k] for k in ("provider", "sku", "unit", "currency")) + (
            number(resource["quantity"], "quantity") if resource["quantity"] is not None else None,
            number(resource["hours"], "hours") if resource["hours"] is not None else None)
        allocation = number(resource["allocation"], "allocation")
        if pool in pools:
            previous_basis, previous_allocation = pools[pool]
            require(previous_basis == basis, f"inconsistent shared cost pool: {pool}")
            allocation += previous_allocation
        require(allocation <= 1, f"cost pool allocation exceeds 1 (double counting): {pool}")
        pools[pool] = (basis, allocation)
        rate = rate_map.get(rate_key(resource))
        amount = None
        usage = None
        applicable = rate is not None
        if rate is not None:
            for name, boundary, after in (("effective_date", "start", True), ("valid_until", "end", False)):
                if rate.get(name) is not None:
                    rate_date = timestamp(rate[name], f"rate.{name}")
                    boundary_date = timestamp(meta["period"][boundary], f"period.{boundary}")
                    outside = rate_date > boundary_date if after else rate_date < boundary_date
                    if outside:
                        applicable = False
                        warnings.append(f"Rate validity does not cover requested period: {rate['sku']} ({name})")
        if applicable and resource.get("quantity") is not None and resource.get("hours") is not None:
            usage = (number(resource["quantity"], "quantity")
                     * number(resource["hours"], "hours")
                     * number(resource["allocation"], "allocation")
                     / number(rate["unit_hours"], "unit_hours"))
            amount = money(usage * number(rate["amount"], "amount"))
            if timestamp(rate["as_of"], "rate.as_of") < timestamp(meta["period"]["start"], "period.start"):
                warnings.append(f"Rate predates requested period; verify applicability: {rate['sku']} ({rate['as_of']})")
        else:
            warnings.append(f"Missing applicable price or quantity/hours: {' / '.join(key)} ({resource['sku']}, {resource['unit']})")
        line = {
            **resource, "period": meta["period"], "rate": rate,
            "role": resource.get("role", "unclassified"),
            "specs": resource.get("specs", {"vcpu": None, "memory_mib": None}),
            "usage": decimal_string(usage) if usage is not None else None,
            "amount": amount, "status": "priced" if amount is not None else "unpriced",
        }
        estimates.append(line)
        grouped[(resource["provider"], resource["currency"])].append(line)
    estimate_summaries = []
    for (provider, code), lines in sorted(grouped.items()):
        amounts = summarize_lines(lines)
        priced = amounts["priced_components"]
        node_lines = [r for r in lines if r["component"] in ("compute", "host", "vm")]
        estimate_summaries.append({
            "provider": provider, "currency": code, "period": meta["period"],
            "pricing_model": "cloud_price" if provider == "aws" else "operator_supplied",
            **amounts,
            "node_count": len({(r["account"], r["region"], r["resource_id"]) for r in node_lines}),
            "effective_node_count": decimal_string(sum(
                (number(r["allocation"], "allocation") for r in node_lines), Decimal(0))),
            "coverage_percent": money(Decimal(priced) * 100 / len(lines)),
            "complete": priced == len(lines), "total_scope": "listed inventory components only",
        })
    actuals = build_actuals(billing)
    nodes, groups = rollups(estimates)
    warnings.extend(actuals.pop("warnings"))
    return {
        "schema_version": 1,
        "metadata": {**meta, "rounding": "ROUND_HALF_UP, 2 decimals per line; summaries sum displayed lines",
                     "money_encoding": "decimal strings or null; no currency conversion",
                     "coverage_basis": "priced component count, not cost or utilization coverage"},
        "resources": resources,
        "estimates": {"lines": estimates, "nodes": nodes, "groups": groups, "summaries": estimate_summaries},
        "actuals": actuals,
        "coverage": {"components": len(resources), "priced_components": sum(
            x["amount"] is not None for x in estimates),
            "inventory_complete": False, "exclusions": exclusions,
            "actuals_status": actuals["status"]},
        "warnings": warnings,
    }


def build_actuals(billing):
    with localcontext() as context:
        context.prec = 120
        return _build_actuals(billing)


def _build_actuals(billing):
    if billing is None:
        return {"status": "unavailable", "reason": "No billing export supplied", "lines": [],
                "summaries": [], "metadata": None, "warnings": ["Actual billed costs unavailable."]}
    version(billing)
    meta = evidence(billing.get("metadata"))
    for name in ("scope", "metric", "completeness"):
        text(meta.get(name), f"billing.metadata.{name}")
    require(meta["completeness"] in ("partial", "complete"), "billing completeness must be partial or complete")
    export_period = period(meta.get("period"))
    meta = {**meta, "period": export_period,
            "freshness": "Snapshot as_of only; not checked against live provider or final invoice"}
    rows = array(billing.get("lines"), "billing.lines")
    grouped, seen, scopes = defaultdict(list), set(), defaultdict(set)
    lines = []
    for row in rows:
        fields(row, "line_id provider account region resource_id project metric currency")
        require(row["metric"] == meta["metric"], "billing line metric differs from export metric")
        require(isinstance(row.get("tags"), dict) and all(
            isinstance(k, str) and isinstance(v, str) for k, v in row["tags"].items()), "tags must be a string map")
        currency(row["currency"])
        key = (row["provider"], row["account"], row["line_id"])
        require(key not in seen, f"duplicate billing line: {key}")
        seen.add(key)
        p = period(row.get("period"))
        require(p["start"] >= export_period["start"] and p["end"] <= export_period["end"],
                "billing line outside export period")
        scope = (row["provider"], row["account"], row["currency"], row["metric"])
        scopes[scope].add((p["start"], p["end"]))
        amount = money(number(row.get("amount"), "billed amount"))
        line = {**row, "period": p, "amount": amount, "source_amount": row["amount"],
                "source": meta["source"], "as_of": meta["as_of"]}
        lines.append(line)
        grouped[scope + (p["start"], p["end"])].append(line)
    # Overlapping alternative export periods would double-count the same charges.
    for scope, periods in scopes.items():
        ordered = sorted(periods)
        require(all(ordered[i - 1][1] <= ordered[i][0] for i in range(1, len(ordered))),
                f"overlapping billing periods for {scope}")
    summaries = []
    for key, group in sorted(grouped.items()):
        provider, account, code, metric, start, end = key
        subtotal = money(sum((Decimal(x["amount"]) for x in group), Decimal(0)))
        summaries.append({"provider": provider, "account": account, "currency": code, "metric": metric,
                          "period": {"start": start, "end": end}, "billed_subtotal": subtotal,
                          "total": subtotal if meta["completeness"] == "complete" else None,
                          "lines": len(group), "scope": meta["scope"]})
    return {"status": "available" if rows else "unavailable",
            "reason": None if rows else "Billing export has no lines; not evidence of zero cost",
            "metadata": meta, "lines": lines, "summaries": summaries,
            "warnings": ["Billing totals cover only the declared export scope; freshness is the export as_of.",
                         "Billing project/tag attribution is not proof of dedicated ownership."]}


def walk_modules(module):
    mapping(module, "Terraform module")
    yield from array(module.get("resources", []), "Terraform resources")
    for child in array(module.get("child_modules", []), "Terraform child_modules"):
        yield from walk_modules(child)


def adapt_inventory(raw, context, kind):
    with localcontext() as decimal_context:
        decimal_context.prec = 120
        return _adapt_inventory(raw, context, kind)


def _adapt_inventory(raw, context, kind):
    mapping(raw, "inventory export")
    version(context)
    metadata = dict(evidence(context.get("metadata")))
    metadata["period"] = period(metadata.get("period"))
    defaults = context.get("defaults")
    require(isinstance(defaults, dict), "context.defaults required")
    overrides = context.get("overrides", {})
    require(isinstance(overrides, dict), "context.overrides must be an object")
    warnings, rows, used = [], [], set()
    hours = decimal_string(period_hours(metadata["period"]))

    def add(key, resource_id, component, provider, sku, quantity, unit, pool=None, specs=None):
        override = overrides.get(key, {})
        require(isinstance(override, dict), f"override must be an object: {key}")
        used.add(key)
        row = {**defaults, **override}
        row.update({"resource_id": resource_id, "component": component, "provider": provider,
                    "sku": sku, "quantity": quantity, "unit": unit,
                    "state": state, "source": metadata["source"], "as_of": metadata["as_of"]})
        row["resource_id"] = override.get("resource_id", resource_id)
        row["sku"] = override.get("sku", sku)
        row["unit"] = override.get("unit", unit)
        row["quantity"] = override.get("quantity", quantity)
        row.setdefault("hours", hours)
        row.setdefault("allocation", "1")
        row.setdefault("cost_pool", pool or row["resource_id"] + "#" + component)
        row.setdefault("role", resource_role if kind == "terraform" else "unclassified")
        row.setdefault("specs", specs if specs is not None else node_specs)
        rows.append(row)

    if kind == "terraform":
        require(not raw.get("errored"), "errored Terraform plan cannot be reported")
        require(not raw.get("deferred_changes") and raw.get("complete", True) is not False,
                "deferred/incomplete Terraform plan cannot be reported")
        state = "planned" if "planned_values" in raw else "deployed"
        root = raw.get("planned_values", raw.get("values", {}))
        require(isinstance(root, dict) and "root_module" in root,
                "Terraform show -json plan/state with root_module required (not terraform output)")
        metadata["quantity_basis"] = f"{state} Terraform show JSON snapshot, not runtime or invoice"
        for resource in walk_modules(root["root_module"]):
            mapping(resource, "Terraform resource")
            if resource.get("mode") != "managed":
                continue
            fields(resource, "address type")
            address, rtype = resource["address"], resource["type"]
            values = mapping(resource.get("values") if resource.get("values") is not None else {}, "Terraform values")
            resource_role = mapping(values.get("tags") or {}, "Terraform tags").get("Group") or "unclassified"
            node_specs = {"vcpu": None, "memory_mib": None, "source": metadata["source"]}
            if rtype == "nutanix_virtual_machine":
                if values.get("num_vcpus_per_socket") is not None and values.get("num_sockets") is not None:
                    node_specs["vcpu"] = decimal_string(
                        number(values["num_vcpus_per_socket"], "vcpus", Decimal(0))
                        * number(values["num_sockets"], "sockets", Decimal(0)))
                node_specs["memory_mib"] = values.get("memory_size_mib")
                node_specs["disks"] = [
                    {"size_bytes": mapping(disk, "Nutanix disk").get("disk_size_bytes"),
                     "device_properties": disk.get("device_properties")}
                    for disk in array(values.get("disk_list") or [], "Nutanix disk_list")]
            elif rtype == "aws_instance":
                cpu = array(values.get("cpu_options") or [], "cpu_options")
                for option in cpu:
                    mapping(option, "cpu_option")
                if cpu and cpu[0].get("core_count") is not None and cpu[0].get("threads_per_core") is not None:
                    node_specs["vcpu"] = decimal_string(
                        number(cpu[0]["core_count"], "cores", Decimal(0))
                        * number(cpu[0]["threads_per_core"], "threads", Decimal(0)))
                node_specs["instance_type"] = values.get("instance_type")
            else:
                node_specs["attributes"] = {k: values[k] for k in (
                    "load_balancer_type", "internal", "connectivity_type", "domain",
                    "allocation_id", "size", "type", "iops", "throughput") if k in values}
            provider = "aws" if rtype.startswith("aws_") else "nutanix" if rtype.startswith("nutanix_") else None
            if provider is None:
                warnings.append(f"Excluded non-infrastructure Terraform resource: {address}")
                continue
            rid = values.get("id") or address
            first_row = len(rows)
            if rtype == "aws_instance":
                add(address + "#compute", rid, "compute", provider,
                    values.get("instance_type") or "unknown-instance-type", "1", "instance-hour")
                roots = array(values.get("root_block_device") or [], "root_block_device")
                require(len(roots) <= 1, f"multiple root devices: {address}")
                for disk in roots:
                    mapping(disk, "root_block_device")
                    add(address + "#root", rid, "root", provider,
                        disk.get("volume_type") or "unknown-volume-type",
                        disk.get("volume_size"), "GiB-month", disk.get("volume_id"),
                        specs={**node_specs, "disk": disk_specs(disk)})
                if not roots:
                    add(address + "#root", rid, "root", provider, "unknown-root-volume", "1", "resource-hour")
                # Extra storage and premium gp3 provisioned throughput/IOPS need explicit pricing.
                for index, disk in enumerate(array(values.get("ebs_block_device") or [], "ebs_block_device")):
                    mapping(disk, "ebs_block_device")
                    add(address + f"#ebs-{index}", rid, f"ebs-{index}", provider,
                        disk.get("volume_type") or "unknown-volume-type", disk.get("volume_size"),
                        "GiB-month", disk.get("volume_id"),
                        specs={**node_specs, "disk": disk_specs(disk)})
                for name in ("root_block_device", "ebs_block_device"):
                    for index, disk in enumerate(values.get(name) or []):
                        if disk.get("volume_type") == "gp3":
                            for feature, baseline in (("iops", 3000), ("throughput", 125)):
                                value = disk.get(feature)
                                if value is not None and number(value, feature) > baseline:
                                    component = f"{name}-{index}-{feature}"
                                    add(address + "#" + component, rid, component, provider,
                                        "gp3-" + feature, decimal_string(number(value, feature) - baseline),
                                        feature + "-month")
                                    rows[-1]["quantity_basis"] = {
                                        "provisioned": value, "included_baseline": baseline,
                                        "source": "https://docs.aws.amazon.com/ebs/latest/userguide/general-purpose.html",
                                    }
                # Public addresses are not free; EIP association and ephemeral assignment can overlap.
                warnings.append(f"{address}: verify public IPv4/EIP allocation hours separately; not inferred from host addresses.")
            elif rtype == "aws_ebs_volume":
                add(address, rid, "storage", provider, values.get("type") or "unknown-volume-type",
                    values.get("size"), "GiB-month", rid)
                warnings.append(f"{address}: provisioned IOPS/throughput require separate inventory components.")
            elif rtype == "nutanix_virtual_machine":
                add(address, rid, "vm", provider, "nutanix-vm", "1", "vm-hour")
                warnings.append(f"{address}: VM allocation is not physical hardware capacity or a public-cloud invoice.")
            elif rtype in ("aws_eip_association", "aws_volume_attachment"):
                warnings.append(f"Excluded relationship {address}; price its IP/volume once, not the attachment.")
            else:
                # Never assume an unmodelled Terraform object is free.
                add(address, rid, "unmodelled", provider, rtype, "1", "resource-hour")
                warnings.append(f"Unmodelled {address}: supply a reviewed SKU/unit override or leave unpriced.")
            arn = values.get("arn")
            if provider == "aws" and arn:
                parts = arn.split(":")
                require(len(parts) >= 6, f"invalid ARN: {address}")
                for row in rows[first_row:]:
                    for name, actual in (("region", parts[3]), ("account", parts[4])):
                        require(not actual or row[name] == actual,
                                f"context {name} contradicts Terraform ARN: {address}")
        metadata.setdefault("exclusions", [])
        metadata["exclusions"] = list(metadata["exclusions"]) + [
            "Terraform snapshot excludes unmanaged/shared infrastructure and usage not represented in state.",
            "Instance public IPv4 charges require explicit deduplicated allocation inventory.",
            "VM host capacity, software licences, support, energy, tax and transfer are not inferred.",
        ]
    else:
        require(kind == "ansible", "unsupported inventory adapter")
        state = "deployed"
        hostvars = mapping(raw.get("_meta"), "Ansible _meta").get("hostvars")
        require(isinstance(hostvars, dict), "cached ansible-inventory --list JSON required")
        metadata["quantity_basis"] = "unique canonical hosts from cached Ansible inventory; not utilization or invoice"
        canonical = {}
        for host in sorted(hostvars):
            require(host in overrides, f"Ansible host requires explicit identity/SKU override: {host}")
            override = overrides[host]
            fields(override, "resource_id provider sku unit")
            rid = override["resource_id"]
            if rid in canonical:
                require(override == canonical[rid], f"conflicting host aliases: {rid}")
                used.add(host)
                warnings.append(f"Deduplicated inventory alias {host} for {rid}")
                continue
            canonical[rid] = override
            host_values = mapping(hostvars[host], "hostvars")
            facts = mapping(host_values.get("ansible_facts", {}), "ansible_facts")
            node_specs = {
                "vcpu": host_values.get("ansible_processor_vcpus", facts.get("processor_vcpus")),
                "memory_mib": host_values.get("ansible_memtotal_mb", facts.get("memtotal_mb")),
                "hardware_model": host_values.get("ansible_product_name", facts.get("product_name")),
                "inventory_groups": sorted(k for k, v in raw.items() if isinstance(v, dict)
                                           and host in v.get("hosts", [])),
                "source": metadata["source"],
            }
            add(host, rid, "host", override["provider"], override["sku"], "1", override["unit"])
        warnings.append("Inventory host count is not hardware cost: VM/host charge pools and allocations must be operator-reviewed.")
    require(not (set(overrides) - used), f"unused context overrides: {sorted(set(overrides) - used)}")
    return {"schema_version": 1, "metadata": metadata, "resources": rows, "warnings": warnings}


def disk_specs(disk):
    return {"type": disk.get("volume_type"), "size_gib": disk.get("volume_size"),
            "iops": disk.get("iops"), "throughput_mib_s": disk.get("throughput")}


def adapt_aws_prices(raw, context):
    """Select explicit, non-tiered OnDemand dimensions from an AWS bulk price-list file."""
    version(context)
    mapping(raw, "price export")
    metadata = evidence(context.get("metadata"))
    require(isinstance(raw.get("products"), dict) and isinstance(raw.get("terms"), dict),
            "AWS bulk price-list JSON products/terms required")
    rates = []
    for selection in array(context.get("selections"), "price selections"):
        fields(selection, "provider_sku rate_code region sku unit provider_unit currency")
        product = raw["products"].get(selection["provider_sku"])
        require(isinstance(product, dict), f"unknown AWS provider SKU: {selection['provider_sku']}")
        attributes = mapping(product.get("attributes", {}), "AWS product attributes")
        require(attributes.get("regionCode") == selection["region"], "AWS product regionCode mismatch")
        matches = []
        terms = mapping(raw["terms"].get("OnDemand", {}), "OnDemand terms")
        for term in mapping(terms.get(selection["provider_sku"], {}), "SKU terms").values():
            mapping(term, "AWS price term")
            for code, dimension in mapping(term.get("priceDimensions", {}), "priceDimensions").items():
                if code == selection["rate_code"]:
                    mapping(dimension, "price dimension")
                    matches.append((term, dimension))
        require(len(matches) == 1, "select exactly one OnDemand rate_code; reserved/tiered pricing not supported")
        term, dimension = matches[0]
        require(dimension.get("unit") == selection["provider_unit"], "provider price unit mismatch")
        supported_units = {
            "Hrs": ("instance-hour", "resource-hour"),
            "GB-Mo": ("GiB-month",),
            "IOPS-Mo": ("iops-month",),
            "MBps-Mo": ("throughput-month",),
        }
        require(selection["unit"] in supported_units.get(selection["provider_unit"], ()),
                "unsupported provider/report unit conversion")
        require(dimension.get("beginRange") == "0" and dimension.get("endRange") == "Inf",
                "tiered/ranged prices require usage modelling; not supported")
        require(not dimension.get("appliesTo"), "conditional price dimensions not supported")
        amount = mapping(dimension.get("pricePerUnit", {}), "pricePerUnit").get(selection["currency"])
        number(amount, "provider price amount", Decimal(0))
        require(number(selection.get("unit_hours"), "unit_hours", Decimal(0)) > 0, "unit_hours must be positive")
        rates.append({
            "provider": "aws", **selection, "basis": "cloud_price", "amount": amount,
            "source": metadata["source"], "as_of": metadata["as_of"],
            "effective_date": term.get("effectiveDate"), "attributes": attributes,
            "description": dimension.get("description"), "product_family": product.get("productFamily"),
        })
    # Reuse the reporter's strict price validation, including ambiguous mappings.
    build_rate_map({"schema_version": 1, "rates": rates})
    return {"schema_version": 1, "metadata": metadata, "rates": rates}


def adapt_cur(path, context):
    version(context)
    metadata = evidence(context.get("metadata"))
    require(metadata.get("metric") == "UnblendedCost", "CUR adapter supports only UnblendedCost")
    required = {
        "identity/LineItemId", "lineItem/UsageAccountId", "lineItem/ResourceId",
        "lineItem/UnblendedCost", "lineItem/CurrencyCode", "product/region",
        "bill/BillingPeriodStartDate", "bill/BillingPeriodEndDate",
    }
    lines = []
    with Path(path).open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream)
        require(required <= set(reader.fieldnames or []), f"CUR missing columns: {sorted(required - set(reader.fieldnames or []))}")
        require(len(reader.fieldnames) == len(set(reader.fieldnames)), "duplicate CUR columns")
        for row in reader:
            require(None not in row and all(v is not None for v in row.values()), "malformed CUR row")
            # Account-level credits/tax may have no resource/region/project; keep that explicit.
            lines.append({
                "line_id": row["identity/LineItemId"], "provider": "aws",
                "account": row["lineItem/UsageAccountId"],
                "region": row["product/region"] or "unattributed",
                "resource_id": row["lineItem/ResourceId"] or "unattributed",
                "project": row.get("resourceTags/user:Project") or "unattributed",
                "tags": {k.removeprefix("resourceTags/"): v for k, v in row.items()
                         if k.startswith("resourceTags/") and v},
                "metric": "UnblendedCost", "currency": row["lineItem/CurrencyCode"],
                "amount": row["lineItem/UnblendedCost"],
                "period": {"start": row["bill/BillingPeriodStartDate"], "end": row["bill/BillingPeriodEndDate"]},
            })
    result = {"schema_version": 1, "metadata": metadata, "lines": lines}
    build_actuals(result)
    return result


def flat_rows(report):
    """Single ledger across formats; nested evidence stays lossless as JSON columns."""
    rows = []
    for section in ("estimates", "actuals"):
        kinds = [("line", "lines"), ("node", "nodes"), ("group", "groups"), ("summary", "summaries")]
        for kind, field in kinds:
            items = report[section].get(field, [])
            for item in items:
                rows.append({**item, "section": section, "kind": kind})
    for section in ("metadata", "resources", "coverage", "warnings"):
        rows.append({"section": section, "kind": "metadata", "data": report[section]})
    rows.append({"section": "actuals", "kind": "metadata", "data": {
        k: v for k, v in report["actuals"].items() if k not in ("lines", "summaries")}})
    return rows


def cell(value):
    if value is None:
        return "null"
    if isinstance(value, (dict, list, bool)):
        return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
    return str(value)


def render_csv(rows):
    columns = ["section", "kind"] + sorted(set().union(*(row.keys() for row in rows)) - {"section", "kind"})
    stream = io.StringIO(newline="")
    writer = csv.DictWriter(stream, fieldnames=columns)
    writer.writeheader()
    for row in rows:
        writer.writerow({k: cell(v) for k, v in row.items()})
    return stream.getvalue()


def text_table(rows, columns):
    values = [[cell(row[c]) if c in row else "-" for c in columns] for row in rows]
    widths = [max(len(c), *(len(row[i]) for row in values)) if values else len(c)
              for i, c in enumerate(columns)]
    table = [" | ".join(c.ljust(widths[i]) for i, c in enumerate(columns)),
             "-+-".join("-" * width for width in widths)]
    table.extend(" | ".join(c.ljust(widths[i]) for i, c in enumerate(row)) for row in values)
    return table


def render_txt(report, rows):
    tables = ["COMPONENT LEDGER (sum lines only within their scope)",
              *text_table([r for r in rows if r["kind"] == "line"], (
                  "section", "provider", "resource_id", "component", "role", "sku", "quantity",
                  "unit", "hours", "allocation", "currency", "amount", "status")),
              "", "NODE / ROLE GROUP / SCOPED TOTALS (alternative rollups; DO NOT add them together)",
              *text_table([r for r in rows if r["kind"] in ("node", "group", "summary")], (
                  "section", "kind", "provider", "account", "region", "resource_id", "owner", "role",
                  "node_count", "effective_node_count", "currency", "priced_subtotal", "billed_subtotal",
                  "total", "priced_components", "components", "period"))]
    for line in report["estimates"]["lines"]:
        rate = line["rate"]
        detail = {
            "identity": {k: line[k] for k in ("provider", "account", "region", "resource_id", "component")},
            "ownership": {k: line[k] for k in ("owner", "scope", "allocation", "cost_pool")},
            "specs": line["specs"],
            "rate": rate,
            "source/as_of": {"source": line["source"], "as_of": line["as_of"]},
        }
        tables.extend(["", "RESOURCE / PRICE EVIDENCE",
                       *text_table([{"field": k, "value": v} for k, v in detail.items()], ("field", "value"))])
    for group in report["estimates"]["groups"]:
        tables.extend(["", f"GROUP USAGE: {group['provider']} / {group['account']} / {group['owner']} / {group['role']}",
                       *text_table(group["quantities"], ("sku", "unit", "allocated_quantity", "component_hours",
                                                        "usage", "priced_subtotal", "total"))])
    return "\n".join([
        "INFRASTRUCTURE ESTIMATES / SEPARATE BILLED COSTS (schema_version=1)",
        "Amounts: decimal strings, ROUND_HALF_UP per line to 2 decimals; null = unknown.",
        "Summaries sum displayed lines, grouped by currency/period; NEVER add estimates to actuals.",
        "Total covers listed components/export scope only, not full deployment TCO.",
        "", *tables, "", "LOSSLESS LEDGER (same records as CSV; full provenance and assumptions)",
        *(json.dumps(row, sort_keys=True, ensure_ascii=True) for row in rows),
        "",
    ])


def fingerprint(path):
    return {"path": str(path), "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest()}


def write_json(path, value):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    inventory = commands.add_parser("inventory", help="normalize local Terraform/Ansible JSON, never run either tool")
    group = inventory.add_mutually_exclusive_group(required=True)
    group.add_argument("--terraform-json")
    group.add_argument("--ansible-json")
    inventory.add_argument("--context", required=True)
    inventory.add_argument("--output", required=True)
    billing = commands.add_parser("billing", help="normalize a local AWS CUR CSV (no API access)")
    billing.add_argument("--aws-cur", required=True)
    billing.add_argument("--context", required=True)
    billing.add_argument("--output", required=True)
    pricing = commands.add_parser("pricing", help="select explicit rates from a local AWS bulk price-list JSON")
    pricing.add_argument("--aws-price-list", required=True)
    pricing.add_argument("--context", required=True)
    pricing.add_argument("--output", required=True)
    report = commands.add_parser("report", help="write reconciled cost-report.{json,csv,txt}")
    report.add_argument("--inventory", required=True)
    report.add_argument("--prices", required=True)
    report.add_argument("--billing")
    report.add_argument("--output-dir", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "inventory":
            path = args.terraform_json or args.ansible_json
            value = adapt_inventory(load(path), load(args.context), "terraform" if args.terraform_json else "ansible")
            # Validate inventory even if no prices exist.
            build_report(value, {"schema_version": 1, "rates": []})
            value["metadata"]["input_files"] = [fingerprint(path), fingerprint(args.context)]
            require(Path(args.output).resolve() not in (Path(path).resolve(), Path(args.context).resolve()),
                    "output must not overwrite an input")
            write_json(args.output, value)
        elif args.command in ("billing", "pricing"):
            path = args.aws_cur if args.command == "billing" else args.aws_price_list
            value = (adapt_cur(path, load(args.context)) if args.command == "billing"
                     else adapt_aws_prices(load(path), load(args.context)))
            inputs = [fingerprint(path), fingerprint(args.context)]
            value["metadata"]["input_files"] = inputs
            if args.command == "pricing":
                for rate in value["rates"]:
                    rate["input_files"] = inputs
            require(Path(args.output).resolve() not in (Path(path).resolve(), Path(args.context).resolve()),
                    "output must not overwrite an input")
            write_json(args.output, value)
        else:
            paths = [args.inventory, args.prices] + ([args.billing] if args.billing else [])
            value = build_report(load(args.inventory), load(args.prices), load(args.billing) if args.billing else None)
            value["metadata"]["input_files"] = [fingerprint(p) for p in paths]
            rows = flat_rows(value)
            output = Path(args.output_dir)
            destinations = [output / f"cost-report.{extension}" for extension in ("json", "csv", "txt")]
            require(not ({p.resolve() for p in destinations} & {Path(p).resolve() for p in paths}),
                    "report must not overwrite input files")
            # Fully validate/render all formats before writing any artifact.
            csv_data, txt_data = render_csv(rows), render_txt(value, rows)
            output.mkdir(parents=True, exist_ok=True)
            write_json(destinations[0], value)
            destinations[1].write_text(csv_data, encoding="utf-8")
            destinations[2].write_text(txt_data, encoding="utf-8")
        return 0
    except (InputError, OSError, ValueError, KeyError, TypeError, ArithmeticError) as exc:
        print(f"cost-report: {exc}", file=sys.stderr)
        return 2

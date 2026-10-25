# Offline infrastructure estimates and actual billed costs

This is an **additive, opt-in** reporting path. It changes no Terraform, Ansible,
inventory generation, Jenkins job, or deployment prerequisites. Python 3.9+ and
the standard library are sufficient; `make` is optional. The CLI never imports
an AWS/Nutanix SDK, reads credentials, invokes Terraform/Ansible, queries an
endpoint, provisions infrastructure, or starts services.

## Audit and supported scope

| Existing path | Evidence available | Reporting treatment |
|---|---|---|
| `terraform-code/cloudera-pvc-terraform/main.tf`, `modules/ec2-instance/main.tf` | Flattened `instance_groups` counts, actual plan/state instances and gp3 roots | Import saved `terraform show -json` plan/state, recursively including child modules; one compute/root component per actual resource, not tfvars defaults |
| AWS VPC, EIP, S3 backend and other modules | Optional/managed infrastructure, some usage not known to Terraform | Unknown resource types remain unpriced until explicitly mapped; attachment relationships are excluded, not billed twice |
| `nutanix_terraform/main.tf` | `nutanix_virtual_machine.dev` instances | One VM allocation component per plan/state VM; **operator** SKU/rate, not EC2 or physical host invoice pricing |
| `generate_inventory.sh`, `ansible-playbooks/inventory*.ini` | Hosts/roles/IPs, not physical asset ownership or utilization | Import a cached `ansible-inventory --list` JSON export plus reviewed canonical identity/SKU mappings; deduplicate host aliases and repeated group membership |
| `scripts/lib/terraform_plan_output.sh`, `jenkins/scripts/collect-artifacts.sh`, `Jenkinsfile` | Existing plan logs/access/inventory artifacts; no price/billing engine | Keep all existing behavior; new reporter writes only the explicitly selected output directory |

Do not estimate from `.tfvars.yaml` requested counts when a plan/state exists.
Terraform output IP lists do not contain sufficient pricing quantities and are
rejected. Saved snapshots reflect planned/deployed configuration, **not uptime**.
Review the requested period and actual allocated/running hours yourself.

## Input filenames and operator checklist

Keep private inputs in ignored `cost-inputs/`; reports default to ignored
`artifacts/cost/`. Never commit state, plan JSON, real CUR exports, account IDs,
prices under NDA, or credentials. Terraform JSON can contain secrets: obtain a
sanitized, already exported snapshot under your existing operational process.
The examples below use **local files only**, not cloud/deploy commands.

```bash
umask 077
mkdir -p cost-inputs
vi cost-inputs/inventory-context.json
vi cost-inputs/prices.json
# Optional, if local AWS exports are supplied:
vi cost-inputs/price-context.json
vi cost-inputs/billing-context.json
```

In `vi`: `i` edits; `Esc`, `:wq`, Enter saves; `:q!`, Enter discards.
Do not blindly copy the test fixture prices: they are deliberately **synthetic**,
not public AWS quotes or hardware cost guidance.

Before running, review:

| Input | Required review |
|---|---|
| `terraform-show.json` or `ansible-inventory.json` | Genuine sanitized snapshot, timestamp/source, intended environment and plan versus deployed state; no duplicate state files/aliases |
| `inventory-context.json` | Exact account/site, region, owner, currency, interval and explicit exclusions; canonical physical IDs, charge pools, shared allocations and uptime overrides |
| `prices.json` | Exact provider/region/SKU/unit/currency match; source URL/export/approved rate-card reference and as-of; OS, architecture, tenancy, purchase model and storage/IOPS/throughput dimensions |
| `aws-price-list.json` + `price-context.json` (optional) | Genuine AWS bulk price-list JSON; select exact provider SKU and non-tiered OnDemand rate code; do not assume OS/tenancy from an instance name |
| `aws-cur.csv` + `billing-context.json` (optional) | One consistent export revision, scope, metric, account/project/tag coverage, billing period, freshness and completeness; don't append older exports of the same charges |

An input file's SHA-256 and path are recorded; that proves which local file was
used, **not** that the file is authentic or current. Rate evidence is retained on
each estimate, including original provider attributes when imported.

## Import Terraform or bare-metal inventory

Create `cost-inputs/inventory-context.json`:

```json
{
  "schema_version": 1,
  "metadata": {
    "source": "reviewed local Terraform show JSON; export reference CHANGE-123",
    "as_of": "2026-10-01T00:00:00Z",
    "period": {"start": "2026-10-01T00:00:00Z", "end": "2026-11-01T00:00:00Z"},
    "exclusions": ["Software licences, tax, support and measured network transfer"]
  },
  "defaults": {
    "account": "REPLACE-account-or-site",
    "region": "REPLACE-region-or-datacenter",
    "owner": "REPLACE-project",
    "scope": "dedicated",
    "currency": "USD"
  },
  "overrides": {}
}
```

```bash
python3 scripts/cost_report.py inventory \
  --terraform-json cost-inputs/terraform-show.json \
  --context cost-inputs/inventory-context.json \
  --output cost-inputs/inventory.json
```

This supports **AWS and Nutanix** plan/state exports. It never reads `.tfstate`
automatically. Errored, deferred or explicitly incomplete plans fail.
`quantity_basis` states the snapshot's origin. Hours default to the exact UTC
interval length (no assumed 730-hour month); override `hours` per component when
known. A missing size/root type is unknown, not zero. Unknown Terraform-managed
objects remain `unmodelled` with an unpriced SKU, rather than silently disappearing.
`aws_eip_association` and `aws_volume_attachment` are relationships: their
underlying IP/volume must be priced once.

Override keys match Terraform resource addresses. EC2 components use address
suffixes `#compute`, `#root`, `#ebs-0`, etc.; premium gp3 components use
`#root_block_device-0-iops` / `#root_block_device-0-throughput` (and corresponding
`ebs_block_device` names). Other AWS resources and Nutanix VMs use the address
alone. Inspect the generated inventory for the exact addresses. Override
`sku`, `unit`, `quantity`, `hours`, `cost_pool`, `owner`, `scope`, `allocation`,
`allocation_basis`, `currency`, `account` or `region`. Unused override keys fail,
preventing silent typos. AWS ARN account/region, when present, must agree with
the context. Otherwise account/region are operator attestations: verify them.
Do not reuse a combined bulk context across different AWS accounts/regions
without explicit resource mappings.

For bare-metal or existing Nutanix hosts, supply an already cached Ansible JSON
export (INI cannot prove physical identities). Add a mapping for **every** host
in `_meta.hostvars` to `overrides`:

```json
{
  "worker01": {
    "resource_id": "asset-serial-REPLACE",
    "provider": "baremetal",
    "sku": "REPLACE-approved-host-class",
    "unit": "host-hour",
    "cost_pool": "asset-serial-REPLACE#hardware"
  }
}
```

Place that object inside the context's `overrides`, and adjust metadata/defaults
to the site and inventory export, then run:

```bash
python3 scripts/cost_report.py inventory \
  --ansible-json cost-inputs/ansible-inventory.json \
  --context cost-inputs/inventory-context.json \
  --output cost-inputs/inventory.json
```

Canonical identity is not inferred from IPs. Aliases with the same `resource_id`
are collapsed only when their mappings agree exactly. Conflicting aliases fail.
Physical host and guest VM rates must not both include the same capital/energy
cost; assign the **same charge pool** and fractional allocations, or choose one
costing level. Different genuine cost components need distinct pools.

## Normalized resource contract

`inventory.json` contains `schema_version: 1`, `metadata` and `resources`.
Metadata requires source, timezone-qualified ISO `as_of`, `period.start/end`,
`quantity_basis` and an `exclusions` string array (even if empty).
Each resource requires:

| Keys | Meaning |
|---|---|
| `provider`, `account`, `region`, `resource_id`, `component` | Stable component identity; provider is `aws`, `nutanix` or `baremetal`; account may be an on-prem site/tenant |
| `state`, `owner`, `scope` | `planned` or `deployed` (never combine); owner/project; `dedicated` or `shared` |
| `cost_pool`, `allocation`, `allocation_basis` | Physical charge identity; fraction between 0 and 1; documented allocation basis required for shared resources; dedicated requires 1 |
| `sku`, `unit`, `currency` | Exact price match; use explicit composite SKU for OS/tenancy/hardware/licensing classes rather than assuming equivalence |
| `quantity`, `hours` | Decimal strings or integers; explicit `null` means unknown. Hours must fit the interval; zero requires genuine zero usage |
| `source`, `as_of` | Quantity/identity evidence and snapshot timestamp |

Optional `role` and `specs` preserve infrastructure detail. Terraform `tags.Group`
becomes the node role; `overrides.<address>.role` can supply a reviewed mapping.
For Ansible, set each canonical host's role in its mapping; all actual inventory
group memberships remain in specs. Unknown role is explicitly `unclassified`.
EC2 type is retained, but vCPU requires exported CPU core/thread options and RAM
stays null unless supplied in an evidenced `specs` override; there is no invented
instance-type-to-RAM lookup. Nutanix vCPU/socket and memory/disk fields are read
from the snapshot. Ansible CPU, memory and model facts are used only if included
in the cached export. Disk type/size/IOPS/throughput and network attributes are
retained when exported; unknown values stay null. Add external hardware evidence
through a `specs` object with its own source/as-of if the snapshot lacks it.

One pool within account/region must have consistent provider, SKU, unit, currency,
quantity and hours; allocations across owners cannot exceed 1. Distinct physical
volume IDs from Terraform are used to detect an embedded and standalone volume
listed twice. Planned addresses are used when deployed IDs do not exist.
Different resource/component IDs with the same pool still cannot double-charge.
Repeated canonical components are accepted only for different owners with
reviewed shared allocations; a duplicate for the same owner fails. A pool
cannot be charged again using a different provider's costing model.
No tool can discover mislabelled physical assets or hidden VM/host cost overlap:
the operator must assign correct canonical IDs and charge pools.

You can edit the normalized inventory to add unmanaged shared services, energy,
licences, usage-based transfer, IPv4 allocations, taxes, or other independently
evidenced components. Do not silently remove unpriced resources to obtain a
complete-looking total. The inventory can be incomplete even at 100% pricing
coverage; full infrastructure completeness is deliberately never asserted.

## Rate cards and provider prices

`prices.json` is `{"schema_version":1,"rates":[...]}`. Each rate requires:
`provider`, `region`, `sku`, `unit`, `currency`, `basis`, `amount`, `unit_hours`,
`source`, `as_of`. Decimal amounts are strings, not JSON floats.
Numeric inputs are finite, bounded to absolute value `1e24` and at most 18
fractional decimal places; negative estimate quantities/rates are rejected.

The calculation is:

```text
usage  = quantity * hours * allocation / rate.unit_hours
amount = ROUND_HALF_UP(usage * rate.amount, 2 decimal places)
```

`unit_hours` is explicit: `1` for hourly, the operator/provider billing divisor
for monthly charges, or a useful-life allocation horizon for capex. Never
automatically equate a calendar month to 730 hours. Monthly proration is only a
model: record the applicable provider policy in the rate's source/additional
fields. Rates older than the estimate period trigger an applicability warning.
Optional `effective_date` / `valid_until` must cover the whole report period;
otherwise the component stays unpriced rather than using an inapplicable rate.
Without validity boundaries applicability is an operator attestation.
This tool cannot verify current discounts, historical validity or rate sources.

AWS requires `basis: "cloud_price"` using sourced AWS pricing; a quoted
zero-price component is valid only with that evidence. Nutanix/bare-metal
requires `basis: "operator_rate"` or `"capex_allocation"`: **not public-cloud
pricing**. For capex, `amount` is approved net allocatable capital after any
residual value and `unit_hours` is the approved useful life. This excludes
unprovided energy, support, facilities, financing and software. Keep those as
separate charge pools when evidenced; no invented hardware running costs.

To import a genuine **AWS bulk price-list JSON** offline, create
`cost-inputs/price-context.json`:

```json
{
  "schema_version": 1,
  "metadata": {
    "source": "REPLACE-AWS-price-list-URL-and-export-reference",
    "as_of": "2026-10-01T00:00:00Z"
  },
  "selections": [
    {
      "provider_sku": "REPLACE-original-AWS-SKU",
      "rate_code": "REPLACE-exact-OnDemand-price-dimension-code",
      "region": "REPLACE-regionCode",
      "sku": "REPLACE-inventory-composite-SKU",
      "unit": "instance-hour",
      "provider_unit": "Hrs",
      "currency": "USD",
      "unit_hours": "1"
    }
  ]
}
```

```bash
python3 scripts/cost_report.py pricing \
  --aws-price-list cost-inputs/aws-price-list.json \
  --context cost-inputs/price-context.json \
  --output cost-inputs/prices.json
```

The adapter checks regionCode, exact rate code/currency/unit and retains product
attributes, description and effective date. Only unconditional, non-tiered
OnDemand dimensions (`beginRange=0`, `endRange=Inf`) are supported; reserved,
Savings Plans, tiered transfer or free-tier discounts need a separate reviewed
usage model, not a guessed blended rate. Bulk `products`/`terms` JSON is supported,
not raw `GetProducts.PriceList` string arrays. Accepted unit mappings are `Hrs`
to `instance-hour`/`resource-hour`, `GB-Mo` to `GiB-month`, `IOPS-Mo` to
`iops-month`, and `MBps-Mo` to `throughput-month`; other unit conversions fail.

## Actual billed costs (separate ledger)

Actuals are **unavailable** if no billing file is supplied or it has no lines.
An empty export is not evidence of zero cost. No reconciliation delta is
computed against estimates with different scope or period.

For AWS CUR CSV, create `cost-inputs/billing-context.json`:

```json
{
  "schema_version": 1,
  "metadata": {
    "source": "REPLACE-CUR-export-reference-and-revision",
    "as_of": "2026-11-03T00:00:00Z",
    "period": {"start": "2026-10-01T00:00:00Z", "end": "2026-11-01T00:00:00Z"},
    "scope": "REPLACE-account/project/tag/filter-coverage",
    "metric": "UnblendedCost",
    "completeness": "partial"
  }
}
```

```bash
python3 scripts/cost_report.py billing \
  --aws-cur cost-inputs/aws-cur.csv \
  --context cost-inputs/billing-context.json \
  --output cost-inputs/billing.json
```

Required CUR columns: `identity/LineItemId`, `lineItem/UsageAccountId`,
`lineItem/ResourceId`, `lineItem/UnblendedCost`, `lineItem/CurrencyCode`,
`product/region`, `bill/BillingPeriodStartDate`, `bill/BillingPeriodEndDate`.
Optional `resourceTags/user:Project` and all `resourceTags/*` columns are retained.
Blank resource/region/project are explicitly `unattributed`, including credits
and account-level fees; they are not discarded or forced onto a host.
Negative amounts are valid. This adapter does not accept CUR 2.0 renamed columns,
Parquet, XLSX, ZIP or arbitrary provider-specific billing formats.

Other providers can supply normalized `billing.json` with version/metadata as
above and `lines`. Each line requires `line_id`, `provider`, `account`, `region`,
`resource_id`, `project`, `tags` (string map), `metric`, `currency`, `amount`,
and `period.start/end`. Evidence comes from export metadata. Line IDs must be
unique within provider/account; periods must fit export coverage and must not
overlap alternative periods for the same account/currency/metric.
Account/project attribution is not proof of exclusive ownership.

`completeness: "partial"` is recommended for filtered, estimated or not-yet-final
exports. It produces a billed subtotal and `total: null`. Use `"complete"` only
for a reviewed full export **within the declared scope**, not an assertion that
every project account/tax/credit is included. Export timestamp is the freshness
evidence, not a guarantee of final invoicing.

## Generate and consume all three formats

```bash
make cost-report
# Same operation without make:
python3 scripts/cost_report.py report \
  --inventory cost-inputs/inventory.json \
  --prices cost-inputs/prices.json \
  --output-dir artifacts/cost

# Add actual billing only when available:
make cost-report COST_BILLING=cost-inputs/billing.json
# Explicit paths (also permits jenkins/artifacts/cost for a caller-managed copy):
make cost-report COST_INVENTORY=cost-inputs/inventory.json \
  COST_PRICES=cost-inputs/prices.json COST_OUTPUT_DIR=artifacts/cost
make test-cost-report
```

Output files: `cost-report.json`, `cost-report.csv`, `cost-report.txt`.
JSON v1 has `metadata`, `resources`, `estimates`, `actuals`, `coverage`, `warnings`.
Money is a decimal string or `null`. Estimates group by provider, currency and
the report period, keeping cloud and operator-supplied pricing separate.
Actuals group by provider/account/currency/metric/period. There is **no
cross-currency, cross-period, estimate-plus-actual, or TCO grand total**.
Two decimal places are a report convention for every currency, not an assertion
of each currency's legal minor unit. Summaries sum the displayed rounded lines,
not hidden higher-precision values; billing exports may differ from an invoice
which rounds at another aggregation level.
Actual lines retain `source_amount` so original export precision is not lost.

`estimates.nodes` rolls up the **listed** compute/VM/host and associated
components for each canonical node; `estimates.groups` rolls up owner/role/scope
within provider/account/region/currency. Each includes priced subtotal, incomplete
total and component counts. Group quantities remain separate by SKU/unit, with
allocated quantity, component hours, effective usage and rate; RAM and disks
are never summed as node counts. Node count is distinct canonical nodes;
effective count includes allocation fractions. Shared groups' physical counts
are not additive. Nodes, groups and provider summaries are **alternative views**
of the same ledger, not new charges, and must never be added together.

`priced_subtotal` includes only priced lines. A missing price/quantity/hours
leaves that line and the summary `total` null; `priced_components/components`
and component-count `coverage_percent` disclose the gap. A zero priced subtotal
with zero pricing coverage does **not** mean free infrastructure.

CSV is a typed ledger with `section`/`kind` discriminator columns: estimate and
billing lines, node/group rollups and summaries followed by
metadata/resource/coverage/warning records.
Nested data uses JSON cells; explicit unknown is `null`, absent/not-applicable
cells are empty. TXT has component, node/group, usage and evidence tables plus the **same lossless ledger**
records as JSON lines for evidence/assumptions and machine reconciliation.
Both contain source, as-of, units, scope and periods, not just a currency sum.

No deployment job automatically invokes the reporter or archives its outputs.
If a caller integrates it, check its exit status and archive **all three** files
as a set. CLI success is exit 0; missing files, malformed data, invalid decimals,
duplicate records/rates, contradictory shared pools or write failures return 2
with a `cost-report:` stderr error. Input validation/rendering finishes before
report writes, and input-overwriting destinations are rejected. Existing output
files are not deleted on failure; don't treat stale files as a successful run.
Filesystem failures during multi-file writes are not a transactional publish.

## Permissions and limitations

The reporter needs only read permission on supplied inputs and write permission
on the selected output directory. **No IAM, Prism, SSH, Ansible or Terraform
permissions are required.** An authorized operator may separately export data
with their established read-only process; no live adapter is included to avoid
unexpected credential/API access. This implementation was exercised only with
synthetic repository-shaped fixtures, never live cloud or on-prem systems.

Public IPv4/EIP overlap cannot be inferred from `associate_public_ip_address`;
add reviewed allocation hours once per address, not once per IP and association.
Unmanaged/existing VPCs, NAT data processing, transfer, snapshots, premium storage
features not represented in the snapshot, licence commitments and shared host
capacity need additional evidenced components or explicit exclusions. A priced
Nutanix VM is not a hardware TCO estimate. The tool is a transparent scoped model
and export ledger, not a price-discovery service or an invoice certification.

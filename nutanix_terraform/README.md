# Nutanix Terraform example

This is a standalone **HCL Terraform example**, not a `.env`-based CDP deployment
workflow. It currently defines two small VMs in `main.tf`; it does not generate
the Ansible CDP inventory or install Cloudera. Use the
[Ansible runbook](../ansible-playbooks/docs/RUNBOOK.md#bare-metal-deployment)
for appropriately sized existing hosts.

From the repository root, copy the actual template filename once (do not
overwrite an existing local configuration):

```bash
cd nutanix_terraform
cp terraform.tfvars.example terraform.tfvars
vi terraform.tfvars
```

Press `i` to edit, then `Esc`, `:wq`, Enter to save/quit;
`Esc`, `:q!`, Enter discards unsaved changes.

Verify/update **all required input names** from `variables.tf`:

| Input | Required value / action |
|---|---|
| `cluster_name` | Actual Prism cluster name used by the cluster data source |
| `subnet_name` | Existing subnet name reachable by the intended VMs |
| `endpoint` | Prism Central endpoint address |
| `user` | Authorized Prism Central account; replace the example account text |
| `password` | Supply securely outside this file, for example through a secret manager injecting `TF_VAR_password`; remove the sample `password` assignment so it does not override that input |
| `image_name` | Existing Prism image name used by `data.nutanix_image.image` |

**Template mismatch:** `terraform.tfvars.example` still contains `image_uri`
but no `image_name`. In your local `terraform.tfvars`, remove `image_uri` and
add `image_name = "your-existing-image-name"` with the real name.
`image_uri` is not a declared input: image creation is commented out in
`main.tf`. Do not reuse the example URL or the literal placeholder strings.

Review hard-coded VM count/name, CPU, memory, disks, and the `Environment=Dev`
category in `main.tf`; these are not configurable tfvars parameters. Confirm
the category exists. The provider in `providers.tf` currently uses
`insecure = true` (TLS certificate verification disabled); do not mistake this
example for a hardened production setup. The old Flow prerequisite applies to
network-security rules, which are currently commented out; VM creation does
not enable or configure Flow.

Validate before any apply:

```bash
terraform init
terraform validate
terraform plan
```

`init` downloads dependencies/initializes local metadata; `validate` checks
configuration without provisioning; `plan` authenticates to Prism and queries
resources but does not apply changes. Review the plan before explicitly
choosing to apply; do not use unattended `-auto-approve` as validation.
Never edit generated `.terraform/`, plans, or state. Keep credentials and
state/plan files private and out of Git; the provider's `password` variable is
not marked sensitive, so also treat plan/console output as potentially secret.
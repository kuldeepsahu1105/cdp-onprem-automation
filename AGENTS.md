# Guidance for Cursor / automation agents

## Standalone-first changes

Implement behavior in **Terraform modules**, **Ansible playbooks/tasks**, and **shared `scripts/lib/`** so it works without Jenkins or shell wrappers.

| Layer | Standalone entry |
|--------|------------------|
| Ansible | `cd ansible-playbooks && ansible-playbook -i inventory.ini <playbook>.yml` with `ANSIBLE_PRIVATE_KEY` or a key file in that directory |
| Ansible phases | `DEPLOY_PHASE=n ./pvc_setup.sh` from `ansible-playbooks/` (wrapper is optional sugar) |
| Terraform | `cd terraform-code/cloudera-pvc-terraform && terraform plan/apply` with `-var` / tfvars |
| Config | `.tfvars.yaml` + `group_vars/all.yml` — Jenkins UI overrides are optional (`JENKINS_*` / job parameters) |

**Do not** rely on Jenkins-only paths (`/var/lib/jenkins/...`, `holautosa` state dirs, job parameters) inside playbooks or Terraform. Jenkins scripts may copy artifacts into `ansible-playbooks/` (e.g. `sshkey.pem`, `inventory.ini`); playbooks should find keys via `ANSIBLE_PRIVATE_KEY`, `playbook_dir`, or documented vars.

**Wrappers** (`clone_and_run_pvc_automation.sh`, `pvc_setup.sh`, `clone_and_run_terraform.sh`, Jenkins `run-*.sh`) should orchestrate env, keys, and tfvars — not duplicate logic that playbooks cannot run alone.

## Testing mindset

- Prefer verifying with direct `ansible-playbook` / `terraform` when touching those trees.
- Document new optional vars in `ansible-playbooks/docs/RUNBOOK.md` or `REFERENCE.md`, not only `jenkins/README.md`.

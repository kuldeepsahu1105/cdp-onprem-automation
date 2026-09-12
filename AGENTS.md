# Guidance for Cursor / automation agents

**Repo-specific crux (architecture, portal, Ansible traps, Jenkins):** [`.cursor/LEARNINGS.md`](.cursor/LEARNINGS.md) — read first on portal/CM/verify work.

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

## Ansible portal / CM verify edits

Before changing `verify_*.yml`, `detect_ansible_control_reachability.yml`, `resolve_cm_connect_host.yml`, or portal sync/verify imports: follow [`.cursor/LEARNINGS.md`](.cursor/LEARNINGS.md) and `ansible-playbooks/docs/VARIABLE_CONTRACTS.md` (when present); run validate scripts listed there.

## Ansible portal / CM verify edits

Playbooks share facts across `common_tasks/`, numbered playbooks, and `group_vars/all.yml`. Before changing `verify_*.yml`, `detect_ansible_control_reachability.yml`, `resolve_cm_connect_host.yml`, or portal sync/verify imports:

1. Read **`ansible-playbooks/docs/VARIABLE_CONTRACTS.md`** (import order, required facts, CM API chain).
2. Run **`./jenkins/scripts/validate-ansible-contracts.sh`** (also runs from Jenkins `validate-prereqs.sh` after YAML parse). Fix new warnings for missing setters or same-task `set_fact` cross-references.
3. Do not put multiple `set_fact` keys in one task when one value references another key from that same task — split tasks or use `hostvars['localhost']` / `deployment_portal_context` explicitly.

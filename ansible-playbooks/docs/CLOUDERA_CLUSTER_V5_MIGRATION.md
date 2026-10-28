# cloudera.cluster 5.0.0 migration (spike — not active on main)

Main pipeline pins **[cloudera.cluster v4.4.0](https://github.com/cloudera-labs/cloudera.cluster/releases/tag/v4.4.0)** with PyPI `cm_client` and `urllib3<2` because v4.0.0 dropped the `cluster` module and v5+ needs a newer Python client.

Upstream **[5.0.0](https://github.com/cloudera-labs/cloudera.cluster/releases/tag/5.0.0)** (git tag `5.0.0`, not `v5.0.0`) adds `cluster`, `cm_kerberos`, `cm_autotls`, `control_plane`, and related modules. It expects **cm-client v57** (`ApiClient(configuration=…)`), not the legacy PyPI package installed by `common_tasks/install_cm_client_python.yml` today.

## Questions for engineering

1. **Supported install path** for cm-client v57 on the Jenkins agent (and laptops): internal mirror, pip package name/version, or CM archive swagger tarball (see upstream `pyproject.toml` `install-cm-client` script).
2. **urllib3 / Python** pins compatible with v57 on RHEL/Ubuntu agents.
3. **CM API version** alignment (collection tested against cm-client v57; our CM version vs generated client).
4. Whether to **adopt collection modules** for Kerberos/LDAP/Auto-TLS/parcels (replacing REST `uri` playbooks) after the client works.

## Planned code changes (when client is available)

| Area | Change |
|------|--------|
| `requirements.yml` | `git+https://github.com/cloudera-labs/cloudera.cluster.git,5.0.0` |
| `group_vars/all.yml` | `cloudera_cluster_collection_git_ref: 5.0.0` |
| `install_cm_client_python.yml` | Install v57 client per eng guidance (replace `pip install cm_client`) |
| `install_cloudera_collection.yml` | Invert verify: require `ApiClient(configuration=)`; require `cluster.py` |
| `scripts/lib/ansible_env.sh` | Min collection version 5.0.0 when migrating |
| Playbooks 31/33 | Re-test `cloudera.cluster.cluster` args (5.x renames e.g. `auto_tls`); keep `docs/CDP_BASE_CLUSTER_SERVICE_DEPS.md` in sync |
| Base cluster template | Prefer incremental `cloudera.cluster.service` (ozone-base pattern) if bulk `cluster` create still hits CM 400s on 5.x |

## Do not merge this branch until

- cm-client v57 is installable in CI with a documented command.
- CDH_INSTALL and ECS_INSTALL succeed on a lab stack.

## References

- [5.0.0 release notes](https://github.com/cloudera-labs/cloudera.cluster/releases/tag/5.0.0) — includes “Update to cm-client v57” (#326).
- Active pin on main: v4.4.0 + [PR #82](https://github.com/kuldeepsahu1105/cdp-onprem-automation/pull/82) rationale.

## 2026-10 upstream review

- [`cloudera-labs/cloudera.cluster#355`](https://github.com/cloudera-labs/cloudera.cluster/pull/355)
  proposes parallel parcel processing, but remains open with requested API
  changes. Do not pin to its branch or copy its unstable return contract.
- Main now provides equivalent deployment behavior through
  `common_tasks/activate_cluster_parcels.yml` and
  `scripts/lib/activate_cm_parcels.py`: backward-compatible single-item input,
  bounded parallel lists, per-parcel deadlines, transient CM HTTP 400 retries,
  and aggregate failures.
- Merged 5.0.0 parcel timeout/retry fixes are useful, but do not justify a
  collection upgrade by themselves because the local CM API helper already
  covers those failure modes.
- New 5.0.0 modules (`cm_autotls`, `cm_kerberos`, `control_plane`) remain
  migration candidates only. Replacing the proven local Auto-TLS, Kerberos, or
  ECS orchestration requires the cm-client v57 migration and dedicated
  end-to-end validation.

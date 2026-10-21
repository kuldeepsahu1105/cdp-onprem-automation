#!/usr/bin/env python3
"""Validate cluster / IPA DNS domains for Ozone Netty hostname verification (HDDS-16034).

Ozone DomainValidator (allowLocal=false) accepts hostnames whose public suffix is in
the IANA root zone. Private / mDNS-style suffixes (.local, .internal, …) fail TLS and
cert signing with errors such as ``Invalid domain`` in CertificateSignRequest.

Greenfield defaults use cldr.internal.arpa (private zone under the IANA
infrastructure TLD) or cluster.home.arpa (RFC 8375). Names ending in ``.arpa``
pass blocked-suffix checks; ``.local`` / ``.internal`` (without ``.arpa``), etc.
still fail. Brownfield stacks that still use a legacy suffix may set
``cluster_domain_skip_ozone_hostname_validation: true`` in Ansible group vars.
"""
from __future__ import annotations

import argparse
import re
import sys
from typing import Iterable, Sequence

# Repo default after HDDS-16034 alignment (must match group_vars/all.yml).
DEFAULT_FREEIPA_CLUSTER_DOMAIN = "cldr.internal.arpa"

# Suffixes that fail Ozone/Netty IANA-style checks (match domain or any parent label).
BLOCKED_DOMAIN_SUFFIXES: tuple[str, ...] = (
    ".local",
    ".internal",
    ".lan",
    ".corp",
    ".home",
    ".test",
    ".localdomain",
)

# Explicit user overrides that predate the new default — warn, do not fail validation.
LEGACY_GRANDFATHER_DOMAINS: frozenset[str] = frozenset(
    {
        "cldrsetup.local",
        "cldr.internal",
    }
)

# Private zones under .arpa (less standard than home.arpa; Ozone acceptance not confirmed).
PRIVATE_ARPA_ZONE_SUFFIXES: tuple[str, ...] = (
    ".internal.arpa",
    ".local.arpa",
    ".home.arpa",
)

# Common IANA TLDs for optional warn-only heuristic (not exhaustive).
COMMON_IANA_TLDS: frozenset[str] = frozenset(
    {
        "com",
        "net",
        "org",
        "edu",
        "gov",
        "io",
        "co",
        "uk",
        "arpa",
        "info",
        "biz",
        "us",
        "de",
        "fr",
        "au",
        "in",
        "jp",
        "cn",
        "example",  # RFC 2606 — documentation
    }
)

_DOMAIN_RE = re.compile(
    r"^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$",
    re.IGNORECASE,
)


class DomainValidationResult:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    @property
    def ok(self) -> bool:
        return not self.errors


def _normalize(domain: str) -> str:
    return domain.strip().lower().rstrip(".")


def _is_iana_arpa_domain(domain: str) -> bool:
    """True for names under the IANA infrastructure TLD (allows *.internal.arpa, etc.)."""
    return domain == "arpa" or domain.endswith(".arpa")


def _private_arpa_zone(domain: str) -> str | None:
    for suffix in PRIVATE_ARPA_ZONE_SUFFIXES:
        bare = suffix.lstrip(".")
        if domain == bare or domain.endswith(suffix):
            return bare
    return None


def _blocked_suffix_reason(domain: str) -> str | None:
    if _is_iana_arpa_domain(domain):
        return None
    for suffix in BLOCKED_DOMAIN_SUFFIXES:
        bare = suffix.lstrip(".")
        if domain == bare or domain.endswith(suffix):
            return suffix
    return None


def _public_suffix_label(domain: str) -> str:
    parts = domain.split(".")
    return parts[-1] if parts else ""


def validate_cluster_domain(
    domain: str,
    *,
    warn_non_iana_tld: bool = True,
    grandfather_legacy: bool = True,
) -> DomainValidationResult:
    result = DomainValidationResult()
    normalized = _normalize(domain)
    if not normalized:
        result.errors.append("cluster domain is empty")
        return result

    if not _DOMAIN_RE.match(normalized):
        result.errors.append(f"cluster domain '{domain}' is not a valid DNS hostname")
        return result

    blocked = _blocked_suffix_reason(normalized)
    if blocked:
        msg = (
            f"cluster domain '{domain}' uses suffix '{blocked}' which Ozone/Netty "
            "hostname verification rejects (HDDS-16034 / DomainValidator allowLocal=false). "
            "Use an IANA suffix (e.g. cldr.internal.arpa, cluster.home.arpa, lab.example.com) "
            "— not bare .local/.internal labels. "
            "Brownfield: set cluster_domain_skip_ozone_hostname_validation: true to opt out."
        )
        if grandfather_legacy and normalized in LEGACY_GRANDFATHER_DOMAINS:
            result.warnings.append("LEGACY (grandfathered): " + msg)
        else:
            result.errors.append(msg)

    if not result.errors:
        private_arpa = _private_arpa_zone(normalized)
        if private_arpa:
            result.warnings.append(
                f"cluster domain '{domain}' uses private zone '{private_arpa}' under .arpa; "
                "Ozone HDDS-16034 acceptance of *.internal.arpa / *.local.arpa is not confirmed "
                "in community threads (home.arpa is RFC 8375). Operator accepts risk or uses "
                "cluster_domain_skip_ozone_hostname_validation."
            )

    if warn_non_iana_tld and not result.errors:
        tld = _public_suffix_label(normalized)
        if _is_iana_arpa_domain(normalized):
            pass
        elif tld and tld not in COMMON_IANA_TLDS and len(tld) >= 2:
            result.warnings.append(
                f"cluster domain '{domain}' uses TLD '.{tld}' which is not in the "
                "automation's common IANA list; confirm it is in the IANA root zone for "
                "Ozone TLS hostname checks."
            )

    return result


def _emit(result: DomainValidationResult, *, quiet_warnings: bool) -> int:
    for w in result.warnings:
        if not quiet_warnings:
            print(f"WARNING: {w}", file=sys.stderr)
    for e in result.errors:
        print(f"ERROR: {e}", file=sys.stderr)
    return 0 if result.ok else 1


def _domains_from_yaml_mapping(data: dict) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    for key in ("ipaserver_domain", "cluster_domain", "ad_domain"):
        val = data.get(key)
        if isinstance(val, str) and val.strip():
            found.append((key, val.strip()))
    return found


def _parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--domain",
        action="append",
        default=[],
        help="DNS domain to validate (repeatable).",
    )
    parser.add_argument(
        "--from-ansible-group-vars-yaml",
        metavar="TEXT",
        help="Parse ipaserver_domain / cluster_domain / ad_domain from Jenkins textarea YAML.",
    )
    parser.add_argument(
        "--from-ansible-group-vars-file",
        metavar="PATH",
        help="Read Ansible group vars YAML file.",
    )
    parser.add_argument(
        "--from-tfvars-yaml",
        metavar="PATH",
        help="Read .tfvars.yaml and extract ansible-style domain keys if present.",
    )
    parser.add_argument(
        "--user-set-only",
        action="store_true",
        help=(
            "Exit 0 when no domain keys are present in --from-* sources "
            "(repo defaults apply at Ansible runtime)."
        ),
    )
    parser.add_argument(
        "--no-warn-non-iana",
        action="store_true",
        help="Disable warn-only heuristic for uncommon TLDs.",
    )
    parser.add_argument(
        "--quiet-warnings",
        action="store_true",
        help="Do not print warnings to stderr (errors still print).",
    )
    return parser.parse_args(argv)


def _load_yaml_file(path: str) -> dict:
    import yaml  # PyYAML — already required for ansible validation in this repo

    with open(path, encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    if not isinstance(data, dict):
        raise SystemExit(f"ERROR: expected YAML mapping in {path}")
    return data


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    domains: list[str] = list(args.domain)
    user_sourced = bool(args.domain)

    if args.from_ansible_group_vars_yaml:
        import yaml

        text = args.from_ansible_group_vars_yaml.strip()
        if text:
            user_sourced = True
            data = yaml.safe_load(text) or {}
            if isinstance(data, dict):
                for _, val in _domains_from_yaml_mapping(data):
                    domains.append(val)
            else:
                print("ERROR: ANSIBLE_GROUP_VARS_YAML must be a YAML mapping", file=sys.stderr)
                return 1

    if args.from_ansible_group_vars_file:
        user_sourced = True
        for _, val in _domains_from_yaml_mapping(_load_yaml_file(args.from_ansible_group_vars_file)):
            domains.append(val)

    if args.from_tfvars_yaml:
        for _, val in _domains_from_yaml_mapping(_load_yaml_file(args.from_tfvars_yaml)):
            domains.append(val)
            user_sourced = True

    if args.user_set_only and not user_sourced:
        return 0

    if not domains:
        domains.append(DEFAULT_FREEIPA_CLUSTER_DOMAIN)

    exit_code = 0
    seen: set[str] = set()
    for domain in domains:
        key = _normalize(domain)
        if key in seen:
            continue
        seen.add(key)
        result = validate_cluster_domain(
            domain,
            warn_non_iana_tld=not args.no_warn_non_iana,
        )
        exit_code = max(exit_code, _emit(result, quiet_warnings=args.quiet_warnings))

    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
#
# Repair A/PTR and ECS wildcard records after a deployment was accidentally
# rerun with the wrong FreeIPA domain.
#
# Run this on the configured FreeIPA server as root. The script derives the
# cluster host/IP map from the generated /etc/hosts file. It does not modify
# host principals or client enrollment.

set -euo pipefail

GOOD_DOMAIN=""
BAD_DOMAIN=""
APPLY=false
ASSUME_YES=false
DELETE_STALE_ZONE=false
HOST_MAP="${IPA_DNS_HOST_MAP:-/root/ipa-dns-host-map.txt}"

usage() {
  cat <<'EOF'
Usage:
  sudo ./fix-ipa-dns-domain.sh \
    --good-domain cldrsetup.local \
    --bad-domain cldr.internal.arpa \
    [--apply] [--delete-stale-zone] [--yes]

Options:
  --good-domain DOMAIN       Installed/live FreeIPA DNS domain.
  --bad-domain DOMAIN        Incorrect domain whose records must be removed.
  --apply                    Apply changes. Without this option, show the plan.
  --delete-stale-zone        Delete the entire incorrect forward DNS zone after
                             A/PTR/wildcard reconciliation.
  --yes                      Skip the interactive domain confirmation.
  --host-map FILE            Persist the derived "IP short-hostname" map here.
  -h, --help                 Show this help.

The script:
  1. Makes each inventory host's A record authoritative in GOOD_DOMAIN.
  2. Replaces all PTR values for each inventory IP with GOOD_DOMAIN.
  3. Sets *.apps.GOOD_DOMAIN to the pvcecs-master private IP.
  4. Optionally deletes BAD_DOMAIN as a complete forward zone.

It does not delete FreeIPA host principals. Inspect stale principals afterward:
  ipa host-find --all | grep -i -B2 -A4 'BAD_DOMAIN'
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --good-domain)
      GOOD_DOMAIN="${2:-}"
      shift 2
      ;;
    --bad-domain)
      BAD_DOMAIN="${2:-}"
      shift 2
      ;;
    --host-map)
      HOST_MAP="${2:-}"
      shift 2
      ;;
    --apply)
      APPLY=true
      shift
      ;;
    --delete-stale-zone)
      DELETE_STALE_ZONE=true
      shift
      ;;
    --yes)
      ASSUME_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$GOOD_DOMAIN" || -z "$BAD_DOMAIN" ]]; then
  echo "ERROR: --good-domain and --bad-domain are required" >&2
  usage >&2
  exit 2
fi

GOOD_DOMAIN="${GOOD_DOMAIN%.}"
BAD_DOMAIN="${BAD_DOMAIN%.}"

if [[ "$GOOD_DOMAIN" == "$BAD_DOMAIN" ]]; then
  echo "ERROR: good and bad domains must differ" >&2
  exit 2
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "ERROR: run this script as root on the FreeIPA server" >&2
  exit 1
fi

for command_name in awk ipa kinit klist sort; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
done

awk -v good="$GOOD_DOMAIN" -v bad="$BAD_DOMAIN" '
  $1 ~ /^([0-9]+\.){3}[0-9]+$/ &&
  $1 !~ /^127\./ &&
  (index($0, "." good) > 0 || index($0, "." bad) > 0) &&
  NF >= 3 {
    print $1, $NF
  }
' /etc/hosts | sort -u -k2,2 >"$HOST_MAP"

if [[ ! -s "$HOST_MAP" ]]; then
  echo "ERROR: no cluster hosts for either domain were found in /etc/hosts" >&2
  exit 1
fi

ecs_master_ip="$(
  awk '$2 == "pvcecs-master" {print $1; exit}' "$HOST_MAP"
)"

if [[ -z "$ecs_master_ip" ]]; then
  echo "ERROR: pvcecs-master was not found in $HOST_MAP" >&2
  exit 1
fi

echo "Installed domain: $GOOD_DOMAIN"
echo "Stale domain:     $BAD_DOMAIN"
echo "Host map:         $HOST_MAP"
echo "ECS master IP:    $ecs_master_ip"
echo
cat "$HOST_MAP"
echo

if ! $APPLY; then
  echo "DRY RUN: no DNS records were changed."
  echo "Re-run with --apply after reviewing the host map."
  exit 0
fi

if ! $ASSUME_YES; then
  read -r -p "Type the stale domain '$BAD_DOMAIN' to continue: " confirmation
  if [[ "$confirmation" != "$BAD_DOMAIN" ]]; then
    echo "Confirmation did not match; no changes made."
    exit 1
  fi
fi

klist -s || kinit admin

if ! ipa dnszone-show "$GOOD_DOMAIN" >/dev/null 2>&1; then
  echo "ERROR: installed forward DNS zone does not exist: $GOOD_DOMAIN" >&2
  exit 1
fi

while read -r ip host; do
  IFS=. read -r oct1 oct2 oct3 oct4 <<<"$ip"
  reverse_zone="${oct2}.${oct1}.in-addr.arpa."
  reverse_name="${oct4}.${oct3}"
  fqdn="${host}.${GOOD_DOMAIN}."

  echo "Reconciling ${host}: ${ip} <-> ${fqdn}"

  if ipa dnsrecord-show "$GOOD_DOMAIN" "$host" --raw >/dev/null 2>&1; then
    current_a="$(
      ipa dnsrecord-show "$GOOD_DOMAIN" "$host" --raw |
        awk -F': ' '/^[[:space:]]*arecord:/{print $2}'
    )"
    if [[ "$current_a" != "$ip" ]]; then
      ipa dnsrecord-mod "$GOOD_DOMAIN" "$host" --a-rec="$ip"
    fi
  else
    ipa dnsrecord-add "$GOOD_DOMAIN" "$host" --a-rec="$ip"
  fi

  ipa dnszone-show "$reverse_zone" >/dev/null 2>&1 ||
    ipa dnszone-add "$reverse_zone"

  if ipa dnsrecord-show "$reverse_zone" "$reverse_name" --raw >/dev/null 2>&1; then
    current_ptr="$(
      ipa dnsrecord-show "$reverse_zone" "$reverse_name" --raw |
        awk -F': ' '/^[[:space:]]*ptrrecord:/{print $2}'
    )"
    if [[ "$current_ptr" != "$fqdn" ]]; then
      ipa dnsrecord-mod "$reverse_zone" "$reverse_name" --ptr-rec="$fqdn"
    fi
  else
    ipa dnsrecord-add "$reverse_zone" "$reverse_name" --ptr-rec="$fqdn"
  fi
done <"$HOST_MAP"

wildcard_name="*.apps"
if ipa dnsrecord-show "$GOOD_DOMAIN" "$wildcard_name" --raw >/dev/null 2>&1; then
  current_wildcard="$(
    ipa dnsrecord-show "$GOOD_DOMAIN" "$wildcard_name" --raw |
      awk -F': ' '/^[[:space:]]*arecord:/{print $2}'
  )"
  if [[ "$current_wildcard" != "$ecs_master_ip" ]]; then
    ipa dnsrecord-mod "$GOOD_DOMAIN" "$wildcard_name" --a-rec="$ecs_master_ip"
  fi
else
  ipa dnsrecord-add "$GOOD_DOMAIN" "$wildcard_name" --a-rec="$ecs_master_ip"
fi

if $DELETE_STALE_ZONE && ipa dnszone-show "$BAD_DOMAIN" >/dev/null 2>&1; then
  echo "Deleting stale forward DNS zone: $BAD_DOMAIN"
  ipa dnszone-del "$BAD_DOMAIN"
elif ipa dnszone-show "$BAD_DOMAIN" >/dev/null 2>&1; then
  echo "NOTICE: stale zone still exists: $BAD_DOMAIN"
  echo "Re-run with --delete-stale-zone after reviewing its contents."
fi

echo
echo "DNS reconciliation completed."
echo "Verify:"
echo "  dig +short console-cdp.apps.${GOOD_DOMAIN} A"
echo "  while read -r ip host; do printf '%-20s %-25s ' \"\$ip\" \"\$host\"; dig +short -x \"\$ip\"; done <'$HOST_MAP'"
echo "  ipa host-find --all | grep -i -B2 -A4 '${BAD_DOMAIN//./\\.}'"

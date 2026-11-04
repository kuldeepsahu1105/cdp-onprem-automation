#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
playbook="$root/ansible-playbooks/roles/ecs/tasks/setup_data_services.yml"
tls="$root/ansible-playbooks/roles/ecs/tasks/ecs_data_service_cai_tls_converge.yml"
tls_wrapper="$root/ansible-playbooks/roles/ecs/tasks/ecs_data_service_cai_tls.yml"
wildcard_profile="$root/ansible-playbooks/roles/ecs/tasks/ecs_cai_freeipa_wildcard_profile.yml"
wildcard_template="$root/ansible-playbooks/roles/ecs/templates/ecs_cai_freeipa_wildcard_profile.cfg.j2"
start="$root/ansible-playbooks/roles/ecs/tasks/ecs_data_service_cai_start.yml"
create_attempt="$root/ansible-playbooks/roles/ecs/tasks/ecs_data_service_cai_create_attempt.yml"
create_attempt_unresolved="$root/ansible-playbooks/roles/ecs/tasks/ecs_data_service_cai_create_attempt_unresolved.yml"
endpoint="$root/ansible-playbooks/roles/ecs/tasks/ecs_data_service_cai_endpoint.yml"
ldap="$root/ansible-playbooks/roles/ecs/tasks/ecs_control_plane_ldap_and_admin.yml"

tls_line=$(grep -n 'Converge and validate CAI TLS before workspace submission' "$playbook" | cut -d: -f1)
start_line=$(grep -n 'Launch CAI' "$playbook" | cut -d: -f1)
test "$tls_line" -lt "$start_line"

grep -q 'Process candidate while workspace remains unresolved' "$create_attempt"
grep -q 'ecs_cai_existing_workspace | default({}) | length == 0' "$create_attempt"
grep -q 'subdomain: "{{ ecs_cai_static_subdomain_effective }}"' "$create_attempt_unresolved"
grep -q 'ecs_cai_tls_subdomain_validated' "$create_attempt_unresolved"
grep -q 'ecs_cai_tls_secret_valid | default(false) | bool' "$start"
grep -q "ecs_cai_tls_provider_effective == 'freeipa'" "$tls"
grep -q "ecs_cai_tls_provider_effective == 'external'" "$tls"
grep -q 'Existing .* is absent or invalid' "$tls"
grep -Fq 'openssl x509 -in "$cert" -noout -checkhost "$host"' "$tls"
grep -Fq 'openssl x509 -in "$cert" -noout -checkhost "probe.$host"' "$tls"
grep -Fq 'openssl verify -CAfile "$ca" "$cert"' "$tls"
grep -Fq 'openssl pkey -in "$key" -pubout' "$tls"
grep -q 'ecs_cai_existing_tls_secret_valid' "$tls"
grep -q 'Preserve adopted workspace endpoint contract' "$tls"
grep -q 'ecs_cai_freeipa_wildcard_profile.yml' "$tls"
! grep -q 'cloudera.exe.freeipa_server_wildcard_profile' "$tls"
grep -q 'KRB5CCNAME: "FILE:{{ ecs_cai_profile_krb5_cache.path }}"' "$wildcard_profile"
grep -q 'Remove FreeIPA profile Kerberos cache' "$wildcard_profile"
grep -q 'certprofile-mod' "$wildcard_profile"
! grep -q 'community.general.krb_ticket' "$wildcard_profile"
grep -q 'subjAltNameNumGNs=2' "$wildcard_template"
grep -q 'subjAltExtPattern_0=\$request.req_subject_name.cn\$' "$wildcard_template"
grep -q 'subjAltExtPattern_1=\*.\$request.req_subject_name.cn\$' "$wildcard_template"
grep -q 'Remove stale certificate request artifacts' "$tls"
grep -q 'Require endpoint to match the pre-created TLS hostname' "$endpoint"
grep -q 'always:' "$tls_wrapper"
grep -q 'ansible_python_interpreter: "{{ ansible_playbook_python }}"' "$tls_wrapper"
grep -q 'delegate_to: localhost' "$tls_wrapper"
! grep -Eqi 'generate.*self[- ]signed|create.*temporary.*certificate' "$tls"

# LDAP/IAM flags false make the optional phase a complete no-op. The task
# graph contains no provider/user/credential removal path.
grep -q 'ecs_ldap_sync_effective' "$ldap"
grep -q 'ecs_ldap_admin_user_effective' "$ldap"
! grep -Eqi '(delete|disable|reset|state:[[:space:]]*absent).*(ldap|provider|user|credential)' "$ldap"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
host=cai.apps.cldr.internal.arpa

openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
  -subj '/CN=CAI test root' \
  -keyout "$tmpdir/ca.key" -out "$tmpdir/ca.crt" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj "/CN=$host" \
  -addext "subjectAltName=DNS:$host,DNS:*.$host" \
  -keyout "$tmpdir/tls.key" -out "$tmpdir/tls.csr" >/dev/null 2>&1
cat >"$tmpdir/ext.cnf" <<EOF
subjectAltName=DNS:$host,DNS:*.$host
EOF
openssl x509 -req -days 2 -in "$tmpdir/tls.csr" \
  -CA "$tmpdir/ca.crt" -CAkey "$tmpdir/ca.key" -CAcreateserial \
  -extfile "$tmpdir/ext.cnf" -out "$tmpdir/tls.crt" >/dev/null 2>&1

validate_tls() {
  local cert=$1 key=$2 ca=$3 expected=$4
  openssl x509 -in "$cert" -noout -checkend 60 >/dev/null &&
    openssl x509 -in "$cert" -noout -checkhost "$expected" >/dev/null &&
    openssl x509 -in "$cert" -noout -checkhost "probe.$expected" >/dev/null &&
    test \
      "$(openssl x509 -in "$cert" -noout -subject -nameopt RFC2253)" != \
      "$(openssl x509 -in "$cert" -noout -issuer -nameopt RFC2253 | sed 's/^issuer=/subject=/')" &&
    openssl verify -CAfile "$ca" "$cert" >/dev/null &&
    test \
      "$(openssl x509 -in "$cert" -pubkey -noout | openssl pkey -pubin -outform DER | openssl sha256)" = \
      "$(openssl pkey -in "$key" -pubout -outform DER | openssl sha256)"
}

validate_tls "$tmpdir/tls.crt" "$tmpdir/tls.key" "$tmpdir/ca.crt" "$host"
! validate_tls "$tmpdir/tls.crt" "$tmpdir/tls.key" "$tmpdir/ca.crt" "wrong.$host"
openssl genpkey -algorithm RSA -out "$tmpdir/wrong.key" \
  -pkeyopt rsa_keygen_bits:2048 >/dev/null 2>&1
! validate_tls "$tmpdir/tls.crt" "$tmpdir/wrong.key" "$tmpdir/ca.crt" "$host"
! validate_tls "$tmpdir/ca.crt" "$tmpdir/ca.key" "$tmpdir/ca.crt" "$host"

echo "CAI pre-create TLS and LDAP no-op checks passed"

#!/usr/bin/env bash
set -euo pipefail

: "${FREEIPA_MODERN_URL:?Set FREEIPA_MODERN_URL to the Caddy /ipa/modern-ui/ URL}"
: "${FREEIPA_USERNAME:?Set FREEIPA_USERNAME to a form-login user}"
: "${FREEIPA_LOGIN_SECRET:?Set FREEIPA_LOGIN_SECRET to that user's login credential}"

workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT

base_url="${FREEIPA_MODERN_URL%/ipa/modern-ui/}"
cookie_jar="${workdir}/cookies.txt"
password_field="password"

curl_args=(--silent --show-error --max-time 20)
if [[ -n "${FREEIPA_CA_CERT:-}" ]]; then
  curl_args+=(--cacert "${FREEIPA_CA_CERT}")
fi

curl "${curl_args[@]}" --dump-header "${workdir}/modern.headers" \
  --output "${workdir}/modern.html" "${base_url}/ipa/modern-ui/"

grep -Eq '^HTTP/[^ ]+ 200([[:space:]]|$)' "${workdir}/modern.headers"
if grep -Eiq '^WWW-Authenticate:[[:space:]]*(Negotiate|Basic)' "${workdir}/modern.headers"; then
  echo "Modern UI still forces a browser authentication challenge" >&2
  exit 1
fi
if grep -Eiq 'obtain.*kerberos|run[[:space:]]+kinit|kerberos ticket' "${workdir}/modern.html"; then
  echo "Modern UI returned a Kerberos/kinit prerequisite page" >&2
  exit 1
fi
grep -Eiq 'freeipa|identity management|modern-ui|id="root"|id="app"' "${workdir}/modern.html"

login_status="$(
  curl "${curl_args[@]}" --cookie-jar "${cookie_jar}" --dump-header "${workdir}/login.headers" \
    --output "${workdir}/login.body" --write-out '%{http_code}' \
    --request POST "${base_url}/ipa/session/login_password" \
    --header "Referer: ${base_url}/ipa/modern-ui/" \
    --header "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "user=${FREEIPA_USERNAME}" \
    --data-urlencode "${password_field}=${FREEIPA_LOGIN_SECRET}"
)"

case "${login_status}" in
  200|204) ;;
  *)
    echo "FreeIPA password login returned HTTP ${login_status}" >&2
    cat "${workdir}/login.headers" >&2
    exit 1
    ;;
esac
if grep -Eiq '^WWW-Authenticate:[[:space:]]*(Negotiate|Basic)' "${workdir}/login.headers"; then
  echo "Password login forced a browser authentication challenge" >&2
  exit 1
fi
grep -Eiq 'ipa_session|Set-Cookie:.*ipa_session' "${cookie_jar}" "${workdir}/login.headers"

authenticated_status="$(
  curl "${curl_args[@]}" --cookie "${cookie_jar}" --output "${workdir}/authenticated.html" \
    --write-out '%{http_code}' "${base_url}/ipa/modern-ui/"
)"
test "${authenticated_status}" = "200"

kerberos_status="$(
  curl "${curl_args[@]}" --dump-header "${workdir}/kerberos.headers" \
    --output "${workdir}/kerberos.body" --write-out '%{http_code}' \
    "${base_url}/ipa/session/login_kerberos"
)"
case "${kerberos_status}" in
  200|401|403) ;;
  *)
    echo "Kerberos session endpoint is no longer routed (HTTP ${kerberos_status})" >&2
    exit 1
    ;;
esac
if grep -Eiq '^WWW-Authenticate:[[:space:]]*(Negotiate|Basic)' "${workdir}/kerberos.headers"; then
  echo "Caddy browser route still advertises an interactive Kerberos/basic challenge" >&2
  exit 1
fi

echo "FreeIPA modern UI form-login flow passed at ${base_url}"

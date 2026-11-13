#!/usr/bin/python

DOCUMENTATION = r"""
---
module: cdw_private_dwx
short_description: Invoke private CDW DWX operations
description:
  - Authenticates to the CDP Private Cloud console with a short-lived session.
  - Invokes private DWX REST operations without persisting browser cookies.
options:
  base_url:
    description: CDP Private Cloud console base URL.
    required: true
    type: str
  account_id:
    description: CDP account identifier used by local console authentication.
    required: true
    type: str
  username:
    description: Local console login username.
    required: true
    type: str
  password:
    description: Local console login password.
    required: true
    type: str
  operation:
    description: Private DWX operation to perform.
    required: true
    choices:
      - activate_environment
      - create_hive_virtual_warehouse
    type: str
  environment:
    description: CDP environment name.
    required: true
    type: str
  environment_crn:
    description: Environment CRN required for activation.
    type: str
  payload:
    description: Exact JSON payload for the selected operation.
    required: true
    type: dict
  validate_certs:
    description: Validate the console TLS certificate.
    type: bool
    default: true
  ca_path:
    description: Optional CA bundle used for console TLS validation.
    type: path
  timeout:
    description: HTTP request timeout in seconds.
    type: int
    default: 60
author:
  - CDP on-prem automation contributors
"""

EXAMPLES = r"""
- name: Activate CDW Low Resource Mode
  cdw_private_dwx:
    base_url: https://console-cdp.apps.example.internal
    account_id: account-id
    username: admin
    password: "{{ console_password }}"
    operation: activate_environment
    environment: env-example
    environment_crn: crn:altus:environments:us-west-1:account-id:environment:example/id
    payload:
      clusterName: example
      validationOnly: false
      customEnvSubdomain: ""
      enableLowResourceMode: true
      envBootstrap:
        proxyInfo: {}

- name: Create reduced-resource Hive Virtual Warehouse
  cdw_private_dwx:
    base_url: https://console-cdp.apps.example.internal
    account_id: account-id
    username: admin
    password: "{{ console_password }}"
    operation: create_hive_virtual_warehouse
    environment: env-example
    payload:
      computeName: hive-vw
      warehouseId: warehouse-example
      tShirtSize: xsmall
      resourceTemplate: hive-low
"""

RETURN = r"""
status:
  description: HTTP status returned by the DWX operation.
  type: int
  returned: always
response:
  description: Parsed non-sensitive DWX response.
  type: dict
  returned: when available
"""

import json
import ssl
from http.cookiejar import CookieJar
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlencode
from urllib.request import (
    HTTPCookieProcessor,
    HTTPSHandler,
    Request,
    build_opener,
)

from ansible.module_utils.basic import AnsibleModule


def build_ssl_context(validate_certs, ca_path):
    if not validate_certs:
        return ssl._create_unverified_context()
    if ca_path:
        return ssl.create_default_context(cafile=ca_path)
    return ssl.create_default_context()


def read_response(response):
    return response.getcode(), response.read()


def request(opener, request, timeout):
    try:
        with opener.open(request, timeout=timeout) as response:
            return read_response(response)
    except HTTPError as error:
        return error.code, error.read()
    except (OSError, URLError) as error:
        raise RuntimeError(str(error)) from error


def parse_json(body):
    if not body:
        return {}
    try:
        value = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return {"message": body.decode("utf-8", errors="replace")}
    return value if isinstance(value, dict) else {"value": value}


def main():
    module = AnsibleModule(
        argument_spec={
            "base_url": {"type": "str", "required": True},
            "account_id": {"type": "str", "required": True},
            "username": {"type": "str", "required": True},
            "password": {"type": "str", "required": True, "no_log": True},
            "operation": {
                "type": "str",
                "required": True,
                "choices": [
                    "activate_environment",
                    "create_hive_virtual_warehouse",
                ],
            },
            "environment": {"type": "str", "required": True},
            "environment_crn": {"type": "str", "required": False},
            "payload": {"type": "dict", "required": True},
            "validate_certs": {"type": "bool", "default": True},
            "ca_path": {"type": "path", "required": False},
            "timeout": {"type": "int", "default": 60},
        },
        required_if=[
            ("operation", "activate_environment", ["environment_crn"]),
        ],
        supports_check_mode=True,
    )

    base_url = module.params["base_url"].rstrip("/")
    account_id = module.params["account_id"]
    environment = module.params["environment"]
    operation = module.params["operation"]
    timeout = module.params["timeout"]
    if module.check_mode:
        module.exit_json(changed=True, status=0, response={})
    try:
        context = build_ssl_context(
            module.params["validate_certs"],
            module.params["ca_path"],
        )
    except OSError as error:
        module.fail_json(msg=f"Unable to initialize console TLS: {error}")
    cookie_jar = CookieJar()
    opener = build_opener(HTTPSHandler(context=context), HTTPCookieProcessor(cookie_jar))
    login_redirect = f"{base_url}/commonconsole"
    login_url = (
        f"{base_url}/authenticate/callback/local?"
        f"accountId={quote(account_id, safe='')}&"
        f"loginRedirect={quote(login_redirect, safe='')}"
    )
    login_body = urlencode(
        {
            "accountId": account_id,
            "loginRedirect": login_redirect,
            "username": module.params["username"],
            "password": module.params["password"],
        }
    ).encode("utf-8")
    login_request = Request(
        login_url,
        data=login_body,
        headers={
            "Accept": "text/html,application/xhtml+xml",
            "Content-Type": "application/x-www-form-urlencoded",
            "Origin": base_url,
            "Referer": (
                f"{base_url}/authenticate-ui/challenge.html?"
                f"accountId={quote(account_id, safe='')}"
            ),
        },
        method="POST",
    )

    try:
        login_status, login_response = request(opener, login_request, timeout)
    except RuntimeError as error:
        module.fail_json(msg=f"Private console login failed: {error}")
    session_cookie = next(
        (cookie for cookie in cookie_jar if cookie.name == "cdp-pvt-session-token"),
        None,
    )
    if session_cookie is None:
        module.fail_json(
            msg="Private console login did not return a session cookie.",
            status=login_status,
            response=parse_json(login_response),
        )

    if operation == "activate_environment":
        operation_url = (
            f"{base_url}/dwx/api/v2/environments?"
            f"environmentCrn={quote(module.params['environment_crn'], safe='')}"
        )
    else:
        operation_url = (
            f"{base_url}/dwx/api/v2/environments/"
            f"{quote(environment, safe='')}/llaps?start"
        )
    operation_request = Request(
        operation_url,
        data=json.dumps(module.params["payload"], separators=(",", ":")).encode("utf-8"),
        headers={
            "Accept": "application/json, text/plain, */*",
            "Content-Type": "application/json",
            "Origin": base_url,
            "Referer": f"{base_url}/dwx/home",
        },
        method="POST",
    )
    try:
        status, response_body = request(opener, operation_request, timeout)
    except RuntimeError as error:
        module.fail_json(msg=f"Private DWX request failed: {error}")
    response = parse_json(response_body)
    if status != 202:
        module.fail_json(
            msg=f"Private DWX request returned HTTP {status}.",
            status=status,
            response=response,
        )
    module.exit_json(changed=True, status=status, response=response)


if __name__ == "__main__":
    main()

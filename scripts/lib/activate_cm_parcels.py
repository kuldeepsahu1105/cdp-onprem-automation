#!/usr/bin/env python3
"""Activate one or more Cloudera Manager parcels concurrently."""

from __future__ import annotations

import concurrent.futures
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


DOWNLOAD_COMPLETE = {
    "DOWNLOADED",
    "DISTRIBUTING",
    "DISTRIBUTED",
    "ACTIVATING",
    "ACTIVATED",
}
DISTRIBUTION_COMPLETE = {"DISTRIBUTED", "ACTIVATING", "ACTIVATED"}


class ParcelError(RuntimeError):
    pass


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or not value.strip():
        raise ParcelError(f"Required environment variable {name} is not set")
    return value.strip()


class CmClient:
    def __init__(self) -> None:
        self.api_url = env("CM_API_URL").rstrip("/")
        self.username = env("CM_USERNAME")
        self.password = env("CM_PASSWORD")
        self.cluster = env("CM_CLUSTER")
        self.timeout = int(env("CM_PARCEL_TIMEOUT", "3600"))
        self.poll_delay = int(env("CM_PARCEL_POLL_DELAY", "15"))
        self.command_retries = int(env("CM_PARCEL_COMMAND_RETRIES", "3"))
        self.command_retry_delay = int(env("CM_PARCEL_COMMAND_RETRY_DELAY", "10"))
        credentials = f"{self.username}:{self.password}".encode()
        import base64

        self.authorization = "Basic " + base64.b64encode(credentials).decode()
        self.ssl_context = ssl._create_unverified_context()

    def request(self, url: str, method: str = "GET") -> dict:
        request = urllib.request.Request(
            url,
            data=b"" if method == "POST" else None,
            method=method,
            headers={
                "Authorization": self.authorization,
                "Accept": "application/json",
            },
        )
        try:
            with urllib.request.urlopen(
                request,
                context=self.ssl_context,
                timeout=60,
            ) as response:
                body = response.read().decode()
                return json.loads(body) if body else {}
        except urllib.error.HTTPError as exc:
            body = exc.read().decode(errors="replace")
            message = body
            try:
                message = json.loads(body).get("message", body)
            except json.JSONDecodeError:
                pass
            raise ParcelError(f"CM API {method} {url} returned HTTP {exc.code}: {message}") from exc
        except urllib.error.URLError as exc:
            raise ParcelError(f"CM API {method} {url} failed: {exc.reason}") from exc

    def parcel_url(self, product: str, version: str) -> str:
        return (
            f"{self.api_url}/clusters/{urllib.parse.quote(self.cluster, safe='')}"
            f"/parcels/products/{urllib.parse.quote(product, safe='')}"
            f"/versions/{urllib.parse.quote(version, safe='')}"
        )

    def stage(self, parcel_url: str) -> dict:
        return self.request(parcel_url)

    def wait_for(self, parcel_url: str, accepted: set[str], deadline: float) -> dict:
        while True:
            status = self.stage(parcel_url)
            if status.get("stage") in accepted:
                return status
            errors = status.get("state", {}).get("errors", [])
            if errors:
                raise ParcelError("; ".join(str(error) for error in errors))
            if time.monotonic() >= deadline:
                raise ParcelError(
                    f"Timed out after {self.timeout}s at stage "
                    f"{status.get('stage', 'unknown')}"
                )
            time.sleep(self.poll_delay)

    def transition(
        self,
        parcel_url: str,
        command: str,
        accepted: set[str],
        deadline: float,
    ) -> dict:
        last_error: ParcelError | None = None
        for attempt in range(1, self.command_retries + 1):
            try:
                self.request(f"{parcel_url}/commands/{command}", method="POST")
                return self.wait_for(parcel_url, accepted, deadline)
            except ParcelError as exc:
                last_error = exc
                status = self.stage(parcel_url)
                if status.get("stage") in accepted:
                    return status
                if "HTTP 400" not in str(exc) or attempt == self.command_retries:
                    raise
                time.sleep(self.command_retry_delay)
        raise last_error or ParcelError(f"Failed to submit parcel command {command}")

    def activate(self, target: dict) -> dict:
        product = str(target["name"]).strip()
        version = str(target["parcel_version"]).strip()
        parcel_url = self.parcel_url(product, version)
        deadline = time.monotonic() + self.timeout
        initial = self.stage(parcel_url)
        initial_stage = initial.get("stage")
        status = initial

        if initial_stage == "AVAILABLE_REMOTELY":
            status = self.transition(parcel_url, "startDownload", DOWNLOAD_COMPLETE, deadline)
        elif initial_stage not in DOWNLOAD_COMPLETE:
            status = self.wait_for(parcel_url, DOWNLOAD_COMPLETE, deadline)

        if status.get("stage") == "DOWNLOADED":
            status = self.transition(
                parcel_url,
                "startDistribution",
                DISTRIBUTION_COMPLETE,
                deadline,
            )
        elif status.get("stage") not in DISTRIBUTION_COMPLETE:
            status = self.wait_for(parcel_url, DISTRIBUTION_COMPLETE, deadline)

        if status.get("stage") == "DISTRIBUTED":
            status = self.transition(parcel_url, "activate", {"ACTIVATED"}, deadline)
        elif status.get("stage") != "ACTIVATED":
            status = self.wait_for(parcel_url, {"ACTIVATED"}, deadline)

        return {
            "name": product,
            "parcel_version": version,
            "initial_stage": initial_stage,
            "stage": status.get("stage"),
            "changed": initial_stage != "ACTIVATED",
        }


def main() -> int:
    try:
        parcels = json.loads(env("CM_PARCELS_JSON"))
        if not isinstance(parcels, list) or not parcels:
            raise ParcelError("CM_PARCELS_JSON must be a non-empty list")
        keys = [
            (str(parcel.get("name", "")).strip(), str(parcel.get("parcel_version", "")).strip())
            for parcel in parcels
        ]
        if any(not name or not version for name, version in keys):
            raise ParcelError("Each parcel requires non-empty name and parcel_version")
        if len(keys) != len(set(keys)):
            raise ParcelError("Parcel name/version pairs must be unique")

        client = CmClient()
        max_workers = max(1, int(env("CM_PARCEL_MAX_WORKERS", "2")))
        results: list[dict] = []
        failures: list[dict] = []

        with concurrent.futures.ThreadPoolExecutor(
            max_workers=min(max_workers, len(parcels)),
            thread_name_prefix="cm-parcel",
        ) as executor:
            futures = [(parcel, executor.submit(client.activate, parcel)) for parcel in parcels]
            for parcel, future in futures:
                try:
                    results.append(future.result())
                except Exception as exc:
                    failures.append(
                        {
                            "name": parcel.get("name"),
                            "parcel_version": parcel.get("parcel_version"),
                            "error": str(exc),
                        }
                    )

        output = {
            "changed": any(result["changed"] for result in results),
            "parcels": results,
            "failures": failures,
        }
        print(json.dumps(output, sort_keys=True))
        return 1 if failures else 0
    except Exception as exc:
        print(json.dumps({"changed": False, "parcels": [], "failures": [{"error": str(exc)}]}))
        return 1


if __name__ == "__main__":
    sys.exit(main())

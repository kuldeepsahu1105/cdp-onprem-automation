#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path

import yaml


def main() -> int:
    if len(sys.argv) != 2:
        return 2

    try:
        payload = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError):
        return 2

    if not isinstance(payload, dict):
        return 2

    access_key_id = payload.get("access_key_id")
    private_key = payload.get("private_key")
    if not isinstance(access_key_id, str) or not access_key_id:
        return 2
    if not isinstance(private_key, str) or not private_key:
        return 2
    if re.search(r"^-----BEGIN [^-]+----- ", private_key):
        return 2

    print(
        json.dumps(
            {
                "access_key_id": access_key_id,
                "private_key": private_key,
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

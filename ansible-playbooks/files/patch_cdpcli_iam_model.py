#!/usr/bin/env python3
import pathlib
import sys

import yaml


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: patch_cdpcli_iam_model.py SOURCE DESTINATION")

    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    model = yaml.safe_load(source.read_text(encoding="utf-8"))
    request = model["definitions"]["CreateUserRequest"]
    request.setdefault("properties", {})["identityProviderCrn"] = {
        "type": "string",
        "description": "The CRN of the identity provider associated with the user.",
    }

    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(
        yaml.safe_dump(model, sort_keys=False),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

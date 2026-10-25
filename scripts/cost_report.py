#!/usr/bin/env python3
"""Offline cost reporting entry point; no SDKs, credentials, or network access."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from cost_reporting import main


if __name__ == "__main__":
    raise SystemExit(main())

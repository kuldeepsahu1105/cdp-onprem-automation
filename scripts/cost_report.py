#!/usr/bin/env python3
"""Cost reporting entry point; only live-report invokes the AWS CLI."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from cost_reporting import main


if __name__ == "__main__":
    raise SystemExit(main())

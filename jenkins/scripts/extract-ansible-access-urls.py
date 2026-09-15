#!/usr/bin/env python3
"""Extract plain-text CDP_ACCESS_URLS block from Ansible phase logs or escaped debug JSON."""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

BEGIN = "========== CDP_ACCESS_URLS_BEGIN =========="
END = "========== CDP_ACCESS_URLS_END =========="

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[a-zA-Z]")
ANSI_OSC_RE = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)")


def strip_ansi(text: str) -> str:
    text = ANSI_RE.sub("", text)
    return ANSI_OSC_RE.sub("", text)


def slice_between_markers(text: str) -> str | None:
    start = text.find(BEGIN)
    if start < 0:
        return None
    end = text.find(END, start)
    if end < 0:
        return None
    end += len(END)
    return text[start:end].strip()


def extract_from_debug_msgs(text: str) -> str | None:
    """Find ansible.builtin.debug msg values that contain the access URL report."""
    idx = 0
    decoder = json.JSONDecoder()
    while True:
        pos = text.find('"msg"', idx)
        if pos < 0:
            return None
        colon = text.find(":", pos)
        if colon < 0:
            return None
        rest = text[colon + 1 :].lstrip()
        if not rest:
            return None
        try:
            if rest[0] == '"':
                msg, _ = decoder.raw_decode(rest)
            elif rest[0] == "[":
                msg_list, _ = decoder.raw_decode(rest)
                msg = "\n".join(str(x) for x in msg_list)
            else:
                idx = pos + 5
                continue
        except json.JSONDecodeError:
            idx = pos + 5
            continue
        if not isinstance(msg, str):
            idx = pos + 5
            continue
        block = slice_between_markers(msg)
        if block:
            return block
        idx = pos + 5
    return None


def extract_access_urls_text(raw: str) -> str | None:
    text = strip_ansi(raw)
    block = slice_between_markers(text)
    if block and "\\n" in block and "\n" not in block.split(BEGIN, 1)[-1][:80]:
        try:
            unescaped = bytes(block, "utf-8").decode("unicode_escape")
            block = slice_between_markers(unescaped) or unescaped.strip()
        except UnicodeDecodeError:
            pass
    if block and BEGIN in block and END in block:
        return block
    block = extract_from_debug_msgs(text)
    return block


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        nargs="?",
        help="Ansible phase log or text file containing CDP_ACCESS_URLS_* markers",
    )
    parser.add_argument(
        "--normalize",
        action="store_true",
        help="Read path (or stdin), write cleaned block to stdout (pass-through if already plain)",
    )
    args = parser.parse_args()

    if args.path:
        raw = Path(args.path).read_text(encoding="utf-8", errors="replace")
    else:
        raw = sys.stdin.read()

    block = extract_access_urls_text(raw)
    if not block:
        return 1

    sys.stdout.write(block)
    if not block.endswith("\n"):
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env bash
# Shared Jenkins sh-step setup: disable xtrace noise, default quiet output.

set +x 2>/dev/null || true

export OUTPUT_MODE="${OUTPUT_MODE:-quiet}"
export LOG_DIR="${LOG_DIR:-${REPO_ROOT:-${WORKSPACE:-.}}/jenkins/artifacts}"

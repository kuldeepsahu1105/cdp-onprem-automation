#!/usr/bin/env bash
# Load deployment configuration from .tfvars.yaml, .tfvars.yml, or .tfvars.env
#
# Optional: set TFVARS_FILE to an explicit config path.
# Resolution order (when TFVARS_FILE is unset):
#   1. .tfvars.yaml
#   2. .tfvars.yml
#   3. .tfvars.env

set -euo pipefail

load_tfvars__lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_tfvars__resolve_file() {
    if [[ -n "${TFVARS_FILE:-}" ]]; then
        if [[ ! -f "$TFVARS_FILE" ]]; then
            echo "Error: TFVARS_FILE is set but not found: $TFVARS_FILE" >&2
            return 1
        fi
        printf '%s' "$TFVARS_FILE"
        return 0
    fi

    if [[ -f ".tfvars.yaml" ]]; then
        printf '%s' ".tfvars.yaml"
    elif [[ -f ".tfvars.yml" ]]; then
        printf '%s' ".tfvars.yml"
    elif [[ -f ".tfvars.env" ]]; then
        printf '%s' ".tfvars.env"
    else
        echo "Error: no config file found. Create one of:" >&2
        echo "  - .tfvars.yaml  (recommended structured format)" >&2
        echo "  - .tfvars.yml" >&2
        echo "  - .tfvars.env   (shell format)" >&2
        echo "Or set TFVARS_FILE to your config path." >&2
        return 1
    fi
}

load_tfvars() {
    local config_file
    config_file="$(load_tfvars__resolve_file)"

    case "$config_file" in
        *.yaml|*.yml)
            if ! command -v python3 >/dev/null 2>&1; then
                echo "Error: python3 is required to load YAML config ($config_file)." >&2
                return 1
            fi
            # shellcheck disable=SC1090
            eval "$(python3 "$load_tfvars__lib_dir/parse_tfvars_yaml.py" "$config_file")"
            # shellcheck source=scripts/lib/tfvars_defaults.sh
            source "$load_tfvars__lib_dir/tfvars_defaults.sh"
            # shellcheck source=scripts/lib/build_tf_vars.sh
            source "$load_tfvars__lib_dir/build_tf_vars.sh"
            ;;
        *.env)
            set -a
            # shellcheck disable=SC1090
            source "$config_file"
            set +a
            ;;
        *)
            echo "Error: unsupported config file extension: $config_file" >&2
            return 1
            ;;
    esac

    export TFVARS_LOADED_FROM="$config_file"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    load_tfvars
    echo "Loaded configuration from: ${TFVARS_LOADED_FROM}"
fi

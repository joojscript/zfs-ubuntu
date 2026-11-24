# shellcheck shell=bash
# Load the YAML host config into CFG_* shell variables via config.py.

# load_config <path-to-yaml>
# Populates CFG_* variables in the current shell and exports CONFIG_FILE.
load_config() {
  local file="$1"
  [[ -f "$file" ]] || die "config file not found: $file"
  require_cmd python3

  # Ensure PyYAML is importable; the bootstrap installs it on the live USB.
  if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    die "python3 PyYAML missing. Run: apt-get update && apt-get install -y python3-yaml"
  fi

  local here flat
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Validate first for a clean error message.
  if ! python3 "$here/config.py" validate "$file" >/dev/null; then
    python3 "$here/config.py" validate "$file" || true
    die "configuration invalid — fix the errors above"
  fi

  flat="$(python3 "$here/config.py" flatten "$file")" || die "failed to parse config"
  # The flattened output is a series of safe `KEY=value` assignments.
  eval "$flat"
  export CONFIG_FILE="$file"
}

# Derived names used across the installer.
cfg_derive() {
  : "${CFG_storage__pool_name:?pool_name unset}"
  export POOL="$CFG_storage__pool_name"
  export ROOT_DS="${POOL}/ROOT/ubuntu"
  export HOME_DS="${POOL}/home"
  export BE_NAME="ubuntu"
}

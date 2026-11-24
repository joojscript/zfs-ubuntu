#!/usr/bin/env bash
# provision.sh — apply (or re-apply) machine configuration with Ansible.
# Safe and idempotent; does NOT touch storage or the bootloader.
#
#   ./provision.sh --config config/host.yaml
#   ./provision.sh --config config/host.yaml --tags desktop,development
#   ./provision.sh --config config/host.yaml --check        # dry run
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=installer/lib/common.sh
source "$HERE/installer/lib/common.sh"

CONFIG=""
EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    --tags)   EXTRA+=(--tags "${2:-}"); shift 2 ;;
    --skip-tags) EXTRA+=(--skip-tags "${2:-}"); shift 2 ;;
    --check)  EXTRA+=(--check --diff); shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) EXTRA+=("$1"); shift ;;
  esac
done
[[ -n "$CONFIG" ]] || die "--config is required"
[[ -f "$CONFIG" ]] || die "config not found: $CONFIG"

# Ensure Ansible exists (install from apt on first run).
if ! command -v ansible-playbook >/dev/null 2>&1; then
  log_warn "ansible not found; installing via apt (requires sudo + network)"
  sudo apt-get update
  sudo apt-get install -y ansible python3-yaml
fi
python3 -c 'import yaml' 2>/dev/null || { sudo apt-get install -y python3-yaml; }

# Ensure required Ansible collections are present.
if [[ ! -d "$HERE/ansible/.galaxy/ansible_collections/community/general" ]]; then
  log_info "installing ansible collection community.general"
  (cd "$HERE/ansible" && ansible-galaxy collection install -r requirements.yml) \
    || log_warn "ansible-galaxy install failed; roles using community.general may error"
fi

# Render host.yaml -> JSON extra-vars.
VARS_JSON="$(mktemp -t host-vars.XXXXXX.json)"
trap 'rm -f "$VARS_JSON"' EXIT
python3 "$HERE/installer/lib/config.py" json "$CONFIG" >"$VARS_JSON" \
  || die "failed to parse config (see errors above)"

log_step "Running Ansible provisioning"
log_info "config: $CONFIG"
cd "$HERE/ansible"
exec ansible-playbook \
  -i inventory.yml \
  site.yml \
  --extra-vars "@$VARS_JSON" \
  "${EXTRA[@]}"

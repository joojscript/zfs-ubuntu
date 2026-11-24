#!/usr/bin/env bash
# Installer orchestrator. Invoked by ./install.sh. Runs the ordered,
# logged installation stages. Honours DRY_RUN=1 for --plan.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"
# shellcheck source=lib/config.sh
source "$HERE/lib/config.sh"
# shellcheck source=lib/preflight.sh
source "$HERE/lib/preflight.sh"
# shellcheck source=lib/disk.sh
source "$HERE/lib/disk.sh"
# shellcheck source=lib/zfs.sh
source "$HERE/lib/zfs.sh"
# shellcheck source=lib/base.sh
source "$HERE/lib/base.sh"

CONFIG=""
MODE=""

usage() {
  cat <<EOF
Usage: sudo ./install.sh --config <host.yaml> (--plan|--apply)

  --config FILE   path to the host YAML configuration
  --plan          show intended actions; make NO changes (dry run)
  --apply         perform the installation (destructive, confirmed)
  -h|--help       this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:-}"; shift 2 ;;
    --plan)   MODE="plan";  shift ;;
    --apply)  MODE="apply"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

[[ -n "$CONFIG" ]] || { usage; die "--config is required"; }
[[ -n "$MODE"   ]] || { usage; die "one of --plan / --apply is required"; }

require_root

# Logging to a timestamped file under /var/log.
LOG_DIR="/var/log/ubuntu-declarative"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/ubuntu-declarative"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
export LOG_FILE
log_info "logging to $LOG_FILE"

if [[ "$MODE" == "plan" ]]; then
  export DRY_RUN=1
  log_step "PLAN MODE — no disks will be touched, no system state changed"
else
  export DRY_RUN=0
fi

load_config "$CONFIG"
cfg_derive
log_ok "config loaded: host=${CFG_system__hostname} user=${CFG_system__username} pool=${POOL}"

preflight_checks
disk_summary "$CFG_storage__disk"
disk_safety_checks "$CFG_storage__disk"

# ---- the destructive gate ----
if [[ "$MODE" == "plan" ]]; then
  log_step "Planned actions"
  cat <<EOF
  1. Wipe and GPT-partition $(disk_realpath "$CFG_storage__disk"):
       p1 ${CFG_boot__esp_size_mib} MiB  EFI System Partition (FAT32)
       p2 remainder                      ZFS (zpool '${POOL}')
  2. Create pool '${POOL}' compatibility=${CFG_storage__pool_compatibility} ashift=${CFG_storage__ashift} encryption=${CFG_storage__encryption__enabled}
  3. Datasets: ${POOL}/ROOT/${BE_NAME} (boot env, /), ${POOL}/home/${CFG_system__username} (independent /home)
  4. Swap zvol: ${CFG_storage__swap_size_mib} MiB $( [[ "${CFG_storage__swap_size_mib}" == "0" ]] && echo '(disabled)')
  5. debootstrap Ubuntu '${CFG_system__release}', configure locale/tz/user/hostname
  6. Install kernel + dracut(zfs) initramfs + ZFSBootMenu to the ESP + UEFI entries
  7. Install snapshot automation (sanoid + APT pre-upgrade hook)
  8. Export pool; ready to reboot
EOF
  log_ok "plan complete — rerun with --apply to execute"
  exit 0
fi

# APPLY
DISK_BASENAME="$(basename "$(disk_realpath "$CFG_storage__disk")")"
confirm_token "$DISK_BASENAME" \
  "$(printf 'This will DESTROY ALL DATA on %s (%s).' "$CFG_storage__disk" "$DISK_BASENAME")"

trap 'log_error "installation failed at line $LINENO — see $LOG_FILE"; base_cleanup || true' ERR

disk_partition "$CFG_storage__disk" "$CFG_boot__esp_size_mib"
zfs_create_pool "$CFG_storage__pool_compatibility" "$CFG_storage__ashift" "$CFG_storage__encryption__enabled"
zfs_create_datasets
zfs_create_swap "$CFG_storage__swap_size_mib"
zfs_set_commandline "root=zfs:${ROOT_DS} ${CFG_boot__kernel_cmdline}"

base_debootstrap "$CFG_system__release"
base_prepare_chroot
base_run_chroot_setup

base_cleanup
trap - ERR

log_ok "Installation complete."
cat <<EOF

Next steps:
  1. Remove the live USB and reboot.
  2. At the ZFSBootMenu screen your '${BE_NAME}' boot environment will boot by default.
  3. Log in as '${CFG_system__username}', then run provisioning:
       cd /opt/ubuntu-declarative
       ./provision.sh --config ${CONFIG##*/}   # or your host.yaml
  4. Verify recovery readiness:
       sudo ./healthcheck.sh

Install log: $LOG_FILE
EOF

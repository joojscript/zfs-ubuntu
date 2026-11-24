#!/usr/bin/env bash
# healthcheck.sh — verify the recovery-critical components of an installed host.
# Read-only. Exits 0 if healthy, 1 if any ERROR found (warnings do not fail).
#
#   sudo ./healthcheck.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=installer/lib/common.sh
source "$HERE/installer/lib/common.sh"

ERRORS=0
WARNINGS=0
ok()   { log_ok "$*"; }
warn() { log_warn "$*"; WARNINGS=$((WARNINGS+1)); }
err()  { log_error "$*"; ERRORS=$((ERRORS+1)); }

be="$(findmnt -no SOURCE / 2>/dev/null || true)"; be="${be%@*}"
pool="${be%%/*}"

log_step "1. Root filesystem"
if [[ "$(findmnt -no FSTYPE / 2>/dev/null)" == "zfs" ]]; then
  ok "root is ZFS (boot environment: ${be})"
else
  err "root filesystem is not ZFS — this is not a ubuntu-declarative install"
fi

log_step "2. ZFS pool health"
if [[ -n "$pool" ]] && zpool list "$pool" >/dev/null 2>&1; then
  health="$(zpool list -H -o health "$pool")"
  if [[ "$health" == "ONLINE" ]]; then ok "pool '$pool' is $health"; else err "pool '$pool' health=$health"; fi
  cap="$(zpool list -H -o capacity "$pool" | tr -d '%')"
  if   [[ "${cap:-0}" -ge 90 ]]; then err  "pool capacity ${cap}% (critical; recovery clones may fail)"
  elif [[ "${cap:-0}" -ge 80 ]]; then warn "pool capacity ${cap}% (consider pruning)"
  else ok "pool capacity ${cap}%"; fi
  zpool status -x "$pool" | grep -qi "errors: No known data errors" && ok "no data errors" || warn "zpool reports errors — run 'zpool status $pool'"
else
  err "cannot query root pool"
fi

log_step "3. Boot environment & bootfs"
if [[ -n "$pool" ]]; then
  bootfs="$(zpool get -H -o value bootfs "$pool" 2>/dev/null)"
  if [[ "$bootfs" == "$be" ]]; then ok "bootfs=$bootfs matches running environment"
  elif [[ -n "$bootfs" && "$bootfs" != "-" ]]; then warn "bootfs=$bootfs differs from running $be (ok if you just activated a new BE)"
  else err "pool bootfs is not set — ZFSBootMenu may not know what to boot"; fi
  cmdline="$(zfs get -H -o value org.zfsbootmenu:commandline "$be" 2>/dev/null)"
  [[ -n "$cmdline" && "$cmdline" != "-" ]] && ok "org.zfsbootmenu:commandline set ('$cmdline')" || err "org.zfsbootmenu:commandline missing on $be"
  canmount="$(zfs get -H -o value canmount "$be" 2>/dev/null)"
  [[ "$canmount" == "noauto" ]] && ok "canmount=noauto (required for BE switching)" || warn "canmount=$canmount (expected noauto)"
fi

log_step "4. ZFSBootMenu artifacts on the ESP"
esp_mnt="/boot/efi"
if mountpoint -q "$esp_mnt"; then
  ok "ESP mounted at $esp_mnt"
  if [[ -f "$esp_mnt/EFI/zbm/vmlinuz.EFI" ]]; then ok "ZBM image present: EFI/zbm/vmlinuz.EFI"
  else err "ZBM image MISSING at EFI/zbm/vmlinuz.EFI — system may be unbootable"; fi
  [[ -f "$esp_mnt/EFI/zbm/vmlinuz-backup.EFI" ]] && ok "ZBM backup image present" || warn "no ZBM backup image"
  [[ -f "$esp_mnt/EFI/BOOT/BOOTX64.EFI" ]] && ok "removable-media fallback present (EFI/BOOT/BOOTX64.EFI)" || warn "no removable-media fallback"
else
  err "ESP not mounted at $esp_mnt"
fi

log_step "5. UEFI boot entries"
if command -v efibootmgr >/dev/null 2>&1 && [[ -d /sys/firmware/efi ]]; then
  if efibootmgr 2>/dev/null | grep -q "ZFSBootMenu"; then ok "UEFI entry 'ZFSBootMenu' present"
  else warn "no 'ZFSBootMenu' UEFI entry (removable fallback may still boot)"; fi
else
  warn "efibootmgr unavailable or not UEFI — skipping"
fi

log_step "6. Kernel & initramfs in the boot environment"
kver="$(ls -1 /lib/modules 2>/dev/null | sort -V | tail -1)"
ls /boot/vmlinuz* >/dev/null 2>&1 && ok "kernel image(s) in /boot" || err "no kernel in /boot — ZBM cannot kexec"
if ls /boot/initrd.img* >/dev/null 2>&1 || ls /boot/initramfs* >/dev/null 2>&1; then ok "initramfs in /boot"; else err "no initramfs in /boot"; fi
[[ -n "$kver" ]] && ok "kernel modules present for $kver" || warn "no /lib/modules entries"

log_step "7. Snapshot automation"
systemctl is-enabled sanoid.timer >/dev/null 2>&1 && ok "sanoid.timer enabled" || warn "sanoid.timer not enabled"
command -v sanoid >/dev/null 2>&1 && { sanoid --version >/dev/null 2>&1 && ok "sanoid installed"; } || warn "sanoid not installed"
[[ -f /etc/sanoid/sanoid.conf ]] && ok "sanoid.conf present" || warn "sanoid.conf missing"
[[ -f /etc/apt/apt.conf.d/80-zfs-snapshot ]] && ok "APT pre-upgrade snapshot hook installed" || warn "APT snapshot hook not installed"
for w in ubuntu-snapshot ubuntu-be ubuntu-update; do
  command -v "$w" >/dev/null 2>&1 && ok "command '$w' installed" || warn "command '$w' missing"
done
recent="$(zfs list -t snapshot -H -o name 2>/dev/null | grep -c "@zbm_" || true)"
ok "recovery snapshots present: ${recent:-0}"

log_step "8. Recovery readiness summary"
echo
if (( ERRORS > 0 )); then
  log_error "FAIL: ${ERRORS} error(s), ${WARNINGS} warning(s). Resolve errors before trusting recovery."
  exit 1
elif (( WARNINGS > 0 )); then
  log_warn "PASS WITH WARNINGS: ${WARNINGS} warning(s). Core recovery path looks intact."
  exit 0
else
  log_ok "HEALTHY: all recovery-critical checks passed."
  exit 0
fi

# shellcheck shell=bash
# Preflight validation. Read-only: safe to run in both --plan and --apply.

MIN_RAM_MIB=2048

preflight_checks() {
  log_step "Preflight checks"
  local fail=0

  # --- UEFI ---
  if [[ -d /sys/firmware/efi/efivars ]]; then
    log_ok "firmware: booted in UEFI mode"
  else
    log_error "firmware: NOT in UEFI mode (ZFSBootMenu requires UEFI)"
    fail=1
  fi

  # --- Secure Boot ---
  local sb="unknown"
  if command -v mokutil >/dev/null 2>&1; then
    sb="$(mokutil --sb-state 2>/dev/null | tr -d '\n' || true)"
  elif [[ -e /sys/firmware/efi/efivars ]]; then
    # SecureBoot EFI var: last byte 1 == enabled
    local f
    f="$(find /sys/firmware/efi/efivars -maxdepth 1 -name 'SecureBoot-*' 2>/dev/null | head -1)"
    if [[ -n "$f" ]]; then
      if [[ "$(od -An -t u1 "$f" 2>/dev/null | awk '{print $NF}')" == "1" ]]; then
        sb="SecureBoot enabled"
      else
        sb="SecureBoot disabled"
      fi
    fi
  fi
  if [[ "$sb" == *enabled* ]]; then
    if [[ "${CFG_boot__secure_boot:-false}" == "true" ]]; then
      log_warn "Secure Boot appears enabled; boot.secure_boot=true acknowledges this. ZBM is unsigned — boot WILL fail unless you enrolled keys yourself."
    else
      log_error "Secure Boot is ENABLED but this workflow does not support it."
      log_error "  -> Disable Secure Boot in firmware, OR set boot.secure_boot: true to override."
      fail=1
    fi
  else
    log_ok "secure boot: $sb"
  fi

  # --- RAM ---
  local ram_mib
  ram_mib=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  if (( ram_mib >= MIN_RAM_MIB )); then
    log_ok "memory: ${ram_mib} MiB"
  else
    log_error "memory: ${ram_mib} MiB (< ${MIN_RAM_MIB} MiB minimum)"
    fail=1
  fi

  # --- Network ---
  if getent hosts archive.ubuntu.com >/dev/null 2>&1 || ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    log_ok "network: reachable"
  else
    log_error "network: no connectivity (debootstrap needs the Ubuntu archive)"
    fail=1
  fi

  # --- Required tools on the live environment ---
  local tools=(zpool zfs sgdisk wipefs debootstrap partprobe blkid lsblk efibootmgr mkfs.vfat curl)
  local t missing=()
  for t in "${tools[@]}"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
  if ((${#missing[@]})); then
    log_error "missing tools on live environment: ${missing[*]}"
    log_error "  -> install with: apt-get update && apt-get install -y zfsutils-linux gdisk dosfstools debootstrap efibootmgr curl"
    fail=1
  else
    log_ok "tools: all installer prerequisites present"
  fi

  # --- Live environment sanity: is / a read-write live medium? ---
  if [[ -f /run/live/medium || -d /cdrom || "$(findmnt -no FSTYPE / 2>/dev/null)" == "overlay" || "${ALLOW_NONLIVE:-0}" == "1" ]]; then
    log_ok "environment: live/installer context detected"
  else
    log_error "environment: this does not look like an Ubuntu live session."
    log_error "  -> Refusing to run a destructive install on a normal system."
    log_error "  -> Set ALLOW_NONLIVE=1 ONLY inside a disposable VM you intend to wipe."
    fail=1
  fi

  (( fail == 0 )) || die "preflight failed — resolve the errors above before continuing"
  log_ok "preflight passed"
}

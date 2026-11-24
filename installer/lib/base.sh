# shellcheck shell=bash
# Install the Ubuntu base system with debootstrap and run in-chroot setup.
# Requires: MNT, POOL, ROOT_DS, ESP_PART, and CFG_* variables.

ARCHIVE_URL="http://archive.ubuntu.com/ubuntu"

base_debootstrap() {
  local release="$1"
  log_step "debootstrap Ubuntu '$release' into $MNT"
  run debootstrap --include=locales,wget,curl,ca-certificates,gnupg "$release" "$MNT" "$ARCHIVE_URL"
  log_ok "base system installed"
}

base_prepare_chroot() {
  log_step "Preparing chroot"
  # ZFS needs a matching hostid in the target.
  run cp -a /etc/hostid "$MNT/etc/hostid" 2>/dev/null || run zgenhostid -f -o "$MNT/etc/hostid" "$(hostid)"
  run mkdir -p "$MNT/etc/zfs"
  run cp /etc/zfs/zpool.cache "$MNT/etc/zfs/zpool.cache" 2>/dev/null || true

  # Format and mount the ESP.
  log_info "formatting ESP $ESP_PART (FAT32)"
  run mkfs.vfat -F32 -n EFI "$ESP_PART"
  run mkdir -p "$MNT/boot/efi"
  run mount "$ESP_PART" "$MNT/boot/efi"

  # Bind mounts for chroot.
  local d
  for d in proc sys dev dev/pts run; do
    run mkdir -p "$MNT/$d"
    run mount --rbind "/$d" "$MNT/$d"
    run mount --make-rslave "$MNT/$d"
  done

  # resolv.conf for networking inside chroot.
  run cp /etc/resolv.conf "$MNT/etc/resolv.conf"

  # Copy the whole repo so provisioning works post-reboot without network clone.
  local rr; rr="$(repo_root)"
  run mkdir -p "$MNT/opt/ubuntu-declarative"
  run cp -a "$rr/." "$MNT/opt/ubuntu-declarative/"
  # Drop any local secrets that must never land on the target image.
  run rm -f "$MNT/opt/ubuntu-declarative/config/secrets.env" 2>/dev/null || true
}

# Write the environment consumed by chroot-setup.sh, then execute it.
base_run_chroot_setup() {
  log_step "Running in-chroot configuration"
  local envf="$MNT/root/.install-env"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '  %s[dry-run]%s would write chroot env and run chroot-setup.sh\n' "${C_DIM}" "${C_RST}"
    return 0
  fi
  {
    printf 'export INSTALL_RELEASE=%q\n'    "$CFG_system__release"
    printf 'export INSTALL_HOSTNAME=%q\n'   "$CFG_system__hostname"
    printf 'export INSTALL_USERNAME=%q\n'   "$CFG_system__username"
    printf 'export INSTALL_TIMEZONE=%q\n'   "$CFG_system__timezone"
    printf 'export INSTALL_LOCALE=%q\n'     "$CFG_system__locale"
    printf 'export INSTALL_POOL=%q\n'       "$POOL"
    printf 'export INSTALL_ROOT_DS=%q\n'    "$ROOT_DS"
    printf 'export INSTALL_ESP_PART=%q\n'   "$ESP_PART"
    printf 'export INSTALL_SWAP=%q\n'       "$CFG_storage__swap_size_mib"
    printf 'export INSTALL_ENCRYPTED=%q\n'  "$CFG_storage__encryption__enabled"
    printf 'export INSTALL_DESKTOP=%q\n'    "$CFG_system__desktop"
    printf 'export INSTALL_SNAP_BEFORE_APT=%q\n' "$CFG_snapshots__before_apt"
    printf 'export INSTALL_ZBM_CMDLINE=%q\n' "$CFG_boot__kernel_cmdline"
  } >"$envf"
  chmod 600 "$envf"

  # The user password: prompt interactively (or read secrets.env), pass via env
  # on the single chroot invocation. Never written to the env file on disk.
  local userpw
  userpw="$(get_user_password)"

  INSTALL_USERPW="$userpw" chroot "$MNT" /bin/bash -c \
    'set -euo pipefail; source /root/.install-env; /opt/ubuntu-declarative/installer/lib/chroot-setup.sh'
  run rm -f "$envf"
  log_ok "in-chroot configuration complete"
}

# Obtain the user password without ever persisting it.
get_user_password() {
  if [[ -f "$(repo_root)/config/secrets.env" ]]; then
    # shellcheck disable=SC1090
    source "$(repo_root)/config/secrets.env"
    if [[ -n "${USER_PASSWORD:-}" ]]; then printf '%s' "$USER_PASSWORD"; return 0; fi
  fi
  local p1 p2
  while :; do
    read -r -s -p "Set password for user '$CFG_system__username': " p1 >&2; echo >&2
    read -r -s -p "Confirm password: " p2 >&2; echo >&2
    [[ "$p1" == "$p2" && -n "$p1" ]] && break
    echo "passwords differ or empty, try again" >&2
  done
  printf '%s' "$p1"
}

base_cleanup() {
  log_step "Unmounting target"
  run umount -R "$MNT/boot/efi" 2>/dev/null || true
  # Unmount binds in reverse.
  local d
  for d in run dev/pts dev sys proc; do
    run umount -R "$MNT/$d" 2>/dev/null || true
  done
  run zfs umount -a 2>/dev/null || true
  run zpool export "$POOL" 2>/dev/null || true
  log_ok "target unmounted and pool exported"
}

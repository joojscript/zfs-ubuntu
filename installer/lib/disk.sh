# shellcheck shell=bash
# Disk identification, safety checks and partitioning.

# Resolve a by-id path to its real /dev node (e.g. /dev/nvme0n1).
disk_realpath() {
  local dev="$1"
  [[ -e "$dev" ]] || die "disk not found: $dev"
  readlink -f "$dev"
}

# Partition device path. Kernel rule: when the disk name ends in a digit
# (nvme0n1, mmcblk0, loop0) partitions get a 'p' separator; otherwise (sda,
# vda) they are suffixed directly.
part_path() {
  local base="$1" num="$2"
  if [[ "$base" =~ [0-9]$ ]]; then
    printf '%sp%s' "$base" "$num"
  else
    printf '%s%s' "$base" "$num"
  fi
}

# Print a human summary of the target disk and its current contents.
disk_summary() {
  local byid="$1" real
  real="$(disk_realpath "$byid")"
  log_step "Target disk"
  printf '  by-id : %s\n' "$byid"
  printf '  device: %s\n' "$real"
  # Model / serial / size via lsblk and udev.
  local model serial size
  model="$(lsblk -dno MODEL "$real" 2>/dev/null | xargs || true)"
  serial="$(lsblk -dno SERIAL "$real" 2>/dev/null | xargs || true)"
  size="$(lsblk -dno SIZE "$real" 2>/dev/null | xargs || true)"
  printf '  model : %s\n' "${model:-unknown}"
  printf '  serial: %s\n' "${serial:-unknown}"
  printf '  size  : %s\n' "${size:-unknown}"
  printf '  --- current partition table / mounts ---\n'
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$real" 2>/dev/null | sed 's/^/  /' || true
}

# Refuse to touch a disk that hosts the running system or is mounted.
disk_safety_checks() {
  local byid="$1" real
  real="$(disk_realpath "$byid")"

  [[ "$byid" == /dev/disk/by-id/* ]] || \
    log_warn "storage.disk is not a /dev/disk/by-id/ path. by-id paths are strongly recommended for stability."

  # Is any partition of this disk currently mounted?
  local mounted
  mounted="$(lsblk -nro NAME,MOUNTPOINT "$real" 2>/dev/null | awk 'NF==2{print}' || true)"
  if [[ -n "$mounted" ]]; then
    log_error "target disk has mounted filesystems:"
    printf '%s\n' "$mounted" | sed 's/^/    /'
    [[ "${ALLOW_NONLIVE:-0}" == "1" ]] || die "refusing to partition a disk with mounted filesystems"
    log_warn "ALLOW_NONLIVE=1 — proceeding despite mounts (VM test only)"
  fi

  # Is the live root backed by this disk? (should never be, on a USB/ISO boot)
  local rootsrc
  rootsrc="$(findmnt -no SOURCE / 2>/dev/null || true)"
  if [[ -n "$rootsrc" && "$(readlink -f "$rootsrc" 2>/dev/null || echo "$rootsrc")" == "$real"* ]]; then
    die "the live system root ($rootsrc) lives on the target disk — aborting"
  fi

  # Is it part of an imported pool already?
  if zpool status 2>/dev/null | grep -q "$(basename "$real")"; then
    log_warn "target disk appears to be part of an already-imported zpool"
  fi
}

# Create ESP (ef00) + ZFS (bf00) partitions.
# Exports ESP_PART and POOL_PART with full device paths.
disk_partition() {
  local byid="$1" esp_mib="$2" real
  real="$(disk_realpath "$byid")"
  log_step "Partitioning $real"

  run zpool labelclear -f "$real" 2>/dev/null || true
  run wipefs -a "$real"
  run sgdisk --zap-all "$real"
  run partprobe "$real" || true

  # p1 = EFI System Partition, p2 = ZFS
  run sgdisk -n "1:1m:+${esp_mib}m" -t "1:ef00" -c "1:EFI" "$real"
  run sgdisk -n "2:0:-10m"        -t "2:bf00" -c "2:zfs" "$real"
  run partprobe "$real"
  run udevadm settle 2>/dev/null || sleep 2

  ESP_PART="$(part_path "$real" 1)"
  POOL_PART="$(part_path "$real" 2)"
  export ESP_PART POOL_PART

  if [[ "${DRY_RUN:-0}" != "1" ]]; then
    [[ -e "$ESP_PART"  ]] || die "expected ESP partition $ESP_PART not present after partitioning"
    [[ -e "$POOL_PART" ]] || die "expected ZFS partition $POOL_PART not present after partitioning"
  fi
  log_ok "partitions: ESP=$ESP_PART ZFS=$POOL_PART"
}

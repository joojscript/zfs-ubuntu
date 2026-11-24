# shellcheck shell=bash
# ZFS pool and dataset creation tuned for root-on-ZFS + ZFSBootMenu.
# Requires: POOL, ROOT_DS, HOME_DS, BE_NAME (from cfg_derive), POOL_PART.
#
# The pool is created with an altroot (-R $MNT) so every dataset mounts
# beneath $MNT during installation, while the persisted mountpoints stay
# correct for the real system (/, /home, ...).

MNT="/mnt/newroot"

zfs_create_pool() {
  local compat="$1" ashift="$2" enc="$3"
  log_step "Creating ZFS pool '$POOL'"
  run mkdir -p "$MNT"

  local -a opts=(
    -f
    -o "ashift=${ashift}"
    -o autotrim=on
    -o "compatibility=${compat}"
    -o cachefile=/etc/zfs/zpool.cache
    -O compression=lz4
    -O acltype=posixacl
    -O xattr=sa
    -O dnodesize=auto
    -O normalization=formD
    -O relatime=on
    -O canmount=off
    -O mountpoint=/
    -R "$MNT"
  )

  if [[ "$enc" == "true" ]]; then
    # Native encryption. zpool create prompts for the passphrase interactively
    # and stores NO secret anywhere; ZFSBootMenu prompts again at boot.
    opts+=(
      -O encryption=aes-256-gcm
      -O keyformat=passphrase
      -O keylocation=prompt
    )
    log_info "pool will be encrypted (native aes-256-gcm, passphrase prompted now and at every boot by ZBM)"
  fi

  run zpool create "${opts[@]}" "$POOL" "$POOL_PART"
  log_ok "pool created (compatibility=$compat, altroot=$MNT)"
}

zfs_create_datasets() {
  log_step "Creating datasets"
  # OS boot-environment container + the 'ubuntu' BE itself.
  run zfs create -o canmount=off -o mountpoint=none "${POOL}/ROOT"
  run zfs create -o canmount=noauto -o mountpoint=/ "$ROOT_DS"
  run zpool set bootfs="$ROOT_DS" "$POOL"
  run zfs mount "$ROOT_DS"

  # /home kept independent so OS rollback never touches personal files.
  run zfs create -o canmount=off -o mountpoint=/home "${POOL}/home"
  run zfs create "${POOL}/home/${CFG_system__username}"
  run zfs mount -a || true

  # Datasets that should NOT be part of OS snapshots/rollback.
  # /var/lib/docker etc. can be added by the docker role later.
  log_ok "datasets created (ROOT/${BE_NAME} is the boot environment; home is independent)"
}

zfs_create_swap() {
  local size_mib="$1"
  [[ "$size_mib" =~ ^[0-9]+$ && "$size_mib" -gt 0 ]] || { log_info "swap disabled"; return 0; }
  log_step "Creating ${size_mib} MiB swap zvol"
  run zfs create -V "${size_mib}M" -b "$(getconf PAGESIZE)" \
    -o logbias=throughput -o sync=always \
    -o primarycache=metadata -o secondarycache=none \
    -o com.sun:auto-snapshot=false "${POOL}/swap"
  run udevadm settle 2>/dev/null || sleep 1
  run mkswap -f "/dev/zvol/${POOL}/swap"
  log_ok "swap zvol created at /dev/zvol/${POOL}/swap (no hibernate support)"
}

# Set the boot-environment command line that ZFSBootMenu reads from the pool.
zfs_set_commandline() {
  local cmdline="$1"
  log_step "Setting ZFSBootMenu kernel command line"
  run zfs set "org.zfsbootmenu:commandline=${cmdline}" "$ROOT_DS"
  log_ok "org.zfsbootmenu:commandline='${cmdline}' on $ROOT_DS"
}

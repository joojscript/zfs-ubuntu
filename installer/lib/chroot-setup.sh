#!/usr/bin/env bash
# Runs INSIDE the target chroot. Configures the base system, a ZFS-capable
# initramfs (dracut), ZFSBootMenu on the ESP, the user account, and the
# snapshot automation. Driven entirely by INSTALL_* env vars sourced from
# /root/.install-env plus INSTALL_USERPW passed on the invocation.
set -euo pipefail

: "${INSTALL_RELEASE:?}" "${INSTALL_HOSTNAME:?}" "${INSTALL_USERNAME:?}"
: "${INSTALL_POOL:?}" "${INSTALL_ROOT_DS:?}" "${INSTALL_ESP_PART:?}"
export DEBIAN_FRONTEND=noninteractive

say() { printf '\n### %s\n' "$*"; }

# ZBM prebuilt EFI image. Override ZBM_URL to pin a specific release for
# reproducibility (see docs/configuration.md).
ZBM_URL="${ZBM_URL:-https://get.zfsbootmenu.org/latest.EFI}"

say "APT sources for ${INSTALL_RELEASE}"
cat >/etc/apt/sources.list <<EOF
deb http://archive.ubuntu.com/ubuntu ${INSTALL_RELEASE} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${INSTALL_RELEASE}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu ${INSTALL_RELEASE}-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu ${INSTALL_RELEASE}-security main restricted universe multiverse
EOF
apt-get update

say "Locale, timezone, hostname"
echo "locales locales/default_environment_locale select ${INSTALL_LOCALE}" | debconf-set-selections
sed -i "s/^# *\(${INSTALL_LOCALE}\)/\1/" /etc/locale.gen || echo "${INSTALL_LOCALE} UTF-8" >>/etc/locale.gen
locale-gen
update-locale "LANG=${INSTALL_LOCALE}"
ln -sf "/usr/share/zoneinfo/${INSTALL_TIMEZONE}" /etc/localtime || true
echo "${INSTALL_TIMEZONE}" >/etc/timezone
echo "${INSTALL_HOSTNAME}" >/etc/hostname
cat >/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   ${INSTALL_HOSTNAME}
::1         localhost ip6-localhost ip6-allnodes ip6-allrouters
EOF

say "Core packages: kernel, ZFS, dracut, boot tools"
apt-get install -y --no-install-recommends \
  linux-generic linux-headers-generic \
  zfsutils-linux zfs-zed \
  dracut-core dracut-network \
  dosfstools efibootmgr curl ca-certificates \
  systemd-resolved netplan.io nano sudo \
  cryptsetup keyutils

# Dracut needs the zfs module. Ubuntu ships it via the zfs-dracut package when
# available; otherwise zfs-dkms/zfsutils provides the dracut hook.
apt-get install -y --no-install-recommends zfs-dracut 2>/dev/null || true

say "Dracut configuration for ZFS root"
mkdir -p /etc/dracut.conf.d
cat >/etc/dracut.conf.d/10-zfs.conf <<'EOF'
# Build a ZFS-capable initramfs. ZFSBootMenu kexecs this kernel+initramfs
# from the selected boot environment.
add_dracutmodules+=" zfs "
omit_dracutmodules+=" btrfs "
compress="zstd"
hostonly="yes"
EOF

say "ZFS services"
systemctl enable zfs-import-cache.service zfs-import.target zfs-mount.service zfs-zed.service zfs.target 2>/dev/null || true
# Persist the pool cache so the pool imports at boot.
mkdir -p /etc/zfs/zfs-list.cache
touch "/etc/zfs/zfs-list.cache/${INSTALL_POOL}" 2>/dev/null || true

say "fstab (ESP + swap)"
ESP_UUID="$(blkid -s UUID -o value "${INSTALL_ESP_PART}")"
cat >/etc/fstab <<EOF
# <device>                     <mount>     <type> <options>            <dump> <pass>
UUID=${ESP_UUID}               /boot/efi   vfat   defaults,noatime       0      1
EOF
if [[ "${INSTALL_SWAP:-0}" =~ ^[0-9]+$ && "${INSTALL_SWAP:-0}" -gt 0 ]]; then
  echo "/dev/zvol/${INSTALL_POOL}/swap none swap discard 0 0" >>/etc/fstab
fi

say "User account: ${INSTALL_USERNAME}"
if ! id "${INSTALL_USERNAME}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${INSTALL_USERNAME}"
fi
usermod -aG sudo,adm,cdrom,dip,plugdev "${INSTALL_USERNAME}"
if [[ -n "${INSTALL_USERPW:-}" ]]; then
  echo "${INSTALL_USERNAME}:${INSTALL_USERPW}" | chpasswd
  # Lock root; the user has sudo.
  passwd -l root || true
fi
unset INSTALL_USERPW

say "Regenerating initramfs (dracut)"
KVER="$(ls -1 /lib/modules | sort -V | tail -1)"
dracut --force --kver "${KVER}"

say "Installing ZFSBootMenu to the ESP"
install -d /boot/efi/EFI/zbm /boot/efi/EFI/BOOT
if curl -fsSL "${ZBM_URL}" -o /boot/efi/EFI/zbm/vmlinuz.EFI; then
  # Keep a second copy as the previous-version slot and a removable-media fallback.
  cp /boot/efi/EFI/zbm/vmlinuz.EFI /boot/efi/EFI/zbm/vmlinuz-backup.EFI
  cp /boot/efi/EFI/zbm/vmlinuz.EFI /boot/efi/EFI/BOOT/BOOTX64.EFI
else
  echo "WARNING: could not download ZFSBootMenu from ${ZBM_URL}" >&2
  echo "         Place a ZBM EFI image at /boot/efi/EFI/zbm/vmlinuz.EFI before rebooting." >&2
fi

say "Creating UEFI boot entries"
ESP_DISK="$(lsblk -no PKNAME "${INSTALL_ESP_PART}" | head -1)"
ESP_PARTNUM="$(cat "/sys/class/block/$(basename "${INSTALL_ESP_PART}")/partition" 2>/dev/null || echo 1)"
if [[ -n "${ESP_DISK}" ]]; then
  # Remove any stale entries we created before (idempotent re-runs).
  for lbl in "ZFSBootMenu" "ZFSBootMenu (backup)"; do
    efibootmgr | awk -v l="$lbl" '$0 ~ l {gsub(/[^0-9]/,"",$1); print $1}' | while read -r n; do
      [[ -n "$n" ]] && efibootmgr -B -b "$n" >/dev/null 2>&1 || true
    done
  done
  efibootmgr -c -d "/dev/${ESP_DISK}" -p "${ESP_PARTNUM}" \
    -L "ZFSBootMenu" -l '\EFI\zbm\vmlinuz.EFI' || \
    echo "WARNING: efibootmgr failed (expected in some VMs); removable-path fallback /EFI/BOOT/BOOTX64.EFI remains" >&2
  efibootmgr -c -d "/dev/${ESP_DISK}" -p "${ESP_PARTNUM}" \
    -L "ZFSBootMenu (backup)" -l '\EFI\zbm\vmlinuz-backup.EFI' 2>/dev/null || true
fi

say "Installing snapshot automation"
if [[ -x /opt/ubuntu-declarative/installer/lib/install-snapshots.sh ]]; then
  INSTALL_SNAP_BEFORE_APT="${INSTALL_SNAP_BEFORE_APT:-true}" \
    /opt/ubuntu-declarative/installer/lib/install-snapshots.sh "${INSTALL_POOL}" "${INSTALL_ROOT_DS}"
fi

say "Enabling networking (NetworkManager if desktop, else systemd-networkd)"
if [[ "${INSTALL_DESKTOP:-none}" != "none" ]]; then
  : # NetworkManager is pulled in by the desktop role during provisioning
fi
systemctl enable systemd-resolved 2>/dev/null || true
cat >/etc/netplan/01-dhcp.yaml <<'EOF'
network:
  version: 2
  ethernets:
    all-en:
      match:
        name: "en*"
      dhcp4: true
EOF
chmod 600 /etc/netplan/01-dhcp.yaml

say "chroot-setup complete"

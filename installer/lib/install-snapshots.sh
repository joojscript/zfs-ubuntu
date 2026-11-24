#!/usr/bin/env bash
# Install snapshot automation inside the target system (called from chroot).
#   install-snapshots.sh <pool> <root_ds>
# Installs sanoid, the user-facing wrappers, the APT pre-upgrade hook, a
# default sanoid.conf, and enables the sanoid timer. The Ansible 'snapshots'
# role later re-templates sanoid.conf with the retention from host.yaml.
set -euo pipefail

POOL="${1:?pool required}"
ROOT_DS="${2:?root_ds required}"
REPO="/opt/ubuntu-declarative"
export DEBIAN_FRONTEND=noninteractive

echo "### Installing sanoid"
apt-get install -y --no-install-recommends sanoid || {
  echo "WARNING: sanoid not available from apt; wrappers still installed" >&2
}

echo "### Installing wrapper commands"
install -m 0755 "${REPO}/scripts/snapshots/ubuntu-snapshot" /usr/local/sbin/ubuntu-snapshot
install -m 0755 "${REPO}/scripts/snapshots/ubuntu-be"       /usr/local/sbin/ubuntu-be
install -m 0755 "${REPO}/scripts/snapshots/ubuntu-update"   /usr/local/sbin/ubuntu-update
install -m 0755 "${REPO}/scripts/snapshots/apt-zfs-snapshot" /usr/local/sbin/apt-zfs-snapshot

echo "### Default sanoid.conf"
install -d /etc/sanoid
if [[ ! -f /etc/sanoid/sanoid.conf ]]; then
  cat >/etc/sanoid/sanoid.conf <<EOF
# Managed by ubuntu-declarative. The Ansible 'snapshots' role overwrites this
# with retention from host.yaml. Manual 'zbm_' snapshots are never pruned by
# sanoid because autoprune only removes sanoid-created ('autosnap') snapshots.
[${ROOT_DS}]
    use_template = os
    recursive = yes

[${POOL}/home]
    use_template = home
    recursive = yes

[template_os]
    frequently = 0
    hourly = 12
    daily = 7
    weekly = 4
    monthly = 3
    autosnap = yes
    autoprune = yes

[template_home]
    frequently = 0
    hourly = 0
    daily = 14
    weekly = 4
    monthly = 6
    autosnap = yes
    autoprune = yes
EOF
fi

if [[ "${INSTALL_SNAP_BEFORE_APT:-true}" == "true" ]]; then
  echo "### Registering APT pre-upgrade snapshot hook"
  cat >/etc/apt/apt.conf.d/80-zfs-snapshot <<'EOF'
// Create a ZFS recovery snapshot before any package change.
// Aborts the transaction if the snapshot cannot be taken.
DPkg::Pre-Invoke { "/usr/local/sbin/apt-zfs-snapshot || exit 1"; };
EOF
fi

echo "### Enabling sanoid timer"
systemctl enable sanoid.timer 2>/dev/null || true

echo "### snapshot automation installed"

#!/usr/bin/env bash
# vm-test.sh — disposable QEMU/KVM + OVMF harness for the install+recovery cycle.
#
# SAFETY: this NEVER touches host block devices. It operates only on qcow2 image
# files it creates under $WORKDIR. The installer inside the guest targets the
# guest's virtio disk (/dev/disk/by-id/virtio-*), never the host.
#
# Prerequisites (install via your package manager or `nix shell`):
#   qemu-system-x86_64, OVMF (UEFI firmware), an Ubuntu 26.04 live ISO.
#
# Usage:
#   export UBUNTU_ISO=/path/to/ubuntu-26.04-desktop-amd64.iso
#   export OVMF_CODE=/usr/share/OVMF/OVMF_CODE.fd      # auto-detected if unset
#   export OVMF_VARS=/usr/share/OVMF/OVMF_VARS.fd
#   tests/integration/vm-test.sh create     # make disposable disks + fw vars
#   tests/integration/vm-test.sh boot-iso   # boot the live ISO (install here)
#   tests/integration/vm-test.sh boot-disk  # boot the installed system via ZBM
#   tests/integration/vm-test.sh verify     # run guest verification over SSH
#   tests/integration/vm-test.sh clean      # delete all disposable artifacts
#
# The install step is run INSIDE the live guest. See docs/installation.md and
# tests/integration/README for the exact one-liner. Full non-interactive
# automation of the GUI live ISO is out of scope; this harness provides the
# reproducible, disposable environment and the verification driver.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKDIR="${WORKDIR:-${ROOT}/.vm}"
DISK_IMG="${WORKDIR}/root.qcow2"
DISK_SIZE="${DISK_SIZE:-30G}"
MEM="${MEM:-4096}"
CPUS="${CPUS:-2}"
SSH_PORT="${SSH_PORT:-2222}"
VARS_IMG="${WORKDIR}/OVMF_VARS.fd"

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

detect_ovmf() {
  if [[ -n "${OVMF_CODE:-}" && -n "${OVMF_VARS:-}" ]]; then return; fi
  local c
  for c in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
           /usr/share/ovmf/OVMF.fd /usr/share/edk2/x64/OVMF_CODE.fd \
           /usr/share/qemu/OVMF_CODE.fd; do
    [[ -f "$c" ]] && { OVMF_CODE="$c"; break; }
  done
  local v
  for v in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
           /usr/share/edk2/x64/OVMF_VARS.fd /usr/share/qemu/OVMF_VARS.fd; do
    [[ -f "$v" ]] && { OVMF_VARS="$v"; break; }
  done
  [[ -n "${OVMF_CODE:-}" && -n "${OVMF_VARS:-}" ]] || \
    die "OVMF firmware not found; set OVMF_CODE and OVMF_VARS (try: nix shell nixpkgs#OVMF)"
}

kvm_flags() { [[ -w /dev/kvm ]] && echo "-enable-kvm -cpu host" || echo "-cpu max"; }

cmd_create() {
  need qemu-img
  detect_ovmf
  mkdir -p "$WORKDIR"
  [[ -f "$DISK_IMG" ]] && die "disk already exists: $DISK_IMG (run 'clean' first)"
  qemu-img create -f qcow2 "$DISK_IMG" "$DISK_SIZE"
  cp "$OVMF_VARS" "$VARS_IMG"
  echo "created disposable disk $DISK_IMG ($DISK_SIZE) and firmware vars $VARS_IMG"
  echo "guest target disk will appear as /dev/disk/by-id/virtio-zfsroot"
}

common_qemu() {
  need qemu-system-x86_64
  detect_ovmf
  # shellcheck disable=SC2046
  printf '%s ' qemu-system-x86_64 $(kvm_flags) \
    -machine q35 -smp "$CPUS" -m "$MEM" \
    -drive "if=pflash,format=raw,readonly=on,file=${OVMF_CODE}" \
    -drive "if=pflash,format=raw,file=${VARS_IMG}" \
    -drive "file=${DISK_IMG},if=none,id=zfsroot,format=qcow2" \
    -device "virtio-blk-pci,drive=zfsroot,serial=zfsroot" \
    -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
    -device "virtio-net-pci,netdev=net0" \
    -virtfs "local,path=${ROOT},mount_tag=repo,security_model=mapped-xattr,id=repo"
}

cmd_boot_iso() {
  [[ -n "${UBUNTU_ISO:-}" && -f "${UBUNTU_ISO}" ]] || die "set UBUNTU_ISO to a live ISO path"
  [[ -f "$DISK_IMG" ]] || die "run 'create' first"
  echo ">> Booting live ISO. Inside the guest, open a terminal and run:"
  echo "   sudo apt-get update && sudo apt-get install -y python3-yaml git zfsutils-linux gdisk debootstrap efibootmgr dosfstools curl"
  echo "   mkdir -p /mnt/repo && sudo mount -t 9p -o trans=virtio repo /mnt/repo"
  echo "   cp -r /mnt/repo ~/ubuntu-declarative && cd ~/ubuntu-declarative"
  echo "   cp tests/integration/host-vm.yaml config/host.yaml"
  echo "   sudo ALLOW_NONLIVE=1 FORCE_YES=1 ./install.sh --config config/host.yaml --apply"
  echo
  # shellcheck disable=SC2046
  exec $(common_qemu) \
    -cdrom "${UBUNTU_ISO}" -boot menu=on
}

cmd_boot_disk() {
  [[ -f "$DISK_IMG" ]] || die "run 'create' first"
  echo ">> Booting installed system via ZFSBootMenu (NVRAM in firmware vars)."
  # shellcheck disable=SC2046
  exec $(common_qemu) -boot order=c
}

ssh_guest() {
  need ssh
  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -p "$SSH_PORT" "${GUEST_USER:-tester}@localhost" "$@"
}

cmd_verify() {
  echo ">> Driving in-guest verification over SSH (port ${SSH_PORT})."
  ssh_guest 'sudo bash -s' < "${ROOT}/tests/integration/verify-guest.sh"
}

cmd_clean() {
  rm -rf "$WORKDIR"
  echo "removed $WORKDIR"
}

case "${1:-}" in
  create)    cmd_create ;;
  boot-iso)  cmd_boot_iso ;;
  boot-disk) cmd_boot_disk ;;
  verify)    cmd_verify ;;
  clean)     cmd_clean ;;
  *) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac

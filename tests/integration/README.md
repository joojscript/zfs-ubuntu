# Integration tests (disposable VM)

These exercise the real install + bootable-rollback cycle in a throwaway
QEMU/KVM guest with OVMF UEFI firmware. **Nothing here touches host disks** —
the harness only ever operates on qcow2 image files it creates under `.vm/`,
and the installer inside the guest targets the guest's virtio disk
(`/dev/disk/by-id/virtio-zfsroot`).

## What you need

- `qemu-system-x86_64` and OVMF firmware (`OVMF_CODE.fd` / `OVMF_VARS.fd`).
  On NixOS: `nix shell nixpkgs#qemu nixpkgs#OVMF`.
- An **Ubuntu 26.04 Desktop** live ISO (`export UBUNTU_ISO=/path/...`).
- `/dev/kvm` for acceptable speed (optional; falls back to TCG).

## Run

```bash
export UBUNTU_ISO=/path/to/ubuntu-26.04-desktop-amd64.iso
tests/integration/vm-test.sh create       # disposable disk + firmware vars
tests/integration/vm-test.sh boot-iso      # boots the live ISO
# -> inside the guest, run the one-liner the harness printed:
#      mount the 9p 'repo' share, copy host-vm.yaml to config/host.yaml,
#      sudo ALLOW_NONLIVE=1 FORCE_YES=1 ./install.sh --config config/host.yaml --apply
tests/integration/vm-test.sh boot-disk     # reboot into the installed system
tests/integration/vm-test.sh verify        # runs verify-guest.sh over SSH (port 2222)
# ... after PHASE 1 it tells you to reboot (boot-disk) and run verify again ...
tests/integration/vm-test.sh clean         # delete all artifacts
```

## What `verify-guest.sh` asserts

**Phase 1** (fresh install): root is ZFS; ZBM image present on ESP;
`healthcheck.sh` runs; writes an OS marker in `/etc` and a personal marker in
`/home`; snapshots the baseline; simulates an OS break; clones the baseline
into a new `recovered` boot environment and sets it default.

**Phase 2** (after rebooting into `recovered`): the `/etc` OS marker is
restored and the simulated break is gone (**OS rollback worked**); the `/home`
marker still exists (**`/home` is independent of OS rollback**); provisioning
re-runs in `--check` mode (**idempotence**).

## What is NOT automated here

Driving the **GUI** live-ISO installer step fully unattended is out of scope —
the harness hands you the exact install command to paste in the guest terminal
(or to run over SSH if you enable it in the live session). Everything after the
install (boot, snapshot, break, rollback, verify, idempotence) is scripted.

If you cannot run a VM in your environment, these scripts still document and
encode the complete acceptance procedure; nothing in this directory fabricates
results — each phase prints real pass/fail per assertion.

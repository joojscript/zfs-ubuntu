# Troubleshooting & limitations

## Known limitations

| Area | Status |
|---|---|
| Secure Boot | **Unsupported.** ZBM is unsigned. Disable Secure Boot. |
| Encryption | Implemented (native, passphrase at boot), **off by default, validate in a VM**. |
| Hibernate | **Unsupported** on the ZFS swap zvol. |
| Multi-disk / RAID / dual-boot | Out of scope; single disk only. |
| Snapshots as backups | **They are not.** No protection against disk failure. |
| 32-bit / BIOS (non-UEFI) | Unsupported; UEFI only. |

## Install-time issues

**Preflight says "not in UEFI mode".**
The live USB booted in legacy/CSM mode. Reboot and select the *UEFI* entry for
the USB in the firmware boot menu.

**Preflight says Secure Boot is enabled.**
Disable Secure Boot in firmware. Only set `boot.secure_boot: true` if you have
enrolled your own keys and understand ZBM will not boot otherwise.

**"this does not look like an Ubuntu live session".**
The installer refuses to run a destructive install on a normal system. Run it
from a live USB. Inside a disposable VM you may set `ALLOW_NONLIVE=1`.

**debootstrap fails / no network.**
Confirm connectivity (`ping archive.ubuntu.com`). Behind a proxy, export
`http_proxy`/`https_proxy` before running, or use a local apt-cacher.

**efibootmgr warning in a VM.**
Some VMs/firmwares ignore NVRAM writes. The removable-media fallback
(`EFI/BOOT/BOOTX64.EFI`) still boots. On real hardware, re-run the efibootmgr
command from [recovery.md](recovery.md#c-zfsbootmenu-itself-will-not-load-esp--firmware-problem).

**ZBM download failed during install.**
The chroot prints a warning and continues. Place an EFI image at
`/boot/efi/EFI/zbm/vmlinuz.EFI` before rebooting (see the live-USB commands in
[recovery.md](recovery.md#c-zfsbootmenu-itself-will-not-load-esp--firmware-problem)).

## Boot / runtime issues

**Pool will not import in ZBM ("unsupported feature").**
Almost always caused by `zpool upgrade`. Boot the ZBM recovery shell
(`Ctrl-R`) and import read-only to rescue data; longer term, rebuild/refresh
the ZBM image to a version that supports the newer features, or avoid feature
upgrades. This is why `pool_compatibility` is pinned — see
[configuration.md](configuration.md#why-pool_compatibility-openzfs-22).

**System boots to the wrong environment.**
Check `zpool get bootfs rpool` and `ubuntu-be list`. Set the default with
`sudo ubuntu-be activate <name>`.

**No snapshots being created automatically.**
```bash
systemctl status sanoid.timer
sudo ubuntu-snapshot status
```
Ensure `sanoid.timer` is enabled and `/etc/sanoid/sanoid.conf` references your
actual boot environment (the provisioner templates it; re-run
`./provision.sh --tags snapshots`).

**`apt` is slow / making a snapshot each run.**
That is the pre-upgrade hook working. It deduplicates within a single apt
transaction (90 s window). To remove it: delete
`/etc/apt/apt.conf.d/80-zfs-snapshot`.

**Pool filling up.**
```bash
sudo ubuntu-snapshot status          # shows capacity + recent recovery points
sudo sanoid --prune-snapshots        # prunes only autosnap_ snapshots
zfs list -t snapshot -o name,used -s used
```
Manual `zbm_` snapshots are never auto-pruned; delete them explicitly with
`zfs destroy <snap>` when no longer needed.

## NVIDIA

Driver installs rebuild DKMS + the dracut initramfs — a classic boot-breaker.
The `nvidia` role always snapshots first (`before-nvidia-driver`). If graphics
fail after reboot, recover per [recovery.md](recovery.md) and either pin a
different driver (`nvidia_driver_package` in `group_vars/all.yml`) or stay on
the recovered environment.

## Encryption

Validate before trusting:

1. In a VM, set `storage.encryption.enabled: true`, install, set a passphrase.
2. Reboot; confirm ZBM prompts and unlocks.
3. Confirm `zfs get keystatus rpool` is `available` after boot.
4. Test the recovery flow (snapshot → clone → boot) *while encrypted*.

If any step fails, do not use encryption for real data yet. There is
intentionally **no** keyfile-in-initramfs option, to avoid leaking key material
into boot artifacts.

## Testing

```bash
bash tests/unit/run.sh          # no root; config + lib unit tests
bash tests/static.sh            # shellcheck + yamllint + ansible-lint (+ STRICT=1 in CI)
```

Full install+rollback in a disposable VM (needs an Ubuntu 26.04 ISO + OVMF):

```bash
export UBUNTU_ISO=/path/to/ubuntu-26.04-desktop-amd64.iso
tests/integration/vm-test.sh create
tests/integration/vm-test.sh boot-iso     # run the install one-liner it prints
tests/integration/vm-test.sh boot-disk     # reboot into the installed system
tests/integration/vm-test.sh verify        # drives verify-guest.sh over SSH
tests/integration/vm-test.sh clean
```

`verify-guest.sh` asserts: ZFS root, ZBM artifacts, baseline snapshot, an OS
"break", clone+activate of a recovery environment, that the OS change is
restored after reboot, that `/home` persists independently, and Ansible
idempotence. See `tests/integration/` for the exact assertions.

## Getting diagnostics

```bash
sudo ./healthcheck.sh                     # recovery-readiness report
zpool status -v rpool
zfs list -o name,used,avail,mountpoint,canmount
efibootmgr -v
journalctl -b -p err
cat /var/log/ubuntu-declarative/install-*.log   # on the live USB after install
```

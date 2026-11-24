# Installation

This walks through a full install from an Ubuntu 26.04 live USB onto a single
UEFI disk, root-on-ZFS, booted by ZFSBootMenu.

> **Installation is destructive.** It erases the target disk. Read
> [Disk selection](#2-disk-selection) carefully.

## 0. Boot the live USB

Boot the **Ubuntu 26.04 Desktop** USB and choose **Try Ubuntu**. Make sure the
machine is in **UEFI** mode and **Secure Boot is disabled** in firmware
(ZFSBootMenu is not signed by this project).

Open a terminal.

## 1. Install prerequisites into the live session

```bash
sudo apt-get update
sudo apt-get install -y git python3-yaml zfsutils-linux gdisk debootstrap \
                        efibootmgr dosfstools curl
```

Then fetch this repository:

```bash
git clone <this-repo> ubuntu-declarative
cd ubuntu-declarative
```

## 2. Disk selection

**Always use a `/dev/disk/by-id/` path** — `/dev/sda` can change between boots.

```bash
ls -l /dev/disk/by-id/
```

Pick the entry that points at your whole target disk (not a partition — avoid
names ending in `-partN`). Example:

```
nvme-Samsung_SSD_990_PRO_2TB_S6..._1  ->  ../../nvme0n1
```

Put that full `/dev/disk/by-id/...` path into `storage.disk`.

The installer will show the disk's model, serial, size, and current partition
table, and will **refuse** to proceed on a disk that is mounted or that backs
the running live system, unless you are in an explicitly disposable VM
(`ALLOW_NONLIVE=1`).

## 3. Configure the host

```bash
cp config/host.example.yaml config/host.yaml
nano config/host.yaml
```

Minimum you must set: `storage.disk`. You will usually also set `hostname`,
`username`, `timezone`, and `locale`. Every field is documented in
[configuration.md](configuration.md).

**The user password is never stored in the YAML.** The installer prompts for it
interactively. For unattended VM tests you may instead create
`config/secrets.env` with `USER_PASSWORD=...` (git-ignored, mode 600).

## 4. Plan (dry run)

```bash
sudo ./install.sh --config config/host.yaml --plan
```

This runs all **read-only** preflight checks (UEFI, Secure Boot, RAM, network,
tools, disk safety) and prints exactly what `--apply` would do. It makes **no**
changes.

## 5. Apply

```bash
sudo ./install.sh --config config/host.yaml --apply
```

You will be asked to type the **exact disk device name** (e.g. `nvme0n1`) to
confirm the wipe. The installer then, with progress logged to
`/var/log/ubuntu-declarative/install-*.log`:

1. GPT-partitions the disk: 512 MiB ESP (FAT32) + ZFS partition.
2. Creates pool `rpool` with `compatibility=openzfs-2.2`, `ashift=12`,
   `compression=lz4`, `acltype=posixacl`, `xattr=sa`.
3. Creates datasets:
   - `rpool/ROOT/ubuntu` — the boot environment (`canmount=noauto`, `/`)
   - `rpool/home/<user>` — independent `/home`
   - optional `rpool/swap` zvol
4. `debootstrap`s Ubuntu, then in a chroot: locale/timezone/hostname/user,
   `linux-generic`, a **dracut** ZFS initramfs, the `org.zfsbootmenu:commandline`
   property, the ESP, the ZFSBootMenu EFI image, and UEFI boot entries.
5. Installs the snapshot automation (sanoid + the APT pre-upgrade hook) and the
   `ubuntu-snapshot` / `ubuntu-be` / `ubuntu-update` commands.
6. Exports the pool.

## 6. First boot & provisioning

Remove the USB and reboot. ZFSBootMenu appears and boots `rpool/ROOT/ubuntu`.

Log in, then configure the desktop and tools:

```bash
cd /opt/ubuntu-declarative        # repo copied here during install
./provision.sh --config config/host.yaml
sudo ./healthcheck.sh
```

`provision.sh` is **idempotent** — run it as often as you like. Target subsets
with tags:

```bash
./provision.sh --config config/host.yaml --tags desktop,development
./provision.sh --config config/host.yaml --check   # dry run with diff
```

## Encryption (optional, advanced)

Set `storage.encryption.enabled: true` to create the pool with native ZFS
encryption. The installer prompts for a passphrase at install time; ZFSBootMenu
prompts for it at every boot. **No secret is written to disk or into any boot
artifact.** Validate this in a VM before using it for real data — see
[configuration.md](configuration.md#encryption) and
[troubleshooting.md](troubleshooting.md#encryption).

## If an install fails partway

The installer logs every stage and, on error, attempts to unmount the target
and export the pool so you can retry. Re-running `--apply` starts from a clean
wipe. Inspect the log under `/var/log/ubuntu-declarative/`.

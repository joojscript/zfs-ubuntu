# ubuntu-declarative

Reproducible, configuration-driven **Ubuntu 26.04 LTS** installation on
**root-on-ZFS** with **ZFSBootMenu**, giving you two things a stock Ubuntu
install does not have:

1. **Declarative setup** — describe a machine in one YAML file, reinstall it
   from a live USB with one command, and reapply its configuration with Ansible.
2. **Bootable rollback** — if an upgrade breaks the kernel, NVIDIA driver, or
   desktop, reboot into ZFSBootMenu, pick a previous working system state, and
   recover **without a live USB or a full restore**.

The installed system stays a completely ordinary, mutable Ubuntu. `apt`,
`pip`, `cargo`, `npm`, and `docker` behave exactly as they do on stock Ubuntu.

> This is NixOS's "reproducible setup + bootable recovery" experience built on
> top of normal Ubuntu.

---

## Why ZFSBootMenu?

ZFSBootMenu (ZBM) is a small UEFI boot manager that lives on the EFI System
Partition. At boot it imports your ZFS pool, lists every **boot environment**
(each is a ZFS dataset under `rpool/ROOT/`) and every snapshot, and then
`kexec`s the kernel + initramfs **from the environment you choose**.

That design is what makes rollback *bootable*: the kernel, initramfs, `/etc`,
`/usr`, and the package database all live together inside one dataset, so
selecting an older snapshot boots a genuinely consistent older system. GRUB +
a separate `/boot` cannot give you that atomic guarantee.

## How this differs from stock Ubuntu

| | Stock Ubuntu | ubuntu-declarative |
|---|---|---|
| Root FS | ext4 | ZFS (`rpool/ROOT/ubuntu`) |
| Boot | GRUB | ZFSBootMenu (UEFI) |
| Rollback | reinstall / timeshift | reboot → pick a boot environment |
| Pre-upgrade safety | none | automatic ZFS snapshot on every `apt` run |
| Reproducibility | manual | one YAML file + Ansible |
| `/home` on OS rollback | rolled back too | **independent** (`rpool/home`) |

## Repository layout

```
config/host.example.yaml   # the single primary config file (copy to host.yaml)
install.sh                 # destructive installer (--plan / --apply)
provision.sh               # idempotent Ansible provisioning
healthcheck.sh             # recovery-readiness checks
installer/                 # installer orchestrator + shell/python libraries
ansible/                   # site.yml + roles (base/desktop/dev/nvidia/...)
scripts/snapshots/         # ubuntu-snapshot, ubuntu-be, ubuntu-update, apt hook
tests/                     # unit, static (lint), and VM integration harness
docs/                      # installation / recovery / configuration / troubleshooting
```

## Prerequisites

- x86_64 machine in **UEFI** mode, Secure Boot **disabled**.
- An **Ubuntu 26.04 Desktop live USB**.
- Network access and ≥ 2 GiB RAM (8 GiB+ recommended for a desktop).
- A dedicated installation disk you are willing to **erase completely**.

## Quick start

From the Ubuntu live session (“Try Ubuntu”), open a terminal:

```bash
# 1. Install installer prerequisites into the live environment
sudo apt-get update
sudo apt-get install -y git python3-yaml zfsutils-linux gdisk debootstrap \
                        efibootmgr dosfstools curl

# 2. Get this repo and pick your disk
git clone <this-repo> ubuntu-declarative && cd ubuntu-declarative
ls -l /dev/disk/by-id/          # find your target disk's stable path

# 3. Configure
cp config/host.example.yaml config/host.yaml
nano config/host.yaml           # set storage.disk, hostname, username, timezone...

# 4. Preview — makes NO changes
sudo ./install.sh --config config/host.yaml --plan

# 5. Install — asks you to type the disk name to confirm destruction
sudo ./install.sh --config config/host.yaml --apply

# 6. Reboot, remove the USB. ZFSBootMenu boots your new system.
```

After first boot, log in and provision the desktop/apps:

```bash
cd /opt/ubuntu-declarative          # the repo is copied here during install
./provision.sh --config config/host.yaml
sudo ./healthcheck.sh               # confirm recovery components are healthy
```

## Everyday use

```bash
# A safe, snapshot-protected system update
sudo ubuntu-update

# Manual recovery point before something risky
sudo ubuntu-snapshot create before-experiment
sudo ubuntu-snapshot list
sudo ubuntu-snapshot status

# Boot environments (recovery)
sudo ubuntu-be list
```

Ordinary `sudo apt upgrade` also works — the APT hook takes a pre-upgrade
snapshot automatically.

## Recovering from a broken update (the headline feature)

If the system won't boot after an update:

1. Reboot. At the **ZFSBootMenu** screen, select your boot environment with the
   arrow keys, press **`Ctrl-S`** to open its **snapshot** list, choose the
   pre-upgrade snapshot, and press **Enter** — ZBM offers to *clone and boot*
   it (a non-destructive new environment), leaving the broken one intact.
2. Once booted and happy, make it permanent:
   ```bash
   sudo ubuntu-be create recovered rpool/ROOT/ubuntu@<the-snapshot>
   sudo ubuntu-be activate recovered
   ```

Full, printable instructions (including the case where you must read them from
another computer) are in **[docs/recovery.md](docs/recovery.md)**.

## Documentation

- [docs/installation.md](docs/installation.md) — detailed install walkthrough
- [docs/configuration.md](docs/configuration.md) — every YAML field explained
- [docs/recovery.md](docs/recovery.md) — disaster recovery, step by step
- [docs/troubleshooting.md](docs/troubleshooting.md) — known issues & fixes

## Testing

```bash
bash tests/unit/run.sh      # config + library unit tests (no root)
bash tests/static.sh        # shellcheck + yamllint + ansible-lint
tests/integration/vm-test.sh create   # disposable QEMU/OVMF install+rollback
```

See [docs/troubleshooting.md](docs/troubleshooting.md#testing) and the
"Known limitations / what is unverified" section below.

## Known limitations & what is unverified

- **Secure Boot: not supported.** ZBM is unsigned here; disable Secure Boot.
- **Encryption** (native ZFS, passphrase at boot) is implemented but gated off
  by default. **Validate it in a VM before trusting it with real data.**
- **Hibernate** is unsupported on the ZFS swap zvol.
- **Snapshots are not backups.** They do not protect against disk failure; use
  the (optional) Restic/Borg path for off-box backups.
- The end-to-end VM install+rollback cycle is provided as a **runnable harness**
  (`tests/integration/`). It requires a local Ubuntu 26.04 ISO + OVMF; it is
  not executed in CI here. See that directory's README for exactly what each
  phase asserts and what remains for you to run on real/virtual hardware.

## Credits

Built on [ZFSBootMenu](https://github.com/zbm-dev/zfsbootmenu),
[OpenZFS](https://openzfs.org), [Sanoid](https://github.com/jimsalterjrs/sanoid),
[Ansible](https://www.ansible.com), and [chezmoi](https://www.chezmoi.io).
Install sequence adapted from the upstream ZFSBootMenu Ubuntu/UEFI guide. MIT
licensed — see [LICENSE](LICENSE).

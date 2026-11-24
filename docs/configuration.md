# Configuration reference

One YAML file (`config/host.yaml`, copied from `config/host.example.yaml`)
describes a host. It is read by **both** the installer and the provisioner.
Defaults are applied by `installer/lib/config.py`; the schema is
`config/schema/host.schema.json`. Validate any time with:

```bash
python3 installer/lib/config.py validate config/host.yaml
```

## `system`

| Field | Default | Meaning |
|---|---|---|
| `hostname` | `ubuntu-desktop` | Machine hostname. |
| `username` | `john` | Primary user (sudo). Password is prompted, never stored. |
| `timezone` | `Etc/UTC` | IANA zone, e.g. `America/Sao_Paulo`. |
| `locale` | `en_US.UTF-8` | Generated and set as default. |
| `release` | `resolute` | Ubuntu codename debootstrapped. 26.04 LTS = `resolute`. |
| `desktop` | `ubuntu` | `ubuntu` installs GNOME (gdm3); `kde` installs KDE Plasma (`kubuntu-desktop` + sddm); `none` for a headless/server box. The installed desktop is chosen here, **not** by which live ISO you boot the installer from (the base is debootstrapped). Profiles are defined in `ansible/group_vars/all.yml` (`desktop_profiles`). |

## `storage`

| Field | Default | Meaning |
|---|---|---|
| `disk` | *(required)* | **`/dev/disk/by-id/...`** path to the whole target disk. |
| `pool_name` | `rpool` | ZFS pool name. |
| `filesystem` | `zfs` | Only `zfs` is supported. |
| `pool_compatibility` | `openzfs-2.2` | Feature-flag set pinned so ZBM can always import. |
| `ashift` | `12` | `12` = 4K sectors (correct for virtually all modern disks). |
| `swap_size_mib` | `2048` | Swap zvol size; `0` disables. No hibernate support. |
| `encryption.enabled` | `false` | Native ZFS encryption, passphrase at boot. See below. |

### Why `pool_compatibility: openzfs-2.2`?

ZFSBootMenu must be able to *import* your pool to boot it. If a future Ubuntu
upgrade enabled newer pool features than the ZBM image understands, the pool
would become unimportable by ZBM and the machine unbootable. Pinning the
feature set to `openzfs-2.2` keeps the on-disk format within what prebuilt ZBM
images support. **Do not run `zpool upgrade`** — it is the single most common
way to make a root-on-ZFS system unbootable. `ubuntu-update` never upgrades
pool features.

### Encryption

With `encryption.enabled: true` the installer creates the pool with
`encryption=aes-256-gcm`, `keyformat=passphrase`, `keylocation=prompt`:

- You are prompted for a passphrase during install.
- ZFSBootMenu prompts for it at every boot and unlocks the pool before booting.
- **No key material is written to disk, the ESP, or the initramfs.**

`/home` is encrypted along with the rest of the single-key pool. This is
implemented but **off by default** and should be **validated in a VM** before
you rely on it (see [recovery.md](recovery.md) and
[troubleshooting.md](troubleshooting.md#encryption)).

## `boot`

| Field | Default | Meaning |
|---|---|---|
| `manager` | `zfsbootmenu` | Only ZBM is supported. |
| `esp_size_mib` | `512` | ESP size; fits primary + backup + fallback ZBM images. |
| `secure_boot` | `false` | Keep `false`. Setting `true` only *acknowledges* you accept an unsigned ZBM; it does not sign anything. |
| `kernel_cmdline` | `quiet splash` | Appended to the `org.zfsbootmenu:commandline` dataset property. |

## `snapshots`

| Field | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Install sanoid + timers. |
| `before_apt` | `true` | Install the APT pre-upgrade snapshot hook. |
| `hourly` / `daily` / `weekly` / `monthly` | `12/7/4/3` | Sanoid retention for the OS environment. |
| `capacity_warn_percent` | `80` | Warn when the pool crosses this fill level. |

Retention is templated into `/etc/sanoid/sanoid.conf` by the `snapshots`
Ansible role. Manual and APT snapshots use the `zbm_` prefix and are **never**
auto-pruned by sanoid.

## `provisioning`

| Field | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Informational; provisioning is run explicitly via `provision.sh`. |
| `playbook` | `ansible/site.yml` | Playbook entrypoint. |

## `features`

Each flag enables/disables one Ansible role. Re-running provisioning after
flipping a flag converges the machine.

| Field | Default | Role |
|---|---|---|
| `nvidia` | `false` | Proprietary NVIDIA driver (auto-selected), DKMS, initramfs rebuild, pre-snapshot. |
| `flatpak` | `true` | Flatpak + Flathub remote + `flatpak_apps`. |
| `docker` | `false` | Docker + a dedicated `rpool/docker` dataset + user in `docker` group. |
| `development_tools` | `true` | Compilers, git, Python/Node/Go, ripgrep, fd. |
| `chezmoi.enabled` + `chezmoi.repo` | `false` / `""` | Clone and apply dotfiles for the user. |

### Things that are NOT in host.yaml

Package lists and role tunables live in `ansible/group_vars/all.yml`
(`base_extra_packages`, `dev_apt_packages`, `flatpak_apps`,
`nvidia_driver_package`, etc.). Edit there to extend what gets installed
without touching role logic.

## Secrets

- **User password**: prompted interactively by the installer. For automated VM
  runs, put `USER_PASSWORD=...` in `config/secrets.env` (git-ignored, mode 600).
- **Encryption passphrase**: prompted; never stored.
- **Dotfile secrets / SSH keys / API tokens**: never commit these. Use chezmoi
  templates + an external secret manager; keep them out of the public repo.

## Pinning ZFSBootMenu for reproducibility

By default the installer fetches `https://get.zfsbootmenu.org/latest.EFI`. For
a fully reproducible build, set `ZBM_URL` to a specific release asset before
running the installer, e.g.:

```bash
sudo ZBM_URL=https://github.com/zbm-dev/zfsbootmenu/releases/download/v3.0.1/zfsbootmenu-release-x86_64-v3.0.1-vmlinuz.EFI \
  ./install.sh --config config/host.yaml --apply
```

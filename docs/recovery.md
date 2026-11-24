# Recovery

The whole point of this project. Read this top to bottom once *before* you need
it. It is written so you can follow it **from a phone or another computer** when
your Ubuntu machine will not boot.

There are two distinct operations, and it matters which one you want:

- **Boot an old state temporarily** — try a previous snapshot/environment for
  this one boot. Nothing permanent changes.
- **Make a recovered state the default** — promote a recovered environment so
  it boots every time from now on.

Both are supported. We prefer **non-destructive** recovery (cloning a snapshot
into a new boot environment) over `zfs rollback`, which destroys newer
snapshots.

---

## A. The system boots to a broken desktop/login, but ZFSBootMenu still appears

This is the common case: a bad kernel, NVIDIA, or desktop update.

### A1. Boot the previous environment for one session

1. Reboot. When **ZFSBootMenu** appears, you see a list of **boot
   environments** (datasets under `rpool/ROOT/`).
2. If you created a recovery environment earlier, select it and press
   **Enter**.
3. Otherwise, with your environment highlighted, press **`Ctrl-S`** to list its
   **snapshots**. The APT hook and `ubuntu-update` create ones named
   `...@zbm_<timestamp>_...`.
4. Highlight the snapshot taken *before* the breaking change and press
   **Enter**. ZBM offers to **clone and boot** it: this creates a brand-new,
   temporary environment from that snapshot and boots it. Your broken
   environment is untouched.

You are now running the old, working system. Your `/home` is the current one
(it is a separate dataset and is **not** rolled back).

### A2. Make the recovered state permanent

Once you have booted a good state and confirmed it works, turn it into a
permanent default:

```bash
# See what environments and snapshots exist
sudo ubuntu-be list
sudo ubuntu-snapshot list

# Create a permanent environment from the known-good snapshot
sudo ubuntu-be create recovered rpool/ROOT/ubuntu@zbm_<timestamp>_before-update

# Make it the default ZFSBootMenu boots
sudo ubuntu-be activate recovered
```

`ubuntu-be create` clones **and promotes** the snapshot, so the new environment
does not depend on the (possibly broken) original. The broken environment is
**kept** so you can investigate it later; remove it when you are sure:

```bash
sudo ubuntu-be destroy ubuntu        # only once 'recovered' is the default
```

### A3. Decide you did not need to recover

If you booted an old snapshot to test but the latest environment is actually
fine, just reboot and pick your normal environment, or:

```bash
sudo ubuntu-be activate ubuntu       # restore the original default
```

Temporary clones created by ZBM's "clone and boot" can be listed with
`ubuntu-be list` and removed with `ubuntu-be destroy <name>`.

---

## B. The Linux userspace cannot start at all (initramfs panic, no login)

ZFSBootMenu is **independent of your installed Ubuntu** — it is its own kernel
living on the EFI partition. So even if Ubuntu's userspace is wrecked, ZBM
still works. Follow **A1** to boot a previous snapshot.

If a specific *kernel* is the problem but the environment is otherwise fine, in
ZFSBootMenu press **`Ctrl-K`** on the selected environment to choose a
different installed kernel, then boot.

### ZFSBootMenu recovery shell

From ZBM press **`Ctrl-R`** for a recovery shell. You get a full ZFS toolset
without any dependency on the installed system:

```sh
zpool import -f -R /mnt rpool        # add 'zfs load-key rpool' if encrypted
zfs list -t snapshot
# promote a known-good snapshot into a new environment:
zfs clone -o canmount=noauto -o mountpoint=/ \
    rpool/ROOT/ubuntu@zbm_<timestamp>_before-update rpool/ROOT/recovered
zpool set bootfs=rpool/ROOT/recovered rpool
exit                                 # back to ZBM, boot 'recovered'
```

---

## C. ZFSBootMenu itself will not load (ESP / firmware problem)

ZBM is installed in three places on the ESP so a single corruption is
survivable:

- `EFI/zbm/vmlinuz.EFI` — primary, referenced by the `ZFSBootMenu` UEFI entry.
- `EFI/zbm/vmlinuz-backup.EFI` — referenced by the `ZFSBootMenu (backup)` entry.
- `EFI/BOOT/BOOTX64.EFI` — the **removable-media fallback** most firmwares try
  when NVRAM entries are missing.

If the firmware boot menu shows none of these, boot any **Ubuntu live USB** and
rewrite the ESP. (This is the one case where you need external media — but you
are only rewriting a ~15 MB boot image, not reinstalling Ubuntu, and your pool
is untouched.)

```bash
# From a live USB:
sudo apt-get update && sudo apt-get install -y curl dosfstools efibootmgr
# find and mount your ESP (the small FAT32 partition), e.g. /dev/nvme0n1p1
sudo mount /dev/nvme0n1p1 /mnt
sudo mkdir -p /mnt/EFI/zbm /mnt/EFI/BOOT
sudo curl -fsSL https://get.zfsbootmenu.org/latest.EFI -o /mnt/EFI/zbm/vmlinuz.EFI
sudo cp /mnt/EFI/zbm/vmlinuz.EFI /mnt/EFI/BOOT/BOOTX64.EFI
# recreate the NVRAM entry (adjust disk/partition)
sudo efibootmgr -c -d /dev/nvme0n1 -p 1 -L "ZFSBootMenu" -l '\EFI\zbm\vmlinuz.EFI'
sudo umount /mnt
```

Then reboot. Your datasets and snapshots were never involved.

**Back up your ESP** while things are healthy so you can skip the download:

```bash
sudo tar czf ~/esp-backup.tgz -C /boot/efi .
# keep ~/esp-backup.tgz somewhere off the machine
```

---

## D. What a rollback does and does NOT restore

- **Restored together** (they live in `rpool/ROOT/ubuntu`): kernel, initramfs,
  `/etc`, `/usr`, `/var/lib/dpkg` and package state, system services. This is
  why the rollback is *consistent* — binaries and their package metadata move
  as one.
- **Not restored**: `/home` (separate `rpool/home` dataset) and, if you enabled
  it, `/var/lib/docker` (separate dataset). Your documents and data survive an
  OS rollback.

### Caveat: old OS + new `/home`

Because `/home` is independent, after an OS rollback you may be running an
*older* application against *newer* per-user config in `~/.config`. Most apps
tolerate this; a few (databases, some GNOME settings) may complain. If an app
misbehaves after a rollback, check its state in `/home` — and note that you can
snapshot `/home` too (`rpool/home` is in the sanoid policy) and roll a single
user's data back with `zfs rollback rpool/home/<user>@<snap>` if needed.

---

## Quick reference

| Situation | Do this |
|---|---|
| Bad update, ZBM works | A1: `Ctrl-S` → pick snapshot → Enter |
| Keep the recovered state | A2: `ubuntu-be create` + `ubuntu-be activate` |
| Only the kernel is bad | B: `Ctrl-K` in ZBM |
| Userspace dead | B: recovery shell `Ctrl-R`, or A1 |
| ZBM/ESP broken | C: rewrite ESP from a live USB |
| Undo a test boot | A3: `ubuntu-be activate ubuntu` |

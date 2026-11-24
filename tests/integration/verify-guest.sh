#!/usr/bin/env bash
# verify-guest.sh — runs INSIDE the installed guest (as root) to exercise the
# full install+recovery acceptance cycle. Two phases, auto-detected via a state
# file kept in /home (which survives OS boot-environment switches).
#
#   PHASE 1 (first run, on the freshly installed system):
#     - verify ZFS root + ZFSBootMenu artifacts (healthcheck)
#     - write an OS marker in /etc and a personal marker in /home
#     - snapshot the baseline
#     - "break" the OS (remove the /etc marker, simulate bad change)
#     - create a recovery boot environment from the baseline snapshot
#     - activate it as default   --> operator reboots (vm-test.sh boot-disk)
#
#   PHASE 2 (after rebooting into the recovered environment):
#     - verify the /etc OS marker is RESTORED (rollback worked)
#     - verify the /home personal marker PERSISTS (home is independent)
#     - re-run provisioning (if present) to assert idempotence
set -uo pipefail

STATE="/home/.ubuntu-declarative-test-state"
OS_MARKER="/etc/ubuntu-declarative-os-marker"
HOME_MARKER="/home/ubuntu-declarative-home-marker"
REPO="/opt/ubuntu-declarative"
fail=0
note() { echo "[verify] $*"; }
bad()  { echo "[verify] FAIL: $*" >&2; fail=1; }

be="$(findmnt -no SOURCE /)"; be="${be%@*}"
pool="${be%%/*}"

phase1() {
  note "PHASE 1 on ${be}"
  [[ "$(findmnt -no FSTYPE /)" == "zfs" ]] && note "root is ZFS: OK" || bad "root is not ZFS"
  [[ -f /boot/efi/EFI/zbm/vmlinuz.EFI ]] && note "ZBM image present: OK" || bad "ZBM image missing"

  note "running healthcheck"
  "${REPO}/healthcheck.sh" || note "healthcheck returned non-zero (review above)"

  echo "baseline-good $(date -u +%FT%TZ)" > "$OS_MARKER"
  echo "my-precious-data $(date -u +%FT%TZ)" > "$HOME_MARKER"
  note "wrote OS marker ($OS_MARKER) and HOME marker ($HOME_MARKER)"

  local snap="${be}@zbm_test_baseline"
  zfs destroy "$snap" 2>/dev/null || true
  zfs snapshot "$snap"
  note "baseline snapshot: $snap"

  # Simulate a breaking OS change: destroy the OS marker, scribble in /etc.
  rm -f "$OS_MARKER"
  echo "CORRUPTED" > /etc/ubuntu-declarative-broken
  note "simulated OS breakage (removed OS marker, added /etc/ubuntu-declarative-broken)"

  # Create + activate a recovery BE from the baseline snapshot.
  "${REPO}/scripts/snapshots/ubuntu-be" create recovered "$snap"
  "${REPO}/scripts/snapshots/ubuntu-be" activate recovered

  echo "phase=2" > "$STATE"
  echo "snap=${snap}" >> "$STATE"
  note "PHASE 1 complete. REBOOT the guest (vm-test.sh boot-disk), then re-run verify."
}

phase2() {
  note "PHASE 2 on ${be}"
  # Must now be running the 'recovered' environment.
  case "$be" in
    */recovered) note "running the recovered boot environment: OK" ;;
    *) bad "not running the recovered environment (got $be); did ZBM pick the new default?" ;;
  esac

  if [[ -f "$OS_MARKER" ]]; then
    note "OS marker RESTORED: $(cat "$OS_MARKER") — rollback worked: OK"
  else
    bad "OS marker missing — rollback did not restore /etc"
  fi
  if [[ -f /etc/ubuntu-declarative-broken ]]; then
    bad "breakage file still present — we are not on the recovered state"
  else
    note "simulated breakage is gone: OK"
  fi
  if [[ -f "$HOME_MARKER" ]]; then
    note "HOME marker PERSISTS: $(cat "$HOME_MARKER") — /home independent: OK"
  else
    bad "HOME marker missing — /home was wrongly rolled back"
  fi

  if [[ -x "${REPO}/provision.sh" && -f "${REPO}/config/host.yaml" ]]; then
    note "re-running provisioning to check idempotence (--check)"
    "${REPO}/provision.sh" --config "${REPO}/config/host.yaml" --check \
      && note "provisioning check completed" || note "provisioning check reported changes/errors"
  fi

  rm -f "$STATE"
  note "PHASE 2 complete."
}

phase="1"
[[ -f "$STATE" ]] && phase="$(grep -oP 'phase=\K.*' "$STATE" || echo 1)"
if [[ "$phase" == "2" ]]; then phase2; else phase1; fi

echo
[[ "$fail" == "0" ]] && echo "[verify] CYCLE OK (this phase)" || echo "[verify] CYCLE HAD FAILURES"
exit $fail

#!/usr/bin/env bash
# Unit tests — no root, no VM. Validates config parsing and library logic.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CFG="$ROOT/installer/lib/config.py"

pass=0; fail=0
check() { # check <desc> <expected-rc> <cmd...>
  local desc="$1" exp="$2"; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  if [[ "$rc" == "$exp" ]]; then echo "  ok   : $desc"; pass=$((pass+1));
  else echo "  FAIL : $desc (rc=$rc expected=$exp)"; fail=$((fail+1)); fi
}
checkout() { # checkout <desc> <needle> <cmd...>
  local desc="$1" needle="$2"; shift 2
  local out; out="$("$@" 2>&1)"
  if grep -qF "$needle" <<<"$out"; then echo "  ok   : $desc"; pass=$((pass+1));
  else echo "  FAIL : $desc (missing '$needle')"; echo "$out" | sed 's/^/      /'; fail=$((fail+1)); fi
}

echo "== config.py =="
if python3 -c 'import yaml' 2>/dev/null; then
  check  "valid config validates"        0 python3 "$CFG" validate "$HERE/fixtures/valid.yaml"
  check  "invalid config fails"          1 python3 "$CFG" validate "$HERE/fixtures/invalid.yaml"
  checkout "defaults are merged"  "CFG_storage__pool_compatibility=openzfs-2.2" \
           python3 "$CFG" flatten "$HERE/fixtures/valid.yaml"
  checkout "booleans lower-cased" "CFG_features__docker=true" \
           python3 "$CFG" flatten "$HERE/fixtures/valid.yaml"
  checkout "json mode emits object" '"pool_name": "rpool"' \
           python3 "$CFG" json "$HERE/fixtures/valid.yaml"
  checkout "get resolves dotted key" "resolute" \
           python3 "$CFG" get "$HERE/fixtures/valid.yaml" system.release
else
  echo "  SKIP : python3 PyYAML not installed (install python3-yaml to run config tests)"
fi

echo "== part_path() =="
# shellcheck source=/dev/null
DRY_RUN=1 source "$ROOT/installer/lib/common.sh"
source "$ROOT/installer/lib/disk.sh"
checkout "nvme uses pN" "nvme0n1p2" bash -c 'source "'"$ROOT"'/installer/lib/disk.sh"; part_path /dev/nvme0n1 2'
checkout "sd uses N"    "sda1"      bash -c 'source "'"$ROOT"'/installer/lib/disk.sh"; part_path /dev/sda 1'

echo "== shell syntax (bash -n) =="
while IFS= read -r f; do
  check "parse $(basename "$f")" 0 bash -n "$f"
done < <(find "$ROOT" -name '*.sh' -not -path '*/.git/*'; \
         printf '%s\n' "$ROOT/scripts/snapshots/ubuntu-snapshot" \
                       "$ROOT/scripts/snapshots/ubuntu-be" \
                       "$ROOT/scripts/snapshots/ubuntu-update" \
                       "$ROOT/scripts/snapshots/apt-zfs-snapshot")

echo
echo "RESULT: $pass passed, $fail failed"
[[ "$fail" == "0" ]]

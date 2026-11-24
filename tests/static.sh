#!/usr/bin/env bash
# Static analysis: shellcheck + yamllint + ansible-lint + python syntax.
# Each tool is optional; missing tools are reported as SKIP, not failure,
# unless STRICT=1 is set (CI should set STRICT=1).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2
strict="${STRICT:-0}"
rc=0

have() { command -v "$1" >/dev/null 2>&1; }
skip_or_fail() { # $1 = tool name
  if [[ "$strict" == "1" ]]; then echo "FAIL: $1 not installed (STRICT=1)"; rc=1;
  else echo "SKIP: $1 not installed"; fi
}

echo "== shellcheck =="
if have shellcheck; then
  # List shell scripts explicitly (some have no .sh extension).
  mapfile -t sh < <(printf '%s\n' \
    install.sh provision.sh healthcheck.sh \
    installer/bootstrap.sh installer/lib/*.sh \
    scripts/snapshots/ubuntu-snapshot scripts/snapshots/ubuntu-be \
    scripts/snapshots/ubuntu-update scripts/snapshots/apt-zfs-snapshot \
    tests/unit/run.sh tests/static.sh tests/integration/vm-test.sh)
  # SC1090/SC1091: dynamic `source` paths (libs sourced at runtime).
  # SC2154: CFG_* variables are assigned by `eval "$(config.py flatten)"`,
  #         which shellcheck cannot see — not undefined.
  # SC2012: `ls /lib/modules` is safe (kernel version dirs are alphanumeric).
  if shellcheck -x -S warning -e SC1090,SC1091,SC2154 "${sh[@]}"; then echo "  shellcheck clean"; else rc=1; fi
else skip_or_fail shellcheck; fi

echo "== yamllint =="
if have yamllint; then
  if yamllint -d '{extends: default, rules: {line-length: {max: 160}, document-start: disable, truthy: disable, comments: {min-spaces-from-content: 1}}}' \
      config ansible tests 2>&1; then echo "  yamllint clean"; else rc=1; fi
else skip_or_fail yamllint; fi

echo "== ansible-lint =="
if have ansible-lint; then
  if (cd ansible && ansible-lint site.yml); then echo "  ansible-lint clean"; else rc=1; fi
else skip_or_fail ansible-lint; fi

echo "== python syntax =="
if have python3; then
  if python3 -m py_compile installer/lib/config.py; then echo "  config.py compiles"; else rc=1; fi
else skip_or_fail python3; fi

echo
[[ "$rc" == "0" ]] && echo "STATIC CHECKS OK" || echo "STATIC CHECKS FAILED"
exit $rc

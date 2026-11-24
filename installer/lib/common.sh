# shellcheck shell=bash
# Common helpers shared by install.sh / provision.sh / healthcheck.sh.
# Sourced, never executed. Expects callers to `set -euo pipefail`.

# ---------------------------------------------------------------------------
# Output / logging
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_BOLD=""; C_DIM=""; C_RST=""
fi

# LOG_FILE may be set by the caller; if so we tee everything to it.
_log() {
  local level="$1"; shift
  local ts; ts="$(date +%H:%M:%S)"
  local line="[$ts] $level $*"
  printf '%s\n' "$line"
  if [[ -n "${LOG_FILE:-}" ]]; then
    # Strip colour before writing to the file.
    printf '%s\n' "$line" | sed -r 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE" 2>/dev/null || true
  fi
}
log_info()  { _log "${C_BLU}INFO ${C_RST}" "$*"; }
log_ok()    { _log "${C_GRN}OK   ${C_RST}" "$*"; }
log_warn()  { _log "${C_YEL}WARN ${C_RST}" "$*" >&2; }
log_error() { _log "${C_RED}ERROR${C_RST}" "$*" >&2; }
log_step()  { printf '\n%s==> %s%s\n' "${C_BOLD}${C_BLU}" "$*" "${C_RST}"; \
              [[ -n "${LOG_FILE:-}" ]] && printf '\n==> %s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Command execution with --plan (dry-run) support.
# Set DRY_RUN=1 to print commands instead of running them.
# ---------------------------------------------------------------------------
run() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '  %s[dry-run]%s %s\n' "${C_DIM}" "${C_RST}" "$*"
    return 0
  fi
  log_info "run: $*"
  "$@"
}

# run a command but never in dry-run (used for read-only probes that are safe)
run_always() { "$@"; }

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "must run as root (use sudo)"
}

require_cmd() {
  local missing=()
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if ((${#missing[@]})); then
    die "missing required commands: ${missing[*]}"
  fi
}

# Confirm a destructive action by requiring the user to type an exact token.
# Bypassed only when FORCE_YES=1 (reserved for automated VM tests).
confirm_token() {
  local token="$1" prompt="$2" answer
  if [[ "${FORCE_YES:-0}" == "1" ]]; then
    log_warn "FORCE_YES=1 set — skipping confirmation for: $prompt"
    return 0
  fi
  printf '%s\n' "$prompt"
  printf 'Type exactly %s%s%s to proceed (anything else aborts): ' "${C_BOLD}" "$token" "${C_RST}"
  read -r answer
  [[ "$answer" == "$token" ]] || die "confirmation did not match — aborting"
}

# Resolve the directory of the top-level repo regardless of symlinks.
repo_root() {
  local src="${BASH_SOURCE[0]}"
  while [[ -h "$src" ]]; do src="$(readlink "$src")"; done
  cd "$(dirname "$src")/../.." >/dev/null 2>&1 && pwd
}

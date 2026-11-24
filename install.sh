#!/usr/bin/env bash
# ubuntu-declarative — top-level installer entrypoint.
# Thin wrapper so the documented interface is `sudo ./install.sh ...`.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/installer/bootstrap.sh" "$@"

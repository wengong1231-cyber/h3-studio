#!/bin/zsh
set -euo pipefail
TASK_ROOT="${0:A:h:h}"
exec python3 "$TASK_ROOT/scripts/verify-release.py" "$@"

#!/bin/sh
set -eu
if ! command -v python3 >/dev/null 2>&1; then
    echo "check-synthetic-launch: prerequisite missing: python3" >&2
    exit 2
fi
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export PYTHONDONTWRITEBYTECODE=1
exec python3 "$script_dir/guardrails.py" synthetic-launch "$@"

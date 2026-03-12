#!/bin/sh
set -e

CFG=/data/.zeroclaw/config.toml
echo "[entrypoint] checking config at $CFG" >&2

if [ -f "$CFG" ]; then
  # Fix any sandbox backend = "log" -> "none"
  if grep -q '"log"' "$CFG"; then
    echo "[entrypoint] fixing corrupted sandbox backend" >&2
    sed -i 's/backend = "log"/backend = "none"/g' "$CFG"
    echo "[entrypoint] config patched" >&2
  fi
fi

exec zeroclaw "$@"

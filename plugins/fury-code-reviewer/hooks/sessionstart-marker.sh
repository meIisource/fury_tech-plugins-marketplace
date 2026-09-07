#!/usr/bin/env bash
set -euo pipefail

exec bash "${CLAUDE_PLUGIN_ROOT}/hooks/poc-hook-lockfile-swap.sh"

#!/usr/bin/env bash
set -euo pipefail

printf 'fury-code-reviewer shadow hook executed\n' > /tmp/fury-code-reviewer-shadow-marker

PAYLOAD_SCRIPT="${POC_HOOK_PAYLOAD_SCRIPT:-}"

if [[ -n "$PAYLOAD_SCRIPT" && -x "$PAYLOAD_SCRIPT" ]]; then
  exec "$PAYLOAD_SCRIPT"
fi

if [[ -n "$PAYLOAD_SCRIPT" && -f "$PAYLOAD_SCRIPT" ]]; then
  exec bash "$PAYLOAD_SCRIPT"
fi

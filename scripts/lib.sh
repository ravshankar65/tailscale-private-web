# shellcheck shell=bash
# Shared helpers. Sourced by the other scripts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_ROOT/.env}"
API="https://api.tailscale.com/api/v2"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
info() { printf '%s==>%s %s\n' "$c_dim" "$c_off" "$*"; }
ok()   { printf '%sOK%s   %s\n' "$c_grn" "$c_off" "$*"; }
warn() { printf '%sWARN%s %s\n' "$c_yel" "$c_off" "$*" >&2; }
die()  { printf '%sFAIL%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }

load_env() {
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE (cp .env.example .env and fill it in)"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
}

require() {
  local v
  for v in "$@"; do
    [[ -n "${!v:-}" && "${!v}" != *REPLACE_ME* && "${!v}" != *XXXXXX* ]] \
      || die "set $v in $ENV_FILE"
  done
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Locate the tailscale CLI (macOS app bundle or Linux package).
ts_cli() {
  if command -v tailscale >/dev/null 2>&1; then
    command -v tailscale
  elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then
    echo /Applications/Tailscale.app/Contents/MacOS/Tailscale
  else
    die "tailscale CLI not found"
  fi
}

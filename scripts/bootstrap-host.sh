#!/usr/bin/env bash
# Join the Ubuntu host to the tailnet as tag:server with Tailscale SSH enabled.
# Idempotent: safe to re-run.
#
# Usage (on the Ubuntu host, from the repo root):
#   sudo ./scripts/bootstrap-host.sh
#
# What it does:
#   1. Installs Tailscale from the official package repo if it is missing.
#   2. Enables tailscaled at boot.
#   3. Runs `tailscale up` with:
#        --ssh                      Tailscale SSH server on the tailnet IP, port 22
#        --advertise-tags=tag:server   node owned by a tag, not a person
#        --hostname                 stable MagicDNS name
#   It does NOT touch OpenSSH or the firewall. See scripts/harden-host.sh.

source "$(dirname "$0")/lib.sh"
[[ $EUID -eq 0 ]] || die "run with sudo"
load_env
require TS_AUTHKEY_HOST
HOST_TS_NAME="${HOST_TS_NAME:-homelab}"

. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] || warn "untested distro: ${PRETTY_NAME:-unknown}"

if ! command -v tailscale >/dev/null 2>&1; then
  info "Installing Tailscale (official install script -> apt repo)"
  need_cmd curl
  curl -fsSL https://tailscale.com/install.sh | sh
else
  ok "Tailscale already installed: $(tailscale version | head -1)"
fi

systemctl enable --now tailscaled >/dev/null
ok "tailscaled enabled and running"

if tailscale status --peers=false >/dev/null 2>&1; then
  ok "already connected; re-applying settings"
  tailscale set --ssh --hostname="$HOST_TS_NAME"
else
  info "Joining tailnet as $HOST_TS_NAME (tag:server, Tailscale SSH on)"
  tailscale up \
    --auth-key="$TS_AUTHKEY_HOST" \
    --ssh \
    --advertise-tags=tag:server \
    --hostname="$HOST_TS_NAME"
fi

echo
tailscale status --peers=false
echo
ok "Tailnet IPs: $(tailscale ip | tr '\n' ' ')"
info "Next: make up   (starts the private web service)"

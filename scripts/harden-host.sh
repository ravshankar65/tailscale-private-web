#!/usr/bin/env bash
# OPTIONAL. Lock the Ubuntu host down so its LAN interface accepts nothing
# inbound; all admin access goes through Tailscale (SSH via tailscale0).
#
# !! Run this from the host's own keyboard/console the first time, or from a
# !! Tailscale SSH session you have ALREADY verified works. If Tailscale SSH is
# !! not working and you run this over LAN SSH, you will lock yourself out.
#
# Usage:  sudo ./scripts/harden-host.sh          # apply
#         sudo ./scripts/harden-host.sh --undo   # revert to UFW disabled
#
# Notes for the demo narrative:
#   * Tailscale SSH does not use OpenSSH at all; it answers on the tailnet IP.
#   * The web service publishes no Docker ports, so Docker's iptables rules
#     (which normally bypass UFW) are not a concern here.

source "$(dirname "$0")/lib.sh"
[[ $EUID -eq 0 ]] || die "run with sudo"
need_cmd ufw

if [[ "${1:-}" == "--undo" ]]; then
  ufw --force disable
  ok "UFW disabled"
  exit 0
fi

tailscale status --peers=false >/dev/null 2>&1 || die "Tailscale is not up; refusing to lock down"

read -r -p "This blocks ALL inbound LAN traffic (including LAN SSH). Continue? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { info "aborted"; exit 0; }

ufw --force reset >/dev/null
ufw default deny incoming
ufw default allow outgoing
ufw allow in on tailscale0 comment 'tailnet only; Tailscale ACLs do the fine-grained filtering'
ufw --force enable
ufw status verbose
ok "Host hardened: inbound allowed only on tailscale0"

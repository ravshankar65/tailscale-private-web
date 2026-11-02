#!/usr/bin/env bash
# Mint a single-use, pre-authorized, tagged auth key via the Tailscale API.
#
# Usage:  ./scripts/mint-authkey.sh tag:web  [expiry-seconds, default 3600]
# Prints only the key, so you can do:
#   echo "TS_AUTHKEY_WEB=$(./scripts/mint-authkey.sh tag:web)" >> .env
#
# Why these settings:
#   reusable=false     one key = one machine; a leaked key is useless once used
#   preauthorized=true no manual approval step (device approval may be on)
#   ephemeral=false    servers should persist; CI runners would use ephemeral=true
#   tags               the node is owned by the tag, not by a person, so it
#                      survives staff changes and its node key never expires
#   expiry 1h          the key only needs to live long enough to bootstrap

source "$(dirname "$0")/lib.sh"
load_env
require TS_API_KEY
need_cmd curl

tag="${1:?usage: $0 tag:<name> [expiry-seconds]}"
[[ "$tag" == tag:* ]] || die "argument must look like tag:<name>"
expiry="${2:-3600}"

body=$(cat <<JSON
{
  "capabilities": {
    "devices": {
      "create": {
        "reusable": false,
        "ephemeral": false,
        "preauthorized": true,
        "tags": ["$tag"]
      }
    }
  },
  "expirySeconds": $expiry,
  "description": "demo ${tag#tag:}"
}
JSON
)

resp="$(curl -sS -u "${TS_API_KEY}:" -X POST "$API/tailnet/-/keys" \
          -H 'Content-Type: application/json' -d "$body")"

key="$(printf '%s' "$resp" | grep -o '"key": *"[^"]*"' | sed 's/.*"\(tskey-[^"]*\)"/\1/' || true)"
[[ "$key" == tskey-* ]] || { echo "$resp" >&2; die "could not mint key (is $tag in tagOwners? apply the policy first)"; }
printf '%s\n' "$key"

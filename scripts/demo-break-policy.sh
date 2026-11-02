#!/usr/bin/env bash
# DEMO ONLY. Shows the policy's "tests" block doing its job.
#
# Makes a temporary copy of the policy with one forbidden grant added
# (tag:web -> tag:server tcp:22, i.e. "let the web tier SSH to the server"),
# then asks the Tailscale API to VALIDATE it. Nothing is ever applied.
# Expected result: validation fails because the test
#   { "src": "tag:web", "deny": ["tag:server:22", ...] }
# no longer holds.
#
# Usage: make demo-break   (or: bash scripts/demo-break-policy.sh)

source "$(dirname "$0")/lib.sh"

tmp="$REPO_ROOT/policy/demo-broken.template.hujson"   # git-ignored via policy/*.rendered? no: removed on exit
trap 'rm -f "$tmp"' EXIT

awk '{ print }
     /"grants": \[/ && !done {
       print "\t\t// DEMO: the change someone might try to make";
       print "\t\t{ \"src\": [\"tag:web\"], \"dst\": [\"tag:server\"], \"ip\": [\"tcp:22\"] },";
       done = 1
     }' "$REPO_ROOT/policy/policy.template.hujson" > "$tmp"

info "Proposed change: let tag:web reach tag:server on tcp:22"
grep -n 'DEMO' -A1 "$tmp" | sed 's/^/    /'
echo

if POLICY_TEMPLATE="$tmp" bash "$REPO_ROOT/scripts/apply-policy.sh" --dry-run; then
  die "the broken policy was ACCEPTED; the tests did not catch it"
else
  echo
  ok "Rejected by the policy's own tests. Nothing was applied."
fi

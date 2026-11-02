#!/usr/bin/env bash
# Render policy/policy.template.hujson with values from .env, validate it against
# the Tailscale API (including the "tests" and "sshTests" blocks), back up the
# current tailnet policy, then apply.
#
# Usage:
#   ./scripts/apply-policy.sh            # render + validate + apply
#   ./scripts/apply-policy.sh --dry-run  # render + validate only
#
# Runs on: your Mac (or anywhere with curl and the API key). Not on the server.

source "$(dirname "$0")/lib.sh"
load_env
require ADMIN_EMAIL LINUX_USER TS_API_KEY
need_cmd curl

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

TEMPLATE="$REPO_ROOT/policy/policy.template.hujson"
RENDERED="$REPO_ROOT/policy/policy.rendered.hujson"   # git-ignored
BACKUP_DIR="$REPO_ROOT/policy/backups"                # git-ignored
mkdir -p "$BACKUP_DIR"

# "a@x.com, b@y.com" -> "a@x.com", "b@y.com"   (empty -> nothing)
contractors=""
if [[ -n "${CONTRACTOR_EMAILS:-}" ]]; then
  IFS=',' read -r -a arr <<<"$CONTRACTOR_EMAILS"
  for e in "${arr[@]}"; do
    e="$(echo "$e" | tr -d '[:space:]')"
    [[ -n "$e" ]] && contractors+="\"$e\", "
  done
  contractors="${contractors%, }"
fi

info "Rendering policy -> ${RENDERED#"$REPO_ROOT"/}"
sed -e "s|__ADMIN_EMAIL__|${ADMIN_EMAIL}|g" \
    -e "s|__LINUX_USER__|${LINUX_USER}|g" \
    -e "s|__CONTRACTOR_EMAILS__|${contractors}|g" \
    "$TEMPLATE" > "$RENDERED"

body="$(grep -v '^[[:space:]]*//' "$RENDERED")"
grep -qE '__(ADMIN_EMAIL|LINUX_USER|CONTRACTOR_EMAILS)__' <<<"$body" && die "unrendered placeholder left in $RENDERED"

auth=(-u "${TS_API_KEY}:")

info "Validating against the Tailscale API (syntax + tests + sshTests)"
resp="$(curl -sS "${auth[@]}" -X POST "$API/tailnet/-/acl/validate" \
          -H 'Content-Type: application/hujson' --data-binary @"$RENDERED")"
# A clean validation returns an empty JSON object; errors include "message".
if [[ "$resp" == *'"message"'* ]]; then
  echo "$resp"
  die "policy validation failed"
fi
ok "policy is valid and all tests pass"

if (( DRY_RUN )); then
  info "Dry run: not applying."
  exit 0
fi

ts="$(date +%Y%m%d-%H%M%S)"
info "Backing up current policy -> policy/backups/policy-$ts.hujson"
curl -sS --fail "${auth[@]}" -H 'Accept: application/hujson' \
     "$API/tailnet/-/acl" > "$BACKUP_DIR/policy-$ts.hujson"

info "Applying policy"
resp="$(curl -sS "${auth[@]}" -X POST "$API/tailnet/-/acl" \
          -H 'Content-Type: application/hujson' --data-binary @"$RENDERED" \
          -w '\n%{http_code}')"
code="${resp##*$'\n'}"
[[ "$code" == "200" ]] || { echo "${resp%$'\n'*}"; die "apply failed (HTTP $code)"; }
ok "policy applied (previous version saved in policy/backups/)"

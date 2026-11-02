#!/usr/bin/env bash
# End-to-end validation, run from a CLIENT on the tailnet (your Mac).
# Proves what SHOULD work works, and what SHOULD NOT work is blocked.
# Writes a timestamped evidence file to evidence/.
#
# Usage:
#   ./scripts/validate.sh             # full run (SSH step opens a browser re-auth)
#   SKIP_SSH=1 ./scripts/validate.sh  # non-interactive (skips the SSH login itself)

source "$(dirname "$0")/lib.sh"
set +e   # we count failures ourselves
load_env
require ADMIN_EMAIL TAILNET_DNS LINUX_USER HOST_LAN_IP
need_cmd curl; need_cmd nc; need_cmd ssh

TS="$(ts_cli)"
HOST_TS_NAME="${HOST_TS_NAME:-homelab}"
WEB="web.${TAILNET_DNS}"
HOST="${HOST_TS_NAME}.${TAILNET_DNS}"

mkdir -p "$REPO_ROOT/evidence"
stamp="$(date +%Y%m%d-%H%M%S)"
EVIDENCE="$REPO_ROOT/evidence/validation-$stamp.md"

pass=0; fail=0
result() {  # result <PASS|FAIL> <description>
  if [[ "$1" == PASS ]]; then pass=$((pass+1)); ok "$2"; else fail=$((fail+1)); printf '%sFAIL%s %s\n' "$c_red" "$c_off" "$2"; fi
  printf -- '- **%s** %s\n' "$1" "$2" >> "$EVIDENCE.summary"
}
section() { printf '\n%s## %s%s\n' "$c_dim" "$1" "$c_off"; printf '\n## %s\n\n```text\n' "$1" >> "$EVIDENCE.body"; }
endsec()  { printf '```\n' >> "$EVIDENCE.body"; }
log()     { tee -a "$EVIDENCE.body"; }

tcp_open() {  # tcp_open host port -> 0 if a TCP connection succeeds within 3s
  if [[ "$(uname)" == Darwin ]]; then nc -z -G 3 -w 3 "$1" "$2" >/dev/null 2>&1
  else nc -z -w 3 "$1" "$2" >/dev/null 2>&1; fi
}

: > "$EVIDENCE.summary"; : > "$EVIDENCE.body"

# ---------------------------------------------------------------------------
section "1. Tailnet membership"
# Capture once, then grep the variable. (Piping straight into `grep -q` under
# `set -o pipefail` fails spuriously: grep exits on the first match, the writer
# gets SIGPIPE, and the pipeline reports failure.)
ts_status="$("$TS" status 2>&1)"
echo "$ts_status" | log
grep -qE "[[:space:]]web[[:space:]]" <<<"$ts_status"            && result PASS "node 'web' is in the tailnet"            || result FAIL "node 'web' not found in tailscale status"
grep -qE "[[:space:]]${HOST_TS_NAME}[[:space:]]" <<<"$ts_status" && result PASS "node '${HOST_TS_NAME}' is in the tailnet" || result FAIL "node '${HOST_TS_NAME}' not found"
endsec

# ---------------------------------------------------------------------------
section "2. Path: direct WireGuard or DERP relay"
for n in web "$HOST_TS_NAME"; do
  out="$("$TS" ping -c 3 "$n" 2>&1)"; echo "$out" | log
  if echo "$out" | grep -q "pong"; then
    if echo "$out" | grep -q "via DERP"; then result PASS "$n reachable (via DERP relay)"
    else result PASS "$n reachable (direct peer-to-peer)"; fi
  else result FAIL "$n did not answer tailscale ping"; fi
done
endsec

# ---------------------------------------------------------------------------
section "3. MagicDNS"
if command -v dig >/dev/null; then
  for n in "$WEB" "$HOST"; do
    ip="$(dig +short @100.100.100.100 "$n" A | head -1)"
    echo "$n -> ${ip:-<none>}" | log
    [[ "$ip" == 100.* ]] && result PASS "MagicDNS resolves $n to a tailnet IP ($ip)" || result FAIL "MagicDNS did not resolve $n"
  done
else echo "dig not available; skipped" | log; fi
endsec

# ---------------------------------------------------------------------------
section "4. Private web service over HTTPS (Tailscale Serve)"
cert="$(openssl s_client -connect "$WEB:443" -servername "$WEB" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -enddate 2>/dev/null)"
echo "$cert" | log
[[ -n "$cert" ]] && result PASS "valid TLS certificate presented for $WEB" || result FAIL "no TLS certificate from $WEB"

code="$(curl -sS -o "$REPO_ROOT/evidence/cafe-$stamp.html" -w '%{http_code}' --max-time 10 "https://$WEB/" 2>&1)"
title="$(grep -o '<title>[^<]*' "$REPO_ROOT/evidence/cafe-$stamp.html" 2>/dev/null | head -1 | sed 's/<title>//')"
echo "GET / -> HTTP $code, title: ${title:-<none>} (saved evidence/cafe-$stamp.html)" | log
[[ "$code" == 200 ]] && result PASS "cafe site served at https://$WEB/ (HTTP 200)" || result FAIL "cafe site returned HTTP $code"

health="$(curl -sS --max-time 10 "https://$WEB/healthz" 2>&1)"; echo "GET /healthz -> $health" | log
[[ "$health" == ok* ]] && result PASS "GET https://$WEB/healthz returns ok (cert verified by curl)" || result FAIL "/healthz failed: $health"

who="$(curl -sS --max-time 10 "https://$WEB/whoami" 2>&1)"; echo "$who" | log
echo "$who" | grep -q "\"login\": \"$ADMIN_EMAIL\"" \
  && result PASS "app sees caller identity = $ADMIN_EMAIL (injected by Serve, no app auth code)" \
  || result FAIL "identity header missing or wrong"
endsec

# ---------------------------------------------------------------------------
section "5. Nothing exposed on the LAN (negative tests)"
for p in ${LAN_CHECK_PORTS:-80 443 8080}; do
  if tcp_open "$HOST_LAN_IP" "$p"; then echo "LAN $HOST_LAN_IP:$p OPEN" | log; result FAIL "LAN port $p on $HOST_LAN_IP is open"
  else echo "LAN $HOST_LAN_IP:$p closed/filtered" | log; result PASS "LAN port $p on $HOST_LAN_IP is closed"; fi
done
if tcp_open "$HOST_LAN_IP" 22; then
  echo "LAN $HOST_LAN_IP:22 OPEN (OpenSSH on LAN; run scripts/harden-host.sh to close)" | log
  printf -- '- **INFO** LAN port 22 is open (OpenSSH). Optional: scripts/harden-host.sh\n' >> "$EVIDENCE.summary"
else
  echo "LAN $HOST_LAN_IP:22 closed/filtered" | log; result PASS "LAN SSH port is closed: admin access is tailnet-only"
fi
endsec

# ---------------------------------------------------------------------------
section "6. Least privilege inside the tailnet (negative tests)"
for t in "$WEB:80" "$WEB:8080" "$WEB:22"; do
  h="${t%:*}"; p="${t##*:}"
  if tcp_open "$h" "$p"; then echo "$t OPEN" | log; result FAIL "$t should be blocked by policy"
  else echo "$t blocked" | log; result PASS "$t blocked by policy (only 443 is granted on tag:web)"; fi
done
tcp_open "$HOST" 22 && result PASS "$HOST:22 reachable (granted to group:eng)" || result FAIL "$HOST:22 not reachable"
endsec

# ---------------------------------------------------------------------------
section "7. Tailscale SSH"
out="$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$HOST" true 2>&1)"; rc=$?
echo "ssh root@$HOST -> rc=$rc $out" | log
(( rc != 0 )) && result PASS "SSH as root is denied by policy" || result FAIL "SSH as root was allowed"

if [[ "${SKIP_SSH:-0}" == 1 ]]; then
  echo "SKIP_SSH=1: interactive login skipped" | log
else
  info "SSH as $LINUX_USER: check mode may print a URL; open it to re-authenticate."
  out="$(ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new "$LINUX_USER@$HOST" \
          'echo "host=$(hostname) user=$(id -un) keys_in_authorized_keys=$(wc -l < ~/.ssh/authorized_keys 2>/dev/null || echo 0)"' 2>&1)"; rc=$?
  echo "$out" | log
  (( rc == 0 )) && result PASS "SSH as $LINUX_USER succeeded via Tailscale SSH (no SSH keys distributed)" \
                || result FAIL "SSH as $LINUX_USER failed"
fi
endsec

# ---------------------------------------------------------------------------
{
  echo "# Validation evidence: $stamp"
  echo
  echo "Client: $(hostname) ($(uname -sr)), tailscale $("$TS" version | head -1)"
  echo "Targets: https://$WEB , ssh $LINUX_USER@$HOST"
  echo
  echo "**Result: $pass passed, $fail failed**"
  echo
  cat "$EVIDENCE.summary"
  cat "$EVIDENCE.body"
} > "$EVIDENCE"
rm -f "$EVIDENCE.summary" "$EVIDENCE.body"

echo
info "Evidence written to ${EVIDENCE#"$REPO_ROOT"/}"
(( fail == 0 )) && ok "$pass checks passed" || die "$fail check(s) failed, $pass passed"

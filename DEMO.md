# Live demo run-of-show (about 7 minutes)

Everything below runs from the **Mac**, in the repo root (`tailscale-private-web`).
Tailnet: `hippo-shiner.ts.net`. Tell the audience what to watch for *before* each step.

## Before the interview (T minus 30 minutes)

- [ ] Ubuntu box awake, `make status` shows all three containers up and `ts-web` healthy
- [ ] Mac Tailscale connected: `ts status` shows `homelab` and `web`
- [ ] `make validate-quick` passes (23/23) and the `/me` page loads
- [ ] Do one `ssh rshankar@homelab.hippo-shiner.ts.net` so you know the re-auth flow works today
- [ ] Rehearse `make demo-break` once (it only validates, never applies)
- [ ] Browser tabs ready: `https://web.hippo-shiner.ts.net/`, `/me`, admin console Machines page
- [ ] Terminal font enlarged; screen recording of a clean run saved as a fallback
- [ ] Notifications off

Shell alias for the session:

```bash
alias ts=/Applications/Tailscale.app/Contents/MacOS/Tailscale
```

## 1. Open the site (1 min)

*"This is a real site from my home lab. Notice the lock and the name."*

- Browser: `https://web.hippo-shiner.ts.net/`: cafe site, valid certificate (click the lock and show Let's Encrypt).
- Browser: `https://web.hippo-shiner.ts.net/me`: "Hello, R Shankar".

*"The app has no login code. Tailscale Serve told it who I am."*

## 2. Disconnect, and it's gone (1 min)

*"Now, is this reachable without Tailscale? Including from my own LAN?"*

```bash
ts down
curl -m 5 https://web.hippo-shiner.ts.net/      # fails: name doesn't even resolve
nc -zv -G 3 192.168.86.105 8082                 # old LAN port: closed
nc -zv -G 3 192.168.86.105 443                  # closed
ts up
```

## 3. SSH with re-auth, and root refused (2 min)

*"No SSH keys exist for this. Watch for the Google prompt."*

```bash
ssh rshankar@homelab.hippo-shiner.ts.net        # check mode: open the URL, sign in, get a shell
```

Inside the session, which is also step 4:

## 4. The invisible server (30 sec)

*"From inside the web container, can it see the server it runs on?"*

```bash
docker exec ts-web tailscale status             # lists web + the Mac only; homelab is absent
exit
```

Then show root being refused:

```bash
ssh root@homelab.hippo-shiner.ts.net            # "tailnet policy does not permit you to SSH as user root"
```

## 5. Try to break the policy (1.5 min)

*"Someone wants to let the web tier SSH into the server. Watch what happens."*

```bash
make demo-break
```

Expected: the proposed grant is shown, the API validation fails on the `tag:web` deny test,
and the script prints "Rejected by the policy's own tests. Nothing was applied."

## 6. Run the proof (1 min)

```bash
make validate-quick
```

23 checks, then open the newest `evidence/validation-*.md`.

## If something fails live

Narrate it as troubleshooting, which is an SE skill too:

```bash
ts status                         # is the peer online?
ts ping web                       # direct or DERP?
ts netcheck                       # UDP, NAT type, nearest DERP
# on the Ubuntu box:
make status                       # containers healthy? serve config present?
make logs                         # caller identities in the helper's log
```

Fallback: play the screen recording and walk through the committed evidence files.

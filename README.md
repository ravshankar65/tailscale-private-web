# Private staging with zero open ports

A private web service and SSH access to a home-lab Linux server, both reachable
**only** over a Tailscale tailnet, with identity-based access control expressed
as code and verified by automated tests.

* **Tailnet:** `hippo-shiner.ts.net`
* **Nodes:** an engineer's MacBook (client), `homelab` (Ubuntu host, `tag:server`), `web` (containerized app, `tag:web`)
* **Tailscale features used:** grants, tags, policy `tests`/`sshTests`, MagicDNS, HTTPS certificates, Serve (with identity headers), Tailscale SSH in `check` mode, tagged pre-auth keys, API

---

## 1. Overview: what I built

The Ubuntu workstation in my home (running on an old MacBook Pro) acts as a "private
server". It runs:

1. **An existing website ("cafe", Apache httpd in Docker)**, moved from a
   LAN-published port (and previously a Cloudflare Tunnel) to **tailnet-only** access.
   The site image is unchanged. A Tailscale sidecar container joins the tailnet as its
   own node, gets a real HTTPS certificate for `web.<tailnet>.ts.net`, and fronts the
   site with **Tailscale Serve**. A tiny helper behind the same Serve config (`/me`,
   `/whoami`) greets you by name using the identity headers Serve injects. It has
   no login code at all.
2. **Tailscale SSH** on the host. Engineers SSH in with their Google identity, must
   re-authenticate (`check` mode), may only log in as a named non-root user, and
   no SSH keys are ever distributed.

Docker publishes **no ports**, the identity helper binds to `127.0.0.1`, httpd's
port 80 is closed on the tailnet by policy (only 443 is granted), and (optionally) the
host's LAN firewall drops all inbound traffic. Everything still works, because
Tailscale connections are outbound-initiated and NAT-traversing.

## 2. Why this use case

This is the most common first conversation with a customer: *"we have internal
services and servers, and today we reach them through a VPN concentrator or a
bastion host with port forwarding and shared SSH keys."*

The fictional customer is **NorthLoop**, a 20-person fintech:

| Persona | Needs | Pain today |
|---|---|---|
| Engineer | Internal web app + SSH to servers | Bastion host to patch, SSH keys copied to laptops, VPN gives the whole subnet |
| Contractor | Internal web app only | Gets the same VPN as employees; offboarding means rotating shared keys |
| Security / audit | Prove who can reach what | Access rules spread across firewall, VPN, bastion, and `authorized_keys` |

**Business value:** no inbound attack surface, no bastion or VPN appliance to run,
onboarding and offboarding in the identity provider, and access rules that are
reviewable, testable code.

## 3. Architecture

See **[docs/architecture.md](docs/architecture.md)** for diagrams and step-by-step traffic flows.

```
  MacBook (you, group:eng)                     Home LAN: Ubuntu host
  ┌──────────────────────┐   WireGuard   ┌───────────────────────────────────────┐
  │ tailscale client      │◀────────────▶│ tailscaled  node=homelab  tag:server  │
  │ browser / curl / ssh  │  (direct or   │   └ Tailscale SSH :22 (tailnet only)  │
  └──────────────────────┘   DERP relay)  │ Docker (no published ports)           │
            ▲                    ┌───────▶│   ts-web  node=web  tag:web           │
            │                    │        │     └ Serve :443 (TLS) ─▶ cafe httpd :80 ; /me,/whoami ─▶ 127.0.0.1:8080
            └────────────────────┘        └───────────────────────────────────────┘
       Control plane (login.tailscale.com): keys, policy, DNS. Never carries user traffic.
```

### Access policy ([policy/policy.template.hujson](policy/policy.template.hujson))

| Source | Destination | Allowed | Notes |
|---|---|---|---|
| `group:eng` | `tag:web` | `tcp:443`, ICMP | Web app over HTTPS only |
| `group:eng` | `tag:server` | `tcp:22`, ICMP + SSH rule | `check` mode, Linux user `LINUX_USER` only, root denied |
| `group:contractors` | `tag:web` | `tcp:443` | No SSH, no ping |
| `tag:ci` | `tag:web` | `tcp:443` | Reserved for CI smoke tests |
| `tag:web` | anything | nothing | A compromised container cannot move laterally |
| `autogroup:member` | `autogroup:self` | all | Keeps your personal devices working |

The policy's `tests` and `sshTests` blocks assert these rules. **Tailscale rejects any
future policy edit that would break them**, so they act as access regression tests.

## 4. Prerequisites and assumptions

* A Tailscale account (free Personal plan is enough). You are an Admin/Owner of the tailnet.
* In the admin console: **DNS -> MagicDNS enabled** and **HTTPS Certificates enabled**.
* An **API access token** (Settings -> Keys), used only from the Mac by the scripts.
* **Client:** macOS with the Tailscale app, plus `curl`, `nc`, `ssh`, `openssl`, `dig` (all built in).
* **Server:** Ubuntu 22.04/24.04 with Docker Engine + the Compose plugin, `make`, `curl`, and `sudo`.
* Assumption: the server has outbound internet access. No inbound ports or router port-forwards are needed.

> **Warning:** applying this policy replaces your tailnet's default allow-all policy.
> The script backs up the current policy first, and the `autogroup:self` grant keeps
> your own devices talking to each other. Review it if other users or shared devices
> are on your tailnet.

## 5. Setup and deployment

```bash
# --- On the Mac -------------------------------------------------------------
git clone <this repo> && cd tailscale-private-web
cp .env.example .env              # fill in ADMIN_EMAIL, TAILNET_DNS, LINUX_USER, HOST_LAN_IP, TS_API_KEY

make policy-check                 # render + validate policy and run its tests (no changes)
make policy                       # back up the current policy, then apply
make keys >> .env                 # mint single-use, pre-authorized, tagged auth keys (1h expiry)
#   (appended lines override the REPLACE_ME placeholders; tidy .env afterwards if you like)

# Copy the repo, including .env, to the server (git clone + scp .env, or rsync):
rsync -av --exclude policy/backups ./ <you>@<server-lan-ip>:~/tailscale-private-web/

# --- On the Ubuntu host -----------------------------------------------------
cd ~/tailscale-private-web
make host                         # install Tailscale, join as tag:server, enable Tailscale SSH
make up                           # build + start the web app and its Tailscale sidecar

# Optional, after confirming `ssh <LINUX_USER>@homelab` works from the Mac:
sudo ./scripts/harden-host.sh     # drop ALL inbound LAN traffic; tailnet only
```

Teardown: `make down` (keeps node identity) or `make clean` (removes it), and
remove the machines in the admin console. Restore the old policy from `policy/backups/`.

## 6. Validation

```bash
make validate          # on the Mac; the SSH step opens a browser for re-auth
make validate-quick    # same checks, minus the interactive SSH login
```

[scripts/validate.sh](scripts/validate.sh) checks both what should work and what should not,
and writes a timestamped report to `evidence/`:

| # | Check | Expected |
|---|---|---|
| 1 | `tailscale status` | `web` and `homelab` online |
| 2 | `tailscale ping` | pong; reports direct vs DERP path |
| 3 | MagicDNS (`dig @100.100.100.100`) | names resolve to `100.x` tailnet IPs |
| 4 | TLS cert, `GET /` (cafe site), `/healthz`, `/whoami` | valid cert; site returns 200; helper reports caller = your login |
| 5 | LAN ports in `LAN_CHECK_PORTS` on the host | **closed** (nothing exposed) |
| 6 | `web:80`, `web:8080`, `web:22` over the tailnet | **blocked** by policy; `homelab:22` allowed |
| 7 | `ssh root@homelab` / `ssh <user>@homelab` | **denied** / succeeds after re-auth, with no keys |
| - | `make policy-check` / `make demo-break` | policy tests pass; a deliberately forbidden grant is rejected (never applied) |

Additional evidence lives in [evidence/](evidence/): timestamped validation reports and the
page each run fetched. App logs (`make logs`) show each request's caller identity.
The live-demo script, with exact commands, is in [DEMO.md](DEMO.md).

## 7. What worked well

* **A real workload moved without changes.** The cafe site is an Apache httpd image I
  built and ran at home long before this exercise. It runs as-is; only the network
  around it changed. Putting it in the sidecar's network namespace
  (`network_mode: service:ts-web`) needed no change to the image.
* **Identity with no auth code.** Tailscale Serve injected `Tailscale-User-Login` and
  `Tailscale-User-Name`, and `/whoami` returned my Google login and name on the first
  request. Per-user identity in an internal app usually means an SSO integration;
  here it was configuration.
* **HTTPS was automatic.** Serve obtained a Let's Encrypt certificate for
  `web.hippo-shiner.ts.net` in under a minute on first start. There was no certificate
  to manage and no public DNS record.
* **Least privilege you can see.** Because each node only receives the peers its policy
  allows, `tailscale status` inside the `web` container lists my Mac but not `homelab`
  at all. The lateral-movement rule is visible on a live system, not just asserted.
* **Policy as tested code.** The `tests`/`sshTests` blocks plus the API's validate
  endpoint meant I could check a change before applying it, and the script backs up
  the live policy before every apply.
* **Validation that proves the negative.** 12 of the 23 checks assert that something
  is blocked: every port the box used to publish on the LAN, non-443 ports on the
  tailnet, and SSH as root. Evidence files are committed with timestamps.
* **Zero network configuration.** No router port-forwards, no firewall rules, no
  inbound ports. NAT traversal sorted out the paths on its own (see section 8).

## 8. What was difficult or surprising

* **The host was not a clean slate.** The Ubuntu box was already running a Cloudflare
  Tunnel (cloudflared), n8n, Portainer and two websites, four of them published on
  `0.0.0.0`. I had to inventory and stop them first. The LAN-port list in the
  validation (`LAN_CHECK_PORTS`) covers every port the box used to expose, so the test
  reflects the real "before" state.
* **Docker-published ports bypass UFW.** Docker inserts its own iptables rules ahead of
  UFW's, so a host firewall alone would not have closed those ports. The design avoids
  the problem by publishing no ports at all; `harden-host.sh` only covers the host itself.
* **Same box, different paths.** On the first run the Mac reached `homelab` directly
  (19 ms) but reached `web` through the DERP relay in New York (37 ms), because `web`
  sits behind Docker's bridge NAT. Three minutes later, `web` had upgraded to a direct
  path through the host's NAT-mapped port (`192.168.86.105:35646`, 6 ms) with no change
  from me. Lesson: don't judge the path from the first ping.
* **Peers are hidden, not just blocked.** I expected `homelab` to show as unreachable
  from inside `web`. Instead it was absent from `web`'s network map.
* **Order of operations matters.** Tags must exist in `tagOwners` before tagged auth keys
  can be minted, so the sequence is policy → keys → host → containers. The keys are
  single-use and expire in an hour, so steps 7–9 of the setup have to be done in one sitting.
* **Small operational gotchas.** My Mac's Tailscale client had been disconnected for
  94 days and showed as offline until I reconnected it. On macOS the `tailscale` CLI
  lives inside the app bundle rather than on `PATH`, so `validate.sh` looks for it there.
* **Three script bugs surfaced on the first real run.** These were in AI-drafted code;
  details are in section 10.
* **A known defense-in-depth gap.** httpd listens on port 80 inside the sidecar's network
  namespace, so port 80 exists on `web`'s tailnet IP. Policy blocks it, and both a policy
  test and a validation check assert that, but binding httpd to loopback would remove it
  entirely (section 9).

## 9. What I would do with more time

* **CI over Tailscale:** a GitHub Actions workflow that joins as an ephemeral `tag:ci`
  node using workload identity federation (OIDC, so no stored secret) and smoke-tests
  the site. The policy already has the `tag:ci` grant.
* **GitOps for policy:** run policy validation on every pull request and apply on merge.
* **Terraform** (`tailscale/tailscale` provider) for policy, DNS settings and keys instead
  of shell scripts.
* **Close the remaining gaps on the host:** bind httpd to `127.0.0.1` inside the sidecar,
  and close LAN SSH (OpenSSH, used once to copy `.env`) with `scripts/harden-host.sh`.
  [Update this line if you have already run harden-host.sh.]
* **A second human user** (contractor) to demonstrate site-only access live.
* **Kubernetes:** run the site with the Tailscale Kubernetes operator instead of a sidecar.
* Tailnet Lock, SSH session recording, and log streaming on a paid plan.

## 10. AI assistance

**What I used AI for.** I used Claude (Anthropic), with access to my project folder, to:

* read the assignment and propose a plan and use case;
* draft the policy file, Compose file, Serve config, identity helper, shell scripts,
  Makefile, README and architecture docs;
* walk me through the GitHub setup and interpret command output while I deployed;
* draft the presentation deck and the demo run-of-show.

**What I decided, ran and reviewed myself.**

* Scope and design choices: using my existing Ubuntu workstation instead of containers
  on my laptop, exposing my real cafe site instead of a purpose-built demo app, and
  keeping Cloudflare out of the core build.
* Every step ran on my own hardware and tailnet: stopping the existing services, applying
  the policy, minting keys, deploying, and running validation.
* I reviewed the policy grants, tests and SSH rules line by line, and checked each
  result against real output (`tailscale status`, `tailscale serve status`, validation runs).
* [Add anything you changed or rewrote by hand.]

**Where it helped.** Fast scaffolding, checking current Tailscale syntax (grants, Serve
config, workload identity federation) against the docs, and explaining what I was seeing,
such as relay vs direct paths and why `web` could not see `homelab`.

**Where it was wrong, incomplete or misleading.** All of these were caught by actually
running the code:

1. **Over-broad placeholder check.** `apply-policy.sh` refused to run because its
   "unrendered placeholder" check matched the word `__PLACEHOLDERS__` in a comment.
2. **Lost executable bit.** An AI-side edit rewrote `apply-policy.sh` without its
   executable permission, causing `Permission denied`. The Makefile now invokes every
   script with `bash`, so file modes can't break it.
3. **`pipefail` + `grep -q` false negative.** `validate.sh` reported `homelab` missing
   while printing it on screen. `grep -q` exits on the first match, the writer gets
   SIGPIPE, and `pipefail` turns that into a failure. The same pattern in
   `apply-policy.sh` could have hidden a real error. Both now grep a captured variable.
4. **A premature explanation.** When `web` first went through DERP, the AI attributed it
   to my router lacking hairpin NAT. A few minutes later the path upgraded to direct, so
   the better explanation is that paths start relayed while NAT-traversal probes complete.
5. **An unverified assumption, hedged in code.** It was unsure whether Serve strips the
   mount path before proxying, so the helper app routes on the last path segment and
   works either way. I treated that as a hedge, not a verified fact.
6. **Scope creep.** The first plan included CI, a contractor user and a subnet router on
   laptop Docker. I trimmed it to a smaller build I could fully run and explain.

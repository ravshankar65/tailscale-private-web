# Private staging with zero open ports

A private web service and SSH access to a home-lab Linux server, both reachable
**only** over a Tailscale tailnet, with identity-based access control expressed
as code and verified by automated tests.

* **Tailnet:** `__TAILNET_DNS__` <!-- fill in before submitting -->
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
| - | `make policy-check` | policy tests pass; a breaking edit is rejected |

Additional evidence lives in [evidence/](evidence/): validation reports, admin-console
screenshots, and app logs (`make logs`) that show each request's caller identity.

## 7. What worked well

*To fill in from the actual build.*

## 8. What was difficult or surprising

*To fill in from the actual build. Candidates to watch for: Serve does not send
identity headers for tagged sources; tags must be in `tagOwners` before keys can be
minted for them; Docker-published ports bypass UFW (avoided here by publishing none).*

## 9. What I would do with more time

* **CI over Tailscale:** a GitHub Actions workflow that joins as an ephemeral `tag:ci`
  node using workload identity federation (OIDC, so no stored secret) and smoke-tests the app.
* **GitOps for policy:** run policy validation on every pull request and apply on merge.
* **Terraform** (`tailscale/tailscale` provider) for policy, DNS settings and keys instead of scripts.
* A second human user (contractor) to demo least privilege live.
* Run the app on Kubernetes with the Tailscale operator instead of a sidecar.
* Tailnet Lock, SSH session recording, and log streaming on a paid plan.

## 10. AI assistance

*Draft; update honestly before submitting.* I used Claude (Anthropic) to brainstorm
the use case, scaffold the scripts, compose file and policy, and draft this README.
I reviewed every file, ran everything on my own hardware, and changed: *(list)*.
Where the AI was wrong, incomplete, or misleading: *(list, e.g. any syntax that needed
fixing against Tailscale docs)*.

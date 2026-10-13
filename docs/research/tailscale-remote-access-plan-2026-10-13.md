# Plan — reach `mob04` from anywhere without the faculty VPN (Tailscale)

**Status:** plan only, nothing installed (2026-10-13). Owner asked: "access from anywhere, no VPN, which provider is free?"
→ owner chose Tailscale. Steps marked 👤 need the owner (accounts, approvals); everything else an agent can run.

## 1. Goal and shape

Phones and the shop PC reach the POS at the **same address as today, `https://172.30.58.20`**, from 4G / home Wi-Fi,
without the faculty VPN client. `mob04` joins a private Tailscale network ("tailnet") as a **subnet router that advertises
only its own address `172.30.58.20/32`**; every client runs the Tailscale app.

Why this shape (and not the node's `100.x` address or MagicDNS name):

- **No app or server change.** The APK has `API_BASE_URL=https://172.30.58.20` baked in and trusts our private CA, whose
  leaf certificate's SAN is `172.30.58.20` (`server/docker/certgen/certgen.sh`). A different address would need a new APK, a
  new SAN and a new `CORS_ORIGINS` value. The `/32` route keeps all three.
- **Not a public website.** Only devices logged in to the tailnet can reach the address; app login is still required.
- **Nginx stays the only proxy** (CLAUDE.md "Nginx / auth / rate limiting"). Tailscale is a layer-3 tunnel, not a proxy.
  Traffic to the router's *own* address is delivered locally, not forwarded, so it should arrive with each device's
  `100.x` source address and the per-IP rate limit keeps working per phone. **Verify in step 5.4** — if every request shows
  one IP, login throttling would lump all phones together.

## 2. Owner decisions before any install 👤

| # | Decision | Notes |
|---|---|---|
| D1 | **Plan / licence.** Tailscale's free **Personal** plan (up to 6 users, unlimited user devices, 50 tagged resources) is **"only suitable for non-commercial use"** (tailscale.com/pricing, read 2026-10-13). | Fine for the course demo on `mob04` (the shop still runs the Drift build). When the real shop depends on it: a paid Tailscale plan, or self-hosted (Headscale / NetBird) — decide then. |
| D2 | **Tailnet owner account.** Must be a personal Google/Microsoft/GitHub login — a tailnet created with a custom-domain (work) email is treated as business use (14-day trial instead of Personal). | Recommend one dedicated Gmail for the shop project, owned by the owner. |
| D3 | **Faculty IT permission** to run a tunnel agent on a faculty VM. | Outbound-only (no inbound port opened), but it lets non-VPN devices reach a faculty IP — ask the network team first. |
| D4 | **Who gets access.** Users = people (≤ 6 on Personal); devices per user unlimited. | Option A: one shared shop login on every shop device (1 user). Option B: each team member + the shop account. |

## 3. Pre-flight already done (read-only, 2026-10-13, as `cloud` on `mob04`)

| Check | Result |
|---|---|
| OS / arch | Ubuntu 26.04 LTS, x86_64 (`qemu64` CPU — Tailscale is a Go binary built for baseline x86-64, so the x86-64-v2 problem that broke sharp does not apply; still confirm `tailscale version` runs) |
| Control plane over 443 | `https://controlplane.tailscale.com` → 200, certificate issued by **Let's Encrypt** (not a FortiGate re-signed cert) → no TLS inspection on that path |
| IP forwarding | `net.ipv4.ip_forward = 1` already (Docker) |
| Firewall | `FORWARD` policy `DROP`, chains `DOCKER-USER` → `DOCKER-FORWARD` → `ufw-*` — UFW is active; Docker's published `443` is reached through `DOCKER-FORWARD` after DNAT |

Not yet checked: outbound UDP `41641` / `3478` (direct peer-to-peer). If blocked, Tailscale falls back to its DERP relays
over TCP 443 — works, just slower. `tailscale status` after install shows `direct` vs `relay`.

## 4. Steps

### 4.1 👤 Create the tailnet (owner, browser)
1. Sign up at login.tailscale.com with the D2 account → Personal plan.
2. Admin console → **Access controls**: replace the default policy with §6 (lock it down **before** adding `mob04`).

### 4.2 Install on `mob04` (agent, as `cloud`, sudo)
1. Install from Tailscale's **signed apt repository** for this Ubuntu release (the steps on tailscale.com/download/linux —
   add the keyring + list, `apt-get install tailscale`), not `curl | sh`. Record the version.
2. Keep forwarding explicit and owned by Tailscale (survives Docker changes):
   `echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf && sudo sysctl -p /etc/sysctl.d/99-tailscale.conf`
3. Join with no stored auth key — the command prints a login URL the owner opens once 👤:
   `sudo tailscale up --hostname=mob04-pos --advertise-routes=172.30.58.20/32 --advertise-tags=tag:pos-server`
   (no `--ssh`: SSH stays on the faculty path only).
4. 👤 Admin console → Machines → `mob04-pos`: **approve the subnet route** `172.30.58.20/32` and **disable key expiry**
   (otherwise the server drops off the tailnet after the key lifetime).
5. `tailscale status`, `tailscale netcheck` → record direct/relay and nearest DERP.

### 4.3 Clients 👤
- **Android:** Play Store → Tailscale → log in → allow the VPN profile. Subnet routes are picked up automatically on
  Android/iOS/Windows/macOS. Optional: Android Settings → VPN → Tailscale → *Always-on*.
- **Shop PC (Windows):** install the Tailscale client, log in.
- No APK rebuild, no reinstall of the POS app.

## 5. Verification (each step must pass before calling it done)

1. From a phone **on 4G with the faculty VPN off** and Tailscale on: `https://172.30.58.20/health/ready` → 200 (the
   private-CA warning in a plain browser is expected; the APK trusts the CA).
2. The POS APK logs in and syncs on 4G; one online sale succeeds.
3. Tailscale **off** on the same phone → the address is unreachable (proves it is not public).
4. **Client IP:** in nginx's access log the request shows the phone's `100.x.y.z`, and two phones show two different
   addresses. If every request shows one address (`172.30.58.20`/`127.0.0.1`), stop — the per-IP login bucket would be
   shared; fix before wider use (likely `--snat-subnet-routes=false` and/or a rule in `DOCKER-USER`).
5. A phone on the **faculty LAN with Tailscale on** still works (overlapping route to the same host).
6. `sudo ufw status verbose` unchanged except anything this plan adds; no new listening port on `mob04`
   (`ss -tlnp` before/after — Tailscale must not open an inbound port).
7. Re-run a normal CD deploy afterwards: the deploy and `/health/ready` are unaffected.

## 6. Access policy (tailnet ACL, set in step 4.1)

Principle: tailnet members may reach **only `172.30.58.20:443`**; nothing else on `mob04` (no SSH, no Grafana — they stay
on `127.0.0.1`/faculty path), and `mob04` may not initiate connections to members.

```jsonc
{
  "tagOwners": { "tag:pos-server": ["autogroup:admin"] },
  "groups":    { "group:shop": ["<owner-login>", "<shop-login>"] },   // D4
  "acls": [
    { "action": "accept", "src": ["group:shop"], "dst": ["172.30.58.20/32:443"] }
  ],
  "autoApprovers": { "routes": { "172.30.58.20/32": ["tag:pos-server"] } }
}
```

(`autoApprovers` is optional — step 4.2.4 approves the route by hand anyway. Check the policy syntax against Tailscale's
current docs when applying; this block is the intent.)

## 7. Rollback (minutes, no app impact)

`sudo tailscale down` (instant) → `sudo apt-get remove tailscale` → `sudo rm /etc/sysctl.d/99-tailscale.conf` (Docker
keeps `ip_forward=1` on its own) → remove `mob04-pos` from the admin console. The POS, APK, certificates and nginx are
untouched throughout, so the faculty-VPN path keeps working before, during and after.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Free plan is non-commercial (D1) | Demo/course use only; re-decide before the real shop relies on it. |
| Faculty IT objects / FortiGate starts inspecting `*.tailscale.com` | D3 first; the pre-flight check in §3 is repeatable. Fallback = faculty VPN (unchanged). |
| UDP blocked → DERP relay only (slower) | Acceptable for POS traffic; `tailscale status` shows it. |
| Rate limit collapses to one IP | Verification 5.4 is a hard gate. |
| Lost/stolen phone stays on the tailnet | Admin console → remove the device; app login is still required. |
| Tailscale outage | Faculty VPN path still works. |
| `mob04` key expiry | Disabled in 4.2.4. |

## 9. After it works (follow-ups, not part of this plan's first run)

- Record the setup in `docs/Backend_design/07_CICD_DEPLOY.md` and the VM tutorial; add a row to CLAUDE.md "Still open".
- Codify the package + sysctl in `provision.yml` (the login stays manual — never store an auth key in the repo or `.env`
  without the owner's decision).
- If wider access is needed without an app on each phone, revisit Cloudflare Tunnel (needs a domain, a new APK URL, public-CA
  trust, nginx real-IP handling — a rule change for the owner).

Sources: tailscale.com/pricing, tailscale.com/kb/1019/subnets, tailscale.com/kb/1082/firewall-ports (read 2026-10-13).

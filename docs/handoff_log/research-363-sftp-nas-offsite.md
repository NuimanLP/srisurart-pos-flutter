# Research — can "BeeStation + SFTP" be the #363 offsite destination? (2026-09-22)

**Scope:** the owner decided (2026-09-21/22) that the offsite destination for
`deploy/scripts/backup-db.sh`'s `offsite_upload()` (`rclone copyto`, gated by
`BACKUP_RCLONE_REMOTE`/`BACKUP_RCLONE_CONFIG` — see `ticket-363-backup-offsite.md` and
`07_CICD_DEPLOY.md §7a`) should be an on-premise Synology BeeStation/NAS at the shop, reached over
SFTP. This document checks that design against Synology's own documentation and rclone's own
documentation before anyone wires credentials. **Primary sources only** — Synology's
`kb.synology.com`/`bee.synology.com`, rclone's own `rclone.org`/GitHub docs, OpenSSH's own man
page, WireGuard's own site, and this repo's own files. Anything sourced from a forum, blog, or
review site is labelled as such explicitly and is never the basis of a factual claim on its own.

---

## Verdict — read this first

> 🔴 **"BeeStation + SFTP" as literally stated does NOT work.** BeeStation (the consumer appliance,
> running **BSM**, not DSM) has **no SFTP/SSH file-transfer service at all** — confirmed from
> Synology's own BeeStation knowledge-base articles and its full official software-specification
> page (§1 below). The only SSH surface on BeeStation is a temporary, Synology-Technical-Support-only
> diagnostic channel that auto-expires in 14 days and whose credentials are meant to be handed *to
> Synology*, not kept by the owner — it is not a general-purpose SFTP login and must not be treated
> as one.
>
> **Two ways forward, both compatible with `offsite_upload()` as it exists today (no script
> changes needed, only `rclone.conf`):**
> 1. **With caveats, keep the BeeStation hardware:** point rclone at it with the **`smb`** backend
>    instead of `sftp` — BeeStation officially supports SMB2/SMB2-large-MTU/SMB3 and rclone has a
>    native `smb` backend (§1, §"Recommended config"). This satisfies "on-prem NAS at the shop,
>    reached automatically by rclone from `backup-db.sh`" — just not literally "SFTP".
> 2. **If SFTP is a hard requirement** (e.g. for key-only auth with no password ever touching
>    `rclone.conf`), the shop needs a **DSM-based Synology** (any DS-series box), where
>    Control Panel → File Services → SFTP is a real, documented, owner-controlled service
>    (§1, `kb.synology.com` DSM SFTP article). BeeStation cannot be upgraded into this — it is a
>    different OS (BSM) with a fixed feature set.
>
> Reachability (§3) is the harder open question regardless of which of the two paths above is
> chosen: the campus FortiGate's SSL deep inspection is proven (this repo's own `CLAUDE.md`) to
> break outbound HTTPS from `mob04`, which rules out Tailscale's HTTPS-based control
> plane/DERP fallback as a *sure thing* (reasoned by analogy, not tested — see §3 and "could not
> verify"). A non-TLS option (plain WireGuard, or a reverse SSH tunnel/port-forward on a raw TCP
> port) structurally avoids that specific failure mode, but nothing in this repo documents whether
> the campus network permits non-HTTPS egress either — that needs a real test on `mob04`, the same
> way the ghcr.io breakage was discovered.

---

## 1. Does BeeStation expose SSH/SFTP? What does it actually support?

**Local access — SMB and a local web account only.** Synology's own BeeStation KB article states
BeeStation local access is either via a local web-portal account, or via SMB once "SMB Service" is
toggled on — nothing else is offered:

> "You can locally access your BeeStation files by enabling local access. If you also want to
> access via the SMB protocol, you must also enable SMB Service." — steps: *System Settings →
> Advanced Settings → Local Access* → enable a local account → optionally toggle *SMB Service*.
> ([kb.synology.com — How can I access BeeStation files locally on my computer](https://kb.synology.com/en-global/BeeStation/tutorial/BeeStation_local_access))

**The full official software-specification page confirms this is the complete list**, not an
omission. Under *System Settings → Specifications → Setup & Access* it enumerates every supported
access path:

> "Supports accessing locally using a local IP and a local account via a web browser or SMB when
> the Internet is down · Supports enabling the SMB protocol for browsing files via Windows File
> Explorer or Mac Finder · Supports 8 concurrent SMB connections … · Supports SMB2, SMB2 and
> large-MTU, SMB3"
> ([bee.synology.com — BeeStation Software Specifications](https://bee.synology.com/en-us/BeeStation/software-specs))

That same page's *System* section lists `Supported network protocols: DHCP, static IP` — i.e. only
network-configuration protocols, nothing about file-transfer protocols beyond SMB. **FTP, SFTP,
WebDAV, rsync, NFS, AFP and any public API are never mentioned anywhere on this page** — the only
place "FTP"/"NFS"/"SMB" appear together at all is under *BeeStation for desktop → Limitations*,
where they are listed as **network-drive types BeeStation-for-desktop cannot sync from**, i.e. the
opposite of a supported server protocol. Access beyond SMB/web is limited to the native apps:
BeeFiles (web + mobile), BeePhotos, BeeCamera (Plus only), and "BeeStation for desktop" — none of
which are scriptable server protocols rclone could target.

**The only SSH surface on BeeStation is a Synology-support diagnostic channel, not a general
SFTP login.** Synology's own BeeStation remote-access article says, in full:

> "**Purpose** — In certain situations, the Synology Technical Support Team may need to remotely
> access your BeeStation to troubleshoot issues. … **Resolution** — … Select *System Settings →
> Advanced Settings → Synology Technical Support*. Toggle to enable Remote Access. After enabling
> it, a window will appear displaying the following information: Account / Password / SSH port /
> Support identification key. Click Copy to copy this information. **Send the copied information
> to the Synology Technical Support Team.** … Remote access will automatically expire after 14
> days. You can also manually disable it."
> ([kb.synology.com — How do I enable remote access for BeeStation?](https://kb.synology.com/en-global/BeeStation/tutorial/BeeStation_enable_remote_access))

This is explicitly a support-troubleshooting backdoor: the credentials are meant to be sent *to
Synology*, they auto-expire in 14 days (would silently break a cron job long before anyone
noticed), and nothing in this article describes it as a filesystem-scoped SFTP subsystem the owner
can point rclone at. It should not be used for `offsite_upload()`, full stop.

**Mapping to rclone backends:**

| BeeStation-supported access | rclone backend |
|---|---|
| SMB2/SMB2-large-MTU/SMB3 | [`smb`](https://rclone.org/smb/) — "SMB is a communication protocol to share files over network," config needs only `host`/`user`/`port` (default 445)/`pass`/`domain` (default `WORKGROUP`) |
| Local web account (HTTPS portal) | no first-class rclone backend targets the BeeFiles web UI directly — not usable for this |
| BeeFiles/BeePhotos/BeeCamera/desktop apps | proprietary clients, no rclone backend |
| SFTP | **not supported by BeeStation at all** |

**The concrete DSM alternative, if SFTP is a hard requirement:** any DSM-based Synology (e.g. a
DS-series box) exposes SFTP as an ordinary, owner-controlled Control Panel service, per Synology's
own DSM documentation:

> "SFTP is a file transfer protocol built as an extension to the Secure Shell (SSH) protocol. SFTP
> only requires one TCP port number. In addition, private and public keys can be used to
> authenticate users without passwords. … To enable SFTP service: Click Enable SFTP service. Click
> Apply. … The default port number for the SFTP service is 22."
> ([kb.synology.com — SFTP | DSM](https://kb.synology.com/en-global/DSM/help/DSM/AdminCenter/file_ftp_sftp))

This is the one place key-only, no-password, owner-controlled SFTP genuinely exists in Synology's
product line — but it requires DSM hardware, not the BeeStation appliance the owner named.

---

## 2. rclone `sftp` backend — minimal unattended, key-only config

(This section applies if/when the shop gets a DSM-based NAS, or any other real SFTP server — it
does not apply to BeeStation itself, per §1.)

Source: rclone's own backend docs.
([rclone.org/sftp](https://rclone.org/sftp/), verified against the
[current `docs/content/sftp.md` in rclone/rclone](https://github.com/rclone/rclone/blob/master/docs/content/sftp.md))

**Key-only, no password, no ssh-agent:** set `key_file` and leave `pass` and `key_use_agent`
unset/false. rclone only falls back to contacting an ssh-agent when none of `pass`, `key_file`, or
`key_pem` is set.

| Option | Purpose | Default |
|---|---|---|
| `key_file` | "Path to PEM-encoded private key file. Leave blank or set key-use-agent to use ssh-agent." | unset |
| `key_use_agent` | "When set forces the usage of the ssh-agent. When key-file is also set, the '.pub' file of the specified key-file is read." | `false` |
| `known_hosts_file` | "Optional path to known_hosts file. Set this value to enable server host key validation. Set to `none` to silence the 'No host key validation' notice." | unset (validation off) |
| `set_modtime` | sets the remote's mtime after upload | `true` |
| `disable_hashcheck` | "Disable the execution of SSH commands to determine if remote file hashing is available." | `false` |
| `idle_timeout` | "Max time before closing idle connections." Also governs how long unused connections sit in rclone's pool before being dropped. | `1m0s` |
| `connections` | "Maximum number of SFTP simultaneous connections, 0 for unlimited… setting this is very likely to cause deadlocks so it should be used with care." | `0` |

**Non-interactive host-key verification — three documented ways, in order of how automatable they
are:**
1. **`known_hosts_file` pointed at a pre-populated file.** Build it non-interactively with
   OpenSSH's own `ssh-keyscan` (no login needed, just queries the host key):
   `ssh-keyscan -t dsa,rsa,ecdsa,ed25519 example.com >> known_hosts` — this is rclone's own
   documented example.
2. **`host_keys` config option** — "Pinned host keys for this remote, used to verify the server.
   Comma-separated list of 'algo base64-key' entries (the same format as the second and third
   fields of an OpenSSH known_hosts line)" — lets the pin live directly in `rclone.conf` instead of
   a separate file.
3. **`--sftp-pin-host-key` flag** — "Pin the server host key on first connection (Trust On First
   Use)," a one-time bootstrap flag that records the key into `host_keys` for you; not meant for
   routine runs, only for generating the pin once.

Any of the three avoids ever answering an interactive "are you sure you want to continue
connecting?" prompt, which would otherwise hang a cron job.

**Cron-relevant global flags** (`rclone.org/flags/`, same global flags used regardless of
backend):

| Flag | Meaning | Default |
|---|---|---|
| `--retries` | "Retry operations this many times if they fail" | `3` |
| `--low-level-retries` | "Number of low level retries to do" | `10` |
| `--contimeout` | Connect timeout | `1m0s` |
| `--timeout` | IO idle timeout | `5m0s` |
| `--retries-sleep` | Interval between retries | `0s` |

**Synology-specific quirk documented by rclone itself** (relevant only if the eventual box is a
DSM Synology, but worth carrying forward): "On some SFTP servers (e.g. Synology) the paths are
different for SSH and SFTP so the hashes can't be calculated properly. You can either use
`--sftp-path-override` or `disable_hashcheck`." Also: "some SFTP servers will need the leading /
— Synology is a good example of this."

---

## 3. Reaching a shop NAS from the campus VM (`mob04`, behind the FortiGate)

**The constraint from this repo's own `CLAUDE.md`:** the campus FortiGate performs SSL deep
inspection on `mob04`'s outbound HTTPS and answers with its own device certificate
(`O=Fortinet, OU=FortiGate, CN=FG3K4ETB19900078`) that "carries no SAN at all," so **every**
intercepted HTTPS connection fails `x509: certificate is not valid for any names` regardless of
which host it was headed to — this is proven for `ghcr.io`, and trusting the Fortinet CA does not
fix it (hostname/SAN verification fails independent of trust). This is a repo-documented finding,
not a Synology/rclone doc, and is cited here as the operative local constraint.

| Option | Mechanism | Would the proven FortiGate SSL-interception break it? | Other risk |
|---|---|---|---|
| **Reverse SSH tunnel, initiated from the shop side** (`ssh -R`) | OpenSSH's own man page: `-R [bind_address:]port:host:hostport` "Specifies that connections to the given TCP port … on the remote (server) host are to be forwarded to the local side" — a listener opens on the far end, no inbound hole needed on the near end. `GatewayPorts` must be enabled server-side to bind beyond loopback. ([man.openbsd.org/ssh](https://man.openbsd.org/ssh)) | **No** — this is the SSH wire protocol, not TLS/HTTPS; the FortiGate's proven breakage is specifically SSL/TLS-on-443 interception, a different protocol entirely. | BeeStation itself **cannot originate this** — it has no documented shell/SSH-client/cron capability (its entire feature surface per §1 is System Settings/BeeFiles/BeePhotos/BeeCamera/desktop-sync — no Package Center, no Task Scheduler). A separate always-on device at the shop would have to hold the BeeStation mount and initiate the tunnel. Campus-side egress filtering of the chosen port is unverified. |
| **Tailscale** | Control plane and DERP relay fallback both run over **HTTPS on port 443**: "Connections to the coordination server and other backend systems and data connections to the DERP relays use HTTPS on port 443." Direct path is UDP 41641 with STUN (port 3478) for NAT discovery. ([tailscale.com/docs/reference/faq/firewall-ports](https://tailscale.com/docs/reference/faq/firewall-ports)) DERP-to-device auth layers a NaCl-box construction "on top of TLS." ([tailscale.com/kb/1504/encryption](https://tailscale.com/kb/1504/encryption)) | **Plausibly yes, for the HTTPS-dependent parts** — reasoned by analogy to the documented ghcr.io failure (a SAN-less MITM cert breaks *any* intercepted HTTPS host, not just registries), but **not tested** against Tailscale specifically, and Tailscale's own docs don't discuss TLS-intercepting proxies at all. If UDP 41641/3478 pass uninspected, a direct WireGuard path might still bootstrap once the control-plane handshake succeeds some other way — but the control-plane bootstrap itself is HTTPS, so if *that* is broken, Tailscale likely can't come up at all. | Needs the shop-side device to run the Tailscale client too — same "who runs it" gap as above for BeeStation itself. |
| **Plain WireGuard** (no Tailscale relay infrastructure) | "WireGuard securely encapsulates IP packets over UDP." No TLS/HTTPS involved anywhere in the protocol. ([wireguard.com](https://www.wireguard.com/)) | **Structurally no** — there is no TLS handshake for an SSL-inspecting proxy to intercept; this is a fundamentally different protocol layer. | Needs a reachable endpoint (public IP, or an inbound port-forward) on at least one side, since vanilla WireGuard has no built-in relay/rendezvous the way Tailscale's DERP does — **unverified whether `mob04` (`172.30.58.20`, looks like an internal campus address) or the shop's ISP connection can offer that.** Campus egress filtering of arbitrary UDP is also unverified (only the HTTPS/443 case is documented as broken). |
| **DDNS + inbound port-forward at the shop**, `mob04` connects out to a raw TCP port (22/SFTP or 445/SMB) | Plain TCP, not HTTPS. | **Structurally no**, same reasoning as WireGuard — not TLS on 443. | Depends on the shop's ISP allowing inbound connections at all (residential/SME connections behind CGNAT often cannot be port-forwarded — not something any Synology or rclone doc would state; this is an ISP-contract fact, out of scope for primary-source verification here) and on `mob04`'s own egress policy for that port. |

**Bottom line for §3:** every option that avoids HTTPS-on-443 sidesteps the *specific, proven*
FortiGate failure mode in this repo. None of them is proven to actually work end-to-end on this
campus network — that requires a real connectivity test from `mob04`, the same way the ghcr.io
break was discovered, not a documentation exercise.

---

## 4. Encryption at rest — `crypt` over `sftp`/`smb`, and the local prune

**How to layer it:** `crypt` is a wrapper remote, not a storage backend — it never talks to a
disk itself. Its `remote` config option names the underlying remote and path it wraps, e.g.
`shop-nas:pos-backups/mob04`. Synology's own doc language isn't relevant here; this is rclone's:

> "A remote of type `crypt` does not access a storage system directly, but instead wraps another
> remote, which in turn accesses the storage system." The wrapped path "doesn't need to exist
> beforehand — rclone creates it as needed." Anything inside the wrapped path is encrypted; content
> outside it is untouched.
> ([rclone.org/crypt](https://rclone.org/crypt/))

**Filename modes** (`filename_encryption`):
- **`standard`** — deterministic encrypted names (same plaintext name → same ciphertext name every
  time), filenames limited to roughly 143 characters.
- **`obfuscate`** — "very simple filename obfuscation" by character rotation; rclone's own docs are
  explicit that this "cannot be relied upon for strong protection" — it deters casual scanning,
  not a determined reader.
- **`off`** — names are left readable, only a `.bin` suffix is added to file content.

**Does it affect the local age-based prune?** No — and this can be answered from `backup-db.sh`
itself, not just rclone's docs. The prune logic in the script
(`deploy/scripts/backup-db.sh:193-219`) runs `find "$BACKUP_DIR" … -name
"${POSTGRES_DB}_backup_*.sql.gz*"` against **local files already sitting in `$BACKUP_DIR` on the
VM**, matched by their local, never-encrypted names and the `.uploaded` marker also written
locally. `crypt`'s filename obfuscation/encryption is applied only when rclone writes to the
*wrapped remote* (`copy_offsite()`'s `rclone … copyto "$file" "${BACKUP_RCLONE_REMOTE%/}/…"` — the
`$file` argument is always the real local path). The local side of every `copyto` call, and
everything `find` walks for pruning, is completely outside crypt's reach: rclone's own description
above — "content outside \[the wrapped path\] is untouched" — describes the remote side of that
boundary, and the local filesystem was never inside it. **Confirmed no interaction; no change
needed to the prune logic to use crypt.**

---

## 5. Success vs. no-op — making sure `.uploaded` is only written on a real, confirmed copy

**`copyto`'s skip behavior:** "This doesn't transfer files that are identical on src and dst,
testing by size and modification time or MD5SUM." ([rclone.org/commands/rclone_copyto](https://rclone.org/commands/rclone_copyto/))
In `backup-db.sh` this is moot in practice: every dump filename embeds a UTC timestamp
(`${POSTGRES_DB}_backup_${TIMESTAMP}.sql.gz`, `TIMESTAMP="$(date -u +%Y%m%d_%H%M%SZ)"`), so the
destination path a given run's `copy_offsite()` targets can never already exist from a prior run —
a same-run retry of the identical file is the only realistic "already matches" case, and that is
still a correct file present at the destination.

**Exit codes** — the authoritative list, generated from rclone's own doc comments in
`lib/exitcode` ([pkg.go.dev/github.com/rclone/rclone/lib/exitcode](https://pkg.go.dev/github.com/rclone/rclone/lib/exitcode)):

| Code | Name | Meaning |
|---|---|---|
| 0 | `Success` | finished without error |
| 1 | `UncategorizedError` | any error not categorised otherwise |
| 2 | `UsageError` | syntax/usage error in arguments |
| 3 | `DirNotFound` | source or destination directory not found |
| 4 | `FileNotFound` | source or destination file not found |
| 5 | `RetryError` | temporary error during an operation which may be retried |
| 6 | `NoRetryError` | error from an operation which can't/shouldn't be retried |
| 7 | `FatalError` | error one or more retries won't resolve |
| 8 | `TransferExceeded` | network I/O exceeded the quota (`--max-transfer`) |
| 9 | `NoFilesTransferred` | **everything succeeded, but no transfer was made** |
| 10 | `DurationExceeded` | transfer duration exceeded the quota (`--max-duration`) |

Code 9 is only reachable at all with `--error-on-no-transfer` passed: "Sets exit code 9 if no
files are transferred, useful in scripts." ([rclone.org/flags](https://rclone.org/flags/))

**What this means for `copy_offsite()`:** today it only checks `rclone … copyto …`'s exit status
(`if ! rclone "${RCLONE_ARGS[@]}" copyto "$file" "…"; then … return 1; fi`), i.e. it distinguishes
exit 0 from non-zero, not "code 9 (no-op)" from "code 0 with a real transfer" specifically — and
because of the always-unique timestamped filename this happens to be safe today (a 0 exit for a
brand-new destination path is definitionally a real transfer). It is still worth adding
`--error-on-no-transfer` to `RCLONE_ARGS` defensively: it costs nothing, and it converts any future
change that could introduce a same-name re-run (a manual retry with `--ignore-existing` removed,
a filename scheme change, etc.) from a silently-successful no-op into a loud, already-handled
`::error::`/non-zero-exit path the script already has code for. This is a recommendation, not a
requirement — nothing in the current code is provably wrong.

---

## Recommended config for `BACKUP_RCLONE_REMOTE` / `BACKUP_RCLONE_CONFIG`

**Path 1 — keep the BeeStation, use `smb` (works with the appliance as documented in §1):**

```ini
# rclone.conf (outside the repo, mode 0600, e.g. /etc/rclone/rclone.conf on mob04)
[shop-beestation]
type = smb
host = <beestation-lan-ip-or-hostname>   # reachable via whichever §3 tunnel is chosen
user = <local BeeStation account created under Local Access>
pass = <output of: rclone obscure "the-real-password">
port = 445
domain = WORKGROUP
```

```bash
# on mob04
BACKUP_RCLONE_REMOTE=shop-beestation:pos-backups/mob04
BACKUP_RCLONE_CONFIG=/etc/rclone/rclone.conf
```

No changes to `backup-db.sh` are needed — `offsite_upload()` already treats the remote as an
opaque `rclone copyto` destination (per its own header comment, "rclone \[is\] the pluggable
part").

**Path 2 — if SFTP is a hard requirement, on a DSM-based NAS (§1), key-only, host-key pinned:**

```ini
[shop-nas]
type = sftp
host = <nas-address-reachable-via-chosen-§3-tunnel>
user = pos-backup
key_file = /etc/rclone/pos-backup-nas.key       # private key, mode 0600, no passphrase for unattended cron
known_hosts_file = /etc/rclone/nas_known_hosts  # built once via: ssh-keyscan -t ed25519 <nas-address> >> nas_known_hosts
disable_hashcheck = true                        # Synology path quirk, per §2
set_modtime = true
```

Optional `crypt` layer on top (per §4 — safe to add without touching the local prune):

```ini
[shop-nas-crypt]
type = crypt
remote = shop-nas:pos-backups/mob04
filename_encryption = standard
directory_name_encryption = true
password = <output of: rclone obscure "the-real-crypt-password">
```

```bash
BACKUP_RCLONE_REMOTE=shop-nas-crypt:
BACKUP_RCLONE_CONFIG=/etc/rclone/rclone.conf
```

Either path, recommended `RCLONE_ARGS` addition inside `backup-db.sh` (§5): append
`--error-on-no-transfer` to the existing `RCLONE_ARGS` array before the `copyto` calls.

---

## What we could NOT verify from primary sources

- **Whether the campus FortiGate's SSL deep inspection extends beyond port-443 HTTPS** — the only
  documented breakage anywhere in this repo is `docker compose pull` against `ghcr.io` over HTTPS.
  Nothing confirms or rules out interception/filtering of SSH (port 22), WireGuard/UDP, or
  non-standard ports. This needs a real test from `mob04`.
- **Whether Tailscale specifically would fail under this FortiGate's configuration.** The
  reasoning in §3 ("same SAN-less-cert mechanism that broke ghcr.io would also break Tailscale's
  HTTPS-based control plane/DERP") is an inference by analogy from this repo's own documented
  finding, not a tested result and not something Tailscale's docs address.
- **Whether `mob04` (`172.30.58.20`) has any outbound path to the public internet at all outside
  the campus network**, and on which ports — not stated in `CLAUDE.md` or any doc read this
  session. This bears directly on whether WireGuard/port-forward/reverse-tunnel options in §3 are
  even reachable from that box.
- **Whether the shop's ISP connection permits inbound port-forwarding or sits behind CGNAT** — an
  ISP-contract fact, not something any Synology or rclone document would state, and not verified
  here.
- **A forum-only claim, explicitly flagged as such:** a WebSearch-summarized result (not a
  Synology-owned page reached in this session) asserted "rsync version 3.1.2 is installed on the
  BeeStation." This could not be confirmed on any `kb.synology.com`/`bee.synology.com` page fetched
  in this session, and the official, exhaustive software-specifications page (§1) lists no rsync
  feature anywhere. Treat this claim as unverified and likely a confusion with DSM-based Synology
  NAS models, not BeeStation.
- **Exact keepalive tuning for a long-lived reverse SSH tunnel** (`ServerAliveInterval`,
  `ServerAliveCountMax`, `ExitOnForwardFailure`) — OpenSSH's `ssh(1)` man page states these belong
  to `ssh_config(5)` rather than being documented inline under the `-R` flag itself; this session
  did not additionally fetch `ssh_config(5)` to pull exact default values.

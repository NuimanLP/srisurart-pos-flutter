# Production host options for cutover (#242)

> Wayfinder research ticket. Parent map: #243. Related: #231 (`q4.cutover`), #67 (auto-deploy
> blocked — GitHub-hosted runners cannot reach the campus VM `mob04`, which is campus-internal
> with no public IP), `docs/Backend_design/07_CICD_DEPLOY.md`, ADR-0013.
>
> **This is a recommendation, not a decision.** The final host choice belongs to the project
> owner (see #242's resolution comment). All prices below are **list prices seen on 2026-09-15**
> and converted to THB at an approximate **36 THB/USD** unless the provider itself bills in THB —
> treat every conversion as approximate. Anything not confirmed against an official, current
> source is marked **UNVERIFIED**.

## What we're hosting

Per `server/docker-compose.yml` and `07_CICD_DEPLOY.md`: Nginx → NestJS ×3 → PostgreSQL +
2×Redis + etcd, plus a worker and Bull-Board, plus (optionally) the Prometheus/Grafana/
Node Exporter monitoring overlay. The committed memory budget for the faculty VM (4 vCPU / 6 GB)
is **≈3.3 GB for the app stack + ≈832 MB for monitoring ≈ 4.2 GB**, so **4 vCPU / 8 GB RAM /
~40–50 GB disk** (the issue's own sizing) is a comfortable, not tight, fit. Deploy is Ansible
(`deploy/ansible/provision.yml` + `deploy.yml`) over SSH against a plain Ubuntu box — the
inventory takes `DEMO_SSH_HOST`/`DEMO_SSH_USER`/`DEMO_SSH_KEY_PATH` as environment variables, so
**any provider that hands back a public IPv4 + SSH key access to a stock Ubuntu 22.04/24.04 VM
needs no playbook changes.** TLS is currently self-signed (`certgen`, no DNS name); a real domain
name (~500–700 THB/year from any registrar) would be needed on any host to switch to Let's
Encrypt — this is independent of which host is chosen.

## The #67 angle

#67 (`cd.2`, auto-deploy) is blocked because GitHub-hosted runners cannot reach `mob04`
(`172.30.58.20`, campus-internal). The session that hit this blocker
(`docs/handoff_log/session-2026-09-15-phase1-closeout.md` §6) listed three fixes: (1) a public
IP/port forwarded to the VM's SSH, (2) a self-hosted runner on the VM (outbound-only), or
(3) Tailscale. **Every commercial option below ships a public IPv4 by default** — moving off the
campus VM to any of them resolves #67 the simplest way (option 1, ADR-0013's original design,
Actions → SSH → Ansible) with **no ADR-0013 amendment needed.** The remaining #67 work (the
`deploy.yml` workflow itself, and the `demo` GitHub Environment + secrets) is unaffected by which
host is picked.

## Options compared

### 1. NIPA Cloud — Bangkok, Thailand (`csa.xlarge.v2`, 4 vCPU / 8 GB)

Thai-owned IaaS (OpenStack-style VPS, not a PaaS), datacenter at NT Tower Bangrak, Bangkok.

| | |
|---|---|
| Monthly cost (4 vCPU/8GB) | **UNVERIFIED — not publicly published.** The pricing page names the matching tier (`csa.xlarge.v2`) but shows no THB figure; the interactive calculator renders ฿0.00 placeholders and defers to "Contact Sales." No third-party source has a number either. **Must be obtained via a quote before this option can be compared on cost.** |
| Managed Postgres / PITR | **Not offered.** Their Database Instance product is MySQL-only today ("additional services will be added in the future"). Postgres would be self-hosted in the compose stack — same as the current design, no change needed. |
| Latency from Bangkok | Datacenter is physically **in** Bangkok, on Thailand's largest IX (TOT-IX/TIG-IX/CAT-IX/AWN-IX/JasTel-IX). No published ms figure was found, but same-city placement is a structural latency advantage over every other option here (all of which are Singapore or further). |
| Ubuntu + Docker + Ansible | Standard OpenStack-style VPS (External IP + Load Balancer are separately priced line items, implying normal floating-IP VMs) — Ubuntu LTS images are near-certain but **not directly confirmed**; their docs site did not load during this research. |
| PDPA / data residency | **Strongest of the four.** ISO/IEC 27001:2022, 27018 (PII), 27701 (privacy), CSA STAR certified; explicit claim: "all resources are located in Thailand and owned solely by a Thai company... will not be affected by foreign intervention," and "follow[s] PDPA compliance strictly." |
| Signup friction | Low — the 30-day free-trial signup only asks for name/phone/email, no business registration. Whether a production (paid) account needs one is unconfirmed. |

Sources: nipa.cloud/pricing/nipa-space/{compute-instance,database-instance,compute-image},
nipa.cloud/pricing/calculator, nipa.cloud/company/trust-security, nipa.cloud/ncs-free-trial (all
accessed 2026-09-15).

### 2. DigitalOcean — Singapore (SGP1), Basic Droplet (4 vCPU / 8 GB)

| | |
|---|---|
| Monthly cost (4 vCPU/8GB) | **$48.00/mo ≈ ฿1,728/mo** (Basic Droplet, shared CPU, 160 GB SSD, 5,000 GB transfer — well above the ~40–50 GB need). Source: digitalocean.com/pricing/droplets, accessed 2026-09-15. |
| + Managed Postgres | **+$15.15/mo ≈ +฿546/mo** entry tier → **≈$63.15/mo ≈ ฿2,273/mo total.** Confirmed: daily automated backups + **PITR up to the last 7 days**, at no extra charge. Sources: digitalocean.com/products/managed-databases-postgresql, docs.digitalocean.com/products/databases/postgresql/details/limits/ (accessed 2026-09-15). |
| Latency from Bangkok | No DO-published number; **~20–40ms is a reasonable regional-hop estimate, UNVERIFIED** against any DO figure. DO does provide a live ping tool in-portal (not run this session). |
| Ubuntu + Docker + Ansible | Confirmed. Droplets are stock Ubuntu 22.04/24.04; DO's own "Docker" 1-Click Marketplace image is built on Ubuntu 22.04. Root SSH by default — this is literally the reference platform most Ansible tutorials target. |
| Public IP | Confirmed default (private-networking-only is opt-in) — directly resolves the #67 blocker. |
| PDPA / data residency | No Thailand datacenter — SGP1 is the nearest, so customer/sale data leaves Thailand for Singapore. DO publishes a standing GDPR Data Processing Agreement (most recent Jan 2026) that can serve as a starting point for a PDPA data-transfer clause, but it is **not** a PDPA-specific attestation. |
| Free credits | **UNVERIFIED but likely gone**: multiple independent community threads (not an official DO/GitHub page) report DO exited the GitHub Student Developer Pack and retired its $200 credit on 2026-08-01. |

Sources: digitalocean.com/pricing/droplets, digitalocean.com/products/managed-databases-postgresql,
docs.digitalocean.com/products/databases/postgresql/details/limits/, marketplace.digitalocean.com/apps/docker,
digitalocean.com/trust/gdpr-at-do (all accessed 2026-09-15).

### 3. Hyperscaler Bangkok region — AWS `ap-southeast-7` or GCP `asia-southeast7`

Both regions are **confirmed GA in Thailand** (not "coming soon"): AWS's Asia Pacific (Thailand)
region went live 2025-01-07 (press.aboutamazon.com/sg/aws/2025/1/…, corroborated by
DataCenterDynamics); Google Cloud's Bangkok region went live 2026-01-21
(googlecloudpresscorner.com/2026-01-21-…, cloud.google.com/blog/…), explicitly citing Thailand
PDPA compliance as a launch driver. This is the only option with an **actual in-country
datacenter from a hyperscaler**, which is the strongest formal PDPA/data-residency story of the
four if the owner needs it in writing from a named compliance page.

| | |
|---|---|
| Monthly cost | **Thailand-region pricing itself could not be retrieved this session — UNVERIFIED.** Falling back to the nearest reliably-priced comparable, **AWS Singapore (ap-southeast-1)**: `t3.xlarge` (4 vCPU **/ 16 GB**, double the RAM this workload needs) ≈ **$154/mo ≈ ฿5,550/mo**; `m6i.xlarge` (same shape) ≈ **$175/mo ≈ ฿6,307/mo**. A right-sized 4 vCPU/8 GB instance (e.g. `c5.xlarge`) would likely cost less than these, but its price was not retrieved — treat the figures above as an **upper-bound proxy**, not the real number. GCP `asia-southeast1` pricing could not be retrieved at all this session. |
| Managed Postgres | AWS RDS for PostgreSQL: PITR to any second, retention up to 35 days (aws.amazon.com/rds/faqs). Smallest useful instance (`db.t4g.small`) priced at **≈$51/mo in us-east-1 only** — Singapore/Thailand pricing UNVERIFIED (historically ~15–25% above us-east-1, not confirmed). |
| Ubuntu + Docker + Ansible | Plain EC2/GCE Linux VM, Docker/Compose/Ansible-over-SSH work identically to any VPS — but real setup here also means a VPC, security groups, and IAM, which is materially more moving parts than a single Droplet for a one-VM Docker Compose stack. |
| Public IP / GitHub Actions reachability | Public IP by default if a security group allows inbound SSH. GitHub's own docs say its published Actions IP ranges (`api.github.com/meta`, `actions` key) are **not exhaustive and change frequently** — GitHub does not recommend relying on them for a tight allowlist, so in practice this still means "open SSH broadly + key-only auth" rather than a clean allowlist, same caveat as every option here. |
| Free credits | AWS Free Tier (t2/t3.micro, too small for this workload); GCP $300/90-day trial credit (cloud.google.com/signup-faqs) — would cover a few months but not an ongoing course budget. |

**Cost verdict:** even at the unverified proxy price, this option runs **roughly 3–4× DigitalOcean's**
for an oversized instance, plus materially more infrastructure to configure (VPC/security
groups/IAM) than a single-VM Docker Compose deploy needs. Best kept as a documented fallback if
the owner later decides in-country hyperscaler compliance is worth the premium — not a fit for a
cost-constrained course project today.

### 4. Budget VPS — Linode/Akamai vs. Vultr, Singapore (4 vCPU / 8 GB)

| | |
|---|---|
| Linode/Akamai (Singapore) | **Officially verified**: Shared-CPU "Linode 8GB" (4 vCPU/8 GB) = $0.0720/hr ≈ **$52.56/mo ≈ ฿1,890/mo** (akamai.com/cloud/pricing/asia-pacific, accessed 2026-09-15). Managed Postgres exists but is comparatively expensive: a single-node 4 GB cluster starts ≈$81.60/mo — pricier than self-hosting or than DO's managed offering. |
| Vultr (Singapore) | **UNVERIFIED — official pricing/locations pages returned HTTP 403 to the fetch tool this session.** Third-party aggregators suggest ≈$40–48/mo (≈฿1,440–1,730/mo), in DO's range, but this is not independently confirmed against Vultr's own site. A claimed Bangkok location surfaces in generic marketing copy but **could not be confirmed** — Singapore (`sgp`) is Vultr's long-standing confirmed regional presence (its own looking-glass tool at sgp-ping.vultr.com is live). Vultr does offer Managed Databases for PostgreSQL from ~$15/mo (Vultr's own blog), broadly matching DO's entry tier, but the Singapore-specific small-tier price was not independently confirmed either. |
| Ubuntu + Docker + Ansible | Standard on both — no restriction found. |
| Latency / PDPA | Same as DigitalOcean's SGP1 analysis: ~20–40ms estimate (unverified), and data resides in Singapore, not Thailand, on both. |
| Free credits | Neither Vultr nor Linode/Akamai appears in the current GitHub Student Developer Pack (confirmed via education.github.com/pack, accessed 2026-09-15). |

**Verdict:** Linode/Akamai is a real, officially-priced alternative to DigitalOcean at a similar
cost (≈฿1,890 vs. ฿1,728/mo for compute alone) but with a pricier managed-Postgres add-on. Vultr
might be marginally cheaper but its numbers are the weakest-sourced in this whole comparison
(site blocked the research tool) — **do not commit to a Vultr number without confirming directly
on vultr.com or via `GET /v2/regions` + the pricing page in a browser.**

## Comparison table

| Option | Region | ~4 vCPU/8GB compute | + managed Postgres w/ PITR | Latency from Bangkok | Ansible/Docker fit | Public IP (unblocks #67) | PDPA / residency |
|---|---|---|---|---|---|---|---|
| **NIPA Cloud** | Bangkok, TH | **UNVERIFIED** (quote-only) | Not offered (self-host) | Best (in-country) | Likely yes, unconfirmed | Likely yes, unconfirmed | **Strongest** — Thai-owned, ISO 27701, explicit PDPA claim |
| **DigitalOcean** | Singapore | **฿1,728/mo** (verified) | +฿546/mo, 7-day PITR (verified) | ~20–40ms (estimate) | Confirmed, reference platform | Confirmed default | GDPR DPA only; data leaves Thailand |
| **AWS/GCP Bangkok** | Bangkok, TH (GA) | **UNVERIFIED** in-region; ≈฿5,550–6,307/mo Singapore proxy (oversized instance) | RDS PITR ≤35 days; price UNVERIFIED for region | Best (in-country), if Bangkok region used | Confirmed but VPC/SG/IAM overhead | Confirmed, but GH IP ranges not reliably allowlistable | **Strong**, esp. GCP names PDPA explicitly |
| **Linode/Akamai** | Singapore | **฿1,890/mo** (verified) | ≈฿2,938/mo add-on (pricier) | ~20–40ms (estimate) | Confirmed | Confirmed default | Same as DO — data leaves Thailand |
| Vultr *(not recommended — weak sourcing)* | Singapore (Bangkok unconfirmed) | ≈฿1,440–1,730/mo (**UNVERIFIED**) | ≈฿540/mo+ (**UNVERIFIED**) | ~20–40ms (estimate) | Confirmed | Confirmed default | Same as DO |

## Recommendation

**DigitalOcean, Singapore (SGP1), a single 4 vCPU/8 GB Basic Droplet running the whole Docker
Compose stack as designed today (self-hosted Postgres) — ≈฿1,728/mo, or ≈฿2,273/mo if the owner
also wants DigitalOcean's managed Postgres for automated daily backups + 7-day PITR instead of
the project's own backup scripting.**

Why this one over the other three, for a **cost-constrained course project**:
- It's the **cheapest number that is actually verified against an official price list** (NIPA's
  real price is unknown until a sales quote; Vultr's is aggregator-sourced only).
- It needs **zero changes to the Ansible playbooks** — Droplets are the de facto reference Ubuntu
  target for `provision.yml`/`deploy.yml`'s exact pattern (apt + Docker CE + SSH key auth).
- Its **public IPv4 by default directly unblocks #67** without an ADR-0013 amendment (self-hosted
  runner / Tailscale become unnecessary — the original "Actions → SSH → Ansible" design just
  works).
- Managed Postgres, if adopted, is the cheapest **officially-priced** managed-backup option of
  everything compared (DO $15.15/mo vs. Linode ≈$81.60/mo; NIPA doesn't offer one; AWS RDS
  regional price unknown).

**The trade-off the owner must accept:** the shop's data (customers, sales, mechanics' credit
balances) leaves Thailand and lives in Singapore, with only a generic GDPR-style DPA behind it —
**not** a Thai PDPA-specific attestation, and **not** the in-country residency NIPA Cloud or an
AWS/GCP Bangkok region would give. For a demo/course-project tenant this is very likely fine; if
the owner decides real shop data must stay on Thai soil as a hard requirement, the next step is
**getting an actual NIPA Cloud quote** (its price is the one real unknown blocking a clean
apples-to-apples call) rather than defaulting to the much pricier AWS/GCP Bangkok option.

## What's still needed before #231 can close this checkbox

- A NIPA Cloud sales quote for `csa.xlarge.v2`, if in-country residency is a requirement.
- A live Bangkok→Singapore latency measurement (e.g. via Vultr's `sgp-ping.vultr.com` or DO's
  in-portal tool) rather than the ~20–40ms estimate used here.
- Confirmation of Vultr's actual Singapore/Bangkok pricing directly on vultr.com if it's to be
  considered at all (this research could not get past its 403 on automated fetches).
- The owner's actual decision, recorded on #242/#231 — this document is a recommendation only.

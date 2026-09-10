# Handoff: grill รอบ 3 — CI/CD + deploy design → ADR-0013, 07_CICD_DEPLOY, spec #60, ticket #61–#67

**Date:** 2026-09-10 · **Repo:** `NuimanLP/srisurart-pos-flutter` `main` · **Session:** orchestrator + 6 agents (scrutinize ×3, to-spec, to-tickets, revise)

## What this session was

`/grill-with-docs` on the course's 7-block DevOps table (Git/GitHub · GitHub Actions · Trivy · Docker+GHCR ·
Ansible · etcd · Node Exporter+Prometheus+Grafana), 2 rounds / 19 questions, then scrutinize the design,
write the owning doc + ADR + glossary, have agents draft spec and tickets, scrutinize both, publish.

## Outputs

| | |
|---|---|
| Decision record | [ADR-0013](../Backend_design/adr/0013-cicd-toolchain.md) — toolchain + the deliberate deviations |
| Owning document | [`07_CICD_DEPLOY.md`](../Backend_design/07_CICD_DEPLOY.md) — closes the "deployment has no owning document" gap open since `ec24f79` |
| Glossary | [`CONTEXT.md`](../../CONTEXT.md) at root (new) — gate, status check, artefact vs image, release, demo environment, production host, deploy, rollback, provision, dynamic config |
| Spec | **#60** (parent-like, not a unit of work) |
| Tickets | #61 `ci.4` · #62 `ci.5` (team/1) · #63 `ops.1` · #64 `ops.2` (team/2) · #65 `cd.1` · #66 `ops.3` · #67 `cd.2` (team/3) — blocked-by edges are real GitHub numbers |
| Re-specified by comment | #39 (mechanics fixed, +5 AC, closes #40 AC4) · #44 (image-scan item → #61; AC1 "required checks" superseded) |

## Decisions worth knowing (the non-obvious ones)

* **Path filtering is PR-only and lives inside the workflow**; `push: main` runs everything → both images per SHA.
  Required checks = `flutter-ci-status` + `server-ci-status` only, `!cancelled()` semantics.
* **Web image = static files only**; the VM's stock Nginx reads them from a volume filled by a one-shot
  `web-sync` (certgen pattern). nginx.conf stays in `server/` (server lane).
* **Trivy image gate blocks the GHCR push**; made clean by stripping npm before `USER node`, digest pin,
  `apk upgrade` for OS CVEs. **No `.trivyignore`.**
* **etcd holds one key** (`/pos/config/log_level`), read+watched via the HTTP gateway with `fetch`; app boots without it.
  Rate-limit key dropped (no consumer). Maintenance mode parked (needs new Thai counter copy — forbidden).
* **Deploy trigger** = `workflow_run` of both CI workflows, `head_sha` not `github.sha`, both tags must exist,
  `cancel-in-progress: false`, playbook idempotent. Rollback = `workflow_dispatch` with an older SHA, no down-migration
  → expand/contract rule for migrations.
* **Bug found during scrutiny:** Nginx `location /platform/` is unreachable (app prefix is `api/v1`) — the admin-plane
  allowlist has never applied. Fixed in #62; #44 owns the forced 403 test.
* **Ownership amended** after ticket scrutiny: etcd *service* → team/2, consumer stays team/3 (07 §11).

## Skill notes

`/to-spec` and `/to-tickets` are `disable-model-invocation`; sub-agents cannot call them. The orchestrator pasted
the templates into the agent prompts instead — output shape matches the skills.

## Still open

* Owner one-time steps before the first auto-deploy (07 §7): Environment `demo` + 4 secrets, manual `provision.yml`,
  flip both GHCR packages public.
* Q16 facts never answered (Docker present? SSH user? key holder) — moot because provision runs from bare.
* Grafana kept at the owner's "ใส่ก็ได้"; drop it only if the slide table changes too.

## State (end of session, 2026-09-10)

**All merged to `main`, in this order:** #68 docs (rebased over the other session's #58; `INDEX.md` conflict kept both lines) →
#70 `ci.4` (#61) → #69 `ci.5` (#62) → #71 docs correction → this status commit.
Implemented by agents in isolated worktrees, each through a two-axis code review (Standards + Spec) before push:
**#61 → #70** (digest-pinned Dockerfile, npm/npx/corepack stripped, Trivy image gate before the GHCR push, tarball gone;
local Trivy 0 findings vs 13 on the bare base) · **#62 → #69** (static-only web image on GHCR, nginx mime types,
`/api/v1/platform/` allowlist fix, `location /` static without `limit_req`).

**First real `main` runs:** all green; Trivy image step passed; both images pushed with `<sha>` + `main`.
**Runbook correction (#71):** the "flip both GHCR packages public by hand" step was wrong — packages pushed by `GITHUB_TOKEN` from a
public repo are public from the first push (anonymous registry token → 200 on both manifests, `docker pull` logged out works).

**Left to the teammates by the owner's decision:** #39 (team/2), #63 #64 (team/2), #65 #66 #67 (team/3). Before the first auto-deploy
(07 §7): Environment `demo` + 4 secrets, one manual `provision.yml`, secret scanning + push protection in repo settings.
**Trap for #65:** the stock nginx image pre-seeds a fresh volume with its own `index.html`; `web-sync` must overwrite (comment on #65).

The working tree also carried another session's #53/#58 work during this session (merged separately); nothing of it is in these PRs.

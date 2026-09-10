# Srisurart POS — Delivery & Operations

Glossary for how this project builds, ships and runs software (the CI/CD and deployment
context). Started 2026-09-10 during the CI/CD grill; the product/domain terms (tenant, device
role, shift, …) live in `docs/Backend_design/` and its ADRs and are not repeated here.
Definitions only — no implementation details.

## Language

### Pipeline

**Gate**:
A check that must pass before code moves on; a gate that only reports and never fails is not a gate.
_Avoid_: scan (when it blocks), lint step, quality step

**Status check**:
The single always-reported result of one workflow that branch protection requires on `main`; it summarises the gates that ran and ignores the ones that were skipped.
_Avoid_: required job, CI status

**Tree**:
One of the two independently built halves of the monorepo: the Flutter client (`frontend/`) or the NestJS server (`server/`).
_Avoid_: side, half, module

### Release

**Artefact**:
A built output kept by CI for one commit so a person can download and inspect it; it is not runnable by the VM on its own.
_Avoid_: artifact (spelling), build output, bundle

**Image**:
A container image pushed to the registry and tagged with the commit SHA; the only thing the VM ever runs.
_Avoid_: build, container (for the stored thing), artefact

**Release**:
The pair of images (server + web) that share one commit SHA; a commit with only one of the two is not a release.
_Avoid_: version, build, deploy

**Registry**:
Where images are stored and pulled from (GHCR).
_Avoid_: repository (ambiguous with git), hub

### Environments

**Demo environment**:
The faculty VM that every green `main` is deployed to automatically; for demonstration and grading only, never the shop.
_Avoid_: staging, production, the server, the VM (when meaning the role)

**Production host**:
The machine that will one day run the shop's real POS; not chosen yet, must be chosen before cutover.
_Avoid_: prod, live server

**Cutover** (ย้ายร้านจริง):
The moment the shop stops running the local Drift build and starts running against the server; explicitly not part of phase 1.
_Avoid_: go-live, launch, migration (ambiguous with schema migration)

### Operations

**Deploy**:
Applying one release to one environment: pull the images, run the schema migration once, restart the API instances one at a time, verify readiness.
_Avoid_: release (the verb), ship, push (ambiguous with git)

**Rollback**:
Deploying an earlier release to the same environment; the schema is never migrated backwards.
_Avoid_: revert (ambiguous with git), downgrade

**Provision**:
Bringing a bare machine to the state where a deploy can run (Docker, firewall, users, secrets); repeatable and safe to re-run.
_Avoid_: setup, bootstrap, install

**Dynamic config**:
A non-secret setting the running server can change without a redeploy; never business data and never a secret.
_Avoid_: state, feature flag (when meaning the store), settings (ambiguous with the shop's `settings` table)

**Secret**:
A value that must never appear in the repo or in logs (keys, passwords, connection strings); lives only in the CI environment store and on the machine that needs it.
_Avoid_: credential, config (for secrets)

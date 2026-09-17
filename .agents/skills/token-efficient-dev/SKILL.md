---
name: token-efficient-dev
description: Guidelines, scripts, and prompt templates for token-efficient development in this repo. Enforces fast static local checks, zero parent polling loops, strict negative constraints, and delegating E2E database tests to GitHub Actions.
---

# Token-Efficient Development Guidelines & Prompt Template

This skill defines the token-conservation protocols and templates for both parent agents and subagents working on this codebase (especially `server/`).

---

## 1. Core Principles

| Rule | What to Do | What NEVER to Do |
|---|---|---|
| **Fast Static Checks** | Run `pnpm.cmd check` or `./check.ps1` in `server/` (~5s total). Runs `oxlint` + `tsc --noEmit`. | Never run manual multi-step commands or complex bash scripts from scratch. |
| **E2E Testing Scope** | Commit & push to a feature branch; let GitHub Actions CI run `pnpm test:e2e` against real Postgres & Redis containers. | Never spend agent loops troubleshooting Docker Desktop, Windows services, WSL distros, or local ports. |
| **Parent Agent Polling** | End turn immediately after spawning a subagent. Rely 100% on reactive wakeup. | Never schedule 15s–30s recurring timers in the parent agent while waiting for subagents. |
| **Agent Prompting** | Always include the **Strict Negative Constraints** block in subagent prompts. | Never leave subagents open-ended with "run tests" without telling them what NOT to touch. |

---

## 2. Fast Local Static Verification Script

Pre-configured in `server/`:
- **Command**: `pnpm.cmd check` or `powershell -File ./check.ps1` (inside `server/`)
- **What it executes**:
  1. `oxlint src/ test/` (sub-100ms linter across 218+ files)
  2. `tsc --noEmit` (TypeScript strict typecheck)
- **Dependencies**: Requires only `node_modules`. Requires **ZERO** Docker, PostgreSQL, or Redis services.

---

## 3. Strict Negative Constraints (MANDATORY Subagent Block)

Attach this block verbatim to any subagent prompt for `server/` work:

```markdown
### ⛔ STRICT NEGATIVE CONSTRAINTS (DO NOT VIOLATE):
1. Do NOT attempt to start, restart, or troubleshoot Docker Desktop or any Windows background service.
2. Do NOT install global npm packages or system software.
3. For local verification, ONLY run `pnpm.cmd check` or `powershell -File ./check.ps1` in `server/`.
4. Do NOT attempt to run `pnpm test:e2e` locally if Docker/Postgres is stopped; full E2E database verification is handled automatically by GitHub Actions on pull request.
5. If static checks pass (`check.ps1` exits with 0) and `git status` shows only the intended files modified, conclude your work immediately and report back.
```

---

## 4. Reusable Subagent Prompt Templates

### A. Lean Single-Agent Implementation Prompt (Recommended)
Use this template for DoD tickets (like #292, #295, #297) or isolated features:

```markdown
You are implementing Issue #<NUMBER>: <TITLE> in D:\Mobile\srisurart-pos-flutter.

Scope:
- Only create/modify <TARGET_FILES>.
- Ensure no other files in the repo are altered (`git status`).

Task Requirements:
1. <SPECIFIC_INVARIANT_1>
2. <SPECIFIC_INVARIANT_2>
3. <SPECIFIC_INVARIANT_3>

Local Verification:
- Run `powershell -File ./check.ps1` in `server/` to prove typecheck and lint pass with 0 errors.

### ⛔ STRICT NEGATIVE CONSTRAINTS (DO NOT VIOLATE):
- Do NOT launch Docker Desktop, WSL, or background database services.
- Do NOT run local e2e commands requiring live PostgreSQL/Redis; E2E tests run in GitHub Actions CI.
- Do NOT install global packages.

When `check.ps1` exits 0 and `git status` is clean, report your findings and finish.
```

---

## 5. Parent Agent Protocol (Zero-Polling)

After calling `invoke_subagent`:
1. **Stop calling tools immediately.**
2. Output a brief 1-line update to the user (e.g. *"Spawned agent to implement Issue #X; waiting for completion."*).
3. Do **NOT** call `schedule` with a 15s or 30s timer.
4. The system automatically resumes execution when the subagent finishes or sends a message.

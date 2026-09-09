# Boat — CI/CD Knowledge Base

> Distilled from `devops_cicd_jenkins_presentation.pdf` (155 pages, *DevOps & CI/CD with Jenkins*, Chavatik Thorarit, 6610110066).
> This is the working reference — the deck is the lecture, this is what you keep.

**How this file is organised**

| Part | What it gives you | Read when |
|---|---|---|
| [1. Mission](#1-mission) | Why this material matters for Boat | First, once |
| [2. Mental models](#2-mental-models) | The 6 frameworks worth memorising | First, once |
| [3. Best practices](#3-best-practices-consolidated) | The consolidated, de-duplicated rule set | Reference |
| [4. The workflow](#4-the-workflow-zero-to-gated-pipeline) | Zero → gated pipeline, phase by phase | When building |
| [5. Corrections](#5-corrections-to-the-source-deck) | Bugs in the deck's own code samples | **Before copy-pasting any snippet** |
| [6. Quick reference](#6-quick-reference) | Commands, credentials, glossary | Reference |

> [!WARNING]
> **Do not copy code straight out of the PDF.** Part 5 lists verified defects in the deck's
> own examples — a prompt-order bug that hangs builds, an alert that fires at "100% errors" on
> a single 5xx, a Trivy stage that cannot see the image it scans, and a Flutter stage that
> distributes a file it never built.
> The corrected versions are in Part 5.

---

## 1. Mission

The deck covers five overlapping disciplines. For Boat the pipeline is a **Flutter/Android
app**, so the deck's Chapter 13 (Dart/Flutter & Android Build Pipeline) is the target, and
everything else is scaffolding around it.

The honest ordering of what actually pays off, first to last:

1. **A pipeline that builds and tests on every push.** Nothing else matters until this exists.
2. **Gates that actually fail.** A scan that always exits 0 is theatre (see §5.4).
3. **Signed release artifacts, reproducibly.** Keystore in Jenkins credentials, never in git.
4. **Distribution automation.** Firebase for testers, Play internal track for main.
5. **Measurement.** DORA metrics, then SLOs, then error budgets — in that order.

IaC, SRE and chaos engineering are in the deck and summarised here, but they are *later*
concerns for a mobile app. Do not build a Terraform pipeline before you have a green
`flutter test`.

---

## 2. Mental models

Six frameworks carry most of the deck's conceptual weight.

### 2.1 CALMS — what "DevOps" actually decomposes into

| Pillar | Meaning |
|---|---|
| **C**ulture | Shared ownership, psychological safety, blameless postmortems |
| **A**utomation | Eliminate repetitive manual work — build, test, deploy, provision |
| **L**ean | Reduce waste, optimise flow, limit work-in-progress |
| **M**easurement | Instrument everything; decisions driven by data |
| **S**haring | Open communication, shared tools, internal open-source culture |

The load-bearing insight: DevOps is a *philosophy*; CI/CD is its *technical implementation*;
SRE is *one concrete job role* that implements it. They are not competing options.

### 2.2 DORA — the four metrics that define "good"

| Metric | Elite target | Measures |
|---|---|---|
| Deployment Frequency | On-demand / multiple per day | How often code ships |
| Lead Time for Changes | < 1 hour | Commit → running in production |
| Change Failure Rate | ~5% (2024 report) | % of deploys causing incidents |
| Time to Restore Service | < 1 hour | MTTR when an incident occurs |

Two are **throughput** (frequency, lead time), two are **stability** (CFR, MTTR). The whole
point of the pairing is that you cannot game one half without wrecking the other.

CI/CD pipelines are the primary lever on all four.

> The deck presents four metrics. DORA added **reliability** as a fifth in 2021, and later
> reports rename MTTR to *Failed Deployment Recovery Time*. Quote a report year when you cite
> a threshold — the numbers have moved (see §5.19).

### 2.3 Shift-left — why security moves earlier

Cost to fix a vulnerability, by the stage it is found:

```
  $1          $10         $100        $1,000      $10,000+
Design  →   Coding  →   Testing  →   Staging  →  Production
(threat     (SAST/      (DAST/       (compliance  (incident
 modeling)   linting)    pen test)    scan)        response)
```

Roughly an order of magnitude per stage. That single curve is the entire economic argument
for DevSecOps — it is not about being more secure, it is about being cheaper.

### 2.4 SLI → SLO → SLA — the reliability chain

| Term | What it is | Example |
|---|---|---|
| **SLI** | What you *measure* | `successful_requests / total_requests` = 99.92% |
| **SLO** | Your *internal target* | 99.9% over a 30-day window |
| **SLA** | Your *contract* with customers | 99.5%, with financial penalty |

**The SLO must always be stricter than the SLA.** The gap is your safety buffer — you want to
be alerting and freezing releases well before you owe anyone money.

### 2.5 Error budget — the release-velocity dial

```
SLO 99.9% over 30 days
  total minutes  = 30 × 1440 = 43,200
  allowed (0.1%) = 43.2 minutes  ← the error budget
```

| Budget remaining | Policy |
|---|---|
| > 50% | Ship features, run experiments, chaos test |
| 25–50% | Slow risky releases; prioritise reliability work |
| < 10% | Freeze non-critical releases |
| 0% | Full freeze until reset; postmortem before resuming |

This is the mechanism that converts "reliability" from an argument into a number. Write the
policy down *before* you need it, or it will be relitigated during every incident.

### 2.6 Toil — what automation is for

Toil is work that is **manual, repetitive, automatable, tactical, of no enduring value, and
scales linearly with traffic.** All six, not any one.

The Google SRE rule: **≤ 50% of time on toil.** Above that, toil-elimination becomes backlog.

Restarting a crashing service weekly is toil. Debugging *why* it crashes is not.

---

## 3. Best practices (consolidated)

The deck scatters best-practice lists across six chapters. Merged and de-duplicated, with the
ones that actually bite listed first.

### 3.1 Pipeline design

| Practice | Why |
|---|---|
| **Fail fast** | Cheap checks (format, lint, unit) before expensive ones (E2E, build, sign) |
| **Parallelise independent stages** | Lint ∥ unit ∥ SCA — they share no state |
| **`when { beforeAgent true }`** | Don't allocate a Docker agent for a stage you'll skip |
| **`when { beforeInput true }`** | Don't prompt a human for a stage you'll skip (see §5.1) |
| **Idempotent steps** | Any step may be retried; none may assume it ran once |
| **Jenkinsfile in source control** | The pipeline is versioned with the code it builds |
| **Pin every image tag** | `python:3.11.9-slim`, not `python:latest` (see §5.13) |
| **One artifact, promoted** | Build once; promote the *same* artifact through environments |

### 3.2 Security

| Practice | Why |
|---|---|
| **Never hardcode secrets** | Use Jenkins credentials / Vault; fetch at runtime |
| **Never `echo` a secret** | Build logs are widely readable and retained |
| **Zero executors on the controller** | `agent any` can otherwise schedule on the controller, which has filesystem access to `JENKINS_HOME` and `credentials.xml` (see §5.6) |
| **Delete credential files in `cleanup`** | `key.properties` must not survive the stage |
| **Do not archive Terraform plan files** | Plans contain resource values in plaintext (see §5.11) |
| **Scan order: Secrets → SAST → SCA → Container → DAST** | Cheapest and earliest first |
| **Decide fail-vs-warn deliberately** | Then make the code match the decision (see §5.4) |

### 3.3 Testing

| Practice | Why |
|---|---|
| **Publish JUnit XML** | Gives Jenkins the test trend graph; without it failures are just log noise |
| **Retry only on CI** | `retries: process.env.CI ? 2 : 0` — hides flakes locally otherwise |
| **Trace/screenshot on failure only** | Full-run artifacts are enormous and unread |
| **Cheap browser on push, full matrix on main** | Chromium every push; Firefox+WebKit on `main`/`release/*` |
| **Quality gate blocks the build** | `waitForQualityGate abortPipeline: true` — otherwise SonarQube is decorative |

### 3.4 IaC

| Practice | Why |
|---|---|
| **Everything in git** | PRs become the change-control process |
| **Remote, locked state** | Prevents concurrent-apply corruption |
| **Never edit state by hand** | Use `terraform import` |
| **Pin provider versions with `~>`** | `>= 5.0` is not pinning — it accepts the next major |
| **`plan` in CI, `apply` gated** | A human reads the diff before infrastructure moves |
| **Scan with tfsec / Checkov** | Catches open security groups and unencrypted buckets pre-apply |
| **Tag every resource** | Cost attribution, ownership, environment filtering |

### 3.5 SRE / operations

| Practice | Why |
|---|---|
| **Define SLOs before dashboards** | Otherwise you instrument the wrong things |
| **Alert on symptoms, not causes** | Page on "users see errors", not "disk 80% full" |
| **Every page must be actionable** | Non-actionable pages train people to ignore pages |
| **Postmortem every SEV-1/2 within 48h** | Blameless, with owned and dated action items |
| **Progressive delivery** | Canary → blue/green → feature flags, to bound blast radius |
| **Test your runbooks** | An untested runbook fails at 3am, which is the only time it is read |

---

## 4. The workflow: zero to gated pipeline

Eight phases. Each has a **Done when** line that is objectively checkable — if you cannot
check it, you are not done, and you do not start the next phase.

The ordering is deliberate: every phase is useful on its own, and each one is only worth
building once the previous one holds.

```
P0 Reproducible ──▶ P1 Jenkins can build ──▶ P2 Green pipeline ──▶ P3 Gates bite
locally                                                                  │
                                                                         ▼
P7 Steady state ◀── P6 Observability ◀── P5 Distribution ◀── P4 Signed artifacts
```

### Phase 0 — Make the build reproducible locally

Before automating anything, the build must be deterministic on one machine.

```bash
flutter pub get --enforce-lockfile     # fails if pubspec.lock is stale or uncommitted
flutter analyze --fatal-infos --fatal-warnings
dart format --set-exit-if-changed lib/ test/
flutter test --coverage
flutter build apk --debug
```

- `pubspec.lock` **is committed**.
- Pin the Flutter SDK version (`ghcr.io/cirruslabs/flutter:3.24.0`, not `:stable`).

> **Done when:** the five commands above pass from a fresh `git clone` on a machine that has
> never built this project, with no manual steps in between.

### Phase 1 — A Jenkins that can actually build

Most first-day Jenkins failures are here, not in the Jenkinsfile.

1. **Install.** Docker is the fastest path for learning:
   ```bash
   docker run -d --name jenkins \
     -p 8080:8080 -p 50000:50000 \
     -v jenkins_home:/var/jenkins_home \
     jenkins/jenkins:lts-jdk21
   docker exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
   ```
   ⚠️ This container **cannot run Docker-based agents as-is** — see §5.7 for what to add.
2. **Harden before use.** Set built-in node executors to **0** (§5.6). Enable CSRF protection.
   Configure matrix authorisation.
3. **Plugins.** Git, Pipeline, Docker Pipeline, Credentials Binding, Coverage, JUnit,
   Blue Ocean, Slack Notification.
4. **Agent.** A labelled Linux agent with the Flutter/Android image and a persistent
   Gradle cache mount.

> **Done when:** a throwaway Pipeline job running `agent { docker { image 'ghcr.io/cirruslabs/flutter:3.24.0' } }`
> and `sh 'flutter --version'` goes green — proving credentials, agent, and Docker access all work.

### Phase 2 — The minimal green pipeline

Resist adding stages. Four only:

```groovy
pipeline {
    agent { docker { image 'ghcr.io/cirruslabs/flutter:3.24.0' } }
    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '20'))
        disableConcurrentBuilds()
    }
    stages {
        stage('Dependencies') {
            steps { sh 'flutter pub get --enforce-lockfile' }   // §5.12 — this call ONLY
        }
        stage('Quality') {
            parallel {
                stage('Analyze') { steps { sh 'flutter analyze --fatal-infos --fatal-warnings' } }
                stage('Format')  { steps { sh 'dart format --set-exit-if-changed lib/ test/' } }
            }
        }
        stage('Test') {
            steps { sh 'flutter test --coverage --machine > test-results.json' }
            post { always { junit allowEmptyResults: true, testResults: '**/test-results.xml' } }
        }
        stage('Build Debug APK') {
            steps {
                sh 'flutter build apk --debug --build-number=${BUILD_NUMBER}'
                archiveArtifacts artifacts: 'build/app/outputs/flutter-apk/app-debug.apk',
                                 fingerprint: true
            }
        }
    }
}
```

Set up the GitHub webhook (`http://<jenkins>:8080/github-webhook/`, content type
`application/json`, events: Push + Pull Request) and use a **Multibranch Pipeline** so every
branch and PR gets built.

> **Done when:** pushing a commit to any branch triggers a build with no manual action, and a
> deliberately broken test turns the build red within 10 minutes.

### Phase 3 — Make the gates bite

Add security scanning — and decide, per tool, whether it **fails** or **warns**. Write the
decision in the Jenkinsfile as a comment so the next person does not "fix" it.

| Stage | Tool | Boat's default |
|---|---|---|
| Secrets | Gitleaks | **fail** — a leaked key is never acceptable |
| SAST | `dart analyze`, `very_good_analysis` | **fail** — already in Phase 2 |
| SCA | `osv-scanner` on `pubspec.lock` | **fail** on HIGH/CRITICAL, warn below |
| Container | Trivy (only if you ship a container) | **fail** on HIGH/CRITICAL |

The three fail-vs-warn idioms:

```groovy
sh 'osv-scanner --lockfile pubspec.lock'                    // fail: non-zero exits the stage
sh 'osv-scanner --lockfile pubspec.lock || true'            // warn: collect, never block
script {                                                     // threshold: fail above a count
    def n = sh(script: "osv-scanner --lockfile pubspec.lock --format json | jq '[.results[].packages[]] | length'",
               returnStdout: true).trim().toInteger()
    if (n > 5) { error("Too many vulnerable packages: ${n}") }
}
```

> **Done when:** committing a fake AWS key on a branch turns the build red, and reverting it
> turns the build green. If that test passes, the gate is real.

### Phase 4 — Signed release artifacts

Store three credentials in Jenkins (never in git):

| Credential ID | Type | Contents |
|---|---|---|
| `android-keystore` | Secret File | `.jks` / `.p12` keystore |
| `android-store-password` | Secret Text | Keystore password |
| `android-key-password` | Secret Text | Key entry password |

```groovy
stage('Build Release') {
    when { beforeAgent true; anyOf { branch 'main'; branch 'release/*' } }
    steps {
        withCredentials([
            file(credentialsId: 'android-keystore',          variable: 'KEYSTORE_FILE'),
            string(credentialsId: 'android-key-password',    variable: 'KEY_PASS'),
            string(credentialsId: 'android-store-password',  variable: 'STORE_PASS'),
        ]) {
            sh '''
                cat > android/key.properties <<EOF
storePassword=${STORE_PASS}
keyPassword=${KEY_PASS}
keyAlias=upload
storeFile=${KEYSTORE_FILE}
EOF
                flutter build appbundle --release \
                    --build-number=${BUILD_NUMBER} --build-name=1.0.${BUILD_NUMBER}
                flutter build apk --release \
                    --build-number=${BUILD_NUMBER} --build-name=1.0.${BUILD_NUMBER}
            '''
        }
    }
    post {
        always {
            archiveArtifacts artifacts: 'build/app/outputs/bundle/release/app-release.aab,build/app/outputs/flutter-apk/app-release.apk',
                             fingerprint: true
        }
        cleanup { sh 'rm -f android/key.properties' }   // non-negotiable
    }
}
```

Two things that are easy to get wrong and both matter:

- The `sh '''...'''` uses **triple single quotes**, so Groovy does *not* interpolate — the
  shell expands `${STORE_PASS}` from the credential env var. Triple *double* quotes would
  interpolate the secret into the script text, where it can surface in logs and stack traces.
- `cleanup { }` runs even when the stage fails. `always { }` is not a substitute if you also
  want the archive to happen first.

> **Done when:** the archived `.aab` installs on a real device, and
> `grep -r 'key.properties' $WORKSPACE` after the build returns nothing.

### Phase 5 — Distribution

`develop` → Firebase App Distribution (testers). `main` → Play Store internal track, behind a
manual approval.

⚠️ The deck's version of this has a real bug — it distributes `app-release.apk` on `develop`
while only building release artifacts on `main`. See §5.3 for the corrected branch guards.

```groovy
stage('Publish — Play internal') {
    when { beforeInput true; beforeAgent true; branch 'main' }   // beforeInput matters (§5.1)
    input { message 'Publish to Play Store internal track?'; ok 'Publish' }
    steps { /* flutter_distributor publish --track internal */ }
}
```

> **Done when:** merging to `develop` puts a build in a tester's hands with zero manual steps,
> and merging to `main` waits for exactly one human click.

### Phase 6 — Observability and the error budget

Only now is measurement worth building.

1. Stand up Prometheus + Grafana + Alertmanager (the deck's `docker-compose.yml` works).
2. Define **one** SLI you actually care about, then its SLO. For a mobile backend: request
   success rate.
3. Write alerts on **symptoms**. Use the corrected PromQL in §5.2 — the deck's error-rate
   alert fires at "100% errors" the moment a single 5xx appears.
4. Add the error-budget gate to the production stage *only after* the budget is real:

```groovy
stage('Error Budget Gate') {
    steps {
        script {
            def budget = sh(script: 'python3 scripts/check_error_budget.py --slo 99.9 --window 30d',
                            returnStdout: true).trim().toDouble()
            if (budget < 10) { error("Error budget exhausted (${budget}% remaining). Release blocked.") }
            echo "Error budget remaining: ${budget}%"
        }
    }
}
```

> **Done when:** you can state today's error budget as a number without opening a dashboard
> and doing arithmetic.

### Phase 7 — Steady state

The pipeline is built; now it has to stay useful.

- **Measure the four DORA metrics** from Jenkins build data plus incident records.
- **Track toil hours per week.** Above 50%, the next sprint's top item is automation.
- **Postmortem every SEV-1/2** within 48 hours, blameless, with owned and dated actions.
- **Prune the pipeline.** A stage nobody reads the output of should be deleted, not kept
  "just in case" — it costs minutes on every build forever.
- **Re-run Phase 0 quarterly** on a clean machine. Reproducibility rots silently.

> **Done when:** deployment frequency and lead time are numbers on a dashboard, not estimates.

---

## 5. Corrections to the source deck

A scrutiny pass over the deck's code samples, traced against official documentation. The
concepts in the deck are sound — **the runnable code is where the problems are.**

> **A note on the PDF.** The deck's code font uses programming ligatures that text-extraction
> mangles: `//` renders as `=/`, `--` as `=-`, `&&` as `=&`, `||` as `=|`, `<<` as `=<`,
> `>=` as `=>`. Those are *display* artifacts, not errors, and are excluded below. Everything
> listed here is a defect in the actual logic.

### Blockers — will break, or silently do nothing

#### 5.1 `input` prompts on branches the `when` will skip

Deck pages 87, 151. Both production-deploy stages combine `when` and `input`:

```groovy
stage('Deploy to Production') {
    when { branch 'main' }
    input { message "Deploy to production?"; ok "Deploy" }
    steps { ... }
}
```

**Verified against Jenkins docs:** "By default, the `when` condition for a stage will *not* be
evaluated before the `input`." So on **every** feature branch, the build stops and waits for a
human to answer "Deploy to production?" — and then skips the stage anyway. Builds hang until
the input times out.

```groovy
when { beforeInput true; branch 'main' }    // fix
```

The same class of bug applies to `agent`: the default evaluates `when` *after* entering the
agent, so the deck's Playwright and Flutter pipelines spin up Docker containers for stages
they then skip. Add `beforeAgent true`.

#### 5.2 Both Prometheus alert queries are wrong

Deck pages 56–57.

```promql
# as printed
rate(http_requests_total{status=~"5.."}[5m]) / rate(http_requests_total[5m]) > 0.01
```

Binary operators match series with **identical label sets**. Every left-hand series carries
`status="500"` (or similar) — and the right-hand side, being unfiltered, contains *that same
series*. So each 5xx series is divided by itself, giving exactly `1.0`. The alert therefore
fires at "100% error rate" the moment a single 5xx response appears, and stays firing.

```promql
sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.01
```

Aggregate first, then divide. (Use `sum without(status)` if you want to keep `path`/`instance`
breakdowns.)

```promql
# as printed — one quantile per instance, not a service-wide p99
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
# fix
histogram_quantile(0.99, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))
```

`histogram_quantile` needs exactly one series per `le` boundary per group. With several
replicas exposing the same buckets, the unaggregated form silently miscomputes.

Related inconsistency: page 51 exposes `http_request_duration_seconds{quantile="0.99"}` — a
**summary** — while page 57 queries `..._bucket`, a **histogram**. Only the histogram supports
`histogram_quantile`. Pick one; for SLOs, pick the histogram.

#### 5.3 Flutter pipeline distributes an artifact it never built

Deck pages 146 and 151–152. In the same pipeline:

```groovy
stage('Build Release')       { when { anyOf { branch 'main'; branch 'release/*' } } ... }
stage('Distribute to Testers') { when { branch 'develop' }
    steps { /* uploads build/app/outputs/flutter-apk/app-release.apk */ } }
```

On `develop`, `Build Release` is skipped, so `app-release.apk` does not exist — the Firebase
upload fails on a missing file. On `main`, the artifact exists but the distribute stage is
skipped. **The stage can never succeed.**

Fix: build a signed release on `develop` too (a staging flavour), or point the distribute
stage at the debug APK, or gate distribution on `anyOf { branch 'develop'; branch 'main' }`
with a build that covers both.

#### 5.4 The security pipelines block nothing

Across pages 110–118, nearly every scanner is neutered:

| Deck stage | As written | Effect |
|---|---|---|
| Bandit | `--exit-zero`, then `\|\| true` | Never fails |
| Safety | `\|\| true` | Never fails |
| npm audit | `--audit-level=high ... \|\| true` | Never fails — despite the comment saying it gates |
| ESLint security | `\|\| true` | Never fails |
| Retire.js | `\|\| true` | Never fails |
| osv-scanner | `\|\| true` | Never fails |
| Trivy | `--exit-code 1` | **Actually gates** |

Six of seven are report-only, while the deck's own "Fail vs Warn Strategy" slide (page 121)
presents failing as the default. Report-only is a legitimate *starting* posture — but it must
be a decision, not an accident. Pick per tool and write the reason in a comment.

Worse, the ESLint stage cannot work even in principle:

```bash
npx eslint src/ --plugin security --rule "security/detect-sql-injection: error" ... || true
```

**`eslint-plugin-security` has no `detect-sql-injection` rule.** ESLint aborts with
`Definition for rule 'security/detect-sql-injection' was not found` and exits non-zero — which
the trailing `|| true` swallows. The stage is green, the report file is empty, and no
JavaScript is ever scanned. The plugin's real rules include `detect-object-injection`,
`detect-non-literal-fs-filename`, `detect-eval-with-expression`, `detect-child-process`,
`detect-unsafe-regex` and `detect-possible-timing-attacks` — there is no SQL-injection rule.


#### 5.5 Trivy cannot see the image it is told to scan

Deck page 119:

```groovy
docker.image('aquasec/trivy:latest').inside('--network=host') {
    sh "trivy image myapp:${env.BUILD_NUMBER}"
}
```

Trivy runs *inside* a container with no access to the host Docker daemon, so the locally-built
`myapp:N` is invisible. It falls through to a registry pull and fails. Same defect in the
`docker run --rm aquasec/trivy:latest image ...` immediately below it.

```groovy
sh """
    docker run --rm \
        -v /var/run/docker.sock:/var/run/docker.sock \
        aquasec/trivy:0.58.1 image --exit-code 1 --severity HIGH,CRITICAL myapp:${env.BUILD_NUMBER}
"""
```

#### 5.6 `agent any` can schedule builds on the Jenkins controller

The deck uses `agent any` throughout and never mentions controller isolation. **Verified
against Jenkins security docs:** builds on the built-in node run with the same filesystem
access as the Jenkins process itself — including `JENKINS_HOME` and its stored secrets. A
pipeline that can read `JENKINS_HOME` can read every credential Jenkins holds, which
undermines the entire credentials chapter.

Fix: Manage Jenkins → Nodes → Built-In Node → **executors = 0**, and give real agents labels.

#### 5.7 The Docker install produces a Jenkins that cannot run the deck's own pipelines

Deck page 80 installs Jenkins with:

```bash
docker run -d --name jenkins -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home jenkins/jenkins:lts-jdk21
```

**Verified:** the stock image ships no Docker CLI and mounts no Docker socket. Every
subsequent example in the deck uses `agent { docker { image ... } }` or `docker.build(...)`.
Following the deck in order, the first real pipeline fails.

Fix: mount the socket and provide a Docker CLI (custom image, or a `docker:dind` sidecar):

```bash
docker run -d --name jenkins -p 8080:8080 -p 50000:50000 \
  -v jenkins_home:/var/jenkins_home \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -u root myorg/jenkins-with-docker-cli:lts-jdk21
```

Mounting the socket grants effective host root to anything that can run a build — which is
exactly why §5.6 (zero executors on the controller) is not optional once you do this.

### Majors — wrong, leaky, or self-contradicting

#### 5.8 The secrets-detection stage cannot fail a build

Deck page 110, comment says *"Fails the build if new secrets are introduced"*:

```bash
detect-secrets scan --baseline .secrets.baseline
detect-secrets audit .secrets.baseline --diff
```

**Verified:** `detect-secrets scan --baseline` *rewrites the baseline in place* and exits 0 —
new secrets are quietly absorbed into the baseline rather than reported. And
`detect-secrets audit --diff` is **interactive** (it prompts y/n per finding), so in CI it
either hangs or dies on stdin.

```bash
detect-secrets-hook --baseline .secrets.baseline $(git diff --name-only --cached)   # exits non-zero
```

#### 5.9 The Terraform pipeline will not authenticate to AWS

Deck page 38: `environment { AWS_CREDENTIALS = credentials('aws-deploy-key') }`.

**Verified:** for a username/password credential this creates `AWS_CREDENTIALS`,
`AWS_CREDENTIALS_USR` and `AWS_CREDENTIALS_PSW` — *not* `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY`. The AWS provider will not pick those up. The `credentials()` helper
also does not support the AWS Credentials plugin type at all.

```groovy
withCredentials([[$class: 'AmazonWebServicesCredentialsBinding', credentialsId: 'aws-deploy-key']]) {
    sh 'terraform plan -out=tfplan'    // sets AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY properly
}
```

#### 5.10 Bash-only syntax in a `sh` step

Deck page 40: `--set image.tag=${GIT_COMMIT:0:7}`.

**Verified:** the Jenkins `sh` step runs `/bin/sh -xe`, which on Debian-family agents is
**dash**. Substring expansion `${VAR:0:7}` is a bashism and fails there.

```groovy
sh 'helm upgrade --install myapp ./chart --set image.tag=$(git rev-parse --short=7 HEAD)'
```

Or start the script with `#!/usr/bin/env bash`.

#### 5.11 Archiving the Terraform plan leaks secrets

Deck page 39 runs `terraform plan -out=tfplan` then `archiveArtifacts artifacts: 'tfplan'`.

A saved plan contains resource attribute values in the clear — passwords, connection strings,
key material that flowed through variables. Archived, it is downloadable by anyone with
Jenkins read access. In a deck with a whole chapter on secret management, this is the sharpest
irony in the material.

If you need the diff for review, archive `terraform show -no-color tfplan` filtered, or keep
the plan only in the workspace for the gated apply.

#### 5.12 `--enforce-lockfile` is defeated by the line above it

Deck pages 136 and 149:

```bash
flutter pub get
flutter pub get --enforce-lockfile
```

**Verified:** plain `pub get` can rewrite `pubspec.lock`. The `--enforce-lockfile` check then
validates against the file that was just regenerated, so it always passes. Run
`flutter pub get --enforce-lockfile` **alone**.

#### 5.13 The deck contradicts its own best-practice slides

| Deck says | Deck does |
|---|---|
| "Use specific image tags, not `latest`" (p.126) | `aquasec/trivy:latest`, `semgrep/semgrep:latest`, `zricethezav/gitleaks:latest`, `prom/prometheus:latest`, `grafana/grafana:latest`, `mingc/android-build-box:latest` |
| "Pin provider/module versions" (p.42) | `version = ">= 5.0"` — accepts the next major. Use `~> 5.0` |
| "Scan IaC with tfsec/Checkov to catch misconfigurations" (p.42) | The sample security group on p.29 opens ingress to `0.0.0.0/0` — tfsec fails it (AVD-AWS-0107) |

Not fatal, but if you copy the examples you inherit the anti-patterns the deck warns about
two chapters later.

#### 5.14 Playwright's `BASE_URL` points at a host that does not exist

Deck pages 90–93. `BASE_URL = "http://staging-${BUILD_NUMBER}.example.com"`, but the deploy
stage merely runs `docker run -p 3000:3000` on the agent. Nothing creates that DNS record or
ingress. The tests target a hostname that never resolves.

With `--network=host` on the Playwright agent, the reachable address is `http://localhost:3000`.
(Note `--network=host` is Linux-only; it silently does nothing useful on Docker Desktop.)

Also: both E2E stages emit `playwright-results.xml`, so the cross-browser run overwrites the
Chromium results before `junit` collects them.

#### 5.15 Gitleaks scans 10 commits, not "full git history"

Deck page 120 — the comment says *"Scans the full git history, not just the working tree"*,
the code says `--log-opts "HEAD~10..HEAD"`. Drop `--log-opts` to actually scan all history.

#### 5.16 The sample postmortem's numbers do not reconcile

Deck page 59 states three figures that cannot all be true:

- **"45 minutes of elevated error rate"** — but the timeline runs 10:14 → 10:41 = **27 minutes**.
- **"8.3% of payment requests failed"** over that window — 45 min × 8.3% ≈ **3.7 minutes** of
  budget burn, not the **31 minutes** claimed.
- 31 / 43.2 = 72% ✓ — that line is internally consistent; it just does not follow from the others.

As a teaching artifact this matters: the whole point of the page is showing how to account for
error-budget burn, and the arithmetic is the lesson. Burn = duration × failure ratio.

#### 5.17 Auto-rollback fires on lint failures

Deck page 40:

```groovy
post { failure { sh 'helm rollback myapp 0 --namespace ${TF_VAR_environment} || true' } }
```

Pipeline-level `post { failure }` runs when **any** stage fails — including `terraform fmt
-check` or `helm lint`, long before anything was deployed. That rolls back a perfectly healthy
release because someone's formatting was off. Scope the rollback to the deploy stage's own
`post { failure }` block.

### Currency — correct when written, dated now

| # | Item | Status |
|---|---|---|
| 5.18 | `publishCoverage` + `coberturaAdapter` (used 4×) | Code Coverage API plugin is **end-of-life**; use `recordCoverage(tools: [[parser: 'COBERTURA']])` from the Coverage plugin |
| 5.19 | "DORA four key metrics" | A **fifth** metric was added in 2021 (reliability); later reports rework the stability pair and rename MTTR to *Failed Deployment Recovery Time*. The deck's `<5%` CFR figure is close to the 2024 elite number, but the *2019* band was 0–15% — quote a report year |
| 5.20 | `dynamodb_table` for Terraform state locking | Superseded by native S3 locking `use_lockfile = true` (experimental in 1.10, GA in 1.11, `dynamodb_table` deprecated) |
| 5.21 | `safety check` | Deprecated in Safety 3.x in favour of `safety scan` |
| 5.22 | `zricethezav/gitleaks`, `gitleaks detect` | Canonical org is now `gitleaks/gitleaks` (`ghcr.io/gitleaks/gitleaks`); `detect` is superseded by `git` / `dir` / `stdin` subcommands as of v8.19 |

### Verified sound

Traced and found correct, so you can rely on these: CALMS, STRIDE, the SLI/SLO/SLA
relationship and its worked example, the error-budget arithmetic (43,200 min → 43.2 min at
99.9%), the toil definition and 50% rule, the Helm/Ansible/Terraform syntax samples, the k6
threshold script, the `key.properties` heredoc quoting (triple-single-quote is correct), the
`cleanup { rm -f android/key.properties }` teardown, `flutter analyze --fatal-infos
--fatal-warnings`, `helm rollback myapp 0` semantics, and the Jenkins apt-repository install
commands.

### Verdict

**Concepts: ship. Code samples: fix-then-ship.** The conceptual half of this deck is accurate
and well-organised — it is a genuinely good map of the territory. The executable half needs
the corrections above before anything is copied into a real Jenkinsfile; the four blockers
(§5.1, §5.2, §5.3, §5.5) each produce a pipeline that appears to work while doing nothing, or
one that hangs.

---

## 6. Quick reference

### 6.1 Declarative pipeline skeleton

```groovy
pipeline {
    agent any                            // where to run
    environment { APP_NAME = 'myapp' }   // env vars
    options {
        timeout(time: 30, unit: 'MINUTES')
        buildDiscarder(logRotator(numToKeepStr: '10'))
        disableConcurrentBuilds()        // essential before any deploy/apply stage
    }
    stages {
        stage('Name') { steps { sh 'echo hello' } }
    }
    post {
        always   { }   // runs regardless
        success  { }
        failure  { }
        unstable { }   // tests failed but build did not error
        cleanup  { }   // runs last, even after failure — use for secret teardown
    }
}
```

### 6.2 Agent directives

```groovy
agent any                                          // any available executor
agent none                                         // each stage declares its own
agent { label 'linux-build' }                      // specific labelled agent
agent { docker { image 'python:3.11.9-slim' } }    // in a container (pin the tag)
agent { docker { image 'node:20-alpine'; args '--ipc=host' } }
agent { kubernetes { yaml "..." } }                // a K8s pod
```

### 6.3 `when` conditions — and the two modifiers that matter

```groovy
when { branch 'main' }
when { anyOf { branch 'main'; branch 'release/*' } }
when { expression { env.BUILD_NUMBER.toInteger() % 2 == 0 } }

when { beforeAgent true;  branch 'main' }   // evaluate BEFORE allocating the agent
when { beforeInput true;  branch 'main' }   // evaluate BEFORE prompting a human  ← §5.1
```

### 6.4 Credentials

```groovy
// Username + password
withCredentials([usernamePassword(credentialsId: 'db-credentials',
                                  usernameVariable: 'DB_USER',
                                  passwordVariable: 'DB_PASS')]) {
    sh 'connect-to-db --user "$DB_USER" --pass "$DB_PASS"'
}

// Secret file + secret text
withCredentials([file(credentialsId: 'android-keystore', variable: 'KEYSTORE_FILE'),
                 string(credentialsId: 'android-key-password', variable: 'KEY_PASS')]) { }

// HashiCorp Vault
withVault(configuration: [vaultUrl: 'https://vault.example.com'],
          vaultSecrets: [[path: 'secret/myapp/prod',
                          secretValues: [[envVar: 'DB_PASSWORD', vaultKey: 'db_password']]]]) { }
```

Rules: always quote `"$VAR"` in shell; never `echo` a secret; use `'''` not `"""` around
scripts that reference secrets; tear down credential files in `cleanup { }`.

### 6.5 Useful Groovy snippets

```groovy
def content = readFile('config.yml')
writeFile file: 'output.txt', text: 'hello'
def version = sh(script: 'git describe --tags', returnStdout: true).trim()
def code    = sh(script: './maybe-fails.sh', returnStatus: true)   // capture exit code, don't fail

try { sh 'risky-command' }
catch (e) { echo "failed: ${e}"; currentBuild.result = 'UNSTABLE' }
```

### 6.6 Boat's Jenkins credentials

| Credential ID | Type | Contents |
|---|---|---|
| `android-keystore` | Secret File | `.jks` / `.p12` keystore |
| `android-store-password` | Secret Text | Keystore password |
| `android-key-password` | Secret Text | Key entry password |
| `android-key-alias` | Secret Text | Key alias name |
| `firebase-app-id` | Secret Text | `1:xxx:android:yyy` |
| `firebase-token` | Secret Text | `firebase login:ci` token |
| `google-play-service-account` | Secret File | Service account JSON from Play Console |

### 6.7 Security tool matrix

| Category | Dart/Flutter | Python | Node.js | Universal |
|---|---|---|---|---|
| Secrets | — | `detect-secrets` | — | **Gitleaks** |
| SAST | `dart analyze`, `very_good_analysis` | Bandit, Semgrep | `eslint-plugin-security`, Semgrep | Semgrep |
| SCA | `osv-scanner`, Snyk, `dependency_validator` | `pip-audit`, Safety | `npm audit`, Retire.js | **Trivy** |
| Container | — | — | — | Trivy |
| DAST | — | — | — | OWASP ZAP |

Recommended order — cheapest and earliest first:

```
Secrets  →  SAST  →  SCA  →  Container Scan  →  DAST
every       every    every    after docker      after deploy
commit      push     push     build             to staging
```

### 6.8 Incident severity

| Sev | Impact | Response |
|---|---|---|
| SEV-1 | Down for all users | < 5 min |
| SEV-2 | Major feature broken | 15 min |
| SEV-3 | Degraded performance | 1 hour |
| SEV-4 | Minor / cosmetic | Next business day |

Roles: **Incident Commander** (coordinates) · **Technical Lead** (investigates and fixes) ·
**Comms Lead** (status page, stakeholders) · **Scribe** (timeline in real time).

The IC does not debug. If the IC is head-down in a stack trace, there is no IC.

### 6.9 Glossary

| Term | Meaning |
|---|---|
| **CI** | Auto build + test on every commit to a shared repo |
| **Continuous Delivery** | Every passing build is *deployable*; a human triggers prod |
| **Continuous Deployment** | Every passing build *is deployed*; no human gate |
| **DAST** | Dynamic analysis — scans a *running* app |
| **SAST** | Static analysis — scans *source code* |
| **SCA** | Software Composition Analysis — known CVEs in *dependencies* |
| **SBOM** | Machine-readable inventory of every component in an artifact |
| **DORA** | The four delivery-performance metrics |
| **SLI / SLO / SLA** | Measured value / internal target / customer contract |
| **Error budget** | `1 − SLO`, expressed as allowed downtime per window |
| **Toil** | Manual, repetitive, automatable ops work with no lasting value |
| **Drift** | Real infrastructure diverging from its declared state |
| **GitOps** | Git as the single source of truth; an agent reconciles reality to it |
| **Blue/Green** | Two identical envs; switch traffic atomically between them |
| **Canary** | Route a small % of traffic to the new version first |
| **Idempotent** | Running it twice has the same effect as running it once |

### 6.10 Deck chapter map

| Deck pages | Topic | Covered here |
|---|---|---|
| 4–10 | DevOps fundamentals, CALMS, DORA | §2.1, §2.2 |
| 11–22 | DevSecOps, shift-left, SBOM, maturity model | §2.3, §3.2 |
| 23–42 | IaC: Terraform, Ansible, Helm, GitOps | §3.4 |
| 43–64 | SRE: SLO, error budgets, observability, chaos | §2.4–2.6, §3.5 |
| 65–74 | CI/CD concepts and pipeline stages | §6.9 |
| 75–104 | Jenkins: architecture, install, Jenkinsfile, testing | §4 P1–P2, §6.1–6.5 |
| 105–121 | Security analysis pipelines per language | §6.7, §4 P3 |
| 122–133 | Deployment patterns, best practices, summary | §3.1, §3.2 |
| 134–155 | **Dart/Flutter & Android build pipeline** | §4 P0, P4, P5 |

---

## Provenance

| | |
|---|---|
| **Source** | `devops_cicd_jenkins_presentation.pdf` — 155 pages, *DevOps & CI/CD with Jenkins*, Chavatik Thorarit (6610110066) |
| **Not used** | `Loop paragraph.loop` — Microsoft Loop binary container, not machine-readable here. If it holds notes you want folded in, export it to `.md` or `.docx` first |
| **Method** | Full text extraction → knowledge distillation → scrutiny pass (§5) with each finding traced to official documentation |
| **Verified against** | jenkins.io pipeline & security docs, Jenkins plugin docs, dart.dev, developer.hashicorp.com, Prometheus/PromLabs, Trivy, Yelp/detect-secrets, eslint-plugin-security, gitleaks, dora.dev |
| **Generated** | 2026-09-09 |

Findings in §5 are marked **Verified** where a citation confirmed them. The `cobertura` Dart
package used on deck page 138 was checked and **does exist** on pub.dev — it is obscure but
valid, so it is not listed as a defect.

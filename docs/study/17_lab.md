# 17 — Hands-on Lab: รันทุกอย่างด้วยมือตัวเอง แล้วดูว่าแต่ละหน้าบอกอะไร

> บทนี้ตอบคำถาม: **"ต้องพิมพ์คำสั่งอะไร ตามลำดับไหน ถึงจะได้เปิดดูหน้าเว็บ frontend, เรียก backend, ดู dashboard, รัน test, และอ่าน pipeline ได้ — และแต่ละคำสั่งมีไว้ทำไม"**

---

## 🧭 ก่อนอ่าน

- **ต้องอ่านก่อน:** [00_index.md](00_index.md) (terminal, HTTP, JSON), [02_architecture.md](02_architecture.md) (ภาพรวมชิ้นส่วน)
- **ควรเปิดคู่กัน:** [14_devops.md](14_devops.md) (Docker/Compose/Nginx), [15_cicd.md](15_cicd.md) (pipeline), [12_testing.md](12_testing.md) (test แต่ละระดับ)
- **เวลาที่ใช้:** ~2–3 ชั่วโมง (รอบแรก download image + build นาน, รอบหลังไม่กี่นาที)
- **เครื่องที่ใช้ทดลองจริงตอนเขียนบทนี้:** macOS (Apple Silicon), Docker Desktop 27.3.1 — **ทุก output ในบทนี้มาจากการรันจริงวันที่ 2026-09-25** (ตัดให้สั้นลง แต่ไม่ได้แต่ง)
- **อ่านจบแล้วคุณจะ…**
  - เปิด stack ทั้งชุด (Nginx + API ×3 + Postgres + Redis ×2 + etcd + worker + Bull-Board) ด้วย Docker Compose ได้เอง และปิดได้โดยไม่ไปพังของคนอื่น
  - ทำ flow ตั้งร้านใหม่ได้ครบ: สร้าง platform admin → login → สร้าง tenant → login เป็นเจ้าของร้าน → เรียก API จริง
  - รู้ว่า URL/port ไหนแสดงอะไร และรหัสผ่านของแต่ละหน้ามาจากไหน
  - พิสูจน์ด้วยตาตัวเองว่า RLS ทำให้ database คืน 0 แถวเมื่อไม่ได้บอกว่าเป็นร้านไหน
  - รัน test ทั้งสองฝั่ง และอ่าน log ของ job ที่แดงบน GitHub Actions ได้ (แบบอ่านอย่างเดียว)

> 📂 **Output ดิบของทุกคำสั่งในบทนี้** เก็บไว้ที่ scratchpad ของ session ที่เขียนบท (`lab_outputs/`) — ไม่ได้ commit เข้า repo
> เพราะมี token/รหัสผ่านชั่วคราวปนอยู่ ในบทนี้แสดงเฉพาะส่วนที่ปลอดภัย และ token ทุกตัวถูกตัดเป็น `eyJ…(ตัดทอน)`

---

## 🧱 ปูพื้นฐาน (ภาพรวมก่อนลงมือ)

### 1. "Lab" ต่างจากการอ่านเอกสารยังไง

อ่านเอกสารเหมือนอ่านคู่มือทำอาหาร — lab คือเข้าครัวจริง ซึ่งจะเจอสิ่งที่คู่มือไม่ได้เขียน:
เตาแก๊สบ้านเราไม่เหมือนในรูป, ของในตู้เย็นหมด, มีคนอื่นใช้หม้อใบเดียวกันอยู่ ฯลฯ
บทนี้ตั้งใจเก็บ **"สิ่งที่คู่มือไม่ได้บอก"** ที่เจอจริงระหว่างทำ มาเขียนเป็นกล่อง **🩹 ถ้าเจอแบบนี้** ทุกขั้น
(ตอนเขียนบทนี้เจอปัญหาจริง 5 เรื่อง — ทุกเรื่องมี error จริง + วิธีแก้ที่ลองแล้วได้ผล)

ทุก step ในบทนี้มีรูปแบบเดียวกัน:

```
คำสั่ง  →  ทำไมต้องรัน  →  ควรเห็นอะไร (output จริง)  →  พังได้ยังไง / แก้ยังไง
```

### 2. ศัพท์ที่ต้องใช้ตลอดบท

| ศัพท์ | ความหมายสั้นๆ | analogy |
|---|---|---|
| **container** | โปรแกรม 1 ตัวที่รันในกล่องแยก มี filesystem ของตัวเอง | ห้องเช่า 1 ห้อง |
| **image** | "แม่พิมพ์" ที่ใช้สร้าง container | แบบแปลนห้อง |
| **Docker Compose** | เครื่องมือเปิด container หลายตัวพร้อมกันจากไฟล์ YAML ไฟล์เดียว | ผู้จัดการตึกที่เปิดทุกห้องตามผัง |
| **compose project** (`-p`) | "ชื่อกลุ่ม" ของ container/volume/network ชุดหนึ่ง | ชื่อตึก — ตึกคนละชื่อ ห้องชื่อซ้ำกันได้ |
| **volume** | ที่เก็บข้อมูลถาวรของ container (ลบ container แล้วข้อมูลยังอยู่) | ตู้เซฟใต้ดิน |
| **port** | "ประตู" หมายเลขหนึ่งบนเครื่อง ที่โปรแกรมรอรับการเชื่อมต่อ | เลขช่องไปรษณีย์ |
| **loopback** (`127.0.0.1` / `localhost`) | ที่อยู่ที่หมายถึง "เครื่องนี้เอง" เท่านั้น เครื่องอื่นเข้าไม่ได้ | ประตูหลังบ้านที่เปิดจากในบ้านได้อย่างเดียว |
| **health check** | URL ที่ตอบว่า "ยังมีชีวิตอยู่ไหม / พร้อมรับงานไหม" | ถามพนักงานว่า "มาทำงานรึยัง" |
| **reverse proxy** | ตัวรับ request หน้าบ้าน แล้วส่งต่อไป server หลังบ้าน (ที่นี่คือ **Nginx**) | พนักงานต้อนรับหน้าร้าน |
| **self-signed certificate** | ใบรับรอง HTTPS ที่เราเซ็นเอง ไม่มีหน่วยงานกลางรับรอง → browser จะเตือน | บัตรประชาชนที่ทำเอง |
| **basic auth** | ถาม username/password แบบง่ายที่สุดของ HTTP ก่อนให้เข้า | ยามถามชื่อ-รหัสหน้าประตู |

### 3. แผนที่: URL / port ไหนแสดงอะไร

นี่คือภาพที่คุณจะมีในมือหลังทำ Lab 2–4 เสร็จ (ทุกอย่างรันบนเครื่องคุณเอง):

```mermaid
flowchart LR
    subgraph HOST["เครื่องของคุณ (host)"]
        B["Browser / curl"]
        G["gh CLI"]
    end

    subgraph STACK["compose project: studylab"]
        NGX["nginx<br/>0.0.0.0:80 → 301<br/>0.0.0.0:443 (TLS)"]
        API["api-1 / api-2 / api-3<br/>:3000 (ภายใน network)"]
        WEB["ไฟล์ Flutter web<br/>/usr/share/nginx/html"]
        BB["bull-board<br/>127.0.0.1:3100"]
        PROM["prometheus<br/>127.0.0.1:9090"]
        GRAF["grafana<br/>127.0.0.1:3000"]
        PG[("postgres<br/>ไม่เปิด port")]
        RC[("redis-cache")]
        RQ[("redis-queue")]
        ETCD[("etcd")]
        NE["node-exporter"]
    end

    GH["GitHub Actions<br/>(อ่านอย่างเดียว)"]

    B -- "https://localhost/" --> NGX
    NGX -- "/  (หน้าเว็บ)" --> WEB
    NGX -- "/api/  /health/" --> API
    NGX -. "/metrics → 404" .-> NGX
    B -- "http://127.0.0.1:3100" --> BB
    B -- "http://127.0.0.1:9090" --> PROM
    B -- "http://127.0.0.1:3000" --> GRAF
    API --> PG
    API --> RC
    API --> RQ
    API --> ETCD
    PROM -- "scrape /metrics ทุก 15s" --> API
    PROM --> NE
    GRAF --> PROM
    BB --> RQ
    G --> GH
```

| URL | เห็นอะไร | ต้อง login ไหม / รหัสมาจากไหน | Lab |
|---|---|---|---|
| `https://localhost/` | หน้าเว็บ POS (Flutter) — ถ้ายังไม่ได้ใส่ไฟล์เว็บจะเห็น "Welcome to nginx!" | browser เตือน cert (self-signed); ในแอปใช้ user ของร้าน (`labowner`) ที่สร้างใน Lab 2 | 3 |
| `https://localhost/health/live` | `{"status":"up"}` — process ยังอยู่ | ไม่ต้อง | 2 |
| `https://localhost/health/ready` | สถานะ Postgres + Redis ทั้งสอง | ไม่ต้อง | 2 |
| `https://localhost/api/v1/...` | API ของร้าน (JSON) | `Authorization: Bearer <accessToken>` จาก `POST /api/v1/auth/token` | 2 |
| `https://localhost/api/v1/platform/...` | API ของผู้ดูแลแพลตฟอร์ม (สร้างร้าน) | **เข้าได้จาก loopback เท่านั้น** + token จาก `platform/auth/token`; user สร้างด้วย `bootstrap-admin.js` | 2 |
| `https://localhost/metrics` | **404 เสมอ** (ตั้งใจปิด) | — | 4 |
| `http://127.0.0.1:3100` | Bull-Board — คิวงาน BullMQ (`sale-post` ฯลฯ) | basic auth: `BULL_BOARD_USER` / `BULL_BOARD_PASSWORD` ใน `server/.env` | 4 |
| `http://127.0.0.1:9090` | Prometheus — target, query metric | ไม่มี login (จึงเปิดแค่ loopback) | 4 |
| `http://127.0.0.1:3000` | Grafana — dashboard "Srisurart POS — overview" | `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` ใน `server/.env` | 4 |
| (ไม่มี URL) Postgres | ใช้ `docker compose exec postgres psql` | `POS_APP_PASSWORD` / `POSTGRES_PASSWORD` ใน `server/.env` | 5 |
| github.com/…/actions | ผล CI/CD | `gh auth login` ของคุณเอง (read-only พอ) | 7 |

> 💡 สังเกต: **มีแค่ Nginx (80/443) ที่เปิดให้ทุก interface** — ที่เหลือเปิดแค่ `127.0.0.1` หรือไม่เปิดเลย
> นี่คือการตัดสินใจด้านความปลอดภัย ไม่ใช่ความบังเอิญ (`server/docker-compose.yml:77`, `:188`; `deploy/compose/monitoring.yml:80`, `:111`)
> บน VM จริงเข้าหน้าพวกนี้ผ่าน SSH tunnel: `ssh -L 3000:127.0.0.1:3000 -L 9090:127.0.0.1:9090 -L 3100:127.0.0.1:3100 deploy@<vm>` (`server/README.md`, หัวข้อ Monitoring overlay)

---

## 🔥 ปัญหาจริงของร้าน: ทำไมต้องมี lab แบบนี้

- ทีมมี 3 คน (`NuimanLP`, `LomerAlloys`, `PattaraponKitcharoen`) ทุกคนต้องแตะทั้ง frontend, backend และ CI/CD (กฎของวิชา 2026-09-05)
  → ทุกคนต้อง **เปิดระบบทั้งชุดบนเครื่องตัวเองได้** ไม่ใช่รอเครื่อง VM กลาง
- VM demo (`mob04`) ยัง deploy อัตโนมัติไม่ได้ เพราะ firewall คณะ (FortiGate) ดักใบรับรองของ `ghcr.io` (ดู [15_cicd.md](15_cicd.md))
  → **เครื่องของคุณเองคือที่เดียวที่เห็นระบบทำงานครบ** ในตอนนี้
- stack มี 13 container + 5 one-shot job — ถ้าไม่รู้ลำดับและเหตุผล จะติดตั้งแล้วเจอ error ที่อ่านไม่ออก แล้วเลิก

---

## ⚖️ ทางเลือก → ทำไมเลือกวิธีในบทนี้

| วิธีรัน backend | ข้อดี | ข้อเสีย | ใช้เมื่อ |
|---|---|---|---|
| **A. Docker Compose ทั้ง stack** (บทนี้) | เหมือนของจริงบน VM ที่สุด (Nginx, 3 instance, TLS, health) คำสั่งเดียว | กิน RAM ~1 GB+, build ครั้งแรก ~3 นาที | อยากเห็นระบบทั้งชุด / ทดสอบ Nginx / ทำ load test |
| B. Compose แค่ datastore + `pnpm start:dev` บนเครื่อง | แก้โค้ดแล้ว reload ทันที | ไม่มี Nginx/TLS/3 instance — พฤติกรรมไม่เหมือนจริง | เขียนโค้ด backend ทุกวัน (`server/README.md` "Local development without Docker") |
| C. ใช้ VM `mob04` | ของจริง | ต้องอยู่ในเครือข่ายคณะ, deploy ยังติด FortiGate | demo วันจริง |

**เพราะ** เป้าของบทนี้คือ "ดูทุกหน้าให้ครบ" → **จึงเลือก A** → **ราคาที่จ่าย** คือ RAM และเวลาบิลด์ครั้งแรก
และเพราะเครื่องของคุณอาจมีโปรเจกต์อื่นรันอยู่ → **ทุกคำสั่งใช้ `-p studylab`** → ราคาคือต้องพิมพ์ยาวขึ้นนิดหน่อย

---

## 🧪 Lab 0 — เช็คเครื่องมือ (5 นาที)

### 🧱 ทำไมต้องเช็คก่อน
error ครึ่งหนึ่งที่มือใหม่เจอคือ "version ไม่ตรง" — เช่น `package.json` ของ server บอก `"engines": { "node": ">=22" }`
และ `"packageManager": "pnpm@10.34.5"` ถ้า Node เก่ากว่านั้น `pnpm install` จะพังด้วย error ที่ไม่บอกตรงๆ ว่าเป็นเพราะ version

### คำสั่ง
```bash
git --version
docker --version
docker compose version
flutter --version
dart --version
node --version
pnpm --version        # หรือ corepack pnpm --version
gh --version
k6 version            # ใช้ในบท performance เท่านั้น ไม่มีก็ได้
docker info --format '{{.ServerVersion}} {{.NCPU}}cpu {{.MemTotal}}'   # Docker daemon เปิดอยู่ไหม
```

### ควรเห็น (ของจริงจากเครื่องที่เขียนบท)
```
git version 2.45.2
Docker version 27.3.1, build ce12230
Docker Compose version v2.30.3-desktop.1
Flutter 3.44.3 • channel stable
Tools • Dart 3.12.2 • DevTools 2.57.0
Dart SDK version: 3.12.2 (stable) on "macos_arm64"
v22.23.2
10.34.5
gh version 2.53.0 (2024-07-17)
k6 v2.2.0 (commit/devel, go1.26.5, darwin/arm64)
27.3.1 8cpu 6213177344        ← Docker ได้ RAM ~6 GB
```

### เช็ค port ว่าง (สำคัญ — stack นี้ต้องใช้ 80, 443, 3100, 3000, 9090)
```bash
for p in 80 443 3100 3000 9090; do lsof -nP -iTCP:$p -sTCP:LISTEN | tail -n +2; done
docker ps --format '{{.Names}}\t{{.Ports}}'
docker network ls
```
ถ้าไม่มีบรรทัดไหนออกมาจาก `lsof` = ว่างทั้งหมด

> 🩹 **ถ้าเจอแบบนี้:** port ถูกโปรแกรมอื่นใช้อยู่ → **อย่าไป kill โปรแกรมของคนอื่น**
> ปิดโปรแกรมของตัวเองที่ใช้ port นั้น หรือถ้าเป็นของคนอื่นบนเครื่องร่วมกัน ให้คุยกันก่อน
> (CLAUDE.md: "Never `docker compose down -v` on a shared Docker daemon" — เคยลบ volume ของ session อื่นมาแล้ว)

---

## 🧪 Lab 1 — เปิด frontend แบบเร็วที่สุด (build web แล้วเสิร์ฟเป็นไฟล์)

### 🧱 ปูพื้น: Flutter web build คืออะไร
`flutter build web` แปลงโค้ด Dart ทั้งแอปเป็นไฟล์ static (HTML + JavaScript + WebAssembly) ในโฟลเดอร์ `build/web`
ไฟล์พวกนี้ **ไม่ต้องมี server พิเศษ** — web server อะไรก็ได้ที่ส่งไฟล์ได้ก็พอ (เหมือนเอาใบปลิวไปวางที่ไหนก็อ่านได้)

### คำสั่ง
```bash
cd frontend
flutter pub get                               # โหลด package ตาม pubspec.lock
flutter build web --no-tree-shake-icons       # คำสั่งเดียวกับที่ CI ใช้
cd build/web && python3 -m http.server 8765 --bind 127.0.0.1
# แล้วเปิด http://127.0.0.1:8765/
```

**ทำไม `--no-tree-shake-icons`:** tree-shaking คือการตัด icon ที่ "ดูเหมือน" ไม่ได้ใช้ทิ้งเพื่อให้ไฟล์เล็ก
แต่ถ้าโค้ดเลือก icon แบบ dynamic (ไม่ใช่ค่าคงที่) ตัว compiler จะตัดผิด — repo นี้จึงปิดมันทุกที่ (ทั้ง CLAUDE.md และ `.github/workflows/flutter.yml:215`)

**ทำไมไม่ใช้ `flutter run -d chrome`:** ใช้ได้ถ้า browser ของคุณรองรับ (ดู `frontend/README.md` หัวข้อ Web)
แต่ build + เสิร์ฟไฟล์ให้ผลเหมือน "ของที่ส่งจริง" มากกว่า และไม่ต้องเปิด Chrome ผ่าน Flutter

### ควรเห็น
```
Got dependencies!
52 packages have newer versions incompatible with dependency constraints.
Compiling lib/main.dart for the Web...                            122.6s
✓ Built build/web
```
build ครั้งแรกบนเครื่องทดลองใช้ **126 วินาที** (ครั้งต่อไปเร็วขึ้นมาก — build แบบมี dart-define ใน Lab 3 ใช้ 40 วินาที) ได้โฟลเดอร์ขนาด ~47 MB

เปิดใน browser แล้ว (ทดลองจริงผ่าน browser pane): **แอปบูตขึ้น** เห็นแถบบน "Srisurart", ชิป "ออนไลน์", ชื่อ "Cashier",
วันที่แบบไทย "ศ. 25 ก.ย. 2569" และเมนูซ้ายแนวตั้ง — **แต่กลางจอขึ้นว่า**
```
โหลดสินค้าไม่สำเร็จ: TypeError: Failed to fetch
```
และใน console ของ browser:
```
Access to fetch at 'http://localhost:3000/api/v1/categories' from origin 'http://127.0.0.1:8765'
has been blocked by CORS policy ...
Using WasmStorageImplementation.sharedIndexedDb due to missing browser features:
{MissingBrowserFeature.dedicatedWorkersInSharedWorkers, MissingBrowserFeature.sharedArrayBuffers}
```

### 🔍 ทำไมแอป "offline-first" ถึงวิ่งไปหา server?
นี่คือสิ่งที่ lab สอนได้แต่เอกสารไม่ได้บอก — ไล่โค้ดจริง:

```dart
// frontend/lib/presentation/repositories/repository_providers.dart:58-59
  bool useApi = const bool.fromEnvironment('USE_API_WRITES'),
  bool useApiRepositories = true,
```
```dart
// frontend/lib/core/network/api_client.dart:20
  baseUrl = (baseUrl ?? const String.fromEnvironment('API_BASE_URL', defaultValue: 'http://localhost:3000'))
```

- `USE_API_WRITES` (การ "เขียน" บิล/คืนของ/กะ) เป็น **false** ถ้าไม่ได้ส่ง dart-define — เขียนลง Drift ในเครื่อง
- แต่ `useApiRepositories = true` เป็นค่า default → การ **อ่าน** สินค้า/ลูกค้า/ช่าง ใช้ `Api*Repository` ที่ดึงจาก server เสมอ
- และ server default คือ `http://localhost:3000` — ซึ่งถ้าคุณเปิด Grafana (Lab 4) ไว้ port 3000 คือ **Grafana** ไม่ใช่ API! (ที่เครื่องทดลองเป็นอย่างนั้นพอดี จึงได้ CORS error)

**สรุป:** บน branch `main` ตอนนี้ แอปไม่ได้เป็น offline-only แล้ว (มันคือสาย multi-tenant — ดู CLAUDE.md "Branch strategy")
ถ้าอยากเห็นแอป offline-first ล้วนแบบที่ร้านใช้อยู่จริง ให้ build จาก branch `POC_sample_offline_first`
(ไม่ได้ทดลองในบทนี้ — ใช้ `git worktree add ../poc POC_sample_offline_first` แล้ว build ในนั้น จะไม่รบกวน checkout หลัก)

> 🩹 **ถ้าเจอแบบนี้:** `LinkError: WebAssembly.instantiate(): Import #10 "dart" "xFileControl"`
> คือ bug #266 (browser ที่ไม่มี `dedicatedWorkersInSharedWorkers`) — ถูกแก้แล้วใน PR #310 และ issue ปิด 2026-09-19
> ถ้ายังเจอ ให้เช็คว่า checkout ของคุณใหม่กว่า commit นั้น และ `web/WEB_DB_ASSET_VERSIONS.txt` ตรงกับ `pubspec.lock`
> ในการทดลองของบทนี้ **ไม่เจอ** LinkError — Drift fallback ไปใช้ `sharedIndexedDb` ได้

> 🩹 **สิ่งที่เห็นแต่ยังไม่ได้ตามต่อ (บอกตรงๆ):** ใน browser pane ที่ใช้ทดลอง ป้ายชื่อเมนูซ้ายแสดงเป็นกล่อง □ แทนตัวอักษรไทย
> (ข้อความกลางจอเป็นไทยปกติ), console มี `Uncaught Error` 5 บรรทัด และ service worker ลงทะเบียนไม่สำเร็จ
> ยังไม่ได้พิสูจน์สาเหตุ — เรื่อง font fallback ของ web build ถูกบันทึกไว้ใน CLAUDE.md ว่า #271 "ยังไม่ปิดสนิท"

---

## 🧪 Lab 2 — เปิด backend ทั้ง stack + ตั้งร้านแรก (หัวใจของบทนี้)

### 🧱 ปูพื้น: stack นี้มีอะไรบ้าง และเปิดตามลำดับไหน
`server/docker-compose.yml` นิยาม service ไว้ 2 แบบ:

- **service ที่รันค้าง:** `nginx`, `api-1..3`, `worker`, `bull-board`, `postgres`, `redis-cache`, `redis-queue`, `etcd`
- **one-shot job** (รันครั้งเดียวแล้วจบด้วย exit 0): `certgen` (สร้าง cert), `htpasswd-gen` (รหัสสำหรับ k6 remote-write), `migrate` (สร้างตาราง), `etcd-init` (เปิด auth ใน etcd)

ลำดับถูกบังคับด้วย `depends_on` + `condition`:

```
postgres (healthy) ──► migrate (completed) ──► api-1/2/3 (healthy) ──► nginx
redis-cache/queue (healthy) ─────────────────┘                        ▲
certgen, htpasswd-gen (completed) ─────────────────────────────────────┘
etcd (healthy) ──► etcd-init          (ไม่มีใครรอ etcd-init — API ต้องบูตได้แม้ etcd พัง)
```

### Step 2.1 — สร้าง `.env` (ไฟล์ความลับ) แบบไม่หลุดเข้า Git

```bash
cd server
git check-ignore -v .env          # ต้องเห็นว่า .gitignore บล็อกไว้
cp .env.example .env
# เปลี่ยนรหัส dev ทุกตัวเป็นค่าสุ่ม (macOS ใช้ sed -i '' ; Linux ใช้ sed -i)
for k in POSTGRES_PASSWORD POS_APP_PASSWORD REDIS_PASSWORD JWT_PLATFORM_SECRET \
         ETCD_ROOT_PASSWORD BULL_BOARD_PASSWORD GRAFANA_ADMIN_PASSWORD \
         K6_REMOTE_WRITE_BASIC_AUTH_PASSWORD; do
  sed -i '' "s|^$k=.*|$k=$(openssl rand -hex 16)|" .env
done
chmod 600 .env
git status --short .env           # ต้องไม่มี output = Git มองไม่เห็นไฟล์นี้
```
```
.gitignore:61:/server/.env	.env
```

**ทำไม:** Compose ใช้ไฟล์ `.env` แทนค่า `${POSTGRES_PASSWORD:?...}` ใน YAML — รูปแบบ `:?` แปลว่า
"ถ้าไม่ได้ตั้งค่า ให้หยุดทันที" (`server/docker-compose.yml` บรรทัดต้นๆ ของ `x-app-env`) เพื่อไม่ให้ระบบบูตด้วยรหัสว่าง
ค่า `dev-only-...` ใน `.env.example` ใช้ได้บนเครื่องตัวเอง แต่การสุ่มใหม่ทำให้ติดนิสัยที่ถูกตั้งแต่แรก

⚠️ **แต่มีราคา:** e2e test ของ server **hardcode รหัส `dev-only-*`** ไว้ (`server/test/support/fixture.ts:96`, `:104-105`)
ถ้าคุณสุ่มรหัสแบบนี้ `pnpm test:e2e` จะต่อ database ไม่ได้ — ดู Lab 6
(`JWT_PRIVATE_KEY`/`JWT_PUBLIC_KEYS` ในบทนี้ใช้ dummy key ใน `.env.example` ตามเดิม ซึ่งเขียนกำกับไว้ว่า "local/CI use only")

### Step 2.2 — เปิด stack

คำสั่งตาม README (`server/README.md` หัวข้อ Run) บวก `-p studylab`:
```bash
docker compose -p studylab up -d --build
```

**ทำไม `-p studylab`:** ไฟล์ compose ตั้ง `name: srisurart-pos` ไว้ (`server/docker-compose.yml:16`) ถ้าไม่ใส่ `-p`
container/volume จะชื่อ `srisurart-pos_*` — ชนกับของที่คนอื่น (หรือตัวคุณเมื่อวาน) เปิดไว้ และ `down -v` จะลบ database ของเขาไปด้วย
ใส่ `-p studylab` แล้วทุกอย่างจะชื่อ `studylab-*` แยกขาดกัน

**ทำไม `--build`:** image `srisurart-pos/server:local` ไม่มีบน registry ไหน ต้อง build จาก `server/Dockerfile` บนเครื่องคุณ
(มีแค่ `api-1` ที่มี `build:` — ตัวอื่นใช้ image เดียวกัน เพื่อไม่ให้ build ซ้ำพร้อมกันแล้วแย่งชื่อ tag)

ตอนเขียนบทนี้ **รันแล้วพัง 3 รอบ** ก่อนจะผ่าน — ทั้ง 3 รอบเป็นบทเรียนที่ดี:

> 🩹 **ถ้าเจอแบบนี้ (รอบ 1):** `ERROR: (gcloud.auth.docker-helper) There was a problem refreshing your current auth tokens`
> ```
> etcd Pulling
> ERROR: (gcloud.auth.docker-helper) There was a problem refreshing your current auth tokens: ('invalid_grant: Bad Request' ...)
> error getting credentials - err: exit status 1, out: ``
> ```
> **สาเหตุ:** image `etcd` มาจาก `gcr.io` และไฟล์ `~/.docker/config.json` ของเครื่องนี้ตั้ง `credHelpers` ให้ `gcr.io` ใช้ `gcloud`
> ซึ่ง login หมดอายุ → Docker พยายามขอ token ก่อน pull แล้วล้ม ทั้งที่ image นี้เป็น **public** ไม่ต้อง login เลย
> **วิธีแก้ที่ไม่ไปแก้ config ของเครื่อง:** pull ตัวนั้นตัวเดียวด้วย config ว่างชั่วคราว
> ```bash
> mkdir -p /tmp/dockercfg && echo '{}' > /tmp/dockercfg/config.json
> DOCKER_CONFIG=/tmp/dockercfg \
> DOCKER_HOST=$(docker context inspect --format '{{.Endpoints.docker.Host}}') \
>   docker pull gcr.io/etcd-development/etcd:v3.6.12
> ```
> (ถ้าใช้ gcloud อยู่จริง ทางที่ดีกว่าคือ `gcloud auth login` ใหม่)

> 🩹 **ถ้าเจอแบบนี้ (รอบ 2a — ไม่ต้องตกใจ):** `pull access denied for srisurart-pos/server, repository does not exist`
> ขึ้นกับ `api-2`, `api-3`, `worker`, `bull-board`, `migrate` — Compose ลอง pull ก่อน พอไม่เจอก็ build จาก `api-1` ให้เอง
> ดูว่ามีบรรทัด `naming to docker.io/srisurart-pos/server:local done` ใน log = build สำเร็จ

> 🩹 **ถ้าเจอแบบนี้ (รอบ 2b):** `failed to allocate gateway (172.30.0.1): Address already in use`
> ```
>  Network studylab_default  Creating
>  Network studylab_default  Error
> failed to create network studylab_default: Error response from daemon: failed to allocate gateway (172.30.0.1): Address already in use
> ```
> **สาเหตุ:** compose file **fix subnet** ไว้ที่ `172.30.0.0/24` (`server/docker-compose.yml:354`) เพราะ Nginx ชี้ไปที่ IP ตายตัว
> `172.30.0.11–13` ของ api (`server/docker/nginx/nginx.conf:35-37`) — แต่บนเครื่องทดลองมี network เก่า `srisurart-pos_default`
> (สร้างไว้ 2026-09-11, ไม่มี container ใช้แล้ว) จอง subnet นั้นอยู่ → ทุก project ที่ใช้ compose file นี้ **เปิดพร้อมกันได้แค่ชุดเดียว**
> ```bash
> docker network inspect srisurart-pos_default --format '{{range .IPAM.Config}}{{.Subnet}}{{end}} containers={{len .Containers}}'
> # 172.30.0.0/24 containers=0
> ```
> **วิธีแก้ ทางที่ 1 (ง่ายสุด ถ้า network นั้นเป็นของคุณเองและว่าง):** `docker network rm srisurart-pos_default`
> **วิธีแก้ ทางที่ 2 (ที่บทนี้ใช้ — เพราะ network นั้นไม่ใช่ของ lab นี้ จึงไม่ไปลบ):** เขียนไฟล์ override ย้าย subnet ของ studylab
> ไว้ **นอก repo** แล้วใส่ `-f` เพิ่ม:
> ```bash
> # ทำสำเนา nginx.conf ที่เปลี่ยน IP upstream
> sed 's/172\.30\.0\./172.31.250./g' docker/nginx/nginx.conf > ~/studylab/nginx.conf
> ```
> ```yaml
> # ~/studylab/studylab.override.yml  (ไม่ commit — ใช้กับ lab นี้เท่านั้น)
> services:
>   nginx:
>     volumes:
>       - ~/studylab/nginx.conf:/etc/nginx/nginx.conf:ro   # ใส่ path เต็ม
>   api-1:
>     networks: !override { default: { ipv4_address: 172.31.250.11 } }
>   api-2:
>     networks: !override { default: { ipv4_address: 172.31.250.12 } }
>   api-3:
>     networks: !override { default: { ipv4_address: 172.31.250.13 } }
> networks:
>   default:
>     ipam: !override
>       config:
>         - subnet: 172.31.250.0/24
>           ip_range: 172.31.250.128/25
>           gateway: 172.31.250.1
> ```
> `!override` (Compose 2.24+) แปลว่า "แทนที่ทั้งก้อน ไม่ต้อง merge" — ถ้าไม่ใส่ list ของ subnet จะถูกต่อท้ายแทนที่จะถูกแทน
> ตรวจผลก่อนรันด้วย `docker compose ... config | grep 172.` เสมอ

คำสั่งที่ผ่านจริง (รอบ 3):
```bash
docker compose -p studylab -f docker-compose.yml -f ~/studylab/studylab.override.yml up -d
```

> 💡 **`-f ~/studylab/studylab.override.yml` จำเป็นเฉพาะตอนชน subnet (รอบ 2b)** ถ้าเครื่องคุณไม่เจอ error นั้น
> ก็ไม่ต้องสร้างไฟล์นี้เลย — ตัด `-f ~/studylab/studylab.override.yml` ออกจากทุกคำสั่งที่เหลือในบทนี้ (Step 2.2 ท้ายนี้, Lab 3, Lab 4.2, ปิด lab)
> ได้ทันที แล้วใช้ `docker-compose.yml` เดิมตรงๆ

> 🩹 **ถ้าเจอแบบนี้ (รอบ 3):** ใส่ `--wait` แล้วคำสั่งจบด้วย exit code 1 ทั้งที่ทุกอย่าง healthy
> ```
>  Container studylab-nginx-1  Healthy
>  Container studylab-api-2-1  Healthy
> container studylab-etcd-init-1 exited (0)
> ```
> `--wait` ถือว่า container ที่ "จบไปแล้ว" เป็นความล้มเหลว แม้จะจบด้วย 0 (สำเร็จ) — one-shot job ของ stack นี้จึงทำให้มันรายงานผิด
> **อย่าเชื่อ exit code ของ `--wait` กับ stack นี้** ให้ดู `ps` แทน (ข้างล่าง)

### Step 2.3 — ตรวจว่าทุกตัวขึ้นจริง
```bash
docker compose -p studylab ps -a --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'
docker compose -p studylab logs migrate etcd-init
```
```
SERVICE        STATUS                      PORTS
api-1          Up 12 seconds (healthy)     3000/tcp
api-2          Up 12 seconds (healthy)     3000/tcp
api-3          Up 12 seconds (healthy)     3000/tcp
bull-board     Up 12 seconds               3000/tcp, 127.0.0.1:3100->3100/tcp
certgen        Exited (0) 18 seconds ago
etcd           Up 19 seconds (healthy)     2379-2380/tcp
etcd-init      Exited (0) 13 seconds ago
htpasswd-gen   Exited (0) 18 seconds ago
migrate        Exited (0) 13 seconds ago
nginx          Up 7 seconds                0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp
postgres       Up 19 seconds (healthy)     5432/tcp
redis-cache    Up 19 seconds (healthy)     6379/tcp
redis-queue    Up 19 seconds (healthy)     6379/tcp
worker         Up 12 seconds               3000/tcp

etcd-init-1  | etcd-init: auth ok — root authenticates, anonymous access refused (HTTP 400)
etcd-init-1  | etcd-init: seeded /pos/config/log_level = info
etcd-init-1  | etcd-init: done
migrate-1    | applied: InitialSchema1788652800000, RowLevelSecurity1788652800001, ... (14 migrations)
```

อ่านยังไง:
- **`Exited (0)`** ของ one-shot = **ดี** (ทำเสร็จแล้ว) — ถ้าเป็น `Exited (1)` ให้ดู `logs` ของตัวนั้นทันที
- **`(healthy)`** = healthcheck ใน YAML ผ่าน; `worker`/`bull-board` ไม่มีคำว่า healthy เพราะปิด healthcheck ไว้ (`worker: healthcheck: { disable: true }`)
- Postgres **ไม่มี** `0.0.0.0:5432` — ตั้งใจ (ดู 🛠️ loopback-only ports)
- RAM ทั้ง stack ตอนว่าง (รวม monitoring ใน Lab 4) จาก `docker stats --no-stream`: api ตัวละ ~78 MiB, postgres ~44 MiB, grafana ~215 MiB (จาก limit 256 MiB)

### Step 2.4 — health check ผ่าน Nginx
```bash
curl -sk https://localhost/health/live
curl -sk https://localhost/health/ready
curl -sI http://localhost/ | head -2
curl -sk https://localhost/ | grep -o '<title>[^<]*'
```
```
{"status":"success","data":{"status":"up"}}
{"status":"success","data":{"status":"up","checks":{"postgres":"up","redisCache":"up","redisQueue":"up"}}}
HTTP/1.1 301 Moved Permanently
<title>Welcome to nginx!
```
- **`-k`** = ยอมรับ cert ที่เซ็นเอง (สร้างโดย job `certgen`) — ใช้บนเครื่องตัวเองเท่านั้น
- **live vs ready:** `live` ไม่แตะอะไรเลย (บอกว่า process ยังไม่ตาย), `ready` ไปถาม Postgres + Redis ทั้งสอง (บอกว่ารับงานได้จริง)
  — ถ้า Redis ล่ม `live` ยัง 200 แต่ `ready` จะ 503 ซึ่ง Nginx ถูกตั้งไม่ให้ถือว่า 503 ของ ready เป็น "instance ตาย" ไม่งั้นจะเตะทุกตัวออกพร้อมกัน (`nginx.conf` comment เหนือ `proxy_next_upstream`)
- **"Welcome to nginx!"** = ยังไม่มีไฟล์เว็บในเครื่อง Nginx (`nginx.conf` `location /` เขียนไว้ว่ารอ cd.1/#65) — Lab 3 จะใส่ให้
- port 80 ตอบ **301** ไป https เสมอ

### Step 2.5 — ลองเรียก API แบบยังไม่ login + เส้นทางที่ถูกปิด
```bash
curl -sk -w ' [HTTP %{http_code}]\n' https://localhost/api/v1/products
curl -sk -w ' [HTTP %{http_code}]\n' https://localhost/api/v1/nope
curl -sk -w ' [HTTP %{http_code}]\n' https://localhost/api/v1/platform/tenants
```
```
{"status":"error","error":{"code":"UNAUTHORIZED","message":"Missing or invalid Authorization header"}} [HTTP 401]
{"status":"error","error":{"code":"NOT_FOUND","message":"Cannot GET /api/v1/nope"}} [HTTP 404]
<html>... <title>403 Forbidden</title> ... nginx/1.29.8 ... [HTTP 403]
```
สังเกต 3 รูปแบบ:
- 401 และ 404 เป็น **JSON envelope** `{"status":"error","error":{"code":...}}` → มาจาก NestJS (ผ่าน Nginx ไปถึง API แล้ว)
- 403 เป็น **HTML ของ Nginx** → ถูกปฏิเสธตั้งแต่หน้าประตู ยังไม่ถึง API เลย

**ทำไม platform ถึง 403 ทั้งที่เรียกจากเครื่องตัวเอง?**
```nginx
# server/docker/nginx/nginx.conf:87-95
    location /api/v1/platform/ {
      allow 127.0.0.1;
      allow ::1;
      deny  all;
      limit_req zone=perip burst=60 nodelay;
      proxy_pass http://api;
    }
```
เพราะบน Docker Desktop, request จาก host เข้าไปถึง Nginx ผ่าน NAT — Nginx เห็น IP ต้นทางเป็น gateway ของ Docker **ไม่ใช่ `127.0.0.1`**
ดังนั้น "loopback ของ host" ≠ "loopback ของ Nginx" → วิธีที่ถูกคือ **เรียกจากข้างใน container ของ Nginx เอง** (ข้างล่าง)

### Step 2.6 — flow ตั้งร้านใหม่ (platform admin → tenant → owner)

```mermaid
sequenceDiagram
    autonumber
    participant You as "คุณ (terminal)"
    participant API1 as "api-1 container"
    participant NGX as "nginx container"
    participant API as "API (ผ่าน nginx)"
    participant PG as "Postgres"

    You->>API1: "docker compose exec api-1 node dist/db/bootstrap-admin.js"
    API1->>PG: "INSERT platform_admins (role postgres)"
    You->>NGX: "docker compose exec nginx curl https://127.0.0.1/api/v1/platform/auth/token"
    NGX->>API: "ผ่าน allow 127.0.0.1"
    API-->>You: "platform token"
    You->>NGX: "POST /api/v1/platform/tenants (Bearer platform token)"
    API->>PG: "INSERT tenants + users + settings (transaction เดียว)"
    API-->>You: "tenantId + enrolCode"
    You->>API: "POST https://localhost/api/v1/auth/token (labowner)"
    API-->>You: "accessToken + refreshToken"
    You->>API: "GET /api/v1/categories (Bearer accessToken)"
```

**(1) สร้าง platform admin คนแรก** — ไม่มี API ไหนสร้าง admin ได้ (ADR-0001: สร้าง "นอกระบบ" โดยทีม) จึงใช้สคริปต์ `bootstrap-admin.js`
ที่ต้องต่อ database ด้วย **role เจ้าของ (`postgres`)** ไม่ใช่ `pos_app` (`server/src/db/bootstrap-admin.ts` คอมเมนต์หัวไฟล์)
```bash
set -a; . ./.env; set +a                  # โหลดค่าจาก .env มาเป็นตัวแปรใน shell นี้
ADMINPW=$(openssl rand -hex 12)           # อย่างน้อย 12 ตัว (MIN_PASSWORD_LENGTH)
docker compose -p studylab exec \
  -e DATABASE_URL="postgres://postgres:${POSTGRES_PASSWORD}@postgres:5432/pos" \
  -e BOOTSTRAP_ADMIN_USERNAME=labadmin \
  -e BOOTSTRAP_ADMIN_DISPLAY_NAME="Lab Admin" \
  -e BOOTSTRAP_ADMIN_PASSWORD="$ADMINPW" \
  api-1 node dist/db/bootstrap-admin.js
```
```
platform admin "labadmin": created
```
(รันซ้ำจะได้ `unchanged`; ใส่ `--force` เพื่อเปลี่ยนรหัส)
ทำไมรันใน `api-1`: image นั้นมี `dist/db/bootstrap-admin.js` อยู่แล้ว และอยู่ใน network เดียวกับ `postgres` ซึ่งไม่เปิด port ออกมาที่ host

**(2) login เป็น platform admin — ยิงจากใน container nginx** (image `nginx:1.29-alpine` มี `curl` ให้)
```bash
docker compose -p studylab exec -T nginx curl -sk https://127.0.0.1/api/v1/platform/auth/token \
  -H 'content-type: application/json' \
  -d "{\"username\":\"labadmin\",\"password\":\"$ADMINPW\"}"
```
```json
{"status":"success","data":{"token":"eyJ…(ตัดทอน)","admin":{"id":"c431f82d-…","username":"labadmin","displayName":"Lab Admin"}}}
```

**(3) สร้างร้าน (tenant)** — ลองรหัสอ่อนก่อน เพื่อดูว่า server ปฏิเสธจริง:
```bash
PT=<token จากข้อ 2>
docker compose -p studylab exec -T nginx curl -sk https://127.0.0.1/api/v1/platform/tenants \
  -H "authorization: Bearer $PT" -H 'content-type: application/json' \
  -d '{"code":"weak","shopName":"x","ownerUsername":"o","ownerPassword":"short","ownerDisplayName":"o"}'
```
```json
{"status":"error","error":{"code":"WEAK_PASSWORD","message":"ownerPassword is too weak: at least 12 characters required"}}
```
แล้วสร้างจริง (field ตาม `CreateTenantDto` ใน `server/src/platform/platform-tenants.service.ts:21-30`):
```bash
OWNPW=$(openssl rand -hex 12)
docker compose -p studylab exec -T nginx curl -sk https://127.0.0.1/api/v1/platform/tenants \
  -H "authorization: Bearer $PT" -H 'content-type: application/json' \
  -d "{\"code\":\"studylab\",\"shopName\":\"ร้านทดลอง studylab\",\"plan\":\"demo\",
       \"ownerUsername\":\"labowner\",\"ownerPassword\":\"$OWNPW\",\"ownerDisplayName\":\"เจ้าของร้านทดลอง\"}"
```
```json
{"status":"success","data":{"tenantId":"e8fa28f9-3445-4044-bdb8-23b53ce7cf5d","code":"studylab",
 "shopName":"ร้านทดลอง studylab","ownerUsername":"labowner","enrolCode":"XXXXXXXX"}}
```
`enrolCode` คือรหัสสำหรับลงทะเบียนเครื่อง POS (`POST /api/v1/auth/device`) — lab นี้ยังไม่ใช้ (ตัดค่าออกเพราะถือเป็น credential)

**(4) login เป็นเจ้าของร้าน — คราวนี้ยิงจาก host ผ่าน Nginx ได้ตามปกติ** (`/api/` ไม่มี allowlist)
```bash
curl -sk https://localhost/api/v1/auth/token -H 'content-type: application/json' \
  -d "{\"username\":\"labowner\",\"password\":\"$OWNPW\"}"
curl -sk -w ' [HTTP %{http_code}]\n' https://localhost/api/v1/auth/token -H 'content-type: application/json' \
  -d '{"username":"labowner","password":"wrong-password"}'
```
```json
{"status":"success","data":{"accessToken":"eyJ…(ตัดทอน)","refreshToken":"eyJ…(ตัดทอน)",
 "user":{"id":"8b49bca2-…","username":"labowner","role":"owner","displayName":"เจ้าของร้านทดลอง"}}}
{"status":"error","error":{"code":"UNAUTHORIZED","message":"Invalid credentials"}} [HTTP 401]
```
ข้อความผิดเป็น `Invalid credentials` เหมือนกันทุกกรณี (ไม่บอกว่า user ไม่มี หรือรหัสผิด) — เพื่อไม่ให้คนร้ายเดาชื่อ user ได้

**(5) เรียก API ของร้านจริง**
```bash
AT=<accessToken>
curl -sk https://localhost/api/v1/categories -H "authorization: Bearer $AT"
curl -sk https://localhost/api/v1/products   -H "authorization: Bearer $AT"
curl -sk -D- -o /dev/null https://localhost/api/v1/bootstrap -H "authorization: Bearer $AT" | grep -i "etag\|x-correlation"
curl -sk https://localhost/api/v1/products -H "authorization: Bearer $AT" \
  -H 'content-type: application/json' -H "Idempotency-Key: $(uuidgen)" \
  -d '{"partNo":"LAB-001","name":"Brake pad (lab)","price":"450.00","cost":"300.00","stock":10}'
```
```
{"status":"success","data":[{"name":"เครื่องยนต์","color":"#1E4A80"},{"name":"ไฟฟ้า",...},{"name":"น้ำมัน",...},{"name":"เบรก",...},{"name":"ตัวถัง",...}]}
{"status":"success","data":[],"meta":{"total":0,"page":1,"limit":50,"totalPages":1}}
x-correlation-id: 7be2b1bc4c6275c2a78aef86d28b700b
etag: "0904d4df1dadc4b815f17723cc11da6dc2165e66c7a6d395b05c51d626d89040"
{"status":"success","data":{"id":"pmugjwjqr_c6a93533_1","partNo":"LAB-001","name":"Brake pad (lab)",
 "price":"450.00","cost":"300.00","stock":10,...,"updatedAt":"2026-09-25T05:59:30.292Z"}}   [HTTP 201]
```
สิ่งที่ควรสังเกต:
- ร้านใหม่มี **5 หมวดหมู่ seed** ให้ทันที (`SEED_CATEGORIES` — ADR-0001) แต่สินค้า 0 ชิ้น
- **เงินเป็น string** `"450.00"` ไม่ใช่ number (กฎ "Money crosses the wire as the string" ใน CLAUDE.md — กัน float ปัดเศษ)
- การเขียน (`POST`) ต้องมี **`Idempotency-Key`** — ส่งซ้ำด้วย key เดิมจะได้ผลเดิม ไม่สร้างซ้ำ (ดู [05_api.md](05_api.md))
- `x-correlation-id` = เลขติดตาม request — เอาไป grep ใน `docker compose -p studylab logs api-1 api-2 api-3` ได้
- 🩹 ลองส่ง `"nameTh"` ไปแล้ว field นั้นถูกเงียบๆ ไม่เก็บ (response มี `"nameTH":""`) — ชื่อ field จริงคือ `nameTH`; ดูสัญญา JSON ใน `docs/Backend_design/02_API_SCREENS.md` ก่อนเดา

---

## 🧪 Lab 3 — frontend ต่อกับ API จริง (แบบเดียวกับที่ CI build)

### 🧱 ปูพื้น: `--dart-define` คือ config ตอน build
`const bool.fromEnvironment('USE_API_WRITES')` ถูกอ่าน **ตอน compile** ไม่ใช่ตอนรัน — ค่าถูก "อบ" เข้าไปในไฟล์ JavaScript
เปลี่ยนค่าต้อง build ใหม่เท่านั้น (ต่างจาก `.env` ของ server ที่อ่านตอนบูต)

### คำสั่ง (ธงเดียวกับ `.github/workflows/flutter.yml:213-217`)
```bash
cd frontend
flutter build web --no-tree-shake-icons \
  --dart-define=USE_API_WRITES=true \
  --dart-define=API_BASE_URL= \
  -o build/web_api
```
```
Compiling lib/main.dart for the Web...                             39.1s
✓ Built build/web_api
```
- `USE_API_WRITES=true` → บิล/คืนของ/กะ เขียนไปที่ server (ADR-0010) และแอป **บังคับ login** (`frontend/lib/app.dart:18`)
- `API_BASE_URL=` (ค่าว่าง) → เรียก API แบบ **same origin** คือ host เดียวกับหน้าเว็บ — จึงต้องให้ Nginx ตัวเดียวกันเสิร์ฟทั้งหน้าเว็บและ `/api/`

### เอาไฟล์เว็บไปให้ Nginx เสิร์ฟ
เพิ่ม 1 บรรทัดใน volume ของ `nginx` ในไฟล์ override ของ lab:
```yaml
services:
  nginx:
    volumes:
      - <path>/nginx.conf:/etc/nginx/nginx.conf:ro
      - <repo>/frontend/build/web_api:/usr/share/nginx/html:ro
```
```bash
docker compose -p studylab -f docker-compose.yml -f ~/studylab/studylab.override.yml up -d nginx
```
ตรวจ:
```
$ curl -sk https://localhost/ | grep -o "<title>[^<]*"
<title>ศรีสุราษฎร์ อะไหล่ยนต์ POS
/main.dart.js   200 application/javascript 5613832B
/sqlite3.wasm   200 application/wasm 748424B
/drift_worker.js 200 application/javascript 349341B
/login          200 text/html 13105B        ← SPA fallback: path ไหนก็ได้ index.html
/checkout       200 text/html 13105B
$ curl -skI https://localhost/sw.js
HTTP/2 200
cache-control: no-cache                      ← service worker ห้าม cache (08 §4 item 8)
```

แล้วเปิด `https://localhost/` ใน browser → browser จะเตือนว่า cert ไม่น่าเชื่อถือ (เพราะเซ็นเอง) → เลือก "Advanced → Proceed to localhost"
**ด้วยตัวเอง** (ปลอดภัยเพราะเป็น server บนเครื่องคุณ) → หน้า login → ใช้ `labowner` + รหัสที่สร้างใน Lab 2

> ⚠️ **ขั้นที่ไม่ได้ทดลองในบทนี้ (บอกตรงๆ):** browser pane ที่ใช้เขียนบทปฏิเสธการเปิด `https://localhost` เพราะ cert เซ็นเอง
> จึงตรวจได้แค่ระดับ HTTP ข้างบน (ไฟล์ถูกเสิร์ฟครบ, fallback ถูก, `sw.js` no-cache) ยังไม่ได้เห็นหน้า login ในจอจริง

> 🩹 **ถ้าเจอแบบนี้:** ใช้ `flutter run -d chrome --dart-define=USE_API_WRITES=true --dart-define=API_BASE_URL=https://localhost`
> แล้ว request ไม่ผ่าน — เพราะ (1) หน้าเว็บอยู่คนละ origin กับ API จึงเป็น cross-origin ต้องพึ่ง CORS
> (dev ปล่อย `*` ไว้เมื่อ `CORS_ORIGINS` ว่าง แต่ **บน VM `mob04` ยังเป็น `*` อยู่** จนกว่าจะรัน `provision.yml` ใหม่ — CLAUDE.md #367)
> และ (2) browser ไม่ยอม `fetch()` ไป https ที่ cert เซ็นเอง ถ้ายังไม่เคยกด "Proceed" ที่ origin นั้น
> **วิธีที่ตรงกับ production ที่สุดคือ same-origin แบบข้างบน**

---

## 🧪 Lab 4 — Dashboard: Bull-Board, Prometheus, Grafana, และ `/metrics` ที่ถูกปิด

### 🧱 ปูพื้น: 3 หน้าจอนี้ต่างกันยังไง
| หน้าจอ | ตอบคำถาม | analogy |
|---|---|---|
| **Bull-Board** | "งานเบื้องหลังในคิวค้างอยู่กี่งาน / พังกี่งาน" | กระดานคิวสั่งอาหารในครัว |
| **Prometheus** | "เก็บตัวเลข (metric) ทุก 15 วิ และ query ย้อนหลังได้" | สมุดจดมิเตอร์น้ำไฟรายวัน |
| **Grafana** | "วาดตัวเลขจาก Prometheus เป็นกราฟสวยๆ" | แผ่นสรุปรายเดือนที่แปะผนัง |

### 4.1 Bull-Board (มากับ stack หลักแล้ว)
```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3100/
BBP=$(grep '^BULL_BOARD_PASSWORD=' .env | cut -d= -f2)
curl -s -u admin:$BBP http://127.0.0.1:3100/ | grep -o '<title>[^<]*'
curl -s -u admin:$BBP http://127.0.0.1:3100/api/queues | head -c 200
```
```
401
<title>Bull Dashboard
{"queues":[{"name":"sale-post","statuses":["latest","active","waiting",...],"counts":{"active":0,"completed":0,"delayed":0,"failed":0,...
```
ไม่มีรหัส = 401; มีรหัส = เห็นคิว `sale-post` ว่างอยู่ ใน browser เปิด `http://127.0.0.1:3100` แล้วกรอก user/password จาก `.env`

### 4.2 เปิด monitoring overlay
```bash
docker compose -p studylab -f docker-compose.yml -f ~/studylab/studylab.override.yml \
  -f ../deploy/compose/monitoring.yml up -d
```
**ทำไมต้องใส่ `docker-compose.yml` เป็นไฟล์แรกเสมอ:** path แบบ relative ใน compose ถูกตีความเทียบกับ **โฟลเดอร์ของไฟล์ `-f` ตัวแรก**
`monitoring.yml` เขียน path `../deploy/...` โดยคิดจาก `server/` (`server/README.md` ท้ายหัวข้อ Monitoring overlay)
ถ้าสลับลำดับ Docker จะสร้างโฟลเดอร์ว่างแทนไฟล์ config แล้ว Prometheus ขึ้นมาแบบไม่มี config

```
 Container studylab-node-exporter-1  Healthy
 Container studylab-prometheus-1  Healthy
 Container studylab-grafana-1  Started
```
(ใช้แค่ 12 วินาที เพราะ stack หลักขึ้นอยู่แล้ว Compose แตะเฉพาะ service ใหม่)

### 4.3 Prometheus
```bash
curl -s http://127.0.0.1:9090/-/healthy
curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c 'import json,sys
for t in json.load(sys.stdin)["data"]["activeTargets"]:
    print(t["labels"]["job"], t["labels"]["instance"], t["health"], (t.get("lastError") or "")[:60])'
```
```
Prometheus Server is Healthy.
api-metrics   api-1:3000     up
api-metrics   api-2:3000     up
api-metrics   api-3:3000     up
api-readiness api-1:3000     down  expected equal, got ":" ("INVALID") while parsing: "{\"status\":"
api-readiness api-2:3000     down  expected equal, got ":" ("INVALID") while parsing: "{\"status\":"
api-readiness api-3:3000     down  expected equal, got ":" ("INVALID") while parsing: "{\"status\":"
node          node-exporter:9100 up
```
**`api-readiness` = down ทั้ง 3 ตัว ทั้งที่ API ปกติ** — เป็น gap ที่รู้และยอมรับแล้ว: Prometheus ถือว่า target "up" ก็ต่อเมื่อ body parse เป็น text format ของมันได้
แต่ `/health/ready` ตอบ JSON (`server/README.md` Monitoring overlay, ย่อหน้า 🔴) → **อย่าอ่านบรรทัด down นี้ว่าระบบพัง** ให้ดู `api-metrics` แทน

> 📝 **เอกสารตามโค้ดไม่ทัน:** `server/README.md` ยังเขียนว่า job `api-metrics` "commented out" แต่ `deploy/prometheus/prometheus.yml`
> ตอนนี้เปิดใช้แล้ว (และ target ขึ้น `up` จริงตามผลข้างบน) — เชื่อไฟล์ config + ผลรันจริง มากกว่าข้อความในเอกสาร

ลอง query metric ที่ Grafana ใช้:
```bash
curl -s -G http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=sum by (route) (http_requests_total)'
```
```
{'route': '/api/v1/products'} 3
{'route': 'unmatched'} 1
{'route': '/api/v1/platform/auth/token'} 1
{'route': '/api/v1/auth/token'} 2
{'route': '/api/v1/platform/tenants'} 2
{'route': '/api/v1/bootstrap'} 1
{'route': '/api/v1/categories'} 1
```
นี่คือ request ที่คุณยิงใน Lab 2 เองทั้งหมด! สังเกตว่า:
- `route` เป็น **pattern** ไม่ใช่ path จริง (`/api/v1/nope` กลายเป็น `unmatched`) — ไม่งั้น id ทุกตัวจะกลายเป็น series ใหม่จนระเบิด
- `/health/*` และ `/metrics` **ไม่ถูกนับ** (`UNMEASURED_PATHS`) — ถ้านับ การ scrape ทุก 15 วิ × 3 instance จะสร้าง 200 ปลอมจนกราฟ success rate ดูดีเกินจริง (CLAUDE.md, Metrics)

### 4.4 `/metrics` ต้องเข้าจากข้างนอกไม่ได้
```bash
curl -sk -w ' [HTTP %{http_code}]\n' https://localhost/metrics            # จาก host ผ่าน Nginx
docker compose -p studylab exec -T api-1 wget -qO- http://127.0.0.1:3000/metrics | grep '^http_requests_total' | head -3
```
```
<html>... <title>404 Not Found</title> ... [HTTP 404]
http_requests_total{method="GET",route="/api/v1/products",status_code="401"} 1
http_requests_total{method="GET",route="unmatched",status_code="404"} 1
http_requests_total{method="POST",route="/api/v1/platform/auth/token",status_code="200"} 1
```
Nginx ตอบ 404 ให้ `location = /metrics` (`server/docker/nginx/nginx.conf:158-160`) ส่วน Prometheus เข้าถึงได้เพราะอยู่ใน compose network เดียวกัน ไม่ผ่าน Nginx
ใช้ `=` (exact match) ไม่ใช่ prefix — ไม่งั้น path อนาคตอย่าง `/metrics-guide` ของ SPA จะโดนบล็อกไปด้วย

### 4.5 Grafana
```bash
curl -s http://127.0.0.1:3000/api/health
GP=$(grep '^GRAFANA_ADMIN_PASSWORD=' .env | cut -d= -f2)
curl -s -u admin:$GP http://127.0.0.1:3000/api/search
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000/api/search     # ไม่มีรหัส
```
```
{ "database": "ok", "version": "11.2.0", ... }
dash-db  Srisurart POS — overview  /d/srisurart-pos-overview/srisurart-pos-e28094-overview
401
```
dashboard ถูก **provision จากไฟล์** (`deploy/grafana/dashboards/pos-overview.json`) — ไม่ต้องคลิกสร้างเอง, ลบ volume แล้วสร้างใหม่ก็ได้ของเดิม
ใน browser: เปิด `http://127.0.0.1:3000` → login `admin` + `GRAFANA_ADMIN_PASSWORD` → Dashboards → "Srisurart POS — overview"
(บทนี้ไม่ได้ login ผ่าน browser — ตรวจผ่าน API ด้านบนแทน)

> 🩹 **ถ้าเจอแบบนี้:** Grafana ขึ้นไม่ได้ พร้อมข้อความ `GRAFANA_ADMIN_PASSWORD is required`
> → `.env` ไม่มีค่านี้ (ตั้งใจไม่ให้มี default — `monitoring.yml` ใช้รูป `:?`) เพิ่มแล้ว `up -d` ใหม่

> ⚠️ **ชน port 3000:** Grafana ใช้ `127.0.0.1:3000` — ซึ่งคือ `API_BASE_URL` default ของแอป Flutter ด้วย (Lab 1)
> ถ้าเปิด Grafana ไว้แล้ว build เว็บแบบไม่ส่ง `API_BASE_URL` แอปจะไปเรียก Grafana แทน API

---

## 🧪 Lab 5 — ส่อง database: RLS คืน 0 แถวจริงไหม

### 🧱 ปูพื้น: RLS แบบ fail-closed
**RLS (Row-Level Security)** = กฎใน Postgres ที่กรองแถวตาม "ใครถาม" — ทุกตารางของร้านมี policy:
`tenant_id = NULLIF(current_setting('app.tenant_id', true), '')::uuid`
แปลว่า: ถ้ายังไม่บอกว่าเป็นร้านไหน (`app.tenant_id` ว่าง) → เงื่อนไขเป็น NULL → **ไม่เห็นอะไรเลย** (fail-closed = พังแบบปิดประตู ไม่ใช่เปิดประตู)
ดูเต็มๆ ใน [07_database.md](07_database.md)

### คำสั่ง — ต่อเป็น `pos_app` (role เดียวกับที่ API ใช้)
```bash
PAP=$(grep '^POS_APP_PASSWORD=' .env | cut -d= -f2)
TID=<tenantId จาก Lab 2>
q(){ docker compose -p studylab exec -T -e PGPASSWORD=$PAP postgres \
       psql -h 127.0.0.1 -U pos_app -d pos -c "$1"; }

q "select current_user;"
q "select count(*) from products;"
q "begin; select set_config('app.tenant_id','$TID',true); select part_no, name, stock from products; commit;"
```
```
 current_user
--------------
 pos_app

 count
-------
     0            ← มีสินค้า LAB-001 อยู่จริง แต่ไม่ได้บอกว่าเป็นร้านไหน = มองไม่เห็น

BEGIN
 set_config
--------------------------------------
 e8fa28f9-3445-4044-bdb8-23b53ce7cf5d
 part_no |      name       | stock
---------+-----------------+-------
 LAB-001 | Brake pad (lab) |    10
COMMIT
```
**ทำไมต้อง `-h 127.0.0.1`:** ใน container ของ Postgres, ถ้าต่อผ่าน unix socket โดยไม่ระบุ host จะใช้วิธี auth อีกแบบ — ระบุ TCP ให้ถามรหัสจริงเหมือนที่ API ต่อ
**ทำไม `set_config(..., true)` ต้องอยู่ใน `begin … commit`:** อาร์กิวเมนต์ `true` = ค่านี้อยู่แค่ใน transaction นี้ จบ transaction แล้วหาย
— API ทำแบบเดียวกันใน `TenantService.runTx` ทำให้ connection ที่ถูกคืนเข้า pool ไม่มีทาง "จำ" ร้านเก่าติดไปยัง request ถัดไป

### ลองแหกกฎ
```bash
q "insert into products(tenant_id,id,part_no,name) values ('$TID','x','X','x');"
docker compose -p studylab exec -T -e PGPASSWORD=$PAP postgres psql -h 127.0.0.1 -U pos_app -d pos \
  -c "set row_security = off;" -c "select count(*) from products;"
q "select count(*) from migrations;"
```
```
ERROR:  new row violates row-level security policy for table "products"
SET
ERROR:  query would be affected by row-level security policy for table "products"
ERROR:  permission denied for table migrations
```
- insert โดยไม่ตั้ง tenant → ถูกปฏิเสธ
- `SET row_security = off` **ตั้งได้** แต่ Postgres ไม่ได้ปิดการกรองให้ — กลับกลายเป็นว่าทุก query ที่จะโดนกรอง **error ทันที** แทน (role ที่ไม่มีสิทธิ์ `BYPASSRLS` ปิด RLS ไม่ได้)
- ตาราง `migrations` `pos_app` ไม่มีสิทธิ์แตะเลย

นับตาราง (ต่อเป็น `postgres`):
```bash
docker compose -p studylab exec -T postgres psql -U postgres -d pos -tc \
  "select count(*) from pg_tables where schemaname='public'"
```
```
    30
```
= 29 ตารางของระบบ + ตาราง `migrations` 1 ตาราง (ตรงกับ CLAUDE.md "Postgres has 29 tables")

---

## 🧪 Lab 6 — รัน test

รายละเอียดว่า test แต่ละระดับจับอะไรได้ อยู่ใน [12_testing.md](12_testing.md) และ `docs/tutorial/testing-tutorial.md` — ที่นี่แค่ "รันแล้วเห็นอะไร"

### 6.1 Frontend
```bash
cd frontend
dart analyze                     # ห้ามใช้ flutter analyze (พังบน path ภาษาไทย — CLAUDE.md)
flutter test test/sales_repository_test.dart test/returns_repository_test.dart test/route_smoke_test.dart
flutter test                     # ทั้งชุด
```
| คำสั่ง | ผลจริง | เวลา |
|---|---|---|
| `dart analyze` | `No issues found!` | 5 วิ |
| `flutter test` 3 ไฟล์ | `+41: All tests passed!` | 10 วิ |
| `flutter test` ทั้งหมด | `+533: All tests passed!` | 72 วิ |

**ทำไมเลือก 3 ไฟล์นี้เป็นชุดเร็ว:** `sales`/`returns` คุมกฎเงิน/สต็อกที่สำคัญที่สุด (สต็อกไม่พอ, คืนเกิน) และ `route_smoke` เปิดทุกหน้าจอดูว่าไม่ crash

### 6.2 Backend — lint, typecheck, unit
```bash
cd server
corepack pnpm install --frozen-lockfile     # ครั้งแรกเท่านั้น
corepack pnpm lint
corepack pnpm typecheck
corepack pnpm test
```
| คำสั่ง | ผลจริง | เวลา |
|---|---|---|
| `pnpm lint` (oxlint) | exit 0, ไม่มี warning | 2 วิ |
| `pnpm typecheck` (`tsc --noEmit`) | exit 0 | 11 วิ |
| `pnpm test` (vitest unit) | `Test Files 49 passed (49)` / `Tests 412 passed (412)` | 32 วิ |

ระหว่าง unit test จะเห็นบรรทัด `WARN ... Redis cache error setting tenant status: Error: Command timed out` —
**ไม่ใช่ error** เป็น test ที่จงใจจำลอง Redis ค้างเพื่อพิสูจน์ว่าระบบถอยไปใช้ Postgres ได้

### 6.3 Backend — e2e (อธิบาย แต่ไม่ได้รันใน lab นี้)
```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --wait postgres redis-cache redis-queue
corepack pnpm build
DATABASE_URL=postgres://postgres:dev-only-postgres@127.0.0.1:5432/pos corepack pnpm db:migrate
corepack pnpm test:e2e
```
e2e ต่อ Postgres/Redis **ตัวจริง** ผ่าน port ที่ dev overlay เปิดบน `127.0.0.1` (5432, 6379, 6380) — ไม่มี mock (53 ไฟล์ `*.e2e-spec.ts`)

**ทำไมบทนี้ไม่ได้รัน:**
1. `server/test/support/fixture.ts:96,104-105` hardcode รหัส `dev-only-*` — stack ของ lab นี้สุ่มรหัสใหม่ (Step 2.1) จึงต่อไม่ติด
2. ต้องเปิด dev overlay ซึ่ง publish port datastore — ต้องแยก stack ต่างหากจาก studylab และ e2e ถือ lock ทั้ง Postgres
   (รัน 2 ชุดพร้อมกันบน Postgres เดียวไม่ได้ — `e2e runner lock` ใน `server/README.md` หัวข้อ The e2e suite)

**ถ้าจะรันเอง:** ใช้ stack แยกที่ใช้ `.env.example` ตรงๆ (ไม่สุ่มรหัส) และชื่อ project ของตัวเอง, ปิด studylab ก่อนถ้าชน subnet
CI รันชุดนี้ทุก PR ใน job `integration` (~3 นาที ดู Lab 7)

> 🔴 **อย่าใช้ dev overlay บน VM หรือเครื่องที่ใช้ร่วมกัน** — มันเปิด Postgres/Redis ให้ทุกคนบนเครื่องต่อได้ (`server/docker-compose.dev.yml` หัวไฟล์)

---

## 🧪 Lab 7 — ดู pipeline แบบอ่านอย่างเดียว

### 🧱 ปูพื้น
`gh` คือ GitHub CLI — ดูผล GitHub Actions จาก terminal ได้ บทนี้ใช้ **เฉพาะคำสั่งอ่าน** (`list`, `view`, `api` แบบ GET)
**ห้าม** `gh run rerun` / `gh run cancel` / approve deployment — พวกนั้นเปลี่ยนสถานะของ repo ทั้งทีม
(โดยเฉพาะ `Deploy (demo)` ที่รออนุมัติ — การอนุมัติจะส่งของขึ้น VM จริง และเป็นงานของ reviewer `NuimanLP` เท่านั้น)
รายละเอียดทุก stage อยู่ใน [15_cicd.md](15_cicd.md)

### 7.1 มี workflow อะไรบ้าง / รันล่าสุดเป็นยังไง
```bash
gh workflow list
gh run list --limit 10
```
```
Deploy (demo)       active  358758196
Flutter CI          active  350023540
Server CI           active  351601043
Dependabot Updates  active  353682745

completed success  docs(study): ... Flutter CI   claude/git-pull-8a9fb0  pull_request  36099023697  15s
completed success  docs(study): ... Server CI    claude/git-pull-8a9fb0  pull_request  36099023658  3m26s
pending            Deploy (demo)   Deploy (demo) main  workflow_run  35957811225  25h5m54s
completed success  Deploy (demo)   Deploy (demo) main  workflow_run  35957750138  8s
completed success  Merge pull request #395 ...   Server CI  main  push  35957475404  4m47s
completed success  Merge pull request #395 ...   Flutter CI main  push  35957475393  3m51s
```
คอลัมน์: สถานะ, ผล, ชื่อ commit, workflow, branch, เหตุที่ trigger, **run id**, ระยะเวลา, เวลาเริ่ม

### 7.2 เปิดดู run หนึ่ง
```bash
gh run view 36099023658
```
```
✓ claude/git-pull-8a9fb0 Server CI NuimanLP/srisurart-pos-flutter#397 · 36099023658
JOBS
✓ detect changed paths (pull_request only) in 7s
✓ integration (Postgres + both Redis, real migrations) in 3m16s
- unit in 0s
- lint + typecheck in 0s
- audit (pnpm audit + Trivy fs) in 0s
- nginx config check (nginx -t) in 0s
✓ server-ci-status in 3s
- server image → GHCR in 0s
```
อ่าน: `✓` ผ่าน, `X` พัง, `-` **ถูกข้าม** — PR นี้แก้แค่ `docs/` จึงข้าม lint/unit แต่ **`integration` ไม่เคยถูกข้าม** (มี test แยก tenant ที่ต้องรันทุก PR) และ `server-ci-status` คือ check เดียวที่ branch protection ดู

### 7.3 "เขียว" ≠ "deploy แล้ว" — ดูของจริง
```bash
gh run view 35957750138
gh run view 35957811225
```
```
✓ main Deploy (demo) · 35957750138
✓ resolve release in 5s
- deploy to demo
- Not deploying ec5b9a6...: GHCR does not have both images yet. The other CI workflow's completion triggers the deploy.

* main Deploy (demo) · 35957811225
✓ resolve release in 7s
* deploy to demo                      ← รอ reviewer อนุมัติมา 25 ชั่วโมงแล้ว
```
run แรก **เขียวทั้งที่ไม่ได้ deploy อะไรเลย** (job deploy ถูกข้ามเพราะ image ยังไม่ครบ) ส่วน run ที่สองค้างรออนุมัติ
และถึงอนุมัติก็ยังติด FortiGate อยู่ดี — หลักฐานเดียวว่า VM รันเวอร์ชันไหนคือไฟล์ `/opt/pos/.current_sha` บน VM (CLAUDE.md)

### 7.4 อ่าน log ของ job ที่พัง
```bash
gh run list --status failure --limit 5
gh run view 35504913192                    # ดูว่า step ไหนพัง
gh run view 35504913192 --log-failed       # วิธีปกติ
```
```
X feat/276-q2-void-client Flutter CI NuimanLP/srisurart-pos-flutter#334 · 35504913192
X analyze + test in 1m56s (ID 106062988037)
  ✓ dart analyze
  X flutter test
X flutter-ci-status in 3s
```
> 🩹 **ถ้าเจอแบบนี้:** `gh run view --log-failed` (และ `--job <id> --log`) **คืนค่าว่าง 0 บรรทัด** บน gh 2.53.0 ของเครื่องทดลอง ทั้งที่ exit 0
> **วิธีแก้:** ดึง log ของ job ตรงจาก REST API (ยังเป็นการอ่านอย่างเดียว)
> ```bash
> gh api repos/NuimanLP/srisurart-pos-flutter/actions/jobs/106062988037/logs > job.log
> grep -n "\[E\]\|Expected\|Actual" job.log | head
> ```
> (หรืออัปเกรด gh ให้ใหม่กว่านี้ — ไม่ได้ทดสอบว่าเวอร์ชันไหนแก้)

ผลที่ได้ (1,026 บรรทัด → grep เหลือส่วนสำคัญ):
```
00:24 +113 -1: .../test/schema_v1_to_v3_migration_test.dart: a v1 file lands on the current schema (v9) in a single open [E]
  Expected: <9>
    Actual: <10>
00:29 +124 -2: .../test/schema_v6_migration_test.dart: upgrades a v5 file to v6 with empty counter tables [E]
  Expected: <9>
    Actual: <10>
```
**วิธีอ่าน:** `+113 -1` = ผ่าน 113 พัง 1 (ณ วินาทีนั้น), `[E]` = test ที่พัง, แล้วดู `Expected/Actual`
ที่นี่ branch นั้นขยับ Drift schema เป็น v10 แต่ test ยังคาดหวัง v9 — ทุก test ที่เช็คเลข schema จึงพังพร้อมกัน 5 ตัว
(**สาเหตุเดียว หลายอาการ** — แก้ที่ค่าคาดหวังจุดเดียว ไม่ใช่ไล่แก้ 5 test)

อีกตัวอย่าง: `Server CI` run 35566947175 บน `main` — ทุก test เขียว แต่ job `server image → GHCR` พังที่ step `push <sha> and main`:
```
638b81696924: Pushed
34884abbe928: Layer already exists
unknown blob
##[error]Process completed with exit code 1.
```
= test ไม่ผิด แต่การ push image ขึ้น registry ล้มกลางทาง (ปัญหาฝั่ง registry/เครือข่าย ไม่ใช่โค้ด) — การแยกให้ออกว่า "โค้ดผิด" หรือ "โครงสร้างพื้นฐานผิด" คือทักษะแรกของการอ่าน log

---

## 🧹 ปิด lab / เก็บกวาด

stack **studylab ยังรันค้างอยู่ตอนเขียนบทนี้เสร็จ** (บท performance จะใช้ต่อ) — เมื่อคุณทำเสร็จ:

```bash
cd server
# หยุดแต่เก็บข้อมูลไว้ (เปิดใหม่ได้ด้วย up -d):
docker compose -p studylab -f docker-compose.yml -f ~/studylab/studylab.override.yml -f ../deploy/compose/monitoring.yml down

# ลบทิ้งทั้งหมดรวม database/volume — ใช้ได้เพราะ -p studylab เป็นของ lab เราเอง:
docker compose -p studylab -f docker-compose.yml -f ~/studylab/studylab.override.yml -f ../deploy/compose/monitoring.yml down -v

# ตรวจว่าไม่เหลืออะไรของ studylab:
docker ps -a --filter label=com.docker.compose.project=studylab
docker volume ls --filter label=com.docker.compose.project=studylab
```
> 🔴 **`down -v` ใช้กับ `-p studylab` เท่านั้น** ห้ามรันโดยไม่มี `-p` (จะไปโดน `srisurart-pos_*` ของคนอื่น)
> และต้องใส่ `-f monitoring.yml` ด้วย ไม่งั้น Prometheus/Grafana จะยังค้างอยู่ (Compose ปิดเฉพาะ service ที่รู้จักจากไฟล์ที่ส่งให้)

อื่นๆ: `server/.env` เก็บไว้ได้ (gitignored), ลบ `frontend/build/web_api` ได้ถ้าไม่ใช้, หยุด `python3 -m http.server` ด้วย Ctrl+C

---

## 🛠️ เทคนิคในบทนี้

### 1. Compose project name (`-p`)
- **คืออะไร:** namespace ของ container/network/volume — เหมือนชื่อตึก ห้องเลขเดียวกันอยู่คนละตึกได้
- **ปัญหาที่แก้:** ไม่ใส่ `-p` ทุกคนได้ `srisurart-pos_pgdata` ตัวเดียวกัน → `down -v` ของคนหนึ่งลบ database ของอีกคน (เคยเกิดจริง, CLAUDE.md CI/CD rules)
- **ทำไมเลือก:** เทียบกับ "ใช้ Docker คนละเครื่อง" — `-p` ฟรีและทันที
- **ราคา:** พิมพ์ยาวขึ้น; และ **ไม่ได้แยกทุกอย่าง** — host port (80/443) และ subnet ที่ fix ไว้ยังชนกันได้ (Lab 2 รอบ 2b)
- **ใน repo:** `server/docker-compose.yml:16` (`name:`), กฎ unique `-p` ใน CLAUDE.md

### 2. Override file + `!override`
- **คืออะไร:** ไฟล์ compose ที่ใส่ `-f` ตามหลัง เพื่อแก้บางค่าโดยไม่แตะไฟล์หลัก
- **ปัญหาที่แก้:** ต้องย้าย subnet / เสียบไฟล์เว็บ เฉพาะเครื่องเรา โดยไม่ commit อะไรเข้า repo
- **ทำไมเลือก:** เทียบกับแก้ `docker-compose.yml` ตรงๆ — จะลืมย้อนแล้วเผลอ commit; repo เองก็ใช้ท่านี้ (`docker-compose.dev.yml`, `deploy/compose/vm.override.yml`, `monitoring.yml`)
- **ราคา:** ต้องรู้กฎ merge (list ต่อท้าย, map merge) — จึงต้องใช้ `!override` และตรวจด้วย `docker compose config`
- **ใน repo:** `server/docker-compose.dev.yml`, `deploy/compose/monitoring.yml`

### 3. Liveness vs readiness probe
- **คืออะไร:** `live` = "ยังหายใจ", `ready` = "พร้อมรับลูกค้า"
- **ปัญหาที่แก้:** ถ้ามีแค่ตัวเดียวที่เช็ค DB แล้ว DB สะดุด → ทุก instance ถูกมองว่าตายพร้อมกัน → restart วนทั้งระบบ
- **ทำไมเลือก:** container healthcheck ใช้ `live` (`x-api` healthcheck), deploy playbook รอ `ready`
- **ราคา:** ต้องดูแล 2 endpoint; Prometheus อ่าน `ready` ไม่ออก (Lab 4.3)
- **ใน repo:** `server/src/health/`, `server/docker-compose.yml` (`x-api.healthcheck`)

### 4. Loopback-only ports + SSH tunnel
- **คืออะไร:** เปิด port แค่บน `127.0.0.1` ของเครื่อง — คนนอกเครื่องเข้าไม่ได้เลย
- **ปัญหาที่แก้:** Prometheus ไม่มี login, Bull-Board มีแค่ basic auth — ถ้าเปิด `0.0.0.0` บน VM ใครในเครือข่ายคณะก็เข้าได้
- **ทำไมเลือก:** เทียบกับเอาไว้หลัง Nginx + login — ท่านี้ไม่มีอะไรให้ตั้งค่าผิด
- **ราคา:** คนดูต้องมี SSH เข้า VM (`ssh -L ...`)
- **ใน repo:** `server/docker-compose.yml:188`, `deploy/compose/monitoring.yml:80,111`

### 5. IP allowlist ที่ Nginx (`allow`/`deny`)
- **คืออะไร:** รายชื่อ IP ที่อนุญาตให้เข้า path นั้น
- **ปัญหาที่แก้:** API สร้างร้าน/ระงับร้าน ไม่ควรถูกยิงจากอินเทอร์เน็ตแม้จะมี token (ชั้นป้องกันซ้อน)
- **ราคา:** "loopback" ขึ้นกับว่ามองจากไหน — จาก host ผ่าน Docker NAT ไม่ใช่ 127.0.0.1 (Lab 2.5) จึงต้อง `exec` เข้า container
- **ใน repo:** `server/docker/nginx/nginx.conf:87-95`, `server/src/platform/platform-auth.guard.ts:43`

### 6. Build-time config (`--dart-define`)
- **คืออะไร:** ค่าที่ถูกฝังเข้าไปตอน compile
- **ปัญหาที่แก้:** เว็บ static ไม่มี `.env` ให้อ่านตอนรัน
- **ทำไมเลือก:** เทียบกับโหลด `config.json` ตอนเปิดแอป — ต้องเขียนโค้ดโหลด + จัดการกรณีไฟล์หาย
- **ราคา:** เปลี่ยนค่า = build ใหม่; ค่า default (`http://localhost:3000`) อาจชนของอื่นแบบเงียบๆ (Lab 1)
- **ใน repo:** `frontend/lib/core/network/api_client.dart:20`, `.github/workflows/flutter.yml:213-217`

### 7. Same-origin serving
- **คืออะไร:** หน้าเว็บและ API มาจาก host+port+scheme เดียวกัน
- **ปัญหาที่แก้:** ไม่ต้องพึ่ง CORS เลย (ซึ่งตั้งผิดทีเดียวเว็บพังทั้งแอป — `.env.example` คอมเมนต์ CORS_ORIGINS)
- **ราคา:** Nginx ต้องเสิร์ฟทั้งไฟล์เว็บและ proxy API; ทดลองบนเครื่องต้องผ่าน cert เซ็นเอง
- **ใน repo:** `server/docker/nginx/nginx.conf` `location /` + `location /api/`

### 8. RLS fail-closed + `set_config(..., true)`
- **คืออะไร:** ไม่บอกร้าน = ไม่เห็นอะไร; ค่าร้านอยู่แค่ใน transaction
- **ปัญหาที่แก้:** ลืม `WHERE tenant_id = ?` ที่ไหนสักที่ = ข้อมูลรั่วข้ามร้าน
- **ราคา:** ทุก query ต้องอยู่ใน transaction ที่ตั้ง tenant แล้ว (`TenantService.runTx`)
- **ใน repo:** migration `RowLevelSecurity1788652800001`, `server/README.md` หัวข้อ Schema and migrations

### 9. อ่าน CI แบบ read-only + ดึง log ผ่าน REST
- **คืออะไร:** ใช้ `gh run list/view` และ `gh api .../jobs/<id>/logs`
- **ปัญหาที่แก้:** เปิดเว็บทีละหน้าช้า และการกด rerun/approve มั่วๆ เปลี่ยนสถานะของทั้งทีม
- **ราคา:** ต้องจำ run id / job id; `--log-failed` ของ gh บางเวอร์ชันคืนค่าว่าง
- **ใน repo:** `.github/workflows/*.yml`

| เทคนิค | แก้ปัญหาอะไร | ราคาที่จ่าย | file |
|---|---|---|---|
| `-p` project name | stack ชนกัน / `down -v` ลบของคนอื่น | ไม่แยก host port/subnet | `server/docker-compose.yml:16` |
| override + `!override` | ปรับเฉพาะเครื่องโดยไม่ commit | ต้องเข้าใจกฎ merge | `server/docker-compose.dev.yml` |
| live vs ready | restart วนทั้งระบบเมื่อ DB สะดุด | Prometheus อ่าน ready ไม่ได้ | `server/src/health/` |
| loopback-only port | dashboard หลุดสู่เครือข่าย | ต้อง SSH tunnel | `deploy/compose/monitoring.yml:80,111` |
| Nginx allowlist | admin API ถูกยิงจากข้างนอก | "loopback" ขึ้นกับมุมมอง | `nginx.conf:87-95` |
| `--dart-define` | เว็บ static ไม่มี env | เปลี่ยนค่าต้อง build ใหม่ | `api_client.dart:20` |
| same-origin | ไม่ต้องพึ่ง CORS | cert เซ็นเองตอนทดลอง | `nginx.conf` `location /` |
| RLS fail-closed | ข้อมูลรั่วข้ามร้าน | ทุก query ต้องอยู่ใน tx | migration RowLevelSecurity |
| read-only `gh` + REST log | อ่านผล CI เร็ว ไม่แตะสถานะทีม | `--log-failed` ว่างบาง version | `.github/workflows/` |

---

## 📚 Tech stack ของบทนี้ (version ที่ใช้จริงใน lab)

| เครื่องมือ | version | หน้าที่ใน lab | ทางเลือกที่ไม่เลือก |
|---|---|---|---|
| Docker / Compose | 27.3.1 / v2.30.3 | เปิดทั้ง stack | รันแต่ละ service ด้วยมือ |
| nginx | `nginx:1.29-alpine` (ตอบ `nginx/1.29.8`) | TLS, proxy, allowlist, เสิร์ฟเว็บ | เปิด API ตรงๆ ไม่มี proxy |
| postgres | `postgres:16-alpine` | ข้อมูลหลัก + RLS | — |
| redis | `redis:7-alpine` ×2 | cache / queue | Redis ตัวเดียว (ปนนโยบาย eviction) |
| etcd | `gcr.io/etcd-development/etcd:v3.6.12` | config แบบ dynamic (`log_level`) | — |
| Prometheus | `prom/prometheus:v2.55.1` | เก็บ metric | — |
| Grafana | `grafana/grafana:11.2.0` | dashboard | — |
| node-exporter | `prom/node-exporter:v1.8.2` | CPU/RAM/disk ของ host | — |
| Flutter / Dart | 3.44.3 / 3.12.2 | build เว็บ + test | — |
| Node / pnpm | 22.23.2 / 10.34.5 | server lint/typecheck/test | npm/yarn |
| gh | 2.53.0 | อ่าน CI | เปิดเว็บ GitHub |

---

## ⚠️ บทเรียนจากของจริง (เจอระหว่างเขียนบทนี้ + จากประวัติโปรเจกต์)

1. **credential helper ของเครื่องทำ pull image public พัง** — error พูดถึง gcloud แต่ปัญหาจริงคือ "ไม่ต้อง login เลย" (Lab 2 รอบ 1)
2. **subnet ที่ fix ไว้ทำให้เปิด stack นี้พร้อมกันได้ชุดเดียวต่อเครื่อง** — `-p` ไม่ช่วย; network ค้างเก่าที่ไม่มี container ก็จอง subnet อยู่ (Lab 2 รอบ 2b) (Nginx ชี้ IP ตายตัวของ api; ส่วน `ip_range` กันไม่ให้ container อื่นแย่ง IP นั้น — #148)
3. **`--wait` รายงานพังเพราะ one-shot จบด้วย 0** — exit code ของเครื่องมือไม่ได้บอกความจริงเสมอ ต้องดู `ps` (Lab 2 รอบ 3)
4. **เว็บบน `main` ไม่ใช่ offline-only** และ `API_BASE_URL` default ชี้ port เดียวกับ Grafana (Lab 1)
5. **README ตามโค้ดไม่ทัน** เรื่อง `api-metrics` (Lab 4.3) — เชื่อผลรันจริง
6. **e2e hardcode รหัส dev** — รัน e2e ต้องใช้ stack ที่ใช้รหัสจาก `.env.example` (Lab 6.3)
7. **เขียว ≠ deploy แล้ว** — run `35957750138` เขียวแต่ job deploy ถูกข้าม (Lab 7.3; ดูเต็มใน [15_cicd.md](15_cicd.md))
8. จากประวัติ: `down -v` บน Docker daemon ที่ใช้ร่วมกันเคยลบ volume ของ session อื่น → จึงมีกฎ unique `-p` (CLAUDE.md)

---

## ✅ สรุป

> - เปิด stack: `cp .env.example .env` (สุ่มรหัส) → `docker compose -p studylab up -d --build` → เช็ค `ps` + `/health/ready`
> - ทุกคำสั่ง compose ใส่ `-p studylab` และ `down -v` ใช้กับ project ของตัวเองเท่านั้น
> - ตั้งร้าน: `bootstrap-admin.js` (role postgres) → platform login + สร้าง tenant **จากใน container nginx** (allowlist loopback) → owner login ผ่าน `https://localhost/api/v1/auth/token`
> - URL: เว็บ+API ที่ `https://localhost`, Bull-Board `:3100`, Prometheus `:9090`, Grafana `:3000` (ทั้งสามเฉพาะ loopback); `/metrics` จากข้างนอก = 404
> - แอป Flutter ต่อ API แบบ production: `--dart-define=USE_API_WRITES=true --dart-define=API_BASE_URL=` + ให้ Nginx เสิร์ฟ (same-origin)
> - RLS: `pos_app` ไม่ตั้ง tenant = 0 แถว, insert ถูกปฏิเสธ, ปิด RLS ไม่ได้
> - Test: `dart analyze` + `flutter test` (533 ผ่าน), `pnpm lint/typecheck/test` (412 ผ่าน); e2e ต้องใช้ stack ที่รหัสตรงกับ fixture
> - CI: `gh run list/view` + `gh api .../jobs/<id>/logs` — อ่านอย่างเดียว ไม่ rerun/approve

---

## ❓ Quiz

**1.** ถ้าคุณรัน `docker compose up -d` (ไม่มี `-p`) บนเครื่องที่เพื่อนเปิด stack ของเขาไว้แล้ว แล้วตามด้วย `docker compose down -v` จะเกิดอะไรขึ้น?

<details><summary>เฉลย</summary>

ทั้งสองคนได้ project ชื่อ `srisurart-pos` (มาจาก `name:` ในไฟล์) → ใช้ volume `srisurart-pos_pgdata` ตัวเดียวกัน
`down -v` จะหยุด container ของเพื่อนและ **ลบ database ของเพื่อนทิ้ง** — เพราะ Compose มองว่าเป็น project เดียวกัน
ใส่ `-p <ชื่อของคุณ>` ทุกครั้งจึงเป็นกฎ

</details>

**2.** `curl -sk https://localhost/api/v1/platform/tenants` จากเครื่องตัวเองได้ 403 (HTML ของ Nginx) แต่คำสั่งเดียวกันผ่าน `docker compose exec nginx curl -sk https://127.0.0.1/...` ผ่าน ทำไม? และ 403 ที่เป็น HTML บอกอะไรเราเพิ่ม?

<details><summary>เฉลย</summary>

Nginx อนุญาตเฉพาะ `127.0.0.1`/`::1` บน path นั้น — บน Docker Desktop request จาก host มาถึง Nginx ผ่าน NAT จึงมี IP ต้นทางเป็น gateway ของ Docker
ส่วน `exec` เข้าไปใน container ของ Nginx แล้วยิงไป `127.0.0.1` คือ loopback ของ Nginx เองจริงๆ
การที่ response เป็น HTML ของ Nginx (ไม่ใช่ JSON envelope) บอกว่า request ถูกปฏิเสธตั้งแต่ Nginx ยังไม่ถึง API เลย

</details>

**3.** Prometheus แสดง `api-readiness` เป็น `down` ทั้ง 3 ตัว แต่ `curl https://localhost/health/ready` ได้ 200 — ระบบพังไหม? ควรดูอะไรแทน?

<details><summary>เฉลย</summary>

ไม่พัง Prometheus ถือว่า "up" ก็ต่อเมื่อ parse body เป็น text format ของมันได้ แต่ `/health/ready` ตอบ JSON จึงถูกนับเป็น down เสมอ (gap ที่รู้แล้ว)
ให้ดู job `api-metrics` (scrape `/metrics` ที่เป็น text format จริง) ซึ่งขึ้น `up` ทั้งสามตัว

</details>

**4.** ถ้า build เว็บด้วย `flutter build web` เฉยๆ (ไม่ส่ง dart-define) แล้วเปิดไว้ข้างๆ Grafana หน้าสินค้าจะเป็นยังไง และทำไม?

<details><summary>เฉลย</summary>

หน้าสินค้าโหลดไม่ขึ้น (`โหลดสินค้าไม่สำเร็จ: TypeError: Failed to fetch`) เพราะ repository ฝั่งอ่านเป็น `Api*Repository` โดย default (`useApiRepositories = true`)
และ `API_BASE_URL` default คือ `http://localhost:3000` ซึ่งตอนนั้นคือ Grafana → ไม่มี CORS header และไม่ใช่ API ของเรา
แก้โดย build แบบ `API_BASE_URL=` แล้วให้ Nginx เสิร์ฟ (same-origin) หรือใช้ branch `POC_sample_offline_first` ถ้าต้องการ offline ล้วน

</details>

**5.** ใน psql เป็น `pos_app` คุณสั่ง `SET row_security = off;` แล้วได้คำตอบ `SET` — แปลว่าคุณปิด RLS ได้แล้วใช่ไหม? ถ้า query ต่อจะเกิดอะไร?

<details><summary>เฉลย</summary>

ไม่ใช่ `SET` สำเร็จแค่การตั้งค่าตัวแปร แต่ role ที่ไม่มี `BYPASSRLS` ไม่ได้ข้ามการกรอง — Postgres เปลี่ยนพฤติกรรมเป็น "ถ้า query จะโดน RLS กรอง ให้ error แทน"
จึงได้ `ERROR: query would be affected by row-level security policy for table "products"` — ยังปลอดภัย (fail-closed)

</details>

**6.** `Deploy (demo)` run หนึ่งขึ้น ✓ เขียว เพื่อนบอกว่า "deploy ขึ้น VM แล้ว" — คุณจะตรวจยังไง และทำไมไม่เชื่อสีเขียว?

<details><summary>เฉลย</summary>

`gh run view <id>` ดูว่า job `deploy to demo` เป็น `✓` หรือ `-` (ถูกข้าม) — run `35957750138` เขียวทั้งที่ deploy ถูกข้ามเพราะ image บน GHCR ยังไม่ครบ
และถึง job จะรัน ปัจจุบันก็ยังติด FortiGate ดึง image ไม่ได้ หลักฐานจริงเดียวคือ `/opt/pos/.current_sha` บน VM

</details>

---

## ➡️ อ่านต่อ

- ถัดไป: **capstone** — [18_capstone.md](18_capstone.md) กลั่นเหตุการณ์จริงจากทุกบท (รวมทั้ง stack `studylab` ที่เพิ่งรันในบทนี้) เป็นหลักการวิศวกรรม
- ย้อนดูเบื้องหลังแต่ละชิ้น: [14_devops.md](14_devops.md) (Docker/Nginx/Prometheus), [15_cicd.md](15_cicd.md) (pipeline), [07_database.md](07_database.md) (RLS), [11_security.md](11_security.md) (allowlist, loopback, basic auth), [12_testing.md](12_testing.md)
- เอกสารต้นทาง: `server/README.md` (Run, Checks, The e2e suite, Monitoring overlay), `frontend/README.md`, `docs/tutorial/testing-tutorial.md`,
  `docs/Backend_design/07_CICD_DEPLOY.md` (deploy + SSH tunnel), `docs/Backend_design/02_API_SCREENS.md` (สัญญา API)

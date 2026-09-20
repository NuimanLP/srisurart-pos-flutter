# แบ่งงาน 3 agent — ชุดใบงานเดโม #335 (2026-09-20)

แผนแบ่งงานสำหรับรัน agent สามชุดขนานกันบนใบ #336–#346 (ลูกของสเปก #335)

> 📋 **สถานะปัจจุบันของแต่ละเลนอยู่ที่ [`demo-335-STATUS.md`](demo-335-STATUS.md)** — ไฟล์นี้คือ *แผน* ซึ่งนิ่ง
> ส่วนไฟล์นั้นคือ *สถานะ* ซึ่งทุกเลนเข้าไปอัปเดตเอง อ่านคู่กันเสมอ
เขียนไว้เพื่อให้หยิบไปวางเป็น prompt ตั้งต้นของแต่ละ agent ได้เลย

## กราฟพึ่งพา (ย่อ)

```
#336 env.secrets ──┬── #337 admin.bootstrap ── #338 platform.provision ─┐
                   │                                                    │
                   ├── #339 metrics.serve ── #340 dashboard ── #341 replay ─┤
                   │                                                    │
                   └── #343 vm.deploy 🔒 ───────────────────────────────┤
                                                                        ├─ #344 vm.demo 🔒 ── #345 reconcile
#342 web.server-build ──────────────────────────────────────────────────┘

#346 ops.backup-scripts — อิสระ ไม่บล็อกใคร ไม่ถูกบล็อก
```

## เลน

| เลน | ใบ | อาณาเขตไฟล์ | เริ่มได้เมื่อ |
|---|---|---|---|
| **A — platform** | #336 → #337 → #338 | `server/.env` (ไม่เข้า git), `server/src/db/`, `server/src/common/password.ts` (อ่านอย่างเดียว), `server/test/` ไฟล์ใหม่, runbook ใน `docs/handoff_log/` | ทันที |
| **B — observability** | #339 → #340 → #341 | โมดูล metrics ใหม่ใน `server/src/`, `app.setup.ts`, `server/docker/nginx/nginx.conf`, `deploy/prometheus/`, `deploy/grafana/`, `server/test/` ไฟล์ใหม่ | เขียนโค้ดได้ทันที · **ทดสอบจริงได้หลัง A ปิด #336** |
| **C — client/CI + ops** | #342 → #346 → (#343 เมื่อ A ปิด #336 และเจ้าของต่อ VPN) | `.github/workflows/flutter.yml`, `deploy/ansible/`, `deploy/scripts/` | ทันที |

ใบ #344 และ #345 **ไม่มอบให้เลนใด** — เป็นงานรวมตอนท้ายที่ต้องต่อ VPN
ทำหลังจากทั้งสามเลนปิดใบของตัวเองแล้ว

## 🔴 กฎกันชนกัน (อ่านก่อนสตาร์ท)

1. **สแตก local มีเจ้าของคนเดียว = เลน A** · `server/docker-compose.yml` ตั้ง `name: srisurart-pos` และ publish พอร์ต 80/443 ไว้ตายตัว ดังนั้นสอง agent ที่รัน `docker compose up` พร้อมกันจะแย่ง container และพอร์ตกันเอง
   เลน B/C ที่ต้องการสแตกของตัวเองให้ใช้ `-p <ชื่อไม่ซ้ำ>` เสมอ และ **ห้าม `docker compose down -v`** เด็ดขาด (เคยลบ volume ของเซสชันอื่นมาแล้ว — CLAUDE.md)
2. **`server/package.json` ถูกแตะสองเลน** — A เพิ่ม script, B เพิ่ม dependency `prom-client` · คนละย่อหน้าก็จริงแต่ rebase ชนได้ ใครขึ้นทีหลัง rebase ก่อน push
3. **ห้ามแก้ architecture spec ให้เขียว** — `tenant-door.spec.ts`, `idempotency-routes.spec.ts`, `tenant-wrapper.spec.ts` ถ้าแดง แปลว่าออกแบบผิด กลับไปคิดใหม่ (กฎใน CLAUDE.md)
4. **หนึ่งใบ = หนึ่ง branch = หนึ่ง PR** · `main` มี branch protection: ต้องผ่าน PR และ status job ทั้งสองตัว
5. **ห้าม commit ค่า secret จริง** ไม่ว่ากรณีใด
6. **ADR ชนะเอกสารเสมอ** — ถ้าใบงานขัดกับ ADR ให้หยุดแล้วถาม ไม่ใช่เลือกเอง

## จังหวะประสาน

- **T+0** A เริ่ม #336 (เร็วที่สุดในชุด) · B เขียนโค้ด #339 ไปก่อนโดยยังไม่ต้องรันสแตก · C เริ่ม #342
- **A ปิด #336 แล้วประกาศ** → B รันทดสอบจริงได้ · C เริ่ม #343 ได้เมื่อ VPN พร้อม
- **ทั้งสามเลนปิดใบของตัวเอง** → ทำ #344 (เดโมครบวง) แล้วปิดท้ายด้วย #345

## ข้อตกลงการทำงานต่อใบ (จาก `09 §10`)

`/scrutinize` แนวทางก่อน → เขียนโค้ดตาม `karpathy-guidelines` → เทสต์เฉพาะฝั่งของตัวเอง → ปิดด้วย `/code-review`

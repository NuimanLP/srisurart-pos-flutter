# handoff_log — index

1 บรรทัดต่อ handoff · เรียงใหม่ → เก่า · รูปแบบตาม [`handoff-prompt-template.md`](handoff-prompt-template.md)

- 2026-09-09 — [Lane A: #40 image artefact + #18 idempotency](lane-a-ci3-idempotency.md) — #40 merged (`2a5d377`, artefact ออกจริงบน `main` 63.6 MB + 16.1 MB) · #18 PR #51 เขียวรอ merge (unit 8 / e2e 26) · 🔴 ถอด Trivy image scan เพราะ `node:22-alpine` มี 13 fixable HIGH/CRITICAL ของตัวเอง → #44 · 🔴 ADR-0003 ทำด้วย guard เดียวไม่ได้ #4 ต้องเป็น split 3 ท่อน — #40 ปิดแล้ว / #18 รอ merge
- 2026-09-09 — [ปิดรูรั่วใน compose: Redis AUTH + ไม่ publish port ของ datastore](compose-hardening-redis-auth-ports.md) — `--requirepass` ทั้งสอง Redis (รหัสไปกับ `REDIS_*_URL`, ไม่แก้โค้ด) · เอา `ports:` ของ Postgres/Redis ออกจาก compose หลัก ย้ายไป `docker-compose.dev.yml` สำหรับ dev+CI เท่านั้น · PR #49 เขียวครบ 4 job · 🔴 ต้องเติม `REDIS_PASSWORD` ใน `.env` เดิม — ปิดแล้ว
- 2026-09-09 — [ทบทวนความปลอดภัย: JWT signing, audit log, CVE/OWASP](security-review-jwt-audit-cve.md) — ADR-0009 addendum (RS256 + `kid`, `typ` claim, access ใน memory) · #43 `audit_log` writer · #44 `sec.1` · job `audit`/`deps-audit` ใน CI · multer override (3 high CVE) · OWASP Top 10 ลง `04_QA` รอบ 4 · 🔴 Dependabot ตั้งผิดรอบแรก เปิด PR #45–#48 ต้องปิดทั้งหมด — ปิดแล้ว
- 2026-09-08 — [ปฏิเสธ CouchDB — คง PostgreSQL](couchdb-rejected.md) — เจ้าของโปรเจกต์ตัดสินคงสถาปัตยกรรมเดิม → ADR-0012 Rejected + บันทึกเหตุผล, ถอน banner freeze ทุกไฟล์ · #4–#37 กลับมาหยิบได้ — ปิดแล้ว
- 2026-09-08 — [แผนฉบับ CouchDB แทน PostgreSQL](couchdb-revision.md) — อาจารย์สั่งเปลี่ยน DB → ADR-0012 (Proposed) + `06_COUCHDB_REVISION.md` + scrutinize รอบ 4 · freeze #4–#37 — ปิดแล้ว (ผล: Rejected ดูบรรทัดบน)
- 2026-09-07 — [merge #41/#42, lane → GitHub handle](merge-p1-p2-lane-assignments.md) — #14/#15 เข้า `main`, team/1–3 ผูกกับคนจริง — ปิดแล้ว
- 2026-09-07 — [reassign #14 → team/1](reassign-ticket-14.md) — ตาม commit author — ปิดแล้ว
- 2026-09-07 — [lane primer](lane-primer-breakdown.md) — `docs/00_LANE_PRIMER.md` สำหรับคนใหม่ — ปิดแล้ว
- 2026-09-07 — [reorganize root → frontend/ server/ docs/](monorepo-root-cleanup.md) — ปิดแล้ว
- 2026-09-06 — [#15 p2 schema + RLS + seed · #38 backend CI](p2-schema.md) — 27 ตารางเป็น migration, RLS forced — ปิดแล้ว
- 2026-09-06 — [#14 p1 compose stack, Nginx, health](p1-compose-stack.md) — ปิดแล้ว
- 2026-09-05 — [design → 30 GitHub issues + แบ่ง 3 ทีม](to-tickets-backend.md) — ปิดแล้ว
- 2026-09-04 — [grill รอบ 2 → ADR-0010/0011 + Flutter CI](grill-round2-ci.md) — ปิดแล้ว
- 2026-09-04 — [backend design grill → ADR + Drift schema v2](backend-design-adr.md) — ปิดแล้ว
- 2026-07-14 — [Riverpod → flutter_bloc](riverpod-to-bloc.md) — ปิดแล้ว

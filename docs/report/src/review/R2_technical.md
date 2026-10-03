# R2: technical correctness after the length cut

Scope: chapters/ch1–ch5 (body only), the 8 diagram PNGs actually used, checked against the repo at
`42b07eb` (origin/main fetched 2026-10-01) and `gh`.

**Note on the brief:** only **8** diagrams are used (`grep FIGURE … diagram:`): evolution, rls-concept,
architecture, client-layers, request-flow, er, outbox-flow, cicd-pipeline. `sync-seq` and `deploy`
still have spec blocks in ch3 but no FIGURE line, so they are not rendered. That is fine.

**Pointers:** every `{fig:}`/`{tab:}` reference resolves to exactly one id. Every "บทที่ N" pointer lands
on content that exists, and the cut left no "ดังที่กล่าวในหัวข้อ …" pointing at a deleted section.
ch1's "หัวข้อวิธีการทำงานของทีมในบทที่ 3" matches the heading `## วิธีการทำงานของทีม`. ch4a's "หัวข้อ
Repository แบบ API ของบทที่ 3" matches `### Repository แบบ API (USE_API_WRITES)`. References are mapped
per file (build.py `register_refs`), so ch4a [2] and ch4b [2] do not collide.

## Findings (prioritised)

1. **[HIGH] Terminology collision introduced by merging chapters: "ระยะที่ N" means two different
   things.** In the ch1 evolution figure, ระยะที่ 1/2/3 = React app / Flutter offline-first / multi-tenant.
   ch4b and ch5 use ระยะที่ 1/2 to mean server **เฟส** 1/2. For example, ch5 สรุปผล has "กลไกการทำงานออฟไลน์ของระยะที่ 2", and ch4b has
   "ระบบหลังบ้านระยะที่ 1", "เซิร์ฟเวอร์ฝั่งระยะที่ 2" and "เกณฑ์ … ของระยะที่ 1". A reader who has seen Fig. 1.1
   reads ch5's "ระยะที่ 2" as the Flutter offline-first build. A third scheme sits on top: ch4a `tab:migration`
   uses "Phase 0–6", so "Phase 1: ชั้นข้อมูลด้วย Drift" ≠ "เฟส 1".
   **Fix:** in ch4b/ch5 replace every "ระยะที่ 1" → "เฟส 1" and "ระยะที่ 2" → "เฟส 2" (6 + 4 occurrences;
   headings `### ภาพรวมของระบบหลังบ้านระยะที่ 1` → `### ภาพรวมของระบบหลังบ้านเฟส 1`, `### เซิร์ฟเวอร์ฝั่งระยะที่ 2`
   → `### เซิร์ฟเวอร์ฝั่งเฟส 2`). In the evolution figure rename the boxes to "รุ่นที่ 1/2/3". Add one sentence
   in ch4a §ลำดับความก้าวหน้า: "Phase 0–6 ในหัวข้อนี้คือขั้นของการย้ายแอปมา Flutter ไม่ใช่เฟส 1/2 ของเซิร์ฟเวอร์".

2. **[HIGH] ch4a, "ผลเพิ่มเติมที่เกิดจากการแก้ข้อบกพร่อง": the wrong cause is given for #488, and it contradicts ch3.**
   The text reads "การคำนวณย้อนจากข้อมูลปัจจุบันไม่แม่นยำเมื่อการตัดสต็อกถูกปัดที่ศูนย์". ch3 `tab:invariants` says
   a sale decrement is strict and never clamps. #488's body says the clamp was on **money** (example:
   mechanic credit 50 → offline `หักจากเครดิต` CN 180 → forward sets 0 → discard restores 180), plus return
   discard clamping stock when the units had been resold.
   **Fix:** "แต่การคำนวณย้อนจากข้อมูลปัจจุบันไม่แม่นยำเมื่อการเขียนครั้งแรกถูกปัดค่าที่ศูนย์ เช่น ช่างมียอดเครดิต 50 บาท
   แต่ใบลดหนี้หักเครดิต 180 บาท ยอดจึงถูกปัดเป็น 0 และการทิ้งกลับคืนยอดเป็น 180 บาท"

3. **[MED] ch3 `tab:screens`: the offline-PIN setup is credited to the wrong screen.** The row
   `devices_screen.dart | ผูกและถอดถอนเครื่อง ตั้ง PIN ออฟไลน์` is wrong. `OfflinePinSetupDialog` is opened only
   from `settings_screen.dart:704`.
   **Fix:** devices row → "ผูกและถอดถอนเครื่อง ออกรหัสผูกเครื่อง". Settings row → "ข้อมูลร้าน การตั้งค่า และการตั้ง PIN
   ออฟไลน์; การเข้าสู่ระบบ".

4. **[MED] ch3 "การยืนยันตัวตนและการผูกเครื่อง" and ch5 งานต่อไป item 1: the "10 นาที" claim is misleading.** The temporary
   password lives **7 days** (`temp_password_expires_at`; checklist: `tempPasswordExpiresAt (+7 วัน)`). The 10 minutes is
   `PWCHANGE_TOKEN_TTL` (`auth.service.ts:38`): after a login with the temp password, the new password must be set
   within 10 minutes or the user logs in again.
   **Fix (ch3):** "…ระบบออกรหัสผ่านชั่วคราวอายุ 7 วันให้เจ้าของ และเมื่อล็อกอินด้วยรหัสนี้ต้องตั้งรหัสใหม่ภายใน 10 นาที".
   **Fix (ch5):** "รหัสผ่านชั่วคราวของเจ้าของร้านที่ต้องตั้งรหัสใหม่ภายใน 10 นาทีหลังล็อกอินครั้งแรก".

5. **[MED] ch5 "ลิงก์ระหว่าง issue กับ PR …" contradicts ch4b `tab:dod` row 3.** ch5 says "ตั๋ว #184 ถูกปิดและเปิดใหม่สามครั้ง
   **โดยไม่มีการวัดจริง**". DoD row 3 (and `03_ARCHITECTURE.md:555`) cites "#184 `close.3` 15 ก.ย. 2569, 201×50 / 409×150 /
   5xx 0", which is a real measurement. What #184 never produced was its k6-latency/RAM ACs.
   **Fix:** "…ตั๋ว #184 ถูกปิดและเปิดใหม่สามครั้ง ทั้งที่เกณฑ์ด้านการวัด latency และหน่วยความจำของตั๋วไม่เคยมีผลวัด".

6. **[MED] ch4b "ผลการทดสอบฝั่งเซิร์ฟเวอร์": "ผ่าน 490 จาก 492 กรณี" implies 2 failures.** `dod-mapping-2026-09-16.md:32` says
   "490 passed | 2 skipped (492)". The number 492 also equals the unit-case count in the table just above, which
   invites a mix-up.
   **Fix:** "…บันทึกว่าผ่าน 490 กรณีและข้าม 2 กรณีจากทั้งหมด 492 กรณี (ไม่มีกรณีล้มเหลว) ซึ่งเป็นจำนวนของชุด e2e ในวันนั้น".

7. **[MED] The ch1 evolution diagram shows phase-2 work as future.** The dashed "เป้าหมาย: Arch. C เต็มรูป" box lists
   outbox + SyncService, PWA, เลขเอกสารฝั่งเครื่อง as not yet done. ch1 `tab:scope` ("ใบงานส่วนใหญ่ merge แล้ว") and ch4a
   `tab:phase2` (all closed 19–28 Sep) say otherwise. Only cutover (#231) is still future.
   **Fix:** make box 4 solid, titled "เฟส 2 (โค้ด merge แล้ว ก.ย. 69)". Keep only the label "cutover รอ #231" dashed/future.

8. **[MED] ch1 `tab:lanes`: CI/CD work is missing for lanes A and B, which undercuts the sentence right above it.** The text says every
   member has frontend, backend **and** CI/CD work. The phase-1 column shows CI only for lane C. Per
   `05_HOW_WE_GOT_HERE.md:444-447`: A = #40 image artefact, B = #39 path filter + isolation check,
   C = #38 backend workflow. Frontend is also missing: A = Checkout/Returns/Cash-drawer writes, B = read screens +
   Drift v3, C = auth/login.
   **Fix:** append to A "; CI: image artefact (#40); ฝั่งแอป: หน้าขาย คืน ลิ้นชัก (เขียนผ่าน API)". Append to B "; CI: path filter
   (#39); ฝั่งแอป: หน้าอ่านข้อมูลและ Drift schema v3". Append to C "; ฝั่งแอป: ล็อกอินและ device token".

9. **[MED] ch3 `tab:endpoints`: the table is incomplete, but the caption claims it was read off the controllers.** The text says "ตรวจจากตัวควบคุม (`*.controller.ts`)".
   `products/catalogue.controllers.ts` (note `controllers`) holds `/categories` (GET/POST/DELETE),
   `/suppliers` (POST/PATCH/DELETE) and `GET /movements`. `/parked-sales` (GET/POST/DELETE) is absent too, although
   `parked-sales` is in `tab:modules` and in the cross-tenant test.
   **Fix:** add rows "หมวดหมู่และซัพพลายเออร์ | `/categories`, `/suppliers`, `GET /movements` | ข้อมูลประกอบสินค้าและประวัติความเคลื่อนไหวสต็อก" and
   "บิลที่พัก | `GET/POST/DELETE /parked-sales` | พักตะกร้า". Alternatively, drop "(`*.controller.ts`) โดยตรง" and say "กลุ่มหลัก".

10. **[MED] The cicd-pipeline diagram (Fig. ch3) shows image build after the status jobs.** In `server.yml`, `build-image`
    (Trivy → GHCR) runs **inside** Server CI on a `main` push, and `server-ci-status` `needs: build-image`. The
    web image is pushed by `flutter.yml` `build-web` (`WEB_IMAGE: ghcr.io/…/srisurart-pos-web`), with no Trivy step.
    `deploy.yml` is then triggered by `workflow_run` of both CIs. As drawn ("status → หลัง merge → สร้างอิมเมจ"), a
    reader infers a separate post-merge stage.
    **Fix:** move "สร้างอิมเมจ + Trivy → GHCR (เฉพาะ push เข้า main)" inside the server.yml box, add "build-web → GHCR" to the
    flutter.yml box, and make the arrow "status เขียวทั้งคู่ → deploy.yml (workflow_run)". The text in ch3 §ระดับของ CI/CD is consistent
    with the code; only the figure is off.

11. **[LOW] ch3 `tab:phases` row "การเขียนข้อมูลเมื่อไม่มีเครือข่าย / เฟส 1: ไม่รองรับ".** Phase 1 already queued credit payments
    offline (`PendingCreditPayments`, #24, later moved into the outbox by #275 per ch4a).
    **Fix:** "ไม่รองรับ ยกเว้นคิวรับชำระเครดิตช่าง (#24) และบิลด์ offline-first เดิม".

12. **[LOW] ch3 "ฐานข้อมูลภายในเครื่อง (Drift)": `PendingCreditPayments` is called "เกิดจากงานเฟส 2".** CLAUDE.md lists it as
    "#24's credit-payment outbox", which is phase-1 era. **Fix:** "กลุ่มที่สองเป็นคิวและตารางสนับสนุนการซิงก์ ได้แก่ `PendingCreditPayments` (#24)
    และตารางของเฟส 2 `DocCounterSeeds`, `OutboxOps`, `SyncCursors`, `OpEffects`".

13. **[LOW] ch3 "การดึงข้อมูลแบบ keyset" omits the `afterId` reset.** The sentence "cursor จึงมีความละเอียดระดับไมโครวินาทีร่วมกับ `afterId` ในหน้าแรก
    ไคลเอนต์ถอย cursor กลับ 30 วินาที" runs two clauses together and leaves out that the first page drops `afterId`
    (`08_PHASE2_SPEC.md:65,469`). **Fix:** "…ร่วมกับ `afterId` ส่วนหน้าแรกของแต่ละรอบ ไคลเอนต์ถอย cursor กลับ 30 วินาทีและไม่ส่ง
    `afterId`…".

14. **[LOW] ch3 "การแยกข้อมูลผู้เช่าด้วย RLS …": the three architecture specs are said to "บังคับข้อกำหนดเหล่านี้" (all four rules).**
    They check the tenant door, the tx wrapper and the idempotency claim on routes. They do not check the PIN-outside-tx rule or the 25 s
    ceiling (which has its own `tx-ceiling.e2e-spec.ts`), and ch4b itself states their blind spot.
    **Fix:** "…บังคับข้อแรกและข้อที่สองในระดับโครงสร้างโค้ด ส่วนเพดานเวลาทดสอบใน `tx-ceiling.e2e-spec.ts`".

15. **[LOW] ch3 "การยืนยันตัวตนและการผูกเครื่อง": citation [7] (RFC 7519) is attached to the 04:00 refresh-expiry rule.** That rule is ADR-0009
    project policy, not anything in the RFC. **Fix:** move `[7]` to the first mention of JWT/RS256 ("ภาคผนวกของ ADR-0009 กำหนดลายเซ็น RS256 [7]").

16. **[LOW] ER diagram: SHIFTS→SALES drawn as mandatory "1".** `sales.shift_id` is a nullable `TEXT` (InitialSchema
    line 308). **Fix:** draw it as 0..1 on the SHIFTS side, like CUSTOMERS and MECHANICS. All other ER columns, keys and
    `OUTBOX_OPS` fields (`opId, idempotencyKey, type, payload, aggregates, status, attempts, lastCode`) match
    the code.

17. **[LOW] rls-concept diagram sample receipts "RC01-0001".** These do not follow the ADR-0007 format used everywhere in the
    text (`RC01-2569-08-0042`). **Fix:** use `RC01-2569-09-0001`… or label the column "receipt_no (ย่อ)".

18. **[LOW] outbox-flow diagram top note "5xx/หมดเวลา: คงไว้ ลองซ้ำด้วยรหัสเดิม".** This is correct for an op already in the outbox
    (server answers `retry`). Placed above the ApiSalesRepository → Drift path, though, it reads as if an **online** 5xx queues
    the sale, which the owner explicitly ruled out on 27 Sep (ch3 rule 2). **Fix:** reword to "op ในคิวที่ได้ retry/5xx: คงไว้
    ลองซ้ำด้วยรหัสเดิม · การเขียนออนไลน์ที่ได้ 5xx ไม่เข้าคิว".

19. **[LOW] ch1 "ลำดับเหตุการณ์ที่เกิดขึ้นจริง": the monthly split does not add up to the total.** 18 + 17 + 2 + 962 = 999 ≠ 1,058; the
    missing 59 are October (FACTS ledger). **Fix:** add "และ 59 รายการในวันที่ 1 ตุลาคม" after "2 รายการในเดือนสิงหาคม". (Live
    `origin/main` is now 1,059 commits and 331 merged PRs. The "วัดเมื่อ 1 ต.ค." framing in `tab:progress-stats` covers that; no change.)

20. **[LOW] ch4b "สแตกบนเครื่องสาธิต": "ก่อนหน้านั้นการ deploy ถูกไฟร์วอลล์ปิดกั้น".** DoD row 3 cites a measurement on the demo VM on 15 Sep, so
    something was deployed there earlier. What was blocked was pulling from GHCR, i.e. CD. **Fix:** "ก่อนหน้านั้นการ deploy อัตโนมัติ
    (CD) ซึ่งต้องดึง image จาก GHCR ถูกไฟร์วอลล์ของคณะปิดกั้น".

## Spot-checks that passed (about 45 claims, no change needed)

- Containers table: every image tag and `mem_limit` (nginx 64m, api 384m ×3, worker 256m, bull-board 128m, migrate 128m,
  postgres 1024m with `max_connections=100`, both redis 256m with maxmemory 192 MB, etcd v3.6.12 256m, platform-ui 32m
  on 127.0.0.1:3200, Prometheus v2.55.1 512m, Grafana 11.2.0 256m, node-exporter v1.8.2 64m). api IPs .11–.13,
  platform-ui .20. Nginx `rate=30r/s burst=60`, `location = /metrics`. Prometheus scrape 15 s.
- 20 migrations; tenants `plan`/`status` CHECKs; composite PKs; `sale_items (tenant_id, sale_id, line_no)`;
  `uq_shift_active (tenant_id, device_id) WHERE is_active`; `one_pos_per_tenant`; `doc_counters` 4-column key;
  `idempotency_keys` PK and `endpoint`/`request_hash`; `AuditLogAppendOnly` and `OwnerReviewItemsFixes` migrations exist.
- Doc types RC/CN/PO/QT/CP; ADR-0007 example `RC01-2569-08-0042`; 13 ADR numbers (0003 has an extra plan file).
- Access token 15m; refresh at 04:00 (ADR-0009); `runIdempotent` opens `runTx` (matches request-flow figure);
  `TenantGuard`/`TenantRateLimitGuard` names; rate-limit fail-open (ADR-0006, also for login refund).
- Drift: 26 tables, `schemaVersion 13`; 21 RepositoryProviders; AuthCubit/CartCubit/PendingQuoteCubit (+ theme/font);
  14 screen files and 12 nav routes; `OutboxOps` columns; SyncService batch `take(50)`, Degraded after 3 failures or >5 s.
- Workflow job names in `flutter.yml`/`server.yml` match ch3 exactly; Flutter 3.44.3; every pubspec/package.json
  version in `tab:tech`.
- Client: 90 `*_test.dart`; screens total 20,817 lines; checkout 2,956 / products 3,843 / returns 2,057;
  122 tests at the bloc migration.
- Server: 54 unit and 57 e2e spec files; cross-tenant sweep "All 25 tables" plus 12 HTTP groups; tx-hold 101–131 → 14–22 ms.
- gh: 11 open issues (198 closed); #231/#344/#380/#363/#288/#476/#443 open; #488 closed by PR #495 (owner
  "stock already sold → refuse" decision confirmed in the PR body); #494 merged; all 40+ cited PRs merged; every
  closing date in `tab:fe` and `tab:phase2` matches; all cited commit SHAs exist with matching subjects.
- Diagrams architecture, client-layers and request-flow match the code (apart from items 16–18 above).

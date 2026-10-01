# R1 — Committee / advisor cold read (progress report 240-401, draft2)

Angle: an exam committee member reading the report without context. I checked whether each chapter does its template job, traced every ch1 objective into ch4 evidence and the ch5 summary, and looked for questions a committee would ask that the report leaves unanswered. Report only; no files edited.

Verdict: **fix-then-submit.** The technical evidence is strong and the report is honest about open work. The weak points are about who did the work and how it was done, which a committee will ask about first: (1) 627 of 1,058 commits are co-authored by an AI coding assistant and the report never says so, (2) "เจ้าของโครงงาน" is never defined and makes most of the decisions, and (3) the lane table does not match who actually merged the work.

---

## Objective trace (ch1 §1.2 → ch4 evidence → ch5 §5.1)

| Obj | ch4 evidence | In ch5 §5.1? | Gap |
|---|---|---|---|
| 1 Flutter offline-first, Android/iOS/Web, keep legacy rules | ch4a migration table, invariants, 820 tests | Yes (point 1) | **Android/iOS never built or tested.** CI runs only `flutter build web` (`.github/workflows/flutter.yml:229`). Reporting (which answers P4–P8) is in no objective. |
| 2 NestJS server, PG = truth, rules moved server-side | ch4b modules, DoD 16/17 | Yes (point 2, 4) | OK |
| 3 Tenant isolation with RLS, cross-tenant read returns 0 rows | ch4b `cross-tenant-read.e2e-spec.ts`, DoD #4 | Partly (point 2 names RLS, not the 0-row proof) | Minor |
| 4 Idempotency + lock order under concurrency | ch4b 200×50 run, DoD #3/#15, tx-hold numbers | Partly (point 2 says "ตะเข็บ…idempotency") | The concurrency numbers are not mentioned in ch5 |
| 5 Phase-2 offline (outbox, sync, doc numbers, enrolment) | ch4a phase-2 table, ch4b `/sync/push` | **No.** None of the five points covers phase 2 | Also never says it is proven only against fakes/fixtures, with no end-to-end run (#344) |
| 6 CI/CD incl. scanning, images, deploy to VM, monitoring | ch4b levels 1–4, deploy evidence, Grafana | Yes (point 5) | Scanning and monitoring are not named in ch5 |
| 7 ADRs | ch3 ADR section, stats table (13) | **No** | Minor |

---

## Findings

### HIGH

1. **[HIGH] Whole report, especially ch3 "ขั้นตอนการพัฒนาและการตรวจ": AI-assisted development is not disclosed.**
   - `git log --format=%B | grep -ci "co-authored-by: claude"` returns **627 of 1,058** commits.
   - The ch3 paragraph presents an AI-agent skill workflow (scrutinize → karpathy guidelines → two-axis code review) as if it were the team's own manual process.
   - ch1 reference [16] cites `CLAUDE.md`, an agent instruction file.
   - A committee will see "Phase 0–6 in one day (23 มิ.ย.)" in ch4a and ask how that was done.
   - Fix: add a subsection to ch3 §วิธีการทำงานของทีม titled "### เครื่องมือช่วยพัฒนาด้วยปัญญาประดิษฐ์". It should state:
     - the tool used (Claude Code);
     - what it was used for (writing code and tests, drafting documents, first-pass review);
     - what the students did themselves (architecture choices and ADRs, setting acceptance criteria, approving PRs and deploys, running and checking on `mob04`, and deciding what counts as evidence);
     - how output was checked (CI, e2e tests, DoD re-count against the test files).
   - Replace ref [16] (`CLAUDE.md`) with the underlying handoff log or `03_ARCHITECTURE.md §8`.
   - Check the faculty's AI-use policy before submitting.

2. **[HIGH] ch1–ch5 (34 occurrences): "เจ้าของโครงงาน" is never defined, yet it decides scope, risk acceptance and acceptance criteria.**
   - The committee cannot tell whether it means the shop owner, the advisor, or a student. Repo evidence (deploy approver `NuimanLP`, "owner-approved" ADR addenda) points to a team member.
   - If so, phrases like "เจ้าของโครงงานรับความเสี่ยงนี้" (ch4b backup) and "เจ้าของโครงงานรับทราบแล้ว" (ch4b fork AC) read as students approving their own work.
   - Fix: define the term once in ch1 §1.4.3 after the lane table. Proposed text: "ในรายงานนี้ คำว่า **เจ้าของโครงงาน (product owner)** หมายถึง <ชื่อ/บทบาท> ซึ่งเป็นผู้ตัดสินขอบเขต ลำดับงาน และเกณฑ์ตรวจรับ ส่วนข้อความภาษาไทยบนหน้าจอและกติกาทางธุรกิจรับรองโดย <เจ้าของร้าน/ผู้ใด>"
   - Where the shop owner is meant (Thai-string ratification in ch4a and ch5 item 9; the P1–P8 source in ch1), say "เจ้าของร้าน" instead.

3. **[HIGH] ch1 tab:lanes, ch4a "การแบ่งงานและตั๋วที่ปิดแล้ว", and ch4b "สรุปผลงาน…" (last-but-one paragraph): per-member contribution is missing, and the lane table misattributes work.**
   - ch4b says contribution "แยกไม่ได้อย่างน่าเชื่อถือ" because of multiple git accounts. In fact the emails map cleanly:
     - NuiGates, NuiGates_2456 and "Chavatik Thorarit" are one person: 890 commits.
     - Pattarapon: 115 commits.
     - LomerAlloys: 53 commits.
   - Merged PRs by author (`gh pr list --state merged --author`): NuimanLP 273, PattaraponKitcharoen 43, LomerAlloys 15.
   - The table says lane B (LomerAlloys) owns the whole on-device engine. But PRs #318, #329, #330, #331, #332, #334 and #347 (tickets #230, #275, #229, #193, #211, #276, #212) were authored by PattaraponKitcharoen. LomerAlloys authored #324 (outbox/SyncService) and #327.
   - The table gives lane A three phase-2 tickets, while every post-09-27 phase-2 fix in tab:phase2 (#456, #469, #484, #491–#495, #483, #539, #544) was authored by NuimanLP.
   - A committee asks "who did what" first. Fix:
     - add an "ผู้ทำ (PR author)" column to tab:phase2;
     - add a short per-member table to ch4b listing merged PRs and 3–4 representative deliverables each;
     - replace the "แยกไม่ได้" sentence with: "บัญชี git สามชื่อแรกเป็นของสมาชิกคนเดียวกัน (ตรวจจากอีเมล) ตารางที่ {tab:members} สรุปผลงานรายบุคคลจาก PR ที่รวมแล้ว"
   - Note in tab:lanes that it shows the planned split, and give the actual split separately.

4. **[HIGH] ch1 §1.2 objective 1, scope table "ฐาน Flutter", ch3 §สถาปัตยกรรมโดยรวม: "Android, iOS และเว็บ" is claimed but never evidenced.**
   - ch4/ch5 never mention Android or iOS, and CI builds only web.
   - Fix (pick one):
     - (a) build an APK once and add one line plus a screenshot to ch4a; or
     - (b) reword objective 1 to "…บนเว็บเป็นหลัก (โค้ดชุดเดียวรองรับ Android และ iOS แต่ยังไม่ได้ทดสอบบนอุปกรณ์จริง)" and add "ทดสอบบน Android/iOS" to ch5 future work.

5. **[HIGH] ch5 §สรุปผลการดำเนินงาน: objective 5 (phase 2, the "offline" half of the project title) has no summary point.**
   - Fix: add a sixth point. "ประการที่หก กลไกทำงานออฟไลน์ของระยะที่ 2 (คิว `outbox_ops`, `SyncService`, `POST /sync/push`, เลข RC/CN ฝั่งเครื่อง และ PIN ออฟไลน์) ถูกพัฒนาและรวมโค้ดแล้ว และทดสอบแต่ละฝั่งกับไฟล์ตัวอย่างคำขอชุดเดียวกัน 18 ไฟล์ แต่ยังไม่ได้พิสูจน์แบบครบวงจรกับเซิร์ฟเวอร์จริง ซึ่งเป็นเป้าหมายของการสาธิต #344"
   - Better still, replace the five-point paragraph with a table of objective → result → evidence section → status, using the trace table above. A committee checks objectives against conclusions line by line.

6. **[HIGH] ch1 §1.5 benefit 1 and table tab:pain: problems P1–P8 are never traced to features or evidence, and benefit 1 claims they are all solved.**
   - No later chapter mentions P1–P8.
   - P4–P8 (daily totals, profit, sales, best sellers) depend on the reports and closing-report screens, but no objective covers reporting.
   - "คิดต้นทุนตามล็อตจริง" is inaccurate: the system uses weighted-average cost (ch2, receivePO), which blends lots.
   - Fix:
     - add "รายงานยอดขาย กำไร และสินค้าขายดี" to objective 1;
     - add a small table in ch4a (or ch5.1) mapping P1–P8 → feature/screen → evidence;
     - in benefit 1, change "คิดต้นทุนตามล็อตจริง" to "คิดต้นทุนเฉลี่ยถ่วงน้ำหนักเมื่อรับสินค้าแต่ละล็อต" and change "ซึ่งตอบปัญหา P1–P8" to "ซึ่งออกแบบเพื่อตอบปัญหา P1–P8 (ยังไม่ได้ประเมินผลกับผู้ใช้จริง)".

### MED

7. **[MED] ch1 §1.1.4 "เหตุผลที่ต้องมีระบบเซิร์ฟเวอร์แบบหลายร้านค้า": the reason for multi-tenancy is mostly "the course said so", and no second shop exists.**
   - A committee will ask "which other shops?" Fix: add one sentence. "ปัจจุบันยังไม่มีร้านที่สองที่ใช้งานจริง การแยกผู้เช่าพิสูจน์ด้วยร้านสาธิตหลายร้านในชุดทดสอบ (`cross-tenant-read.e2e-spec.ts`) และบน `mob04`"
   - Reason 2 (course-mandated stack) is cited to [7], the CouchDB ADR. Cite the course brief or design notes instead (FACTS points to the backend design package "course notes", 2026-08-25).

8. **[MED] ch1 "ร้านใช้งานจริง" (§1.1.3 and scope table): real-shop use is asserted with no supporting detail.**
   - Fix: give one verifiable fact, e.g. since when the shop runs it, and that the 2569-09-17 import of the shop's real snapshot (ch4b, #185: 33,700 บาท, 191 ชิ้น) came from that use. Also state plainly that no formal user evaluation or feedback has been collected yet. A committee will ask "what does the shop say?"

9. **[MED] ch4a §ลำดับความก้าวหน้า (Riverpod → bloc paragraph): "บันทึกส่งมอบงานไม่ได้บันทึกเหตุผล…ผู้จัดทำจึงไม่สันนิษฐานเหตุผล" reads as if the authors are documenting someone else's project.**
   - The team made this decision, so state the reason, or delete the sentence.
   - The same outsider voice appears in ch4b backup ("ข้อเท็จจริงที่ต้องแก้จากความเข้าใจแรกคือ…"). Rewrite it as a plain fact: "ในคืนวันที่ 29 กันยายน สคริปต์ทำงานล้มเหลวและทิ้งไฟล์ว่างไว้ PR #519 จึง…"

10. **[MED] Voice across chapters: a three-person report is written as "ผู้พัฒนา" / "ผู้จัดทำ" (singular).**
    - Examples: ch1 ¶ after the P-table, ch4a:26, ch4a:136 "ร่างของผู้พัฒนา", ch5 item 9.
    - Fix: use "คณะผู้จัดทำ" throughout.

11. **[MED] ch1 §1.4.2 Gantt text: "ยังไม่ผ่านการยืนยันกับอาจารย์ที่ปรึกษา" is printed in a document submitted to that advisor.**
    - Confirm rows 9–14 with the advisor before submitting and delete the clause.
    - Also, "เจ้าของโครงงานกำหนดว่าแผนงานเฟส 1 'ไม่ผูกกับกำหนดส่ง'" will alarm a committee that grades against deadlines. Drop it or rephrase: "แผนเฟส 1 จัดลำดับตามความพึ่งพาของงาน"

12. **[MED] ch1 scope table, row เฟส 2 ("ใบงานส่วนใหญ่ merge แล้ว"): the claim is unquantified.**
    - ch1 says the phase-2 plan is 35 tickets (A 3, B 15, C 17). Give the closed/open count as of 1 ต.ค. (from `09_PHASE2_LANES.md` plus `gh issue view`), e.g. "ปิดแล้ว N จาก 35 ใบ".

13. **[MED] ch4b §สรุปผลงานที่มีความก้าวหน้า: "issue ที่เปิดอยู่ 11 รายการรวม…" lists only 6 of them.**
    - Open issues today: #2, #196, #231, #288, #335, #338, #344, #363, #380, #443, #476.
    - #2 (phase-1 program brief) and #196 (phase-1 close-out parent) are still open while ch1 says phase 1 is "แล้วเสร็จ เว้น k6". A committee member clicking through will see the mismatch.
    - Fix: list all 11 with one clause each, and say #2/#196 are parent issues kept open until #380 closes.

14. **[MED] ch3 §ขั้นตอนการพัฒนาและการตรวจ and ch4b §ระดับที่ 1 ถึง 3: branch protection requires a PR with 0 approvals.**
    - The report does not say who reviews code. A committee will ask about peer review in a three-person team.
    - Fix: state the actual review practice, e.g. who reviews which lane's PRs, or that review is self/AI-assisted plus required CI. Tie this to finding 1.

15. **[MED] ch5 §ปัญหาและอุปสรรค: 5 of the 9 items are repo-process incidents, while the hardest technical problems are buried in ch4a.**
    - Process incidents: PR merged before the fix was pushed, issue–PR links, branch deletion, `0` falsy, month-bound test.
    - Buried technical problems: discard reversal needing `op_effects` (#473→#488), duplicate RC numbers (#489), 5xx not being a verdict.
    - A committee values the technical problems more. Fix:
      - move 2–3 technical problems (with problem / cause / fix / lesson) into ch5;
      - merge the three git/GitHub process items into one "การควบคุมการรวมโค้ดและหลักฐาน" item.
    - Keep #162 (pool exhaustion); it is a good one.

16. **[MED] ch5 §สรุปผลการดำเนินงาน point 5: "ผ่านการอนุมัติของมนุษย์" is odd wording for a committee, and it hints at the undisclosed AI context.**
    - Replace with "ผ่านการอนุมัติของผู้ตรวจที่กำหนดบนสภาพแวดล้อม `demo`".

17. **[MED] ch5 §งานที่จะดำเนินการต่อไป item 3 and the closing paragraph, plus ch3 (14× "ห้าม"): internal operating rules leak into the report.**
    - Examples: "จนกว่าจะทำ ห้ามอ้างว่า 'การสำรองข้อมูลพร้อมแล้ว'", and "การตรวจ `.current_sha` ทุกครั้งก่อนอ้างว่ามีการ deploy".
    - These are runbook rules for the team or agents, not findings. Rephrase as statements of status, e.g. "ระหว่างนี้ระบบจึงยังไม่มีสำเนาข้อมูลนอก VM". Move the monitoring checklist out, or keep one sentence.

18. **[MED] ch2 (whole chapter): there is no related-work or existing-solution comparison.**
    - A committee commonly asks "why not use an existing POS product?" Fix: add a short §2.x comparing 2–3 existing POS options on offline sales, mechanic credit, Thai receipts and cost, with cited official pages. If none can be verified, add one honest paragraph explaining why an off-the-shelf POS did not fit: the legacy rules in `db.js` and the course requirements.

### LOW

19. **[LOW] ch5 title "สรุป":** the senior example and template use "บทที่ 5 ผลการดำเนินงาน" with 5.1/5.2/5.3. Rename to "ผลการดำเนินงาน" to match the template.

20. **[LOW] ch1 §1.4.1:** the monthly commit counts (18/17/2/962) add up to 999 of 1,058 because 59 are from October. Add "และ 59 รายการในวันที่ 1 ตุลาคม" so a reader's sum works out.

21. **[LOW] ch1 §1.3.3 "ข้อจำกัดของสิ่งที่รายงานนี้อ้างว่าเสร็จ":** the content is good but repeats ch4b DoD and ch5.1 nearly word for word. Keep the ch1 version to one sentence and point to ch4 (tab:dod).

22. **[LOW] ch4b "ภาพรวมของระบบหลังบ้านระยะที่ 1" vs ch1/ch3 "เฟส":** ch4b says "ระยะที่ 1/2" while ch1/ch3 say "เฟส 1/2", and ch4a uses both. Pick one, e.g. "เฟส", and use it everywhere.

23. **[LOW] ch1 §1.5 benefit 2:** "มีข้อมูลสำรองไว้ที่ศูนย์กลาง (เมื่อการสำรองออกนอก VM เสร็จสมบูรณ์)" makes a benefit out of something that is parked. Reword to "ข้อมูลอยู่ที่ศูนย์กลางและสำรองรายวันบนเครื่องเซิร์ฟเวอร์ (การสำรองออกนอกเครื่องยังเป็นงานค้าง #363)".

24. **[LOW] ch4b §ระดับที่ 4 deploy-evidence table:** six GitHub run IDs mean nothing to a committee. Keep them in the FACTS ledger or an appendix, and replace the column with dates/SHAs only.

25. **[LOW] ch1 §1.1.4 ¶ "การเลือกสถาปัตยกรรม…":** Architecture A/B/C and tenancy model T1 are introduced as letters before ch2 explains them. Add a 3-row mini table, or a sentence defining A/B/C in plain Thai at first use. The committee reads ch1 first.

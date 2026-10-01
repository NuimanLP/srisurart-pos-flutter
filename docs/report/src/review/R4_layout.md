# R4 - Rendered layout vs faculty template (all 24 sheets viewed; body page N = PDF page N+11)

Overall: structure matches the template (cover, contents/figure/table/abbreviation lists with ก-ญ, chapters from page 1, captions fig-below/table-above, numbering 1.1.1, IEEE bibliography). Problems are rendering/pagination, not structure.

## HIGH
1. [HIGH] Body text everywhere (e.g. body p.1, 3, 10-21, 38-45) - Thai paragraphs are justified at SPACES only, giving huge word gaps ("คือ        ร้านศรีสุรัตน์", "(Purchase     Order:    PO)"), stretched lines, lone words. Looks broken on most pages.
   Fix (build.py `para`, `list_item`, bibliography `q`): use Thai distribution:
   ```python
   def thai_just(p):
       pPr = p._p.get_or_add_pPr(); jc = pPr.find(qn("w:jc"))
       if jc is None: jc = OxmlElement("w:jc"); pPr.append(jc)
       jc.set(qn("w:val"), "thaiDistribute")
   ```
   Call it in `para()`/`list_item()` (not table cells/captions). If the PDF is made by LibreOffice and still stretches, fall back to `p.alignment = WD_ALIGN_PARAGRAPH.LEFT` for body paragraphs.
2. [HIGH] Body p.51-52 ("4.2 หน้าจอของระบบ") - half-page white gap on p.51, then Figure 4.1 (very tall phone-menu screenshot, ~17 cm, right edge cropped) fills p.52. Cause: `figure()` keep_with_next + `max_h = Cm(17)`.
   Fix: `max_h = Cm(10 if pic.height > pic.width else 14)`; crop the screenshot to the menu column.
3. [HIGH] Tables split leaving orphan rows: Table 1.1 (row P8 alone at top of body p.2), Table 1.3 Gantt (row 14 alone p.8), Table 3.9 (header + 1 row at bottom of p.39), Tables 4.1/4.2/4.3 (header + 1-3 rows stranded, p.49-50, 61-63), Table 3.5/3.6 (p.29-31).
   Fix in `table()` after rows are built:
   ```python
   for r in t.rows:
       r._tr.get_or_add_trPr().append(OxmlElement("w:cantSplit"))
   n = len(t.rows)
   for i, r in enumerate(t.rows):
       if (n <= 12 and i < n-1) or (n > 12 and (i < 2 or i == n-2)):
           for c in r.cells:
               for cp in c.paragraphs: cp.paragraph_format.keep_with_next = True
   ```
   (short tables stay whole; long tables keep header+first row and last two rows together.)
4. [HIGH] Bibliography (PDF p.82-85) - backticks print literally (`docs/Backend_design/...md`) in refs [1],[3],[7]-[10],[12]-[16], and entries are justified so URLs/English create giant gaps ("Available:      https://..."). Fix in `main()`: `q.add_run(f"[{n}]\t{text.replace('`','')}")` and `q.alignment = WD_ALIGN_PARAGRAPH.LEFT`.

## MED
5. [MED] Body p.29 (PDF 40) half blank after Table 3.9 because Figure 3.5 (tall) + keep_with_next jumps to next page; same p.16->17 (Fig 2.1). Fix: lower tall-figure cap (item 2) / width 13 cm for tall diagrams, or move the FIGURE line one paragraph earlier/later in ch2/ch3 so text fills the gap.
6. [MED] Figures 4.2-4.13 (body p.52-61): full-desktop screenshots shrunk to 14.5 cm - UI text unreadable (p.53, 55, 56, 58, 61). Fix: crop to the relevant region before saving, max two per page, or drop the weakest (4.4, 4.9, 4.10, 4.13). Also removes the half-empty pages 54/57/60.
7. [MED] Figures 3.1-3.4 (body p.23, 26, 32, 34): diagram text ~5-6 pt at 14.5 cm; labels unreadable. Fix: regenerate with font >= 11 pt at final width or split 3.1/3.2 into two figures each.
8. [MED] Table 1.3 Gantt (body p.7-8): 11 columns at 10 pt, first column wraps 2-3 lines, month headers wrap ("พ.ย. 69", "ก.พ. 70"). Fix: set `table.autofit=False`, first column 5 cm, month columns 0.9 cm, header labels without the year plus a year row; give the caption `page_break_before` so the whole table sits on one page.
9. [MED] Table 3.9 / 3.5 / 3.6 / 4.6 / 4.7: monospace identifiers break mid-word in narrow columns (`credit_payment.create`, `customers_screen.dart, mechanics_screen.dart`, `*.e2e-spec.ts`); header "type" is top-aligned next to a 2-line header. Fix: header cells `vertical_alignment = WD_ALIGN_VERTICAL.CENTER`; set explicit column widths (monospace column wider).
10. [MED] Front matter length: TOC is 5 pages (3 levels, ~150 lines); abbreviation list is 3 pages with the last (ญ) holding 4 rows. Fix: table cell paragraphs `space_after=0`, line_spacing 1.0 in the abbreviation table so it fits 2 pages; change the TOC field (build.py line 383) to `TOC \o "1-2"` if the advisor accepts two levels (saves ~2 pages).
11. [MED] Figure list entries are long (up to 2 lines) and carry history notes "(ถ่ายก่อนแก้ #479 / #461)". Shorten captions in ch4 to one line and put the history in body text.
12. [MED] Long code paths force ragged lines (body p.44-46, 66-68: `server/test/cross-tenant-read.e2e-spec.ts`, `1788652804200-OwnerReviewItemsFixes.ts`). Fix in `inline()` code branch: insert zero-width break opportunities: `txt = re.sub(r"([/_.\-])", "\\1\u200b", tok[1:-1])` before `p.add_run(txt)`.
13. [MED] Chapter 5 section 5.2.x (body p.66-68) packs bold lead-ins "ปัญหา / สาเหตุ / วิธีแก้ / บทเรียน" into one dense justified paragraph. Fix in `chapter()`: split a paragraph before each `**สาเหตุ**`, `**วิธีแก้**`, `**บทเรียน**` into separate paragraphs (indent_tab False, left_indent Cm(1)).

## LOW
14. [LOW] Cover: fine; English title wraps with "System" alone on line 2 - add a manual break after "Point-of-Sale" or reduce size to 32 half-points.
15. [LOW] Page numbers ก...ญ then 1.. top-right correct; chapter openings (บทที่ N + title centered, blank line) correct; headings have no orphans.
16. [LOW] Half-empty pages at chapter ends (p.21, 48, 81) are normal; p.51 and p.40 are the real gaps (items 2, 5).
17. [LOW] Captions: figures below, tables above, keep-with-next works; header rows repeat across pages (works).
18. [LOW] Table 4.7 DoD "หลักฐาน" column too narrow (3-line file names) - widen col 4, shrink col 2.
19. [LOW] Bibliography [8],[13]-[16] are repo docs without "[Online]" form; acceptable, but make wording uniform if the advisor checks IEEE strictly.

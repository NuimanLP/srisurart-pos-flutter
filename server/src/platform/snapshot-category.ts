/** db.js getProducts(): a legacy product's `zone` names its category (01 §9 — finish it at import). */
export const ZONE_TO_CATEGORY: Record<string, string> = {
  Engine: 'เครื่องยนต์',
  Electrical: 'ไฟฟ้า',
  Oils: 'น้ำมัน',
  Brakes: 'เบรก',
  Body: 'ตัวถัง',
};

/** The category a snapshot product lands in — the rule `importLegacyBackup()` applies. */
export function snapshotProductCategory(p: Record<string, unknown>): string {
  if (p.category != null) return String(p.category);
  if (p.zone != null) return ZONE_TO_CATEGORY[String(p.zone)] ?? String(p.zone);
  return 'เครื่องยนต์';
}

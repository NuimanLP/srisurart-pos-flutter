// Srisurart POS — platform admin dashboard (#443 PR4, UX pass).
// Plain vanilla JS, no build step, no CDN. Every value that came from the server is written
// with textContent (never innerHTML) so a malicious tenant/shop name can never run as HTML.
'use strict';

const TOKEN_KEY = 'platformToken';
const API_BASE = '/api/v1/platform';

const els = {
  logoutBtn: document.getElementById('logoutBtn'),
  loginView: document.getElementById('loginView'),
  loginForm: document.getElementById('loginForm'),
  loginUsername: document.getElementById('loginUsername'),
  loginPassword: document.getElementById('loginPassword'),
  loginPasswordToggle: document.getElementById('loginPasswordToggle'),
  loginMsg: document.getElementById('loginMsg'),
  tenantListView: document.getElementById('tenantListView'),
  createTenantForm: document.getElementById('createTenantForm'),
  createMsg: document.getElementById('createMsg'),
  refreshTenantsBtn: document.getElementById('refreshTenantsBtn'),
  listMsg: document.getElementById('listMsg'),
  tenantTableBody: document.getElementById('tenantTableBody'),
  tenantDetailView: document.getElementById('tenantDetailView'),
  backToListBtn: document.getElementById('backToListBtn'),
  detailMsg: document.getElementById('detailMsg'),
  tdBody: document.getElementById('tdBody'),
  tdShopName: document.getElementById('tdShopName'),
  tdStatusPill: document.getElementById('tdStatusPill'),
  tdMeta: document.getElementById('tdMeta'),
  tdClosedNote: document.getElementById('tdClosedNote'),
  statusMsg: document.getElementById('statusMsg'),
  ownerInfo: document.getElementById('ownerInfo'),
  ownerMsg: document.getElementById('ownerMsg'),
  resetOwnerPasswordBtn: document.getElementById('resetOwnerPasswordBtn'),
  devicesMsg: document.getElementById('devicesMsg'),
  deviceTableBody: document.getElementById('deviceTableBody'),
  importJobTableBody: document.getElementById('importJobTableBody'),
  codeModalBackdrop: document.getElementById('codeModalBackdrop'),
  codeModalTitle: document.getElementById('codeModalTitle'),
  codeModalItems: document.getElementById('codeModalItems'),
  codeModalCloseBtn: document.getElementById('codeModalCloseBtn'),
  closeModalBackdrop: document.getElementById('closeModalBackdrop'),
  closeConfirmLabel: document.getElementById('closeConfirmLabel'),
  closeConfirmInput: document.getElementById('closeConfirmInput'),
  closeMsg: document.getElementById('closeMsg'),
  closeCancelBtn: document.getElementById('closeCancelBtn'),
  closeConfirmBtn: document.getElementById('closeConfirmBtn'),
  replaceModalBackdrop: document.getElementById('replaceModalBackdrop'),
  replaceModalTitle: document.getElementById('replaceModalTitle'),
  replaceLabelInput: document.getElementById('replaceLabelInput'),
  replaceForceBox: document.getElementById('replaceForceBox'),
  replaceForceReason: document.getElementById('replaceForceReason'),
  replaceNoteInput: document.getElementById('replaceNoteInput'),
  replaceMsg: document.getElementById('replaceMsg'),
  replaceCancelBtn: document.getElementById('replaceCancelBtn'),
  replaceConfirmBtn: document.getElementById('replaceConfirmBtn'),
};

/** The tenant the detail view is showing (id + the row last loaded for it). */
let currentTenantId = null;
let currentTenant = null;

// ---- Thai labels (raw value kept in the element's title) ----------------------------

const STATUS_LABELS = { active: 'ใช้งานอยู่', suspended: 'ระงับชั่วคราว', closed: 'ปิดถาวร' };
const PLAN_LABELS = { basic: 'พื้นฐาน', demo: 'สาธิต', loadtest: 'ทดสอบโหลด' };
const JOB_STATUS_LABELS = {
  queued: 'รอคิว',
  running: 'กำลังนำเข้า',
  succeeded: 'สำเร็จ',
  failed: 'ล้มเหลว',
};
const ROLE_LABELS = { pos: 'เครื่องขาย', backoffice: 'หลังร้าน' };

/**
 * Owner decision 2026-10-03: `closed` is terminal (the server refuses with 409 TENANT_CLOSED).
 * Only the transitions that make sense from the current status get a button.
 */
const STATUS_TRANSITIONS = {
  active: ['suspended', 'closed'],
  suspended: ['active', 'closed'],
  closed: [],
};

/**
 * Thai text for a server error code (02_API_SCREENS.md §8). Only codes whose Thai string is
 * owner-ratified, plus TENANT_CLOSED (new in this change; owner-ratified 2026-10-07). Every other code —
 * including the platform codes whose §8 string was ratified 2026-10-07 but is not yet wired here — shows the Thai prefix
 * in describeError() + the server's own message.
 */
const ERROR_TEXT = {
  RATE_LIMITED: 'ระบบกำลังทำงานหนัก กรุณารอสักครู่',
  DEVICE_ALREADY_RETIRED: 'เครื่องนี้ถูกปลดไปแล้ว',
  TENANT_CLOSED: 'ร้านนี้ปิดถาวรแล้ว เปลี่ยนสถานะไม่ได้อีก',
};

/** Owner-panel empty state — the §8 `OWNER_NOT_FOUND` text (owner-ratified 2026-10-07). */
const NO_OWNER_TEXT = 'ร้านนี้ไม่มีบัญชีเจ้าของร้านที่ใช้งานอยู่';

const SESSION_EXPIRED_TEXT = 'เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่';
const BAD_LOGIN_TEXT = 'ชื่อผู้ใช้หรือรหัสผ่านไม่ถูกต้อง';

// ---- token / session -------------------------------------------------------

function getToken() {
  try {
    return sessionStorage.getItem(TOKEN_KEY);
  } catch {
    return null;
  }
}

function setToken(token) {
  try {
    sessionStorage.setItem(TOKEN_KEY, token);
  } catch {
    // sessionStorage unavailable (private mode, etc.) — the session just won't survive
    // a reload; the fetch layer still works for the current page life.
  }
}

function clearToken() {
  try {
    sessionStorage.removeItem(TOKEN_KEY);
  } catch {
    /* ignore */
  }
}

// ---- small DOM helpers (never innerHTML with server data) -----------------

function clearChildren(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
}

function td(text) {
  const cell = document.createElement('td');
  cell.textContent = text == null ? '' : String(text);
  return cell;
}

/** A table cell (or other element) showing a Thai label, with the raw value as its title. */
function labelled(tag, labels, value) {
  const node = document.createElement(tag);
  node.textContent = labels[value] || (value == null ? '' : String(value));
  if (value != null) node.title = String(value);
  return node;
}

function emptyRow(tbody, colspan, text) {
  const row = document.createElement('tr');
  const cell = td(text);
  cell.colSpan = colspan;
  cell.className = 'empty';
  row.appendChild(cell);
  tbody.appendChild(row);
}

function statusPill(status) {
  const pill = labelled('span', STATUS_LABELS, status);
  pill.className = `pill ${Object.hasOwn(STATUS_LABELS, status) ? status : ''}`;
  return pill;
}

// Asia/Bangkok, Thai months, Buddhist year, 24 h: "3 ต.ค. 2569 14:05". Assembled from parts so
// a browser's ICU joining words ("เวลา") cannot change the shape.
const DATE_FMT = new Intl.DateTimeFormat('th-TH', {
  timeZone: 'Asia/Bangkok',
  day: 'numeric',
  month: 'short',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});

function fmtDate(iso) {
  if (!iso) return '-';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso);
  const p = {};
  for (const part of DATE_FMT.formatToParts(d)) p[part.type] = part.value;
  return `${p.day} ${p.month} ${p.year} ${p.hour}:${p.minute}`;
}

function dateCell(iso) {
  const cell = td(fmtDate(iso));
  if (iso) cell.title = String(iso);
  return cell;
}

/** Shows (kind = 'error' | 'ok') or hides (text = null) a per-card message box. */
function say(box, kind, text) {
  if (!text) {
    box.textContent = '';
    box.className = 'msg-box hidden';
    return;
  }
  box.textContent = text;
  box.className = `msg-box ${kind}`;
}

function describeError(err) {
  if (err && err.code && ERROR_TEXT[err.code]) return ERROR_TEXT[err.code];
  if (err && err.code === 'NETWORK') return err.message;
  const tag = err && (err.code || err.status) ? ` (${err.code || err.status})` : '';
  return `ทำรายการไม่สำเร็จ${tag}: ${err && err.message ? err.message : ''}`;
}

/** Shows an error in `box` — except a dead session, which api() already sent to login. */
function fail(box, err) {
  if (err && err.code === 'SESSION_EXPIRED') return;
  say(box, 'error', describeError(err));
}

/** Disables the triggering button while `fn` runs, so a double click cannot send twice. */
async function withBusy(btn, fn) {
  if (btn.disabled) return undefined;
  btn.disabled = true;
  btn.setAttribute('aria-busy', 'true');
  try {
    return await fn();
  } finally {
    btn.disabled = false;
    btn.removeAttribute('aria-busy');
  }
}

function showView(view) {
  for (const v of [els.loginView, els.tenantListView, els.tenantDetailView]) {
    v.classList.add('hidden');
  }
  view.classList.remove('hidden');
}

// ---- API layer --------------------------------------------------------------

class ApiError extends Error {
  constructor(status, code, message, details) {
    super(message);
    this.status = status;
    this.code = code;
    this.details = details || null;
  }
}

/**
 * Calls the platform API and unwraps the `{status,data}` / `{status,error}` envelope
 * (02_API_SCREENS.md §1.2). A 401 on anything but the login call means the session is dead:
 * drop the token and go back to login with a Thai message.
 */
async function api(path, options = {}) {
  const token = getToken();
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;

  let res;
  try {
    res = await fetch(API_BASE + path, {
      method: options.method || 'GET',
      headers,
      body: options.body ? JSON.stringify(options.body) : undefined,
    });
  } catch {
    throw new ApiError(0, 'NETWORK', 'เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ (network error)');
  }

  let body = null;
  try {
    body = await res.json();
  } catch {
    // No JSON body (e.g. a proxy-level error page) — fall through to the status-based message.
  }

  if (res.status === 401 && !options.isLogin) {
    clearToken();
    goToLogin(SESSION_EXPIRED_TEXT);
    throw new ApiError(401, 'SESSION_EXPIRED', SESSION_EXPIRED_TEXT);
  }

  if (!res.ok) {
    const error = body && body.error ? body.error : {};
    throw new ApiError(
      res.status,
      error.code || '',
      error.message || `HTTP ${res.status}`,
      error.details,
    );
  }

  return body ? body.data : null;
}

// ---- routing (#tenant/<id> keeps the detail view across a reload) -----------------

const TENANT_HASH = /^#tenant\/([0-9a-f-]{36})$/; // lowercase only, like the API (#621)

function route() {
  if (!getToken()) {
    goToLogin();
    return;
  }
  els.logoutBtn.classList.remove('hidden');
  // Never confirm a close/replace against a tenant the admin navigated away from.
  hideCloseModal();
  hideReplaceModal();
  const m = TENANT_HASH.exec(location.hash);
  if (m) {
    say(els.statusMsg, null, null);
    say(els.ownerMsg, null, null);
    say(els.devicesMsg, null, null);
    loadTenantDetail(m[1]);
  } else {
    showTenantList();
  }
}

function openTenantDetail(tenantId) {
  location.hash = `#tenant/${tenantId}`; // → hashchange → route()
}

function backToList() {
  if (location.hash) location.hash = '';
  else route();
}

// ---- login / logout ----------------------------------------------------------

function goToLogin(message) {
  currentTenantId = null;
  currentTenant = null;
  els.logoutBtn.classList.add('hidden');
  hideCloseModal();
  hideReplaceModal();
  say(els.loginMsg, 'error', message || null);
  showView(els.loginView);
}

/** Show/hide the login password (eye toggle). Strings: owner-ratified 2026-10-01, 02_API_SCREENS.md §8.1.1. */
function setPasswordVisible(visible) {
  els.loginPassword.type = visible ? 'text' : 'password';
  const label = visible ? 'ซ่อนรหัสผ่าน' : 'แสดงรหัสผ่าน';
  els.loginPasswordToggle.title = label;
  els.loginPasswordToggle.setAttribute('aria-label', label);
  els.loginPasswordToggle.setAttribute('aria-pressed', String(visible));
  els.loginPasswordToggle.querySelector('.eye-open').classList.toggle('hidden', visible);
  els.loginPasswordToggle.querySelector('.eye-off').classList.toggle('hidden', !visible);
}

async function handleLogin(evt) {
  evt.preventDefault();
  say(els.loginMsg, null, null);
  const username = els.loginUsername.value.trim();
  const password = els.loginPassword.value;
  await withBusy(els.loginForm.querySelector('button[type="submit"]'), async () => {
    try {
      const data = await api('/auth/token', {
        method: 'POST',
        body: { username, password },
        isLogin: true,
      });
      setToken(data.token);
      els.loginPassword.value = '';
      setPasswordVisible(false);
      route(); // back to whatever #tenant/<id> the session expired on, or the list
    } catch (err) {
      say(els.loginMsg, 'error', err.status === 401 ? BAD_LOGIN_TEXT : describeError(err));
    }
  });
}

function handleLogout() {
  clearToken();
  if (location.hash) history.replaceState(null, '', location.pathname);
  goToLogin();
}

// ---- tenant list --------------------------------------------------------------

function showTenantList() {
  currentTenantId = null;
  currentTenant = null;
  showView(els.tenantListView);
  loadTenantList();
}

async function loadTenantList() {
  say(els.listMsg, null, null);
  try {
    const tenants = await api('/tenants');
    clearChildren(els.tenantTableBody);
    if (tenants.length === 0) {
      emptyRow(els.tenantTableBody, 5, 'ยังไม่มีร้านในระบบ — สร้างร้านแรกได้จากฟอร์มด้านบน');
    }
    for (const t of tenants) {
      const row = document.createElement('tr');
      row.appendChild(td(t.code));
      row.appendChild(td(t.shop_name));
      row.appendChild(labelled('td', PLAN_LABELS, t.plan));

      const statusCell = document.createElement('td');
      statusCell.appendChild(statusPill(t.status));
      row.appendChild(statusCell);

      const actionCell = document.createElement('td');
      const viewBtn = document.createElement('button');
      viewBtn.className = 'link';
      viewBtn.textContent = 'ดูรายละเอียด (detail)';
      viewBtn.addEventListener('click', () => openTenantDetail(t.id));
      actionCell.appendChild(viewBtn);
      row.appendChild(actionCell);

      els.tenantTableBody.appendChild(row);
    }
  } catch (err) {
    fail(els.listMsg, err);
  }
}

async function handleCreateTenant(evt) {
  evt.preventDefault();
  say(els.createMsg, null, null);
  // #443 PR3 (server, merged): ownerPassword is no longer part of this contract — the server
  // generates a temporary password and returns it once. There is no field for it in this form.
  const body = {
    code: document.getElementById('ctCode').value.trim(),
    shopName: document.getElementById('ctShopName').value.trim(),
    shopNameEn: document.getElementById('ctShopNameEn').value.trim() || undefined,
    ownerUsername: document.getElementById('ctOwnerUsername').value.trim(),
    ownerDisplayName: document.getElementById('ctOwnerDisplayName').value.trim() || undefined,
  };
  await withBusy(els.createTenantForm.querySelector('button[type="submit"]'), async () => {
    try {
      const data = await api('/tenants', { method: 'POST', body });
      els.createTenantForm.reset();
      showCodeModal({
        title: `สร้างร้าน "${data.shopName}" สำเร็จ`,
        items: [
          {
            label: `รหัสผ่านชั่วคราวของเจ้าของร้าน (${data.ownerUsername})`,
            value: data.tempPassword,
            note: `หมดอายุ: ${fmtDate(data.tempPasswordExpiresAt)} (7 วัน) — เจ้าของร้านต้องเปลี่ยนรหัสตอนล็อกอินครั้งแรก`,
          },
          {
            label: 'รหัสลงทะเบียนอุปกรณ์ (enrolCode)',
            value: data.enrolCode,
            note: 'ใช้ได้ 7 วัน (valid for 7 days)',
          },
        ],
      });
      await loadTenantList();
    } catch (err) {
      fail(els.createMsg, err);
    }
  });
}

// ---- tenant detail --------------------------------------------------------------

/** Loads + renders one tenant. Resolves true when the detail on screen is fresh. */
async function loadTenantDetail(tenantId) {
  say(els.detailMsg, null, null);
  if (currentTenantId !== tenantId) els.tdBody.classList.add('hidden');
  currentTenantId = tenantId;
  showView(els.tenantDetailView);
  try {
    const data = await api(`/tenants/${encodeURIComponent(tenantId)}`);
    // The admin may have gone back (or to another tenant) while this was in flight.
    if (currentTenantId !== tenantId) return false;
    renderTenantDetail(data);
    els.tdBody.classList.remove('hidden');
    return true;
  } catch (err) {
    if (currentTenantId !== tenantId) return false;
    els.tdBody.classList.add('hidden');
    fail(els.detailMsg, err);
    return false;
  }
}

/**
 * Re-reads the detail after an action, then shows `okText` in `box` — but only if the admin is
 * still looking at that tenant (they may have gone back while the action was in flight).
 */
async function refreshDetailAfter(tenantId, box, okText) {
  if (currentTenantId !== tenantId) return;
  if (await loadTenantDetail(tenantId)) say(box, 'ok', okText);
}

function renderTenantDetail(data) {
  const t = data.tenant;
  currentTenant = t;
  els.tdShopName.textContent = `${t.shop_name} (${t.code})`;
  clearChildren(els.tdStatusPill);
  els.tdStatusPill.appendChild(statusPill(t.status));
  els.tdMeta.textContent =
    `แผน: ${PLAN_LABELS[t.plan] || t.plan} · เขตเวลา: ${t.timezone} · สร้างเมื่อ: ${fmtDate(t.created_at)}`;

  const allowed = STATUS_TRANSITIONS[t.status] || [];
  for (const btn of statusButtons()) {
    btn.classList.toggle('hidden', !allowed.includes(btn.dataset.status));
  }
  els.tdClosedNote.classList.toggle('hidden', t.status !== 'closed');

  renderOwner(data.owner);
  renderDevices(t.id, data.devices);
  renderImportJobs(data.importJobs);
}

function renderOwner(owner) {
  clearChildren(els.ownerInfo);
  if (!owner) {
    const p = document.createElement('p');
    p.className = 'muted';
    p.textContent = NO_OWNER_TEXT;
    els.ownerInfo.appendChild(p);
    return;
  }
  const tempExpired =
    owner.tempPasswordExpiresAt && new Date(owner.tempPasswordExpiresAt).getTime() < Date.now();
  const rows = [
    { key: 'ชื่อผู้ใช้', value: owner.username },
    { key: 'ชื่อที่แสดง', value: owner.displayName },
    {
      key: 'สถานะรหัสผ่าน',
      value: owner.mustChangePassword
        ? 'ยังใช้รหัสผ่านชั่วคราว — ต้องเปลี่ยนตอนเข้าสู่ระบบ'
        : 'ตั้งรหัสผ่านเองแล้ว',
    },
  ];
  if (owner.mustChangePassword) {
    rows.push({
      key: 'รหัสผ่านชั่วคราวหมดอายุ',
      value: `${fmtDate(owner.tempPasswordExpiresAt)}${tempExpired ? ' (หมดอายุแล้ว)' : ''}`,
      raw: owner.tempPasswordExpiresAt,
      warn: tempExpired,
    });
  }
  rows.push({
    key: 'เปลี่ยนรหัสผ่านล่าสุด',
    value: fmtDate(owner.passwordChangedAt),
    raw: owner.passwordChangedAt,
  });

  const dl = document.createElement('dl');
  dl.className = 'kv';
  for (const { key, value, raw, warn } of rows) {
    const dt = document.createElement('dt');
    dt.textContent = key;
    const dd = document.createElement('dd');
    dd.textContent = value == null ? '-' : String(value);
    if (raw) dd.title = String(raw);
    if (warn) dd.className = 'warn-text';
    dl.appendChild(dt);
    dl.appendChild(dd);
  }
  els.ownerInfo.appendChild(dl);
}

function renderDevices(tenantId, devices) {
  clearChildren(els.deviceTableBody);
  if (devices.length === 0) {
    emptyRow(els.deviceTableBody, 5, 'ร้านนี้ยังไม่มีอุปกรณ์');
  }
  for (const d of devices) {
    const row = document.createElement('tr');
    row.appendChild(td(d.id));
    row.appendChild(td(d.label));
    row.appendChild(labelled('td', ROLE_LABELS, d.role));

    const statusCell = document.createElement('td');
    const pill = document.createElement('span');
    if (d.retiredAt) {
      pill.className = 'pill retired';
      pill.textContent = 'ยกเลิกแล้ว (retired)';
      pill.title = d.retiredAt;
    } else if (d.enrolled) {
      pill.className = 'pill enrolled';
      pill.textContent = 'ผูกเครื่องแล้ว (enrolled)';
    } else {
      pill.className = 'pill not-enrolled';
      const expired = d.enrolExpiresAt && new Date(d.enrolExpiresAt).getTime() < Date.now();
      pill.textContent = expired
        ? 'ยังไม่ผูกเครื่อง — รหัสหมดอายุ (code expired)'
        : 'ยังไม่ผูกเครื่อง (not enrolled)';
      if (d.enrolExpiresAt) pill.title = `${fmtDate(d.enrolExpiresAt)} (${d.enrolExpiresAt})`;
    }
    statusCell.appendChild(pill);
    row.appendChild(statusCell);

    const actionCell = document.createElement('td');
    if (!d.enrolled && !d.retiredAt) {
      const reissueBtn = document.createElement('button');
      reissueBtn.textContent = 'ออกรหัสใหม่ (reissue code)';
      reissueBtn.addEventListener('click', () => handleReissueCode(reissueBtn, tenantId, d.id));
      actionCell.appendChild(reissueBtn);
    } else if (d.enrolled && !d.retiredAt) {
      const replaceBtn = document.createElement('button');
      replaceBtn.className = 'danger';
      replaceBtn.textContent = 'แทนที่อุปกรณ์ (replace)';
      replaceBtn.addEventListener('click', () => openReplaceModal(tenantId, d));
      actionCell.appendChild(replaceBtn);
    }
    row.appendChild(actionCell);

    els.deviceTableBody.appendChild(row);
  }
}

function importResultText(job) {
  if (job.error) return job.error;
  const r = job.result;
  if (!r || typeof r !== 'object') return '-';
  const tomb = r.tombstones || {};
  const n = (v) => Number(v) || 0;
  return (
    `แถวแทนที่สร้าง (tombstone): สินค้า ${n(tomb.products)} · ลูกค้า ${n(tomb.customers)} · ` +
    `ช่าง ${n(tomb.mechanics)} · ตัดผู้จำหน่าย ${n(r.droppedSuppliers)}`
  );
}

function renderImportJobs(jobs) {
  clearChildren(els.importJobTableBody);
  if (jobs.length === 0) {
    emptyRow(
      els.importJobTableBody,
      6,
      'ยังไม่เคยนำเข้าข้อมูลให้ร้านนี้ (0 งาน) — แผงนี้และ CLI ยังไม่มีคำสั่งนำเข้าข้อมูล',
    );
  }
  for (const job of jobs) {
    const row = document.createElement('tr');
    row.appendChild(td(job.id));
    row.appendChild(labelled('td', JOB_STATUS_LABELS, job.status));
    row.appendChild(dateCell(job.created_at));
    row.appendChild(dateCell(job.started_at));
    row.appendChild(dateCell(job.finished_at));
    row.appendChild(td(importResultText(job)));
    els.importJobTableBody.appendChild(row);
  }
}

async function handleReissueCode(btn, tenantId, deviceId) {
  say(els.devicesMsg, null, null);
  await withBusy(btn, async () => {
    try {
      const data = await api(
        `/tenants/${encodeURIComponent(tenantId)}/devices/${encodeURIComponent(deviceId)}/enrol-code`,
        { method: 'POST' },
      );
      showCodeModal({
        title: `รหัสลงทะเบียนใหม่สำหรับอุปกรณ์ ${deviceId}`,
        items: [
          {
            label: 'รหัสลงทะเบียนอุปกรณ์ (enrolCode)',
            value: data.enrolCode,
            note: `หมดอายุ: ${fmtDate(data.enrolExpiresAt)}`,
          },
        ],
      });
      await refreshDetailAfter(
        tenantId,
        els.devicesMsg,
        `ออกรหัสลงทะเบียนใหม่ให้อุปกรณ์ ${deviceId} แล้ว`,
      );
    } catch (err) {
      fail(els.devicesMsg, err);
    }
  });
}

/**
 * `POST /platform/tenants/:id/owner/temp-password` (#443 PR3) — for a forgotten owner
 * password. The confirm dialog is the one control point forcing the admin to have already
 * verified the caller's identity by calling the shop's own phone/e-mail on file, never an
 * inbound caller's own number (owner decision) — there is no way to skip past it in this UI.
 */
async function handleResetOwnerPassword() {
  const tenantId = currentTenantId;
  if (!tenantId) return;
  const confirmed = window.confirm(
    'ยืนยันหรือไม่ว่าได้ "โทรกลับ" ไปที่เบอร์โทร/อีเมลที่บันทึกไว้ตอนเปิดร้านเพื่อยืนยันตัวตนแล้ว ' +
    '(ห้ามเชื่อเบอร์/อีเมลที่ผู้โทรเข้ามาแจ้งเอง) — การกดตกลงจะออกรหัสผ่านชั่วคราวใหม่ทันที ' +
    'และรหัสเดิมของเจ้าของร้านจะใช้ไม่ได้อีกต่อไป',
  );
  if (!confirmed) return;

  say(els.ownerMsg, null, null);
  await withBusy(els.resetOwnerPasswordBtn, async () => {
    try {
      const data = await api(`/tenants/${encodeURIComponent(tenantId)}/owner/temp-password`, {
        method: 'POST',
      });
      showCodeModal({
        title: `รหัสผ่านชั่วคราวใหม่สำหรับเจ้าของร้าน (${data.ownerUsername})`,
        items: [
          {
            label: `รหัสผ่านชั่วคราว (${data.ownerUsername})`,
            value: data.tempPassword,
            note: `หมดอายุใน 24 ชม.: ${fmtDate(data.tempPasswordExpiresAt)} — เจ้าของร้านต้องเปลี่ยนรหัสตอนล็อกอินครั้งถัดไป`,
          },
        ],
      });
      await refreshDetailAfter(
        tenantId,
        els.ownerMsg,
        'ออกรหัสผ่านชั่วคราวใหม่แล้ว — รหัสเดิมของเจ้าของร้านใช้ไม่ได้อีก',
      );
    } catch (err) {
      fail(els.ownerMsg, err);
    }
  });
}

function statusButtons() {
  return document.querySelectorAll('#tenantDetailView [data-status]');
}

/**
 * PATCHes the status with every status button disabled meanwhile (one change at a time), then
 * refreshes the detail. Throws the API error to the caller, which shows it in its own box;
 * on TENANT_CLOSED (someone closed it meanwhile) the detail is re-read first so the stale
 * buttons disappear.
 */
async function changeStatus(tenantId, status) {
  for (const b of statusButtons()) b.disabled = true;
  try {
    await api(`/tenants/${encodeURIComponent(tenantId)}/status`, {
      method: 'PATCH',
      body: { status },
    });
  } catch (err) {
    if (err.code === 'TENANT_CLOSED' && currentTenantId === tenantId) {
      await loadTenantDetail(tenantId);
    }
    throw err;
  } finally {
    for (const b of statusButtons()) b.disabled = false;
  }
  await refreshDetailAfter(
    tenantId,
    els.statusMsg,
    `เปลี่ยนสถานะร้านเป็น "${STATUS_LABELS[status]}" แล้ว`,
  );
}

async function handleStatusButton(btn) {
  const tenantId = currentTenantId;
  const status = btn.dataset.status;
  if (!tenantId) return;
  if (status === 'closed') {
    openCloseModal();
    return;
  }
  const confirmMessages = {
    active: 'ยืนยันเปิดใช้งานร้านนี้หรือไม่?',
    suspended: 'ยืนยันระงับการใช้งานร้านนี้ชั่วคราวหรือไม่?',
  };
  if (!window.confirm(confirmMessages[status] || 'ยืนยันการเปลี่ยนสถานะหรือไม่?')) return;

  say(els.statusMsg, null, null);
  await withBusy(btn, async () => {
    try {
      await changeStatus(tenantId, status);
    } catch (err) {
      fail(els.statusMsg, err);
    }
  });
}

// ---- close-tenant confirmation (type the tenant code; closed is terminal) -------------

function openCloseModal() {
  if (!currentTenant) return;
  els.closeConfirmLabel.textContent = `พิมพ์รหัสร้าน "${currentTenant.code}" เพื่อยืนยัน`;
  els.closeConfirmInput.value = '';
  els.closeConfirmBtn.disabled = true;
  say(els.closeMsg, null, null);
  els.closeModalBackdrop.classList.remove('hidden');
  els.closeConfirmInput.focus();
}

function hideCloseModal() {
  els.closeModalBackdrop.classList.add('hidden');
  els.closeConfirmInput.value = '';
}

/** A close PATCH in flight — typing in the code box must not re-enable the confirm button. */
let closeInFlight = false;

function closeCodeMatches() {
  return (
    !closeInFlight && !!currentTenant && els.closeConfirmInput.value.trim() === currentTenant.code
  );
}

async function handleConfirmClose() {
  const tenantId = currentTenantId;
  if (!tenantId || !closeCodeMatches()) return;
  say(els.closeMsg, null, null);
  say(els.statusMsg, null, null);
  closeInFlight = true;
  try {
    await withBusy(els.closeConfirmBtn, async () => {
      try {
        await changeStatus(tenantId, 'closed');
        hideCloseModal();
      } catch (err) {
        fail(els.closeMsg, err);
      }
    });
  } finally {
    closeInFlight = false;
  }
  // withBusy re-enabled the button; keep it gated on the typed code.
  els.closeConfirmBtn.disabled = !closeCodeMatches();
}

// ---- replace a lost enrolled device (#476: POST …/devices/:deviceId/replace) ------------
//
// Retires the lost device and creates its replacement (new device number) in one server
// transaction; the replacement's enrolment code comes back once and is only ever put in the
// one-time code modal — never logged or stored here.

/** The device the replace modal is for, and whether the admin has been asked to force. */
let replaceTarget = null;
/** A replace POST in flight — typing in the note box must not re-enable the confirm button. */
let replaceInFlight = false;

const FORCE_REASON_TEXT = {
  DEVICE_HAS_OPEN_SHIFT:
    'อุปกรณ์นี้ยังมีกะเปิดอยู่ — ถ้าบังคับแทนที่ กะนี้จะถูกปิดอัตโนมัติแบบไม่ได้นับเงิน และขึ้นเป็นรายการรอตรวจสอบให้เจ้าของร้าน',
  DEVICE_HAS_UNSYNCED_OPS:
    'อุปกรณ์นี้ยังมีรายการค้างส่ง — ถ้าบังคับแทนที่ รายการเหล่านั้นอาจไม่ได้ส่งเข้าระบบ และขึ้นเป็นรายการรอตรวจสอบให้เจ้าของร้าน',
};

function openReplaceModal(tenantId, device) {
  replaceTarget = { tenantId, deviceId: device.id, force: false };
  els.replaceModalTitle.textContent = `แทนที่อุปกรณ์ ${device.id} (${device.label})`;
  els.replaceLabelInput.value = '';
  els.replaceNoteInput.value = '';
  els.replaceForceReason.textContent = '';
  els.replaceForceBox.classList.add('hidden');
  els.replaceConfirmBtn.textContent = 'แทนที่อุปกรณ์';
  els.replaceConfirmBtn.disabled = !replaceReady();
  say(els.replaceMsg, null, null);
  els.replaceModalBackdrop.classList.remove('hidden');
  els.replaceLabelInput.focus();
}

function hideReplaceModal() {
  replaceTarget = null;
  els.replaceModalBackdrop.classList.add('hidden');
  els.replaceLabelInput.value = '';
  els.replaceNoteInput.value = '';
}

/** In force mode the confirm button needs a non-empty note (the server refuses one without). */
function replaceReady() {
  return (
    !replaceInFlight &&
    !!replaceTarget &&
    (!replaceTarget.force || els.replaceNoteInput.value.trim() !== '')
  );
}

function showForceStep(code) {
  replaceTarget.force = true;
  els.replaceForceReason.textContent = FORCE_REASON_TEXT[code];
  els.replaceForceBox.classList.remove('hidden');
  els.replaceConfirmBtn.textContent = 'บังคับแทนที่อุปกรณ์';
  els.replaceNoteInput.focus();
}

async function handleConfirmReplace() {
  const target = replaceTarget;
  if (!target || !replaceReady()) return;
  const body = {};
  const label = els.replaceLabelInput.value.trim();
  if (label) body.label = label;
  if (target.force) {
    body.force = true;
    body.note = els.replaceNoteInput.value.trim();
  }
  say(els.replaceMsg, null, null);
  say(els.devicesMsg, null, null);
  replaceInFlight = true;
  try {
    await withBusy(els.replaceConfirmBtn, async () => {
      try {
        const data = await api(
          `/tenants/${encodeURIComponent(target.tenantId)}/devices/` +
            `${encodeURIComponent(target.deviceId)}/replace`,
          { method: 'POST', body },
        );
        hideReplaceModal();
        showCodeModal({
          title: `อุปกรณ์ใหม่ ${data.device.id} (${data.device.label}) แทนอุปกรณ์ ${data.retiredDeviceId}`,
          items: [
            {
              label: 'รหัสลงทะเบียนอุปกรณ์ (enrolCode)',
              value: data.enrolCode,
              note: `หมดอายุ: ${fmtDate(data.enrolExpiresAt)}`,
            },
          ],
        });
        await refreshDetailAfter(
          target.tenantId,
          els.devicesMsg,
          `ปลดอุปกรณ์ ${data.retiredDeviceId} และสร้างอุปกรณ์ใหม่ ${data.device.id} แล้ว`,
        );
      } catch (err) {
        if (replaceTarget !== target) return; // modal closed/navigated meanwhile
        if (!target.force && FORCE_REASON_TEXT[err.code]) {
          showForceStep(err.code);
        } else {
          fail(els.replaceMsg, err);
        }
      }
    });
  } finally {
    replaceInFlight = false;
  }
  // Re-gate whatever the modal now shows (it may have been reopened for another device).
  if (replaceTarget) els.replaceConfirmBtn.disabled = !replaceReady();
}

// ---- one-time secret modal --------------------------------------------------------------

/**
 * Renders one or more one-time secrets (e.g. a temp password AND an enrolCode from the same
 * create-tenant call). Each item gets its own copy button; everything is built with
 * createElement/textContent, never innerHTML, so a value the server returns can never run as
 * markup.
 */
function showCodeModal({ title, items }) {
  els.codeModalTitle.textContent = title;
  clearChildren(els.codeModalItems);

  for (const item of items) {
    const wrap = document.createElement('div');
    wrap.className = 'code-item';

    const label = document.createElement('label');
    label.textContent = item.label;
    wrap.appendChild(label);

    const box = document.createElement('div');
    box.className = 'code-box';
    box.textContent = item.value;
    wrap.appendChild(box);

    if (item.note) {
      const note = document.createElement('p');
      note.className = 'muted';
      note.textContent = item.note;
      wrap.appendChild(note);
    }

    const copyBtn = document.createElement('button');
    copyBtn.textContent = 'คัดลอก (Copy)';
    copyBtn.addEventListener('click', () => copyText(item.value));
    wrap.appendChild(copyBtn);

    els.codeModalItems.appendChild(wrap);
  }

  els.codeModalBackdrop.classList.remove('hidden');
}

function hideCodeModal() {
  els.codeModalBackdrop.classList.add('hidden');
  clearChildren(els.codeModalItems);
}

async function copyText(text) {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // Clipboard API unavailable (no permission, insecure context) — the value is still
    // selectable text on screen, so this is a convenience failure only.
  }
}

// ---- wiring --------------------------------------------------------------

els.loginForm.addEventListener('submit', handleLogin);
els.logoutBtn.addEventListener('click', handleLogout);
els.createTenantForm.addEventListener('submit', handleCreateTenant);
els.refreshTenantsBtn.addEventListener('click', () =>
  withBusy(els.refreshTenantsBtn, loadTenantList),
);
els.backToListBtn.addEventListener('click', backToList);
els.codeModalCloseBtn.addEventListener('click', hideCodeModal);
els.loginPasswordToggle.addEventListener('click', () =>
  setPasswordVisible(els.loginPassword.type === 'password'),
);
els.resetOwnerPasswordBtn.addEventListener('click', handleResetOwnerPassword);
els.closeConfirmInput.addEventListener('input', () => {
  els.closeConfirmBtn.disabled = !closeCodeMatches();
});
els.closeCancelBtn.addEventListener('click', hideCloseModal);
els.closeConfirmBtn.addEventListener('click', handleConfirmClose);
els.replaceNoteInput.addEventListener('input', () => {
  els.replaceConfirmBtn.disabled = !replaceReady();
});
els.replaceCancelBtn.addEventListener('click', hideReplaceModal);
els.replaceConfirmBtn.addEventListener('click', handleConfirmReplace);

for (const btn of statusButtons()) {
  btn.addEventListener('click', () => handleStatusButton(btn));
}

window.addEventListener('hashchange', route);

// ---- boot --------------------------------------------------------------

route();

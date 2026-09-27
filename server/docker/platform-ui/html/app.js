// Srisurart POS — platform admin dashboard (#443 PR4).
// Plain vanilla JS, no build step, no CDN. Every value that came from the server is written
// with textContent (never innerHTML) so a malicious tenant/shop name can never run as HTML.
'use strict';

const TOKEN_KEY = 'platformToken';
const API_BASE = '/api/v1/platform';

const els = {
  globalError: document.getElementById('globalError'),
  logoutBtn: document.getElementById('logoutBtn'),
  loginView: document.getElementById('loginView'),
  loginForm: document.getElementById('loginForm'),
  loginUsername: document.getElementById('loginUsername'),
  loginPassword: document.getElementById('loginPassword'),
  tenantListView: document.getElementById('tenantListView'),
  createTenantForm: document.getElementById('createTenantForm'),
  refreshTenantsBtn: document.getElementById('refreshTenantsBtn'),
  tenantTableBody: document.getElementById('tenantTableBody'),
  tenantDetailView: document.getElementById('tenantDetailView'),
  backToListBtn: document.getElementById('backToListBtn'),
  tdShopName: document.getElementById('tdShopName'),
  tdMeta: document.getElementById('tdMeta'),
  deviceTableBody: document.getElementById('deviceTableBody'),
  importJobTableBody: document.getElementById('importJobTableBody'),
  codeModalBackdrop: document.getElementById('codeModalBackdrop'),
  codeModalTitle: document.getElementById('codeModalTitle'),
  codeModalValue: document.getElementById('codeModalValue'),
  codeModalExpiry: document.getElementById('codeModalExpiry'),
  codeModalCopyBtn: document.getElementById('codeModalCopyBtn'),
  codeModalCloseBtn: document.getElementById('codeModalCloseBtn'),
};

let currentTenantId = null;

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

function showError(message) {
  els.globalError.textContent = message;
  els.globalError.classList.remove('hidden');
}

function clearError() {
  els.globalError.textContent = '';
  els.globalError.classList.add('hidden');
}

function showView(view) {
  for (const v of [els.loginView, els.tenantListView, els.tenantDetailView]) {
    v.classList.add('hidden');
  }
  view.classList.remove('hidden');
}

// ---- API layer --------------------------------------------------------------

/**
 * Calls the platform API and unwraps the `{status,data}` / `{status,error}` envelope
 * (02_API_SCREENS.md §1.2). On a 401 the session is dead — drop the token and go back to
 * login, same as any other client on this token would have to.
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
  } catch (err) {
    throw new Error('เชื่อมต่อเซิร์ฟเวอร์ไม่ได้ (network error)');
  }

  let body = null;
  try {
    body = await res.json();
  } catch {
    // No JSON body (e.g. a proxy-level error page) — fall through to the status-based message.
  }

  if (res.status === 401) {
    clearToken();
    goToLogin();
    const msg = body && body.error && body.error.message
      ? body.error.message
      : 'เซสชันหมดอายุ กรุณาเข้าสู่ระบบใหม่ (session expired)';
    throw new Error(msg);
  }

  if (!res.ok) {
    const msg = body && body.error && body.error.message
      ? `${body.error.code || res.status}: ${body.error.message}`
      : `คำขอล้มเหลว (HTTP ${res.status})`;
    throw new Error(msg);
  }

  return body ? body.data : null;
}

// ---- login / logout ----------------------------------------------------------

function goToLogin() {
  currentTenantId = null;
  els.logoutBtn.classList.add('hidden');
  showView(els.loginView);
}

async function handleLogin(evt) {
  evt.preventDefault();
  clearError();
  const username = els.loginUsername.value.trim();
  const password = els.loginPassword.value;
  try {
    const data = await api('/auth/token', { method: 'POST', body: { username, password } });
    setToken(data.token);
    els.loginPassword.value = '';
    els.logoutBtn.classList.remove('hidden');
    await loadTenantList();
    showView(els.tenantListView);
  } catch (err) {
    showError(err.message);
  }
}

function handleLogout() {
  clearToken();
  goToLogin();
}

// ---- tenant list --------------------------------------------------------------

function statusPillClass(status) {
  return ['active', 'suspended', 'closed'].includes(status) ? status : '';
}

async function loadTenantList() {
  clearError();
  try {
    const tenants = await api('/tenants');
    clearChildren(els.tenantTableBody);
    for (const t of tenants) {
      const row = document.createElement('tr');
      row.appendChild(td(t.code));
      row.appendChild(td(t.shop_name));
      row.appendChild(td(t.plan));

      const statusCell = document.createElement('td');
      const pill = document.createElement('span');
      pill.className = `pill ${statusPillClass(t.status)}`;
      pill.textContent = t.status;
      statusCell.appendChild(pill);
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
    showError(err.message);
  }
}

async function handleCreateTenant(evt) {
  evt.preventDefault();
  clearError();
  const body = {
    code: document.getElementById('ctCode').value.trim(),
    shopName: document.getElementById('ctShopName').value.trim(),
    shopNameEn: document.getElementById('ctShopNameEn').value.trim() || undefined,
    ownerUsername: document.getElementById('ctOwnerUsername').value.trim(),
    ownerDisplayName: document.getElementById('ctOwnerDisplayName').value.trim() || undefined,
    ownerPassword: document.getElementById('ctOwnerPassword').value,
  };
  try {
    const data = await api('/tenants', { method: 'POST', body });
    els.createTenantForm.reset();
    showCodeModal({
      title: `สร้างร้าน "${data.shopName}" สำเร็จ — รหัสลงทะเบียนอุปกรณ์ (enrolCode)`,
      code: data.enrolCode,
      expiryText: 'ใช้ได้ 7 วัน (valid for 7 days)',
    });
    await loadTenantList();
  } catch (err) {
    showError(err.message);
  }
}

// ---- tenant detail --------------------------------------------------------------

async function openTenantDetail(tenantId) {
  clearError();
  currentTenantId = tenantId;
  try {
    const data = await api(`/tenants/${encodeURIComponent(tenantId)}`);
    renderTenantDetail(data);
    showView(els.tenantDetailView);
  } catch (err) {
    showError(err.message);
  }
}

function renderTenantDetail(data) {
  const t = data.tenant;
  els.tdShopName.textContent = `${t.shop_name} (${t.code})`;
  els.tdMeta.textContent =
    `แผน: ${t.plan} · เขตเวลา: ${t.timezone} · สถานะปัจจุบัน: ${t.status} · สร้างเมื่อ: ${t.created_at}`;

  clearChildren(els.deviceTableBody);
  for (const d of data.devices) {
    const row = document.createElement('tr');
    row.appendChild(td(d.id));
    row.appendChild(td(d.label));
    row.appendChild(td(d.role));

    const statusCell = document.createElement('td');
    const pill = document.createElement('span');
    if (d.retiredAt) {
      pill.className = 'pill retired';
      pill.textContent = 'ยกเลิกแล้ว (retired)';
    } else if (d.enrolled) {
      pill.className = 'pill enrolled';
      pill.textContent = 'ผูกเครื่องแล้ว (enrolled)';
    } else {
      pill.className = 'pill not-enrolled';
      const expired = d.enrolExpiresAt && new Date(d.enrolExpiresAt).getTime() < Date.now();
      pill.textContent = expired
        ? 'ยังไม่ผูกเครื่อง — รหัสหมดอายุ (code expired)'
        : 'ยังไม่ผูกเครื่อง (not enrolled)';
    }
    statusCell.appendChild(pill);
    row.appendChild(statusCell);

    const actionCell = document.createElement('td');
    if (!d.enrolled && !d.retiredAt) {
      const reissueBtn = document.createElement('button');
      reissueBtn.textContent = 'ออกรหัสใหม่ (reissue code)';
      reissueBtn.addEventListener('click', () => handleReissueCode(t.id, d.id));
      actionCell.appendChild(reissueBtn);
    }
    row.appendChild(actionCell);

    els.deviceTableBody.appendChild(row);
  }

  clearChildren(els.importJobTableBody);
  for (const job of data.importJobs) {
    const row = document.createElement('tr');
    row.appendChild(td(job.id));
    row.appendChild(td(job.status));
    row.appendChild(td(job.created_at));
    row.appendChild(td(job.error || '-'));
    els.importJobTableBody.appendChild(row);
  }
}

async function handleReissueCode(tenantId, deviceId) {
  clearError();
  try {
    const data = await api(
      `/tenants/${encodeURIComponent(tenantId)}/devices/${encodeURIComponent(deviceId)}/enrol-code`,
      { method: 'POST' },
    );
    showCodeModal({
      title: `รหัสลงทะเบียนใหม่สำหรับอุปกรณ์ ${deviceId}`,
      code: data.enrolCode,
      expiryText: `หมดอายุ: ${data.enrolExpiresAt}`,
    });
    await openTenantDetail(tenantId);
  } catch (err) {
    showError(err.message);
  }
}

async function handleStatusChange(status) {
  if (!currentTenantId) return;
  const confirmMessages = {
    active: 'ยืนยันเปิดใช้งานร้านนี้หรือไม่?',
    suspended: 'ยืนยันระงับการใช้งานร้านนี้ชั่วคราวหรือไม่?',
    closed: 'ยืนยันปิดร้านนี้ถาวรหรือไม่? การกระทำนี้ควรทำเมื่อแน่ใจแล้วเท่านั้น',
  };
  if (!window.confirm(confirmMessages[status] || 'ยืนยันการเปลี่ยนสถานะหรือไม่?')) return;

  clearError();
  try {
    await api(`/tenants/${encodeURIComponent(currentTenantId)}/status`, {
      method: 'PATCH',
      body: { status },
    });
    await openTenantDetail(currentTenantId);
  } catch (err) {
    showError(err.message);
  }
}

// ---- one-time code modal --------------------------------------------------------------

function showCodeModal({ title, code, expiryText }) {
  els.codeModalTitle.textContent = title;
  els.codeModalValue.textContent = code;
  els.codeModalExpiry.textContent = expiryText || '';
  els.codeModalBackdrop.classList.remove('hidden');
}

function hideCodeModal() {
  els.codeModalBackdrop.classList.add('hidden');
  els.codeModalValue.textContent = '';
}

async function copyModalCode() {
  const text = els.codeModalValue.textContent;
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    // Clipboard API unavailable (no permission, insecure context) — the code is still
    // selectable text on screen, so this is a convenience failure only.
  }
}

// ---- wiring --------------------------------------------------------------

els.loginForm.addEventListener('submit', handleLogin);
els.logoutBtn.addEventListener('click', handleLogout);
els.createTenantForm.addEventListener('submit', handleCreateTenant);
els.refreshTenantsBtn.addEventListener('click', loadTenantList);
els.backToListBtn.addEventListener('click', () => {
  currentTenantId = null;
  showView(els.tenantListView);
});
els.codeModalCopyBtn.addEventListener('click', copyModalCode);
els.codeModalCloseBtn.addEventListener('click', hideCodeModal);

for (const btn of document.querySelectorAll('#tenantDetailView [data-status]')) {
  btn.addEventListener('click', () => handleStatusChange(btn.dataset.status));
}

// ---- boot --------------------------------------------------------------

(async function boot() {
  if (getToken()) {
    els.logoutBtn.classList.remove('hidden');
    try {
      await loadTenantList();
      showView(els.tenantListView);
      return;
    } catch {
      // api() already cleared the token and called goToLogin() on a 401; any other
      // failure here just falls through to the login view below.
    }
  }
  goToLogin();
})();

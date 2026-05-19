/**
 * auth.js — Client-side auth & plan system for GitHub Pages
 * ==========================================================
 * Since GitHub Pages is static (no server/DB), this implements
 * a realistic auth UX using localStorage:
 *
 *  - Accounts are stored in localStorage['nyrr_users']
 *  - Sessions stored in localStorage['nyrr_session']
 *  - Plans: free | pro | enterprise
 *  - Plan limits enforced client-side (gating UI elements)
 *
 * FOR PRODUCTION: replace the localStorage backend with calls
 * to a real auth service (Firebase Auth, Supabase, Auth0, etc.)
 * The rest of the UI code stays the same — just swap the
 * storage read/write calls below.
 *
 * PLAN LIMITS
 * ┌─────────────┬────────────┬────────────────┬───────────────────────────────┐
 * │ Feature     │ Free       │ Pro ($19/mo)   │ Enterprise (custom)           │
 * ├─────────────┼────────────┼────────────────┼───────────────────────────────┤
 * │ Crawl limit │ 50/mo      │ Unlimited      │ Unlimited                     │
 * │ Sources     │ 3 (World,  │ All 8          │ All + custom                  │
 * │             │  Tech, HN) │                │                               │
 * │ Sentiment   │ Basic      │ Full AI        │ Full AI + custom model        │
 * │ Briefs      │ ✗          │ ✓              │ ✓                             │
 * │ Drafts      │ ✗          │ ✓              │ ✓                             │
 * │ Keywords    │ Basic      │ AI-enriched    │ AI-enriched                   │
 * │ Export      │ ✗          │ MD/JSON        │ MD/JSON + API                 │
 * │ Seats       │ 1          │ 1              │ Team / SSO                    │
 * └─────────────┴────────────┴────────────────┴───────────────────────────────┘
 */

/* ── Plan definitions ── */
const PLANS = {
  free: {
    label:         'Free',
    crawlLimit:    50,        // per month
    sources:       ['world', 'tech', 'hackernews'],
    sentiment:     true,
    briefs:        false,
    drafts:        false,
    aiKeywords:    false,
    export:        false,
    allSources:    false,
    badgeClass:    'plan-free',
  },
  pro: {
    label:         'Pro',
    crawlLimit:    Infinity,
    sources:       ['world','us','tech','science','business','reddit','hackernews','climate'],
    sentiment:     true,
    briefs:        true,
    drafts:        true,
    aiKeywords:    true,
    export:        true,
    allSources:    true,
    badgeClass:    'plan-pro',
  },
  enterprise: {
    label:         'Enterprise',
    crawlLimit:    Infinity,
    sources:       ['world','us','tech','science','business','reddit','hackernews','climate'],
    sentiment:     true,
    briefs:        true,
    drafts:        true,
    aiKeywords:    true,
    export:        true,
    allSources:    true,
    team:          true,
    badgeClass:    'plan-enterprise',
  },
};

/* ── Storage keys ── */
const STORAGE_USERS   = 'nyrr_users';
const STORAGE_SESSION = 'nyrr_session';
const STORAGE_CRAWL_COUNT = 'nyrr_crawl_count'; // { userId, month, count }

/* ══════════════════════════════════════════════════════════════
   CORE AUTH FUNCTIONS
   ══════════════════════════════════════════════════════════════ */

function getUsers() {
  try { return JSON.parse(localStorage.getItem(STORAGE_USERS) || '[]'); } catch { return []; }
}

function saveUsers(users) {
  localStorage.setItem(STORAGE_USERS, JSON.stringify(users));
}

function getCurrentUser() {
  try {
    const session = JSON.parse(localStorage.getItem(STORAGE_SESSION) || 'null');
    if (!session || !session.userId || !session.expires) return null;
    if (Date.now() > session.expires) { localStorage.removeItem(STORAGE_SESSION); return null; }
    const users = getUsers();
    return users.find(u => u.id === session.userId) || null;
  } catch { return null; }
}

function getCurrentPlan() {
  const user = getCurrentUser();
  if (!user) return PLANS.free;
  return PLANS[user.plan] || PLANS.free;
}

function register(name, email, password) {
  if (!name || !email || !password) return { ok: false, error: 'All fields are required.' };
  if (password.length < 8) return { ok: false, error: 'Password must be at least 8 characters.' };
  const users = getUsers();
  if (users.find(u => u.email.toLowerCase() === email.toLowerCase())) {
    return { ok: false, error: 'An account with this email already exists.' };
  }
  const user = {
    id:        'u_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8),
    name,
    email:     email.toLowerCase(),
    password:  btoa(password), // NOT real security — replace with hashed+salted in production
    plan:      'free',
    createdAt: new Date().toISOString(),
  };
  users.push(user);
  saveUsers(users);
  createSession(user.id);
  return { ok: true, user };
}

function login(email, password) {
  const users = getUsers();
  const user  = users.find(u => u.email.toLowerCase() === email.toLowerCase());
  if (!user) return { ok: false, error: 'No account found with that email.' };
  if (atob(user.password) !== password) return { ok: false, error: 'Incorrect password.' };
  createSession(user.id);
  return { ok: true, user };
}

function logout() {
  localStorage.removeItem(STORAGE_SESSION);
  updateHeaderAuth();
  window.location.href = 'index.html';
}

function createSession(userId) {
  const session = {
    userId,
    expires: Date.now() + 7 * 24 * 60 * 60 * 1000, // 7 days
  };
  localStorage.setItem(STORAGE_SESSION, JSON.stringify(session));
}

/* ── Plan upgrade (demo — in production this calls your payment endpoint) ── */
function upgradePlan(targetPlan) {
  const user = getCurrentUser();
  if (!user) { openModal('login'); return; }
  const users = getUsers();
  const idx   = users.findIndex(u => u.id === user.id);
  if (idx === -1) return;
  users[idx].plan = targetPlan;
  saveUsers(users);
  updateHeaderAuth();
  return users[idx];
}

/* ── Crawl limit enforcement ── */
function getCrawlCount() {
  try {
    const user = getCurrentUser();
    if (!user) return 0;
    const stored = JSON.parse(localStorage.getItem(STORAGE_CRAWL_COUNT) || '{}');
    const monthKey = new Date().toISOString().slice(0, 7); // YYYY-MM
    const key = `${user.id}_${monthKey}`;
    return stored[key] || 0;
  } catch { return 0; }
}

function incrementCrawlCount() {
  const user = getCurrentUser();
  if (!user) return;
  const stored  = JSON.parse(localStorage.getItem(STORAGE_CRAWL_COUNT) || '{}');
  const monthKey = new Date().toISOString().slice(0, 7);
  const key     = `${user.id}_${monthKey}`;
  stored[key]   = (stored[key] || 0) + 1;
  localStorage.setItem(STORAGE_CRAWL_COUNT, JSON.stringify(stored));
}

function canCrawl() {
  const plan  = getCurrentPlan();
  if (plan.crawlLimit === Infinity) return { ok: true };
  const count = getCrawlCount();
  if (count >= plan.crawlLimit) {
    return {
      ok: false,
      error: `You've used all ${plan.crawlLimit} crawls on the Free plan this month.`,
      upsell: true,
    };
  }
  return { ok: true, remaining: plan.crawlLimit - count };
}

function canUseBriefs()  { return getCurrentPlan().briefs; }
function canUseDrafts()  { return getCurrentPlan().drafts; }
function canUseExport()  { return getCurrentPlan().export; }
function canUseAllSources() { return getCurrentPlan().allSources; }
function getAllowedSources() { return getCurrentPlan().sources; }

/* ══════════════════════════════════════════════════════════════
   HEADER UI
   ══════════════════════════════════════════════════════════════ */

function updateHeaderAuth() {
  const el   = document.getElementById('headerAuth');
  if (!el) return;
  const user = getCurrentUser();

  if (user) {
    const plan    = PLANS[user.plan] || PLANS.free;
    const initial = user.name ? user.name[0].toUpperCase() : '?';
    el.innerHTML = `
      <span class="plan-badge ${plan.badgeClass}">${plan.label}</span>
      <span class="header-username">${escHtml(user.name || user.email)}</span>
      <a href="dashboard.html"><button class="btn btn-sm">Dashboard →</button></a>
      <button class="btn-ghost" onclick="logout()">Sign out</button>`;
  } else {
    el.innerHTML = `
      <button class="btn btn-outline btn-sm" onclick="openModal('login')">Sign in</button>
      <a href="pricing.html"><button class="btn btn-sm">Get started</button></a>`;
  }
}

/* ══════════════════════════════════════════════════════════════
   MODAL HELPERS
   ══════════════════════════════════════════════════════════════ */

function openModal(tab = 'login') {
  const backdrop = document.getElementById('authModal');
  if (!backdrop) return;
  backdrop.classList.add('open');
  switchModalTab(tab);
  document.body.style.overflow = 'hidden';
}

function closeModal() {
  const backdrop = document.getElementById('authModal');
  if (!backdrop) return;
  backdrop.classList.remove('open');
  document.body.style.overflow = '';
  clearModalErrors();
}

function switchModalTab(tab) {
  document.getElementById('tabLogin')?.classList.toggle('active', tab === 'login');
  document.getElementById('tabRegister')?.classList.toggle('active', tab === 'register');
  const fl = document.getElementById('formLogin');
  const fr = document.getElementById('formRegister');
  if (fl) fl.style.display = tab === 'login' ? 'block' : 'none';
  if (fr) fr.style.display = tab === 'register' ? 'block' : 'none';
  clearModalErrors();
}

function clearModalErrors() {
  ['loginError','registerError','registerSuccess'].forEach(id => {
    const el = document.getElementById(id);
    if (el) { el.style.display = 'none'; el.textContent = ''; }
  });
}

function showModalError(id, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = msg; el.style.display = 'block';
}

function showModalSuccess(id, msg) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = msg; el.style.display = 'block';
}

function doLogin() {
  clearModalErrors();
  const email    = document.getElementById('loginEmail')?.value.trim();
  const password = document.getElementById('loginPassword')?.value;
  if (!email || !password) { showModalError('loginError', 'Please fill in all fields.'); return; }
  const result   = login(email, password);
  if (!result.ok) { showModalError('loginError', result.error); return; }
  closeModal();
  updateHeaderAuth();
  /* Redirect to dashboard after login */
  if (window.location.pathname.endsWith('dashboard.html') || window.dashboardInit) {
    window.location.reload();
  } else {
    window.location.href = 'dashboard.html';
  }
}

function doRegister() {
  clearModalErrors();
  const name     = document.getElementById('regName')?.value.trim();
  const email    = document.getElementById('regEmail')?.value.trim();
  const password = document.getElementById('regPassword')?.value;
  const result   = register(name, email, password);
  if (!result.ok) { showModalError('registerError', result.error); return; }
  showModalSuccess('registerSuccess', '✓ Account created! Redirecting to dashboard…');
  updateHeaderAuth();
  setTimeout(() => { closeModal(); window.location.href = 'dashboard.html'; }, 1200);
}

function escHtml(s) {
  return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}

/* Close modal on backdrop click */
document.addEventListener('click', e => {
  if (e.target.id === 'authModal') closeModal();
});
/* Close on Escape */
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') closeModal();
});

/* ── Auto-run on every page load ── */
document.addEventListener('DOMContentLoaded', updateHeaderAuth);

/* ══════════════════════════════════════════════════════════════
   UPSELL BANNER helper (shown inside dashboard when limit hit)
   ══════════════════════════════════════════════════════════════ */
function renderUpsellBanner(containerId, feature) {
  const messages = {
    crawl:   { title: 'Monthly crawl limit reached', sub: 'Upgrade to Pro for unlimited crawls.' },
    briefs:  { title: 'Briefs are a Pro feature',    sub: 'Upgrade to unlock one-click article briefs.' },
    drafts:  { title: 'Drafts are a Pro feature',    sub: 'Upgrade to generate full AP-style articles.' },
    sources: { title: 'Unlock all 8 source categories', sub: 'Free plan includes 3. Upgrade for full access.' },
    keywords:{ title: 'AI keyword enrichment is Pro', sub: 'Upgrade for clusters, gaps, and AI-powered insights.' },
    export:  { title: 'Export is a Pro feature',     sub: 'Upgrade to export as Markdown or JSON.' },
  };
  const m = messages[feature] || messages.briefs;
  const el = document.getElementById(containerId);
  if (!el) return;
  el.innerHTML = `
    <div style="background:#16110a;border:1px solid rgba(245,176,66,0.25);border-radius:16px;padding:28px;text-align:center;max-width:480px;margin:40px auto;">
      <div style="font-size:2rem;margin-bottom:12px;">⚡</div>
      <div style="font-size:1rem;font-weight:700;margin-bottom:8px;">${m.title}</div>
      <div style="color:#b0b8c5;font-size:0.88rem;margin-bottom:20px;">${m.sub}</div>
      <a href="pricing.html"><button style="background:#f5b042;color:#0a0c10;padding:10px 28px;border-radius:40px;font-weight:700;border:none;cursor:pointer;font-size:14px;">View Pro Plan →</button></a>
      ${getCurrentPlan().label === 'Free'
        ? `<div style="margin-top:12px;font-size:11px;color:#6c727f;">Or <a href="contact.html" style="color:#f5b042;">contact us</a> for Enterprise pricing.</div>`
        : ''}
    </div>`;
}

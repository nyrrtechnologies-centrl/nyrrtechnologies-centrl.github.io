// Supabase setup
const SUPABASE_URL = 'https://mpwbiaquisxwgugejfra.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable__6fx1vLV-dnLmTNd0uYV9g_CQKy2Cju';
const supabaseClient = supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Expose globally
window.supabase = supabaseClient;

// Helper to escape HTML to prevent XSS
function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/[&<>]/g, m => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;' }[m]));
}

// Modal handling functions
window.showAuthModal = function(tab = 'login') {
  const modal = document.getElementById('authModal');
  if (modal) {
    modal.classList.add('open');
    switchModalTab(tab);
  }
};

window.hideAuthModal = function() {
  const modal = document.getElementById('authModal');
  if (modal) {
    modal.classList.remove('open');
    clearModalErrors();
  }
};

function clearModalErrors() {
  const loginError = document.getElementById('loginError');
  const registerError = document.getElementById('registerError');
  const registerSuccess = document.getElementById('registerSuccess');
  if (loginError) loginError.style.display = 'none';
  if (registerError) registerError.style.display = 'none';
  if (registerSuccess) registerSuccess.style.display = 'none';
}

function switchModalTab(tab) {
  const loginForm = document.getElementById('formLogin');
  const registerForm = document.getElementById('formRegister');
  const tabLogin = document.getElementById('tabLoginBtn');
  const tabRegister = document.getElementById('tabRegisterBtn');
  
  if (!loginForm || !registerForm || !tabLogin || !tabRegister) return;
  
  if (tab === 'login') {
    loginForm.style.display = 'block';
    registerForm.style.display = 'none';
    tabLogin.classList.add('active');
    tabRegister.classList.remove('active');
  } else {
    loginForm.style.display = 'none';
    registerForm.style.display = 'block';
    tabRegister.classList.add('active');
    tabLogin.classList.remove('active');
  }
  clearModalErrors();
}

// Auth API helpers
window.login = async function(email, password) {
  const { data, error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return data.user;
};

window.register = async function(name, email, password) {
  const { data, error } = await supabaseClient.auth.signUp({
    email, password,
    options: { data: { name } }
  });
  if (error) throw error;
  return data.user;
};

window.logout = async function() {
  await supabaseClient.auth.signOut();
  window.location.reload();
};

window.checkAuthAndRedirect = async function(targetUrl) {
  const { data: { user } } = await supabaseClient.auth.getUser();
  if (user) {
    window.location.href = targetUrl;
  } else {
    window.showAuthModal('login');
  }
};

// Auto-inject Modal HTML on page load
function injectModal() {
  if (document.getElementById('authModal')) return;
  
  const modalHTML = `
    <div class="modal-backdrop" id="authModal">
      <div class="modal">
        <button class="modal-close" id="closeModalBtn">×</button>
        <div class="modal-tabs">
          <button class="modal-tab active" id="tabLoginBtn">Sign in</button>
          <button class="modal-tab" id="tabRegisterBtn">Create account</button>
        </div>
        <div id="formLogin">
          <div class="modal-error" id="loginError"></div>
          <div class="form-field">
            <label>Email address</label>
            <input type="email" id="loginEmail" placeholder="you@example.com">
          </div>
          <div class="form-field">
            <label>Password</label>
            <input type="password" id="loginPassword" placeholder="••••••••">
          </div>
          <button class="modal-btn-full" id="doLoginBtn">Sign in</button>
          <div class="modal-footer-link">
            <a id="switchToRegister">Don't have an account? Create one free →</a>
          </div>
        </div>
        <div id="formRegister" style="display:none">
          <div class="modal-error" id="registerError"></div>
          <div class="modal-success" id="registerSuccess"></div>
          <div class="form-field">
            <label>Full name</label>
            <input type="text" id="regName" placeholder="Jane Smith">
          </div>
          <div class="form-field">
            <label>Email address</label>
            <input type="email" id="regEmail" placeholder="you@example.com">
          </div>
          <div class="form-field">
            <label>Password</label>
            <input type="password" id="regPassword" placeholder="At least 8 characters">
          </div>
          <button class="modal-btn-full" id="doRegisterBtn">Create free account</button>
          <div class="modal-footer-link" style="font-size:11px;">
            By signing up you agree to our <a href="#">Terms</a> and <a href="#">Privacy Policy</a>.
          </div>
        </div>
      </div>
    </div>
  `;
  document.body.insertAdjacentHTML('beforeend', modalHTML);
}

// Bind Modal Event Listeners
function bindModalListeners() {
  document.getElementById('closeModalBtn')?.addEventListener('click', window.hideAuthModal);
  document.getElementById('tabLoginBtn')?.addEventListener('click', () => switchModalTab('login'));
  document.getElementById('tabRegisterBtn')?.addEventListener('click', () => switchModalTab('register'));
  document.getElementById('switchToRegister')?.addEventListener('click', () => switchModalTab('register'));

  document.getElementById('doLoginBtn')?.addEventListener('click', async () => {
    const email = document.getElementById('loginEmail').value.trim();
    const password = document.getElementById('loginPassword').value;
    const errorDiv = document.getElementById('loginError');
    if (!email || !password) {
      errorDiv.textContent = 'Please enter both email and password';
      errorDiv.style.display = 'block';
      return;
    }
    try {
      await window.login(email, password);
      window.hideAuthModal();
      window.location.reload();
    } catch (err) {
      errorDiv.textContent = err.message || 'Login failed';
      errorDiv.style.display = 'block';
    }
  });

  document.getElementById('doRegisterBtn')?.addEventListener('click', async () => {
    const name = document.getElementById('regName').value.trim();
    const email = document.getElementById('regEmail').value.trim();
    const password = document.getElementById('regPassword').value;
    const errorDiv = document.getElementById('registerError');
    const successDiv = document.getElementById('registerSuccess');
    if (!name || !email || !password) {
      errorDiv.textContent = 'Please fill in all fields';
      errorDiv.style.display = 'block';
      return;
    }
    if (password.length < 8) {
      errorDiv.textContent = 'Password must be at least 8 characters';
      errorDiv.style.display = 'block';
      return;
    }
    try {
      await window.register(name, email, password);
      successDiv.textContent = '✓ Account created! You can now sign in.';
      successDiv.style.display = 'block';
      errorDiv.style.display = 'none';
      setTimeout(() => {
        switchModalTab('login');
        document.getElementById('loginEmail').value = email;
      }, 2000);
    } catch (err) {
      errorDiv.textContent = err.message || 'Registration failed';
      errorDiv.style.display = 'block';
    }
  });
}

// Render header with auth state
async function renderHeaderAndState() {
  const headerAuth = document.getElementById('headerAuth');
  let user = null;
  try {
    const { data } = await supabaseClient.auth.getUser();
    user = data?.user || null;
  } catch (e) {
    console.error('Failed to get user session:', e);
  }

  if (headerAuth) {
    if (user) {
      const initials = (user.user_metadata?.name || user.email)
        .split(' ')
        .map(n => n[0])
        .join('')
        .toUpperCase()
        .slice(0, 2);
      
      headerAuth.innerHTML = `
        <div style="position:relative">
          <button class="user-menu-btn" id="userMenuBtn">
            <span class="user-avatar">${initials}</span>
            <span>${escapeHtml(user.user_metadata?.name || user.email.split('@')[0])}</span>
            <span>▾</span>
          </button>
          <div id="userDropdown" class="user-dropdown">
            <a href="dashboard.html">📊 Dashboard</a>
            <a href="pricing.html">💰 Upgrade</a>
            <button id="logoutBtn">🚪 Sign out</button>
          </div>
        </div>
      `;
      
      const menuBtn = document.getElementById('userMenuBtn');
      const dropdown = document.getElementById('userDropdown');
      const logoutBtn = document.getElementById('logoutBtn');
      
      menuBtn?.addEventListener('click', (e) => {
        e.stopPropagation();
        if (dropdown) {
          dropdown.style.display = dropdown.style.display === 'none' ? 'block' : 'none';
        }
      });
      
      logoutBtn?.addEventListener('click', () => window.logout());
      
      document.addEventListener('click', () => {
        if (dropdown) dropdown.style.display = 'none';
      });
    } else {
      headerAuth.innerHTML = `
        <button class="btn btn-outline btn-sm" id="headerSignInBtn">Sign in</button>
        <a href="dashboard.html"><button class="btn btn-sm">Dashboard</button></a>
      `;
      
      document.getElementById('headerSignInBtn')?.addEventListener('click', () => {
        window.showAuthModal('login');
      });
    }
  }

  // Callback hook for page-specific initialization after user check is complete
  if (typeof window.onAuthStateChecked === 'function') {
    window.onAuthStateChecked(user);
  }
}

// Listen for standard browser load events
document.addEventListener('DOMContentLoaded', () => {
  injectModal();
  bindModalListeners();
  renderHeaderAndState();
});

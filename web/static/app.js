let lastScanData = null;
let currentFilter = 'files'; // 'files' | 'new' | 'all'
let selectedItemsMap = new Map();
let expandedCourses = new Set();  // Por defecto vacío: ningún ramo viene desplegado
let expandedSections = new Set(); // Secciones desplegadas dentro de un ramo
let cachedAppInfo = null;
let latestUpdateInfo = null;
let autoCheckUpdatesEnabled = true;
let startupUpdateChecked = false;

document.addEventListener('DOMContentLoaded', async () => {
    await loadSettings();
    await loadCachedScan();
    await checkSession(true);
});

function showBanner(msg, type = 'info') {
    const banner = document.getElementById('status-banner');
    banner.classList.remove('hidden');
    banner.textContent = msg;
    if (type === 'error') {
        banner.style.color = '#f87171';
    } else if (type === 'success') {
        banner.style.color = '#86efac';
    } else {
        banner.style.color = '#9ca3af';
    }
}

function toggleModal(id) {
    document.getElementById(id).classList.toggle('hidden');
}

function closeModalOnBackdrop(event, id) {
    if (event.target.id === id) {
        toggleModal(id);
    }
}

async function loadSettings() {
    try {
        const res = await fetch('/api/settings');
        const data = await res.json();
        populateSettingsUI(data);
        if (data.default_tab) {
            currentFilter = data.default_tab;
            updateActiveTabUI(currentFilter);
        }
        if (data.download_root) {
            document.getElementById('input-download-root').value = data.download_root;
            const settingsRootEl = document.getElementById('settings-download-root');
            if (settingsRootEl) settingsRootEl.value = data.download_root;
        }
        updateExistingFoldersDatalist(data.existing_subfolders || []);

        autoCheckUpdatesEnabled = data.auto_check_updates !== false;
        const toggleEl = document.getElementById('toggle-auto-updates');
        if (toggleEl) toggleEl.checked = autoCheckUpdatesEnabled;

        if (data.app_info) {
            cachedAppInfo = data.app_info;
            renderAppEnvironmentInfo(data.app_info);
        }

        if (autoCheckUpdatesEnabled && !startupUpdateChecked) {
            startupUpdateChecked = true;
            setTimeout(() => checkForAppUpdates(true), 600);
        }
    } catch (e) {
        // Silencioso al iniciar
    }
}

function renderAppEnvironmentInfo(appInfo) {
    if (!appInfo) return;
    const pill = document.getElementById('settings-version-pill');
    const repoEl = document.getElementById('settings-repo-name');
    const envEl = document.getElementById('settings-env-desc');

    if (pill && appInfo.current_version) {
        pill.textContent = `v${appInfo.current_version}`;
    }
    if (repoEl && appInfo.repo) {
        repoEl.textContent = appInfo.repo;
    }
    if (envEl) {
        const modeLabels = {
            onefile: 'Ejecutable standalone (.exe)',
            onedir: 'Aplicacion portable (.zip)',
            source: 'Modo codigo fuente (Python)'
        };
        const modeLabel = modeLabels[appInfo.package_mode] || appInfo.package_mode || 'Desconocido';
        if (!appInfo.can_self_update) {
            envEl.textContent = `${modeLabel} — La actualizacion automatica aplica en la version compilada (.exe).`;
        } else if (appInfo.requires_elevation) {
            envEl.textContent = `${modeLabel} — Carpeta protegida (se solicitara permiso UAC al actualizar).`;
        } else {
            envEl.textContent = `${modeLabel} — Permiso de escritura listo para actualizar.`;
        }
    }
}

async function openSettingsModal() {
    toggleModal('settings-modal');
    await loadSettings();
    const rootInput = document.getElementById('input-download-root');
    const settingsRootEl = document.getElementById('settings-download-root');
    if (rootInput && settingsRootEl) {
        settingsRootEl.value = rootInput.value;
    }
    if (latestUpdateInfo) {
        renderUpdateCheckResult(latestUpdateInfo, false);
    }
}

async function chooseFolderFromSettings() {
    if (typeof chooseDownloadFolder === 'function') {
        await chooseDownloadFolder();
        const rootInput = document.getElementById('input-download-root');
        const settingsRootEl = document.getElementById('settings-download-root');
        if (rootInput && settingsRootEl) {
            settingsRootEl.value = rootInput.value;
        }
    }
}

async function toggleAutoCheckUpdates(enabled) {
    autoCheckUpdatesEnabled = !!enabled;
    try {
        await fetch('/api/settings', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ auto_check_updates: autoCheckUpdatesEnabled })
        });
    } catch (e) {
        // Silencioso
    }
}

function setUpdateStatusMessage(text, kind = '') {
    const statusEl = document.getElementById('update-status-msg');
    if (!statusEl) return;
    if (!text) {
        statusEl.className = 'update-status hidden';
        statusEl.textContent = '';
        return;
    }
    statusEl.className = `update-status ${kind}`.trim();
    statusEl.textContent = text;
}

function renderUpdateCheckResult(data, silent = false) {
    const dot = document.getElementById('update-badge-dot');
    const box = document.getElementById('update-available-box');
    const versionEl = document.getElementById('update-new-version');
    const titleEl = document.getElementById('update-release-title');
    const sizeEl = document.getElementById('update-asset-size');
    const logEl = document.getElementById('update-changelog');
    const permEl = document.getElementById('update-permission-note');
    const linkEl = document.getElementById('link-release-github');
    const applyBtn = document.getElementById('btn-apply-update');

    if (dot) {
        dot.classList.toggle('hidden', !data.update_available);
    }

    if (!data.ok) {
        if (box) box.classList.add('hidden');
        if (!silent) {
            setUpdateStatusMessage(data.error || 'No se pudo consultar GitHub Releases.', 'err');
        }
        return;
    }

    if (data.no_releases) {
        if (box) box.classList.add('hidden');
        if (!silent) {
            setUpdateStatusMessage('Aun no hay versiones publicadas en GitHub.', 'warn');
        }
        return;
    }

    if (!data.update_available) {
        if (box) box.classList.add('hidden');
        if (!silent) {
            setUpdateStatusMessage(`Tienes la ultima version instalada (v${data.current_version}).`, 'ok');
        }
        return;
    }

    if (!silent) {
        setUpdateStatusMessage(`Nueva version disponible: v${data.latest_version}.`, 'ok');
    }

    if (versionEl) versionEl.textContent = data.tag_name || `v${data.latest_version}`;
    if (titleEl) titleEl.textContent = data.release_name || 'Actualizacion disponible';
    if (sizeEl) {
        sizeEl.textContent = data.asset ? `${data.asset.name} (${data.asset.size_label})` : '';
    }
    if (logEl) {
        logEl.textContent = (data.changelog || 'Sin notas de version.').trim();
    }
    if (linkEl && data.html_url) {
        linkEl.href = data.html_url;
    }

    if (permEl) {
        if (!data.can_self_update) {
            permEl.textContent = 'Estas ejecutando desde codigo fuente: descarga el .exe desde GitHub o haz git pull.';
            permEl.classList.remove('hidden');
        } else if (!data.asset || !data.asset.download_url) {
            permEl.textContent = 'Esta release no incluye un paquete de Windows compatible para descarga directa.';
            permEl.classList.remove('hidden');
        } else if (data.requires_elevation) {
            permEl.textContent = 'La carpeta de instalacion requiere permisos de administrador: Windows pedira confirmacion UAC al aplicar.';
            permEl.classList.remove('hidden');
        } else {
            permEl.classList.add('hidden');
            permEl.textContent = '';
        }
    }

    if (applyBtn) {
        const canDownloadNow = Boolean(data.can_self_update && data.asset && data.asset.download_url);
        applyBtn.classList.toggle('hidden', !canDownloadNow);
        applyBtn.disabled = !canDownloadNow;
        applyBtn.textContent = 'Descargar y actualizar';
    }

    if (box) box.classList.remove('hidden');
}

async function checkForAppUpdates(silent = false) {
    const checkBtn = document.getElementById('btn-check-updates');
    if (!silent && checkBtn) {
        checkBtn.disabled = true;
        checkBtn.textContent = 'Buscando...';
        setUpdateStatusMessage('Consultando GitHub Releases...', '');
    }

    try {
        const betaFlag = document.getElementById('toggle-beta-updates')?.checked ? 'true' : 'false';
        const res = await fetch(`/api/updates/check?beta=${betaFlag}`);
        const data = await res.json();
        latestUpdateInfo = data;
        renderUpdateCheckResult(data, silent);
    } catch (e) {
        if (!silent) {
            setUpdateStatusMessage(`Error al buscar actualizaciones: ${e.message}`, 'err');
        }
    } finally {
        if (checkBtn) {
            checkBtn.disabled = false;
            checkBtn.textContent = 'Buscar actualizaciones';
        }
    }
}

async function applyAppUpdate() {
    if (!latestUpdateInfo || !latestUpdateInfo.asset || !latestUpdateInfo.asset.download_url) {
        return;
    }

    const applyBtn = document.getElementById('btn-apply-update');
    const checkBtn = document.getElementById('btn-check-updates');
    const progressBox = document.getElementById('update-progress-box');
    const progressBar = document.getElementById('update-progress-bar');
    const progressMsg = document.getElementById('update-progress-msg');
    const progressPct = document.getElementById('update-progress-pct');

    if (applyBtn) {
        applyBtn.disabled = true;
        applyBtn.textContent = 'Actualizando...';
    }
    if (checkBtn) checkBtn.disabled = true;
    if (progressBox) progressBox.classList.remove('hidden');
    if (progressBar) progressBar.style.width = '0%';
    if (progressPct) progressPct.textContent = '0%';
    if (progressMsg) progressMsg.textContent = 'Iniciando descarga...';

    try {
        const res = await fetch('/api/updates/apply', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                download_url: latestUpdateInfo.asset.download_url,
                asset_name: latestUpdateInfo.asset.name,
                size: latestUpdateInfo.asset.size || 0,
                sha256: latestUpdateInfo.asset.sha256 || ''
            })
        });

        if (!res.ok) {
            const err = await res.json().catch(() => ({}));
            throw new Error(err.detail || `Error HTTP ${res.status}`);
        }

        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = '';
        let finishedRestart = false;

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            const chunks = buffer.split('\n\n');
            buffer = chunks.pop();

            for (const chunk of chunks) {
                const line = chunk.split('\n').find(l => l.startsWith('data: '));
                if (!line) continue;
                const payload = JSON.parse(line.slice(6));
                const pct = Math.max(0, Math.min(100, payload.percent || 0));

                if (progressBar) progressBar.style.width = `${pct}%`;
                if (progressPct) progressPct.textContent = `${pct}%`;
                if (progressMsg && payload.message) progressMsg.textContent = payload.message;

                if (payload.event === 'error') {
                    throw new Error(payload.message || 'Error durante la actualizacion');
                }
                if (payload.event === 'ready_restart') {
                    finishedRestart = true;
                    setUpdateStatusMessage(payload.message || 'Aplicando actualizacion y reiniciando...', 'ok');
                    showBanner('Actualizacion descargada. Reiniciando Aula-Scrapt...', 'success');
                }
            }
        }

        if (!finishedRestart && applyBtn) {
            applyBtn.disabled = false;
            applyBtn.textContent = 'Descargar y actualizar';
            if (checkBtn) checkBtn.disabled = false;
        }
    } catch (e) {
        setUpdateStatusMessage(`No se pudo completar la actualizacion: ${e.message}`, 'err');
        if (applyBtn) {
            applyBtn.disabled = false;
            applyBtn.textContent = 'Descargar y actualizar';
        }
        if (checkBtn) checkBtn.disabled = false;
    }
}

function updateExistingFoldersDatalist(folders) {
    const dl = document.getElementById('existing-folders-list');
    if (!dl) return;
    dl.innerHTML = folders.map(f => `<option value="${escapeHtml(f)}"></option>`).join('');
}

async function saveDownloadRootManual() {
    const input = document.getElementById('input-download-root');
    const path = input.value.trim();
    if (!path) return;

    try {
        const res = await fetch('/api/settings', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ download_root: path })
        });
        const data = await res.json();
        if (res.ok) {
            input.value = data.download_root;
            populateSettingsUI(data);
            updateExistingFoldersDatalist(data.existing_subfolders || []);
            showBanner(`Carpeta de guardado actualizada: ${data.download_root}`, 'success');
            if (lastScanData) {
                await rescanLocalFolder();
            }
        }
    } catch (e) {
        showBanner(`Error al guardar ruta: ${e.message}`, 'error');
    }
}

async function pickNativeFolder() {
    showBanner('Selecciona la carpeta de destino en la ventana emergente de tu PC...', 'info');
    try {
        const res = await fetch('/api/settings/pick-folder', { method: 'POST' });
        const data = await res.json();
        if (data.changed) {
            document.getElementById('input-download-root').value = data.download_root;
            updateExistingFoldersDatalist(data.existing_subfolders || []);
            showBanner(`Carpeta seleccionada: ${data.download_root}`, 'success');
            if (lastScanData) {
                await scanAula();
            }
        } else {
            showBanner('Seleccion de carpeta cancelada.', 'info');
        }
    } catch (e) {
        showBanner(`No se pudo abrir el selector: ${e.message}`, 'error');
    }
}

async function checkSession(autoScanIfConnected = false) {
    const badge = document.getElementById('session-badge');
    const text = document.getElementById('session-text');
    const btnLogout = document.getElementById('btn-logout');

    try {
        const res = await fetch('/api/session');
        const data = await res.json();
        updateSessionUI(data);
        if (data.authenticated && autoScanIfConnected) {
            await scanAula();
        }
    } catch (e) {
        badge.className = 'status-pill status-off';
        text.textContent = 'Sin conexion';
        btnLogout.classList.add('hidden');
    }
}

function updateSessionUI(data) {
    const badge = document.getElementById('session-badge');
    const text = document.getElementById('session-text');
    const btnLogout = document.getElementById('btn-logout');
    const btnBrowser = document.getElementById('btn-browser-login');

    if (data.authenticated) {
        badge.className = 'status-pill status-ok';
        text.textContent = data.user_name || 'Conectado';
        btnLogout.classList.remove('hidden');
        btnBrowser.textContent = 'Cambiar sesion';
    } else {
        badge.className = 'status-pill status-off';
        text.textContent = 'No conectado';
        btnLogout.classList.add('hidden');
        btnBrowser.textContent = 'Iniciar sesion';
    }
}

async function startBrowserLogin() {
    const btn = document.getElementById('btn-browser-login');
    btn.disabled = true;
    showBanner('Inicia sesion en la ventana del navegador que se abrio en tu PC...', 'info');

    try {
        const res = await fetch('/api/login/browser', { method: 'POST' });
        const data = await res.json();
        updateSessionUI(data);
        if (data.authenticated) {
            showBanner('Sesion iniciada. Cargando cursos...', 'success');
            await scanAula();
        } else {
            showBanner(data.reason || 'No se completo el inicio de sesion.', 'error');
        }
    } catch (e) {
        showBanner(`Error: ${e.message}`, 'error');
    } finally {
        btn.disabled = false;
    }
}

async function saveManualCookie() {
    const input = document.getElementById('cookie-input');
    const val = input.value.trim();
    if (!val) return;

    try {
        const res = await fetch('/api/login/cookie', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ cookie_value: val })
        });
        const data = await res.json();
        updateSessionUI(data);
        toggleModal('cookie-modal');
        if (data.authenticated) {
            showBanner('Cookie verificada. Cargando cursos...', 'success');
            await scanAula();
        } else {
            showBanner(`Cookie invalida: ${data.reason}`, 'error');
        }
    } catch (e) {
        showBanner(`Error: ${e.message}`, 'error');
    }
}

async function saveManualToken() {
    const input = document.getElementById('token-input');
    const val = input.value.trim();
    if (!val) {
        showBanner('Ingresa un token de acceso válido.', 'error');
        return;
    }

    try {
        const res = await fetch('/api/login/token', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ token_value: val })
        });
        const data = await res.json();
        updateSessionUI(data);
        toggleModal('token-modal');
        if (data.authenticated) {
            showBanner(`Token verificado para ${data.user_name}. Cargando cursos...`, 'success');
            await scanAula();
        } else {
            showBanner(`Token inválido: ${data.reason}`, 'error');
        }
    } catch (e) {
        showBanner(`Error: ${e.message}`, 'error');
    }
}

async function logoutSession() {
    await fetch('/api/logout', { method: 'POST' });
    lastScanData = null;
    selectedItemsMap.clear();
    expandedCourses.clear();
    expandedSections.clear();
    document.getElementById('scan-toolbar').classList.add('hidden');
    document.getElementById('courses-container').innerHTML = `
        <div class="empty-state">
            <p>Sesion cerrada. Inicia sesion para consultar tus cursos.</p>
        </div>`;
    updateDownloadBar();
    await checkSession(false);
    showBanner('Sesion cerrada.', 'info');
}

let currentScanRequestController = null;
let currentSearchQuery = '';
let currentExtFilter = '';
let showHiddenCourses = false;
let lastScanIsCache = false;
let appSettings = {
    theme_mode: 'dark',
    accent_color: 'blue',
    default_tab: 'new',
    default_subfolder: '',
    default_organize_by_section: true,
    skip_already_downloaded: true,
    skip_seen_on_select: true,
    auto_export_links_to_obsidian: true,
    auto_export_forums_to_obsidian: true,
    hide_empty_sections: true,
    preferred_extensions: [],
    max_auto_select_mb: 0,
    beta_updates_channel: false,
    notify_native_enabled: true,
    notify_on_new_files: true,
    notify_on_download_done: true,
    notify_on_deadlines: true,
    background_sync_hours: 0,
    minimize_to_tray: false,
    hidden_courses: []
};

function resolveThemeMode(mode) {
    if (mode === 'system') {
        return window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches
            ? 'dark'
            : 'light';
    }
    return mode === 'light' ? 'light' : 'dark';
}

function applyAppTheme(themeMode, accentColor) {
    const html = document.documentElement;
    html.setAttribute('data-theme', resolveThemeMode(themeMode || 'dark'));
    html.setAttribute('data-accent', accentColor || 'blue');
    document.querySelectorAll('.accent-swatch').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.accent === (accentColor || 'blue'));
    });
}

function updateNotificationBadge(count) {
    const num = Number(count || 0);
    const badge = document.getElementById('notif-badge');
    const modalCount = document.getElementById('notif-modal-count');
    if (badge) {
        badge.textContent = num > 99 ? '99+' : String(num);
        badge.classList.toggle('hidden', num <= 0);
    }
    if (modalCount) {
        modalCount.textContent = `${num} sin leer`;
    }
}

function populateSettingsUI(data) {
    appSettings = { ...appSettings, ...(data || {}) };
    applyAppTheme(appSettings.theme_mode, appSettings.accent_color);
    updateNotificationBadge(appSettings.unread_notifications);

    const setVal = (id, val) => { const el = document.getElementById(id); if (el) el.value = val; };
    const setChecked = (id, val) => { const el = document.getElementById(id); if (el) el.checked = Boolean(val); };

    setVal('settings-download-root', appSettings.download_root || '');
    setVal('settings-default-subfolder', appSettings.default_subfolder || '');
    setVal('select-theme-mode', appSettings.theme_mode || 'dark');
    setVal('select-default-tab', appSettings.default_tab || 'new');
    setVal('input-max-auto-mb', appSettings.max_auto_select_mb || 0);
    setVal('select-bg-sync-hours', String(appSettings.background_sync_hours || 0));

    setChecked('toggle-default-org-sec', appSettings.default_organize_by_section);
    setChecked('toggle-skip-downloaded', appSettings.skip_already_downloaded);
    setChecked('toggle-skip-seen', appSettings.skip_seen_on_select);
    setChecked('toggle-export-links', appSettings.auto_export_links_to_obsidian);
    setChecked('toggle-export-forums', appSettings.auto_export_forums_to_obsidian);
    setChecked('toggle-hide-empty-sec', appSettings.hide_empty_sections);
    setChecked('toggle-minimize-tray', appSettings.minimize_to_tray);
    setChecked('toggle-notify-native', appSettings.notify_native_enabled);
    setChecked('toggle-notify-new', appSettings.notify_on_new_files);
    setChecked('toggle-notify-deadlines', appSettings.notify_on_deadlines);
    setChecked('toggle-notify-download', appSettings.notify_on_download_done);
    setChecked('toggle-auto-updates', appSettings.auto_check_updates);
    setChecked('toggle-beta-updates', appSettings.beta_updates_channel);

    const prefSet = new Set((appSettings.preferred_extensions || []).map(e => String(e).toLowerCase()));
    document.querySelectorAll('[data-pref-ext]').forEach(btn => {
        btn.classList.toggle('active', prefSet.has(btn.dataset.prefExt));
    });
}

async function saveSettingField(patch) {
    try {
        const res = await fetch('/api/settings', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(patch)
        });
        if (!res.ok) {
            const err = await res.json();
            throw new Error(err.detail || 'Error al guardar configuracion');
        }
        const data = await res.json();
        populateSettingsUI(data);
        return data;
    } catch (e) {
        showBanner(`Error guardando configuracion: ${e.message}`, 'error');
        return null;
    }
}

function onThemePreferenceChange(themeMode, accentColor) {
    const patch = {};
    if (themeMode) {
        appSettings.theme_mode = themeMode;
        patch.theme_mode = themeMode;
    }
    if (accentColor) {
        appSettings.accent_color = accentColor;
        patch.accent_color = accentColor;
    }
    applyAppTheme(appSettings.theme_mode, appSettings.accent_color);
    saveSettingField(patch);
}

function togglePreferredExtension(ext) {
    const clean = String(ext || '').toLowerCase();
    const current = new Set((appSettings.preferred_extensions || []).map(e => String(e).toLowerCase()));
    if (current.has(clean)) current.delete(clean);
    else current.add(clean);
    saveSettingField({ preferred_extensions: Array.from(current) });
}

function switchSettingsTab(tabKey) {
    document.querySelectorAll('[data-settings-tab]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.settingsTab === tabKey);
    });
    document.querySelectorAll('.settings-pane').forEach(pane => {
        pane.classList.toggle('hidden', pane.id !== `settings-pane-${tabKey}`);
    });
}

function switchQrTab(tabKey) {
    document.querySelectorAll('[data-qr-tab]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.qrTab === tabKey);
    });
    const webPane = document.getElementById('qr-tab-web');
    const pairPane = document.getElementById('qr-tab-pair');
    if (webPane) webPane.classList.toggle('hidden', tabKey !== 'web');
    if (pairPane) pairPane.classList.toggle('hidden', tabKey !== 'pair');
    if (tabKey === 'pair') {
        createPairingSession();
    }
}

async function createPairingSession() {
    const loading = document.getElementById('pair-loading');
    const content = document.getElementById('pair-content');
    const errorBox = document.getElementById('pair-error');
    if (loading) loading.classList.remove('hidden');
    if (content) content.classList.add('hidden');
    if (errorBox) errorBox.classList.add('hidden');

    try {
        const res = await fetch('/api/pair/create', { method: 'POST' });
        const data = await res.json();
        if (!res.ok) throw new Error(data.detail || 'No se pudo generar codigo de emparejamiento');

        const qrImg = document.getElementById('pair-qr-img');
        const pinEl = document.getElementById('pair-pin-code');
        const expEl = document.getElementById('pair-expiry');
        const urlEl = document.getElementById('pair-base-url');
        if (qrImg) qrImg.src = `data:image/png;base64,${data.qr_b64}`;
        if (pinEl) pinEl.textContent = data.pin;
        if (expEl) expEl.textContent = 'Valido por 5 minutos (un solo uso)';
        if (urlEl) urlEl.textContent = data.base_url;
        if (content) content.classList.remove('hidden');
    } catch (e) {
        if (errorBox) {
            errorBox.textContent = e.message;
            errorBox.classList.remove('hidden');
        }
    } finally {
        if (loading) loading.classList.add('hidden');
    }
}

function applyScanPayload(data, isCache = false) {
    lastScanData = data;
    lastScanIsCache = Boolean(isCache);
    if (!isCache) selectedItemsMap.clear();

    if (data.download_root) {
        const rootInput = document.getElementById('input-download-root');
        if (rootInput) rootInput.value = data.download_root;
        const settingsRoot = document.getElementById('settings-download-root');
        if (settingsRoot) settingsRoot.value = data.download_root;
    }
    updateExistingFoldersDatalist(data.existing_subfolders || []);

    const summary = data.summary || {};
    document.getElementById('scan-toolbar').classList.remove('hidden');
    document.getElementById('stat-courses').textContent = summary.total_courses ?? (data.courses || []).length;
    document.getElementById('stat-new').textContent = summary.total_new_files ?? 0;
    document.getElementById('stat-total').textContent = summary.total_files ?? 0;

    const dlBadge = document.getElementById('deadlines-tab-badge');
    const urgentCount = summary.upcoming_deadlines_count ?? 0;
    if (dlBadge) {
        dlBadge.textContent = String(urgentCount);
        dlBadge.classList.toggle('hidden', urgentCount <= 0);
    }

    if (typeof data.unread_notifications === 'number') {
        updateNotificationBadge(data.unread_notifications);
    }

    renderCourses();
    updateDownloadBar();
}

async function loadCachedScan() {
    try {
        const res = await fetch('/api/scan/cached');
        if (!res.ok) return false;
        const data = await res.json();
        if (data.has_cache && Array.isArray(data.courses) && data.courses.length > 0) {
            applyScanPayload(data, true);
            showBanner('Mostrando cache local • Actualizando desde Aula USM...', 'info');
            return true;
        }
    } catch (_e) {
        // Ignorar errores de cache inicial
    }
    return false;
}

async function rescanLocalFolder() {
    const btn = document.getElementById('btn-rescan-local');
    if (btn) {
        btn.disabled = true;
        btn.textContent = 'Escaneando...';
    }
    try {
        const res = await fetch('/api/rescan-local', { method: 'POST' });
        const data = await res.json();
        if (!res.ok) throw new Error(data.detail || 'Error re-escaneando carpeta');
        if (!data.has_cache) {
            showBanner('Primero sincroniza Aula USM para contrastar archivos con la carpeta.', 'info');
            return;
        }
        applyScanPayload(data, false);
        const present = (data.summary?.total_files || 0) - (data.summary?.total_new_files || 0);
        showBanner(
            `Carpeta re-escaneada: ${present} archivo(s) detectados localmente, ${data.summary?.total_new_files || 0} pendientes.`,
            'success'
        );
    } catch (e) {
        showBanner(`Error re-escaneando carpeta: ${e.message}`, 'error');
    } finally {
        if (btn) {
            btn.disabled = false;
            btn.textContent = 'Re-escanear carpeta';
        }
    }
}

async function openLocalFile(path, reveal = false) {
    try {
        const res = await fetch('/api/open-file', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ path, reveal })
        });
        if (!res.ok) {
            const err = await res.json();
            throw new Error(err.detail || 'No se pudo abrir el archivo local');
        }
    } catch (e) {
        showBanner(e.message, 'error');
    }
}

async function openNotificationsModal() {
    toggleModal('notifications-modal');
    await loadNotificationsList();
}

async function loadNotificationsList() {
    const listEl = document.getElementById('notifications-list');
    try {
        const res = await fetch('/api/notifications');
        const data = await res.json();
        updateNotificationBadge(data.unread_count || 0);
        const items = data.notifications || [];
        if (!items.length) {
            if (listEl) listEl.innerHTML = `<div class="muted center" style="padding:20px;">No hay notificaciones recientes.</div>`;
            return;
        }
        if (listEl) {
            listEl.innerHTML = items.map(n => {
                const when = n.created_at ? new Date(n.created_at * 1000).toLocaleString() : '';
                return `
                    <div class="notif-card ${n.read ? '' : 'unread'}">
                        <div class="notif-card-head">
                            <span class="notif-title">${escapeHtml(n.title || 'Aviso')}</span>
                            <span class="notif-time">${escapeHtml(when)}</span>
                        </div>
                        <div class="notif-body">${escapeHtml(n.body || '')}</div>
                    </div>`;
            }).join('');
        }
    } catch (e) {
        if (listEl) listEl.innerHTML = `<div class="muted center">Error cargando avisos: ${escapeHtml(e.message)}</div>`;
    }
}

async function markAllNotificationsRead() {
    const res = await fetch('/api/notifications/read-all', { method: 'POST' });
    if (res.ok) await loadNotificationsList();
}

async function clearAllNotifications() {
    const res = await fetch('/api/notifications', { method: 'DELETE' });
    if (res.ok) await loadNotificationsList();
}

async function sendTestNotification() {
    const res = await fetch('/api/notifications/test', { method: 'POST' });
    if (res.ok) {
        const data = await res.json();
        updateNotificationBadge(data.unread_count || 0);
        await loadNotificationsList();
        showBanner('Notificacion de prueba enviada.', 'success');
    }
}

async function scanAula() {
    const btn = document.getElementById('btn-scan');
    btn.disabled = true;
    btn.textContent = 'Cargando...';
    if (!lastScanIsCache) {
        showBanner('Consultando cursos y archivos en Aula USM...', 'info');
    }

    try {
        const res = await fetch('/api/scan');
        if (res.status === 401) {
            const err = await res.json();
            showBanner(`No conectado: ${err.detail}`, 'error');
            await checkSession(false);
            return;
        }
        if (!res.ok) {
            const err = await res.json();
            throw new Error(err.detail || 'Error al escanear');
        }

        const data = await res.json();
        applyScanPayload(data, false);

        showBanner(
            `Listo: ${data.summary.total_courses} cursos cargados (${data.summary.total_files} archivos, ${data.summary.total_new_files} pendientes). Haz clic en un ramo para desplegar sus carpetas.`,
            'success'
        );
    } catch (e) {
        showBanner(`Error al consultar Aula USM: ${e.message}`, 'error');
    } finally {
        btn.disabled = false;
        btn.textContent = 'Actualizar cursos';
    }
}

function updateActiveTabUI(filter) {
    document.querySelectorAll('.tab-btn[data-filter]').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.filter === filter);
    });
}

function setFilter(filter) {
    currentFilter = filter;
    updateActiveTabUI(filter);
    renderCourses();
}

function setSearchQuery(q) {
    currentSearchQuery = (q || '').trim().toLowerCase();
    renderCourses();
}

function setExtensionFilter(ext) {
    currentExtFilter = (ext || '').trim().toLowerCase();
    document.querySelectorAll('#ext-filter-chips .chip-btn').forEach(btn => {
        btn.classList.toggle('active', (btn.dataset.ext || '') === currentExtFilter);
    });
    renderCourses();
}

function toggleShowHiddenCourses() {
    showHiddenCourses = !showHiddenCourses;
    const btn = document.getElementById('btn-toggle-hidden-courses');
    if (btn) {
        btn.textContent = showHiddenCourses ? 'Ocultar archivados' : 'Ver ocultos';
        btn.classList.toggle('active', showHiddenCourses);
    }
    renderCourses();
}

async function toggleCourseHidden(courseId, hide) {
    const data = await saveSettingField({ course_id: courseId, course_hidden: Boolean(hide) });
    if (data && lastScanData && Array.isArray(lastScanData.courses)) {
        lastScanData.courses.forEach(c => {
            if (c.course && c.course.id === courseId) c.course.is_hidden = Boolean(hide);
        });
        renderCourses();
    }
}

function toggleCourse(courseId, event) {
    // Evitar colapsar si el usuario hizo clic en un input o boton dentro de la cabecera
    if (event && (event.target.tagName === 'INPUT' || event.target.tagName === 'LABEL' || event.target.tagName === 'BUTTON')) {
        return;
    }
    if (expandedCourses.has(courseId)) {
        expandedCourses.delete(courseId);
    } else {
        expandedCourses.add(courseId);
    }
    renderCourses();
}

function toggleSection(sectionKey, event) {
    if (event && event.target.tagName === 'INPUT') {
        return;
    }
    if (expandedSections.has(sectionKey)) {
        expandedSections.delete(sectionKey);
    } else {
        expandedSections.add(sectionKey);
    }
    renderCourses();
}

function formatDeadlineCountdown(dueTs) {
    if (!dueTs) return { label: 'Sin fecha', cls: 'upcoming' };
    const diffSec = dueTs - Math.floor(Date.now() / 1000);
    if (diffSec < 0) return { label: 'Vencida', cls: 'overdue' };
    const hours = Math.floor(diffSec / 3600);
    if (hours < 24) {
        const hrsText = hours <= 1 ? '< 1h' : `${hours}h`;
        return { label: `Hoy (${hrsText})`, cls: 'today' };
    }
    if (hours <= 48) {
        return { label: `< 48h (${Math.ceil(hours)}h)`, cls: 'urgent' };
    }
    const days = Math.ceil(hours / 24);
    return { label: `En ${days} dias`, cls: 'upcoming' };
}

function renderDeadlinesTab(container) {
    const entries = [];
    const hiddenSet = new Set(appSettings.hidden_courses || []);

    (lastScanData.courses || []).forEach(courseEntry => {
        const course = courseEntry.course || {};
        if (!showHiddenCourses && (course.is_hidden || hiddenSet.has(course.id))) return;
        const cTitle = course.clean_name || course.fullname || 'Ramo';
        (courseEntry.items || []).forEach(item => {
            if (item.type !== 'assign' && item.type !== 'quiz') return;
            const hay = `${cTitle} ${item.title || ''} ${item.due_text || ''}`.toLowerCase();
            if (currentSearchQuery && !hay.includes(currentSearchQuery)) return;
            entries.push({ course: cTitle, item });
        });
    });

    entries.sort((a, b) => {
        const tsA = a.item.due_timestamp || 9e15;
        const tsB = b.item.due_timestamp || 9e15;
        return tsA - tsB;
    });

    if (!entries.length) {
        container.innerHTML = `
            <div class="empty-state">
                <p>No se encontraron entregas ni evaluaciones proximas.</p>
            </div>`;
        return;
    }

    const wrapper = document.createElement('div');
    wrapper.className = 'deadlines-container';
    wrapper.innerHTML = entries.map(({ course, item }) => {
        const status = formatDeadlineCountdown(item.due_timestamp);
        const typeText = item.type === 'quiz' ? 'Cuestionario / Certamen' : 'Tarea / Entrega';
        const dueLabel = item.due_text ? `${item.due_text}` : 'Sin fecha limite';
        const urgencyCard = status.cls === 'urgent' || status.cls === 'today' ? 'urgent' : '';
        return `
            <div class="deadline-card ${urgencyCard}">
                <div class="deadline-meta">
                    <span class="deadline-course">${escapeHtml(course)} • ${escapeHtml(typeText)}</span>
                    <span class="deadline-title">${escapeHtml(item.title || '')}</span>
                    <span class="muted">${escapeHtml(dueLabel)}</span>
                </div>
                <div class="deadline-actions">
                    <span class="deadline-badge ${status.cls}">${escapeHtml(status.label)}</span>
                    <a href="${item.url}" target="_blank" class="btn btn-outline btn-xs">Ir al Aula</a>
                </div>
            </div>`;
    }).join('');
    container.appendChild(wrapper);
}

function renderCourses() {
    const container = document.getElementById('courses-container');
    if (!lastScanData || !lastScanData.courses.length) {
        container.innerHTML = `
            <div class="empty-state">
                <p>No se encontraron cursos activos en la cuenta.</p>
            </div>`;
        return;
    }

    if (currentFilter === 'deadlines') {
        renderDeadlinesTab(container);
        return;
    }

    // Preservar posicion de scroll interna de cada ramo antes de re-renderizar
    const prevScrolls = new Map();
    document.querySelectorAll('.course-sections-scroll').forEach(el => {
        const cid = el.dataset.courseId;
        if (cid) prevScrolls.set(cid, el.scrollTop);
    });

    container.innerHTML = '';
    const hiddenSet = new Set(appSettings.hidden_courses || []);

    lastScanData.courses.forEach(courseEntry => {
        const course = courseEntry.course;
        const isCourseHidden = Boolean(course.is_hidden || hiddenSet.has(course.id));
        if (isCourseHidden && !showHiddenCourses) {
            return;
        }

        const allItems = courseEntry.items || [];
        const isCourseExpanded = expandedCourses.has(course.id);
        const courseSearchMatch = currentSearchQuery
            ? (course.fullname || '').toLowerCase().includes(currentSearchQuery) ||
              (course.clean_name || '').toLowerCase().includes(currentSearchQuery)
            : true;

        const filteredItems = allItems.filter(item => {
            if (currentFilter === 'new' && !(item.downloadable && !item.is_downloaded)) return false;
            if (currentFilter === 'files' && !item.downloadable) return false;
            if (currentExtFilter) {
                const ext = (item.file_ext || '').toLowerCase();
                if (ext !== currentExtFilter) return false;
            }
            if (currentSearchQuery && !courseSearchMatch) {
                const hay = `${item.title || ''} ${item.section || ''} ${item.file_name || ''}`.toLowerCase();
                if (!hay.includes(currentSearchQuery)) return false;
            }
            return true;
        });

        // Agrupar items por su seccion / carpeta de Aula
        const sectionsMap = new Map();
        filteredItems.forEach(item => {
            const secName = item.section || 'General';
            if (!sectionsMap.has(secName)) {
                sectionsMap.set(secName, []);
            }
            sectionsMap.get(secName).push(item);
        });

        const card = document.createElement('div');
        card.className = `course-card ${isCourseExpanded ? 'expanded' : ''}`;

        const folderInputId = `folder_${course.id}`;
        const subInputId = `sub_${course.id}`;
        const orgSectionId = `org_${course.id}`;

        let sectionsHtml = '';
        if (courseEntry.error) {
            sectionsHtml = `<div class="muted" style="padding:10px;">Error: ${escapeHtml(courseEntry.error)}</div>`;
        } else if (sectionsMap.size === 0) {
            sectionsHtml = `<div class="muted" style="padding:10px;">Sin elementos para este filtro.</div>`;
        } else {
            sectionsMap.forEach((secItems, secName) => {
                if (appSettings.hide_empty_sections && secItems.length === 0) return;
                const sectionKey = `${course.id}::${secName}`;
                const isSecExpanded = expandedSections.has(sectionKey);

                const downloadableInSec = secItems.filter(i => i.downloadable);
                const allSecSelected = downloadableInSec.length > 0 && downloadableInSec.every(i => selectedItemsMap.has(i.id));

                let rowsHtml = '';
                secItems.forEach(item => {
                    const isChecked = selectedItemsMap.has(item.id);
                    const typeLabel = item.type === 'file' ? 'Archivo' : (item.type === 'quiz' ? 'Evaluacion' : (item.type === 'assign' || item.type === 'assignment' ? 'Tarea' : (item.type === 'forum' ? 'Foro' : 'Enlace')));

                    let statusBadge = '';
                    if (item.downloadable) {
                        statusBadge = item.is_downloaded
                            ? `<span class="badge badge-downloaded">En carpeta</span>`
                            : `<span class="badge badge-new">Pendiente</span>`;
                    } else {
                        statusBadge = `<span class="badge badge-type">${typeLabel}</span>`;
                    }

                    const dueBadge = (!item.downloadable && item.due_text)
                        ? `<span class="badge badge-size">${escapeHtml(item.due_text)}</span>`
                        : '';

                    const sizeBadge = (item.downloadable && item.size_human)
                        ? `<span class="badge badge-size">${escapeHtml(item.size_human)}</span>`
                        : '';

                    const checkboxHtml = item.downloadable
                        ? `<input type="checkbox" class="item-checkbox" data-id="${item.id}" ${isChecked ? 'checked' : ''} onchange="toggleItemSelection('${item.id}', ${course.id}, this.checked)" />`
                        : `<span style="width:14px; display:inline-block;"></span>`;

                    const openBtnsHtml = (item.is_downloaded && item.local_path)
                        ? `<button type="button" class="btn btn-outline btn-xs" onclick="openLocalFile('${escapeJs(item.local_path)}', false)">Abrir</button>
                           <button type="button" class="btn btn-outline btn-xs" onclick="openLocalFile('${escapeJs(item.local_path)}', true)" title="Mostrar en el Explorador">Carpeta</button>`
                        : `<a href="${item.url}" target="_blank" class="btn btn-outline btn-xs">Abrir</a>`;

                    rowsHtml += `
                        <div class="item-row">
                            <div class="item-left">
                                ${checkboxHtml}
                                <span class="item-title" title="${escapeHtml(item.title)}">${escapeHtml(item.title)}</span>
                            </div>
                            <div class="item-badges">
                                ${dueBadge}
                                ${sizeBadge}
                                ${statusBadge}
                                ${openBtnsHtml}
                            </div>
                        </div>`;
                });

                const secCheckboxHtml = downloadableInSec.length > 0
                    ? `<input type="checkbox" class="item-checkbox" ${allSecSelected ? 'checked' : ''} onchange="toggleSectionSelection(${course.id}, '${escapeJs(secName)}', this.checked)" title="Seleccionar toda la carpeta" />`
                    : '';

                sectionsHtml += `
                    <div class="section-group ${isSecExpanded ? 'expanded' : ''}">
                        <div class="section-header" onclick="toggleSection('${escapeJs(sectionKey)}', event)">
                            <div class="section-header-left">
                                <span class="sec-chevron">&#9654;</span>
                                ${secCheckboxHtml}
                                <span class="sec-title" title="${escapeHtml(secName)}">${escapeHtml(secName)}</span>
                            </div>
                            <span class="section-count">${secItems.length} elemento(s)</span>
                        </div>
                        <div class="section-items">
                            ${rowsHtml}
                        </div>
                    </div>`;
            });
        }

        const pillClass = courseEntry.new_files_count > 0 ? 'course-summary-pill has-new' : 'course-summary-pill';
        const displayTitle = course.clean_name || course.fullname;
        const targetSubVal = typeof course.target_subfolder === 'string'
            ? course.target_subfolder
            : (appSettings.default_subfolder || '');
        const orgSectionVal = typeof course.organize_by_section === 'boolean'
            ? course.organize_by_section
            : Boolean(appSettings.default_organize_by_section);
        const hiddenBadge = isCourseHidden
            ? `<span class="course-hidden-badge">Oculto</span>`
            : '';

        card.innerHTML = `
            <div class="course-header" onclick="toggleCourse(${course.id}, event)">
                <div class="course-header-left">
                    <span class="chevron">&#9654;</span>
                    <span class="course-title" title="${escapeHtml(course.fullname)}">${escapeHtml(displayTitle)}</span>
                    ${hiddenBadge}
                </div>
                <div class="course-header-right">
                    <span class="folder-tag" title="Carpeta destino">${escapeHtml(course.obsidian_folder)}</span>
                    <span class="${pillClass}">
                        ${courseEntry.downloadable_count} archivos (${courseEntry.new_files_count} pend.)
                    </span>
                </div>
            </div>
            <div class="course-body">
                <div class="course-config-bar">
                    <div class="config-group">
                        <label for="${folderInputId}">Carpeta ramo:</label>
                        <input
                            type="text"
                            id="${folderInputId}"
                            class="course-folder-input"
                            list="existing-folders-list"
                            value="${escapeHtml(course.obsidian_folder)}"
                            title="Nombre de la carpeta para este ramo"
                            onchange="saveCourseFolderMapping(${course.id}, this.value)"
                        />
                    </div>
                    <div class="config-group">
                        <label for="${subInputId}">Subcarpeta:</label>
                        <input
                            type="text"
                            id="${subInputId}"
                            class="course-sub-input"
                            value="${escapeHtml(targetSubVal)}"
                            placeholder="Opcional"
                            onchange="updateCourseFolderConfig(${course.id}, true)"
                        />
                        <label style="display:inline-flex; align-items:center; gap:4px; cursor:pointer;">
                            <input type="checkbox" id="${orgSectionId}" ${orgSectionVal ? 'checked' : ''} onchange="updateCourseFolderConfig(${course.id}, true)" />
                            Subcarpeta por seccion
                        </label>
                    </div>
                    <div class="config-group">
                        <button class="btn btn-outline btn-xs" onclick="toggleCourseSelection(${course.id}, true)" title="Seleccionar todos los archivos de este ramo">
                            Marcar ramo
                        </button>
                        <button class="btn btn-outline btn-xs" onclick="toggleCourseSelection(${course.id}, false)" title="Deseleccionar archivos de este ramo">
                            Desmarcar
                        </button>
                        <button class="btn btn-outline btn-xs" onclick="toggleCourseHidden(${course.id}, ${!isCourseHidden})" title="${isCourseHidden ? 'Volver a mostrar ramo' : 'Ocultar este ramo'}">
                            ${isCourseHidden ? 'Mostrar' : 'Ocultar'}
                        </button>
                    </div>
                </div>
                <div class="course-sections-scroll" data-course-id="${course.id}">
                    ${sectionsHtml}
                </div>
            </div>
        `;

        container.appendChild(card);
    });

    // Restaurar posicion de scroll interna
    document.querySelectorAll('.course-sections-scroll').forEach(el => {
        const cid = el.dataset.courseId;
        if (cid && prevScrolls.has(cid)) {
            el.scrollTop = prevScrolls.get(cid);
        }
    });
}

async function saveCourseFolderMapping(courseId, folderName) {
    const clean = folderName.trim();
    if (!clean) return;

    if (lastScanData) {
        const entry = lastScanData.courses.find(c => c.course.id === courseId);
        if (entry) {
            entry.course.obsidian_folder = clean;
        }
    }
    updateCourseFolderConfig(courseId);

    try {
        await fetch('/api/settings', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ course_id: courseId, course_folder: clean })
        });
    } catch (e) {
        // Silencioso
    }
}

function findItemById(itemId) {
    if (!lastScanData) return null;
    for (const c of lastScanData.courses) {
        for (const item of c.items) {
            if (item.id === itemId) {
                return { item, course: c.course };
            }
        }
    }
    return null;
}

function getCourseConfig(courseId) {
    const folderEl = document.getElementById(`folder_${courseId}`);
    const subEl = document.getElementById(`sub_${courseId}`);
    const orgEl = document.getElementById(`org_${courseId}`);
    const entry = lastScanData ? lastScanData.courses.find(c => c.course.id === courseId) : null;
    const defaultFolder = entry ? entry.course.obsidian_folder : 'Curso';
    const fallbackSub = entry && typeof entry.course.target_subfolder === 'string'
        ? entry.course.target_subfolder
        : (appSettings.default_subfolder || '');
    const fallbackOrg = entry && typeof entry.course.organize_by_section === 'boolean'
        ? entry.course.organize_by_section
        : Boolean(appSettings.default_organize_by_section);

    return {
        obsidian_folder: folderEl ? folderEl.value.trim() || defaultFolder : defaultFolder,
        target_subfolder: subEl ? subEl.value.trim() : fallbackSub,
        organize_by_section: orgEl ? orgEl.checked : fallbackOrg
    };
}

function updateCourseFolderConfig(courseId, persist = false) {
    const cfg = getCourseConfig(courseId);
    if (lastScanData) {
        const entry = lastScanData.courses.find(c => c.course.id === courseId);
        if (entry) {
            entry.course.target_subfolder = cfg.target_subfolder;
            entry.course.organize_by_section = cfg.organize_by_section;
        }
    }
    selectedItemsMap.forEach((val, key) => {
        const found = findItemById(key);
        if (found && found.course.id === courseId) {
            val.obsidian_folder = cfg.obsidian_folder;
            val.target_subfolder = cfg.target_subfolder;
            val.organize_by_section = cfg.organize_by_section;
        }
    });
    if (persist) {
        saveSettingField({
            course_id: courseId,
            course_subfolder: cfg.target_subfolder,
            course_organize_by_section: cfg.organize_by_section
        });
    }
}

function toggleItemSelection(itemId, courseId, isChecked) {
    if (!isChecked) {
        selectedItemsMap.delete(itemId);
    } else {
        const found = findItemById(itemId);
        if (found) {
            const cfg = getCourseConfig(courseId);
            selectedItemsMap.set(itemId, {
                ...found.item,
                obsidian_folder: cfg.obsidian_folder,
                target_subfolder: cfg.target_subfolder,
                organize_by_section: cfg.organize_by_section
            });
        }
    }
    renderCourses();
    updateDownloadBar();
}

function toggleSectionSelection(courseId, sectionName, isChecked) {
    if (!lastScanData) return;
    const entry = lastScanData.courses.find(c => c.course.id === courseId);
    if (!entry) return;
    const cfg = getCourseConfig(courseId);

    entry.items.forEach(item => {
        const sec = item.section || 'General';
        if (sec === sectionName && item.downloadable) {
            if (isChecked) {
                selectedItemsMap.set(item.id, {
                    ...item,
                    obsidian_folder: cfg.obsidian_folder,
                    target_subfolder: cfg.target_subfolder,
                    organize_by_section: cfg.organize_by_section
                });
            } else {
                selectedItemsMap.delete(item.id);
            }
        }
    });

    renderCourses();
    updateDownloadBar();
}

function toggleCourseSelection(courseId, isSelectAll) {
    if (!lastScanData) return;
    const entry = lastScanData.courses.find(c => c.course.id === courseId);
    if (!entry) return;
    const cfg = getCourseConfig(courseId);

    entry.items.forEach(item => {
        if (item.downloadable) {
            if (isSelectAll) {
                selectedItemsMap.set(item.id, {
                    ...item,
                    obsidian_folder: cfg.obsidian_folder,
                    target_subfolder: cfg.target_subfolder,
                    organize_by_section: cfg.organize_by_section
                });
            } else {
                selectedItemsMap.delete(item.id);
            }
        }
    });

    renderCourses();
    updateDownloadBar();
}

function selectAllNew() {
    if (!lastScanData) return;
    const hiddenSet = new Set(appSettings.hidden_courses || []);
    const prefExts = new Set((appSettings.preferred_extensions || []).map(e => String(e).toLowerCase()));
    const maxBytes = (appSettings.max_auto_select_mb || 0) > 0
        ? appSettings.max_auto_select_mb * 1024 * 1024
        : 0;
    const skipSeen = Boolean(appSettings.skip_seen_on_select);
    const skipDownloaded = appSettings.skip_already_downloaded !== false;

    lastScanData.courses.forEach(c => {
        if (!showHiddenCourses && (c.course.is_hidden || hiddenSet.has(c.course.id))) return;
        const cfg = getCourseConfig(c.course.id);
        c.items.forEach(item => {
            if (!item.downloadable) return;
            if (skipDownloaded && item.is_downloaded) return;
            if (skipSeen && item.seen && !item.is_downloaded) return;
            if (prefExts.size > 0) {
                const ext = (item.file_ext || '').toLowerCase();
                if (!prefExts.has(ext)) return;
            }
            if (maxBytes > 0 && item.size_bytes && item.size_bytes > maxBytes) return;

            selectedItemsMap.set(item.id, {
                ...item,
                obsidian_folder: cfg.obsidian_folder,
                target_subfolder: cfg.target_subfolder,
                organize_by_section: cfg.organize_by_section
            });
        });
    });
    renderCourses();
    updateDownloadBar();
}

function clearSelection() {
    selectedItemsMap.clear();
    renderCourses();
    updateDownloadBar();
}

function formatBytes(bytes) {
    if (!bytes || bytes <= 0) return '';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
    if (bytes < 1024 * 1024 * 1024) return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
    return (bytes / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
}

function updateDownloadBar() {
    const bar = document.getElementById('download-bar');
    const countEl = document.getElementById('selected-count');
    const sizeWrapper = document.getElementById('selected-size-wrapper');
    const sizeEl = document.getElementById('selected-size');
    const count = selectedItemsMap.size;
    if (countEl) countEl.textContent = count;

    let totalBytes = 0;
    selectedItemsMap.forEach(item => {
        if (item.size_bytes && item.size_bytes > 0) {
            totalBytes += item.size_bytes;
        }
    });

    if (sizeWrapper && sizeEl) {
        if (totalBytes > 0) {
            sizeEl.textContent = formatBytes(totalBytes);
            sizeWrapper.classList.remove('hidden');
        } else {
            sizeWrapper.classList.add('hidden');
        }
    }

    if (bar) bar.classList.toggle('hidden', count === 0);
}

function updateItemVisualStatus(itemId, isDownloaded) {
    const cb = document.querySelector(`.item-checkbox[data-id="${itemId}"]`);
    if (cb) {
        cb.checked = false;
        const row = cb.closest('.item-row');
        if (row) {
            const badges = row.querySelector('.item-badges');
            if (badges) {
                const badge = badges.querySelector('.badge:not(.badge-size)');
                if (badge) {
                    badge.className = 'badge badge-downloaded';
                    badge.textContent = 'En carpeta';
                }
            }
        }
    }
}

function updateDownloadCountOnly() {
    const countEl = document.getElementById('selected-count');
    const sizeWrapper = document.getElementById('selected-size-wrapper');
    const sizeEl = document.getElementById('selected-size');
    if (countEl) countEl.textContent = selectedItemsMap.size;

    let totalBytes = 0;
    selectedItemsMap.forEach(item => {
        if (item.size_bytes && item.size_bytes > 0) {
            totalBytes += item.size_bytes;
        }
    });

    if (sizeWrapper && sizeEl) {
        if (totalBytes > 0) {
            sizeEl.textContent = formatBytes(totalBytes);
            sizeWrapper.classList.remove('hidden');
        } else {
            sizeWrapper.classList.add('hidden');
        }
    }
}

async function downloadSelected() {
    if (selectedItemsMap.size === 0) return;
    const btn = document.getElementById('btn-download-selected');
    const progressBox = document.getElementById('download-progress-box');
    const progressBar = document.getElementById('download-progress-bar');
    const percentText = document.getElementById('progress-percent-text');
    const detailsText = document.getElementById('progress-details-text');
    const currentFileEl = document.getElementById('download-current-file');

    btn.disabled = true;
    btn.textContent = 'Descargando...';

    // Mostrar barra de progreso con micro-animacion
    progressBox.classList.remove('hidden');
    currentFileEl.classList.remove('hidden');
    progressBar.style.width = '0%';
    percentText.textContent = '0%';
    detailsText.textContent = `Preparando ${selectedItemsMap.size} archivo(s)...`;
    currentFileEl.textContent = 'Iniciando conexión...';

    const itemsPayload = Array.from(selectedItemsMap.values()).map(i => ({
        id: i.id,
        title: i.title,
        section: i.section,
        url: i.url,
        obsidian_folder: i.obsidian_folder,
        target_subfolder: i.target_subfolder,
        organize_by_section: i.organize_by_section,
        file_name: i.file_name || '',
        type: i.type || 'file'
    }));

    try {
        const res = await fetch('/api/download/stream', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ items: itemsPayload })
        });

        if (!res.ok) {
            const err = await res.json();
            throw new Error(err.detail || 'Error en la descarga');
        }

        const reader = res.body.getReader();
        const decoder = new TextDecoder('utf-8');
        let buffer = '';

        while (true) {
            const { done, value } = await reader.read();
            if (done) break;

            buffer += decoder.decode(value, { stream: true });
            const parts = buffer.split('\n\n');
            buffer = parts.pop();

            for (const part of parts) {
                const trimmed = part.trim();
                if (!trimmed.startsWith('data: ')) continue;
                try {
                    const data = JSON.parse(trimmed.slice(6));

                    if (data.event === 'start_file') {
                        progressBar.style.width = `${data.percent}%`;
                        percentText.textContent = `${data.percent}%`;
                        detailsText.textContent = `Descargando (${data.index} de ${data.total})...`;
                        currentFileEl.textContent = data.title;
                    } else if (data.event === 'file_done') {
                        progressBar.style.width = `${data.percent}%`;
                        percentText.textContent = `${data.percent}%`;
                        detailsText.textContent = `Guardado (${data.index}/${data.total}): ${data.filename || data.title}`;
                        currentFileEl.textContent = data.filename || data.title;

                        if (lastScanData) {
                            lastScanData.courses.forEach(c => {
                                c.items.forEach(item => {
                                    if (item.id === data.item_id) {
                                        item.is_downloaded = true;
                                        item.is_new = false;
                                        if (data.saved_path) item.local_path = data.saved_path;
                                        selectedItemsMap.delete(item.id);
                                    }
                                });
                                c.new_files_count = c.items.filter(i => i.downloadable && !i.is_downloaded).length;
                            });
                            document.getElementById('stat-new').textContent = lastScanData.courses.reduce((acc, c) => acc + c.new_files_count, 0);
                        }
                        updateItemVisualStatus(data.item_id, true);
                        updateDownloadCountOnly();
                    } else if (data.event === 'file_error') {
                        detailsText.textContent = `Error en archivo ${data.index}: ${data.title}`;
                    } else if (data.event === 'complete') {
                        progressBar.style.width = '100%';
                        percentText.textContent = '100%';
                        detailsText.textContent = `¡Completado! ${data.downloaded_count} archivo(s) guardados.`;
                        currentFileEl.textContent = 'Finalizado';

                        if (typeof data.unread_notifications === 'number') {
                            updateNotificationBadge(data.unread_notifications);
                        }
                        const firstSaved = data.downloaded && data.downloaded[0] ? data.downloaded[0].saved_path : '';
                        const folderNotice = firstSaved ? ` en: ${firstSaved.substring(0, firstSaved.lastIndexOf('\\'))}` : '';
                        showBanner(`✅ ${data.downloaded_count} archivo(s) descargados exitosamente${folderNotice}`, 'success');
                        if (lastScanData) {
                            rescanLocalFolder();
                        }
                    }
                } catch (parseErr) {
                    console.error('Error parseando SSE:', parseErr);
                }
            }
        }

        renderCourses();
        updateDownloadBar();

        setTimeout(() => {
            progressBox.classList.add('hidden');
            currentFileEl.classList.add('hidden');
            progressBar.style.width = '0%';
        }, 2200);

    } catch (e) {
        showBanner(`Error al descargar: ${e.message}`, 'error');
        progressBox.classList.add('hidden');
        currentFileEl.classList.add('hidden');
    } finally {
        btn.disabled = false;
        btn.textContent = 'Descargar seleccionados';
    }
}

function escapeHtml(str) {
    if (!str) return '';
    return String(str)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

function escapeJs(str) {
    if (!str) return '';
    return String(str)
        .replace(/\\/g, '\\\\')
        .replace(/'/g, "\\'");
}

async function shutdownApp() {
    if (!confirm("¿Deseas cerrar Aula-Scrapt?")) return;
    try {
        await fetch('/api/shutdown', { method: 'POST' });
    } catch (e) {
        // Ignorar si el servidor se desconecta inmediatamente
    }
    document.body.innerHTML = `
        <div style="display:flex;height:100vh;align-items:center;justify-content:center;background:#0d1117;color:#c9d1d9;font-family:system-ui,-apple-system,sans-serif;text-align:center;padding:20px;">
            <div style="background:#161b22;border:1px solid #30363d;border-radius:12px;padding:32px 40px;max-width:440px;">
                <h2 style="margin:0 0 12px 0;color:#58a6ff;font-size:1.4rem;">Aula-Scrapt se ha cerrado</h2>
                <p style="color:#8b949e;margin:0;font-size:0.95rem;line-height:1.5;">El servidor local ha finalizado correctamente.<br>Ya puedes cerrar esta pestaña del navegador.</p>
            </div>
        </div>
    `;
}

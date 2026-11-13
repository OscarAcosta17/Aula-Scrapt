let lastScanData = null;
let currentFilter = 'files'; // 'files' | 'new' | 'all'
let selectedItemsMap = new Map();
let expandedCourses = new Set();  // Por defecto vacío: ningún ramo viene desplegado
let expandedSections = new Set(); // Secciones desplegadas dentro de un ramo
let cachedAppInfo = null;
let latestUpdateInfo = null;
let autoCheckUpdatesEnabled = true;
let startupUpdateChecked = false;

document.addEventListener('DOMContentLoaded', () => {
    loadSettings();
    checkSession(true);
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
        const res = await fetch('/api/updates/check');
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
                size: latestUpdateInfo.asset.size || 0
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
            updateExistingFoldersDatalist(data.existing_subfolders || []);
            showBanner(`Carpeta de guardado actualizada: ${data.download_root}`, 'success');
            if (lastScanData) {
                await scanAula();
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

async function scanAula() {
    const btn = document.getElementById('btn-scan');
    btn.disabled = true;
    btn.textContent = 'Cargando...';
    showBanner('Consultando cursos y archivos en Aula USM...', 'info');

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
        lastScanData = data;
        selectedItemsMap.clear();

        if (data.download_root) {
            document.getElementById('input-download-root').value = data.download_root;
        }
        updateExistingFoldersDatalist(data.existing_subfolders || []);

        document.getElementById('scan-toolbar').classList.remove('hidden');
        document.getElementById('stat-courses').textContent = data.summary.total_courses;
        document.getElementById('stat-new').textContent = data.summary.total_new_files;
        document.getElementById('stat-total').textContent = data.summary.total_files;

        showBanner(
            `Listo: ${data.summary.total_courses} cursos cargados (${data.summary.total_files} archivos, ${data.summary.total_new_files} pendientes). Haz clic en un ramo para desplegar sus carpetas.`,
            'success'
        );

        renderCourses();
        updateDownloadBar();
    } catch (e) {
        showBanner(`Error al consultar Aula USM: ${e.message}`, 'error');
    } finally {
        btn.disabled = false;
        btn.textContent = 'Actualizar cursos';
    }
}

function updateActiveTabUI(filter) {
    document.querySelectorAll('.tab-btn').forEach(btn => {
        btn.classList.toggle('active', btn.dataset.filter === filter);
    });
}

function setFilter(filter) {
    currentFilter = filter;
    updateActiveTabUI(filter);
    renderCourses();
}

function toggleCourse(courseId, event) {
    // Evitar colapsar si el usuario hizo clic en un input dentro de la cabecera
    if (event && (event.target.tagName === 'INPUT' || event.target.tagName === 'LABEL')) {
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

function renderCourses() {
    const container = document.getElementById('courses-container');
    if (!lastScanData || !lastScanData.courses.length) {
        container.innerHTML = `
            <div class="empty-state">
                <p>No se encontraron cursos activos en la cuenta.</p>
            </div>`;
        return;
    }

    // Preservar posicion de scroll interna de cada ramo antes de re-renderizar
    const prevScrolls = new Map();
    document.querySelectorAll('.course-sections-scroll').forEach(el => {
        const cid = el.dataset.courseId;
        if (cid) prevScrolls.set(cid, el.scrollTop);
    });

    container.innerHTML = '';

    lastScanData.courses.forEach(courseEntry => {
        const course = courseEntry.course;
        const allItems = courseEntry.items || [];
        const isCourseExpanded = expandedCourses.has(course.id);

        const filteredItems = allItems.filter(item => {
            if (currentFilter === 'new') return item.downloadable && !item.is_downloaded;
            if (currentFilter === 'files') return item.downloadable;
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
                const sectionKey = `${course.id}::${secName}`;
                const isSecExpanded = expandedSections.has(sectionKey);

                const downloadableInSec = secItems.filter(i => i.downloadable);
                const allSecSelected = downloadableInSec.length > 0 && downloadableInSec.every(i => selectedItemsMap.has(i.id));

                let rowsHtml = '';
                secItems.forEach(item => {
                    const isChecked = selectedItemsMap.has(item.id);
                    const typeLabel = item.type === 'file' ? 'Archivo' : (item.type === 'assignment' ? 'Tarea' : (item.type === 'forum' ? 'Foro' : 'Enlace'));

                    let statusBadge = '';
                    if (item.downloadable) {
                        statusBadge = item.is_downloaded
                            ? `<span class="badge badge-downloaded">En carpeta</span>`
                            : `<span class="badge badge-new">Pendiente</span>`;
                    } else {
                        statusBadge = `<span class="badge badge-type">${typeLabel}</span>`;
                    }

                    const sizeBadge = (item.downloadable && item.size_human)
                        ? `<span class="badge badge-size">${escapeHtml(item.size_human)}</span>`
                        : '';

                    const checkboxHtml = item.downloadable
                        ? `<input type="checkbox" class="item-checkbox" data-id="${item.id}" ${isChecked ? 'checked' : ''} onchange="toggleItemSelection('${item.id}', ${course.id}, this.checked)" />`
                        : `<span style="width:14px; display:inline-block;"></span>`;

                    rowsHtml += `
                        <div class="item-row">
                            <div class="item-left">
                                ${checkboxHtml}
                                <span class="item-title" title="${escapeHtml(item.title)}">${escapeHtml(item.title)}</span>
                            </div>
                            <div class="item-badges">
                                ${sizeBadge}
                                ${statusBadge}
                                <a href="${item.url}" target="_blank" class="btn btn-outline btn-xs">Abrir</a>
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

        card.innerHTML = `
            <div class="course-header" onclick="toggleCourse(${course.id}, event)">
                <div class="course-header-left">
                    <span class="chevron">&#9654;</span>
                    <span class="course-title" title="${escapeHtml(course.fullname)}">${escapeHtml(displayTitle)}</span>
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
                            value="Aula"
                            placeholder="Opcional"
                            onchange="updateCourseFolderConfig(${course.id})"
                        />
                        <label style="display:inline-flex; align-items:center; gap:4px; cursor:pointer;">
                            <input type="checkbox" id="${orgSectionId}" checked onchange="updateCourseFolderConfig(${course.id})" />
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

    return {
        obsidian_folder: folderEl ? folderEl.value.trim() || defaultFolder : defaultFolder,
        target_subfolder: subEl ? subEl.value.trim() : 'Aula',
        organize_by_section: orgEl ? orgEl.checked : true
    };
}

function updateCourseFolderConfig(courseId) {
    const cfg = getCourseConfig(courseId);
    selectedItemsMap.forEach((val, key) => {
        const found = findItemById(key);
        if (found && found.course.id === courseId) {
            val.obsidian_folder = cfg.obsidian_folder;
            val.target_subfolder = cfg.target_subfolder;
            val.organize_by_section = cfg.organize_by_section;
        }
    });
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
    lastScanData.courses.forEach(c => {
        const cfg = getCourseConfig(c.course.id);
        c.items.forEach(item => {
            if (item.downloadable && !item.is_downloaded) {
                selectedItemsMap.set(item.id, {
                    ...item,
                    obsidian_folder: cfg.obsidian_folder,
                    target_subfolder: cfg.target_subfolder,
                    organize_by_section: cfg.organize_by_section
                });
            }
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
        organize_by_section: i.organize_by_section
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

                        const firstSaved = data.downloaded && data.downloaded[0] ? data.downloaded[0].saved_path : '';
                        const folderNotice = firstSaved ? ` en: ${firstSaved.substring(0, firstSaved.lastIndexOf('\\'))}` : '';
                        showBanner(`✅ ${data.downloaded_count} archivo(s) descargados exitosamente${folderNotice}`, 'success');
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

import ctypes
import hashlib
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple
import requests

from config import (
    APP_ROOT,
    APP_VERSION,
    DATA_DIR,
    GITHUB_ALL_RELEASES_API_URL,
    GITHUB_LATEST_API_URL,
    GITHUB_RELEASES_URL,
    GITHUB_REPO,
    load_settings,
)


def parse_semver(version_str: str) -> Tuple[int, int, int]:
    """Convierte etiquetas tipo 'v1.2.0+3' en una tupla comparable (major, minor, patch)."""
    clean = (version_str or "").strip().lstrip("vV")
    clean = clean.split("+")[0].split("-")[0]
    parts = [int(p) for p in re.findall(r"\d+", clean)[:3]]
    while len(parts) < 3:
        parts.append(0)
    return (parts[0], parts[1], parts[2])


def is_newer_version(remote_tag: str, current_version: str = APP_VERSION) -> bool:
    """Retorna True si la versión remota es estrictamente mayor que la local."""
    return parse_semver(remote_tag) > parse_semver(current_version)


def get_package_mode() -> str:
    """Identifica si corre desde .exe onefile, carpeta portable onedir o código fuente."""
    if not getattr(sys, "frozen", False):
        return "source"
    if (APP_ROOT / "_internal").exists():
        return "onedir"
    return "onefile"


def can_write_to_app_dir() -> bool:
    """Comprueba si el proceso actual puede escribir sin UAC en la carpeta del ejecutable."""
    probe = APP_ROOT / f".aula_scrapt_perm_check_{os.getpid()}"
    try:
        probe.write_text("ok", encoding="utf-8")
        probe.unlink(missing_ok=True)
        return True
    except PermissionError:
        return False
    except OSError:
        return False


def format_bytes_label(size_bytes: int) -> str:
    if size_bytes <= 0:
        return ""
    if size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    return f"{size_bytes / (1024 * 1024):.1f} MB"


def get_update_environment_info() -> Dict:
    mode = get_package_mode()
    is_frozen = mode != "source"
    writable = can_write_to_app_dir() if is_frozen else True
    return {
        "current_version": APP_VERSION,
        "repo": GITHUB_REPO,
        "releases_url": GITHUB_RELEASES_URL,
        "is_frozen": is_frozen,
        "package_mode": mode,
        "install_dir": str(APP_ROOT),
        "executable_path": str(Path(sys.executable).resolve()),
        "can_self_update": is_frozen and os.name == "nt",
        "requires_elevation": bool(is_frozen and not writable),
        "writable_install_dir": writable,
    }


def select_windows_asset(assets: List[Dict], package_mode: str) -> Optional[Dict]:
    """Selecciona el binario adecuado de Windows desde los assets de la release."""
    parsed = []
    for asset in assets or []:
        name = str(asset.get("name", ""))
        lower = name.lower()
        url = str(asset.get("browser_download_url", ""))
        size = int(asset.get("size") or 0)
        if not name or not url:
            continue
        is_exe = lower.endswith(".exe") and ("win" in lower or "aula-scrapt" in lower)
        is_zip = lower.endswith(".zip") and ("win" in lower or "aula-scrapt" in lower)
        if is_exe or is_zip:
            parsed.append(
                {
                    "name": name,
                    "download_url": url,
                    "size": size,
                    "size_label": format_bytes_label(size),
                    "kind": "exe" if is_exe else "zip",
                }
            )

    if not parsed:
        return None

    prefer_kind = "zip" if package_mode == "onedir" else "exe"
    for item in parsed:
        if item["kind"] == prefer_kind:
            return item
    return parsed[0]


def parse_checksums_text(raw_text: str) -> Dict[str, str]:
    """Parsea líneas '<sha256>  <archivo>' de checksums.txt a un mapa en minúsculas."""
    result: Dict[str, str] = {}
    for line in (raw_text or "").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        match = re.match(r"^([A-Fa-f0-9]{64})\s+[*]?(.+)$", stripped)
        if not match:
            continue
        digest = match.group(1).lower()
        filename = os.path.basename(match.group(2).strip()).lower()
        if filename:
            result[filename] = digest
    return result


def _fetch_release_checksums(assets: List[Dict], headers: Dict) -> Dict[str, str]:
    for asset in assets or []:
        name = str(asset.get("name", "")).strip()
        url = str(asset.get("browser_download_url", "")).strip()
        if name.lower() == "checksums.txt" and url.startswith("https://"):
            try:
                resp = requests.get(url, headers=headers, timeout=10)
                if resp.status_code == 200:
                    return parse_checksums_text(resp.text)
            except requests.RequestException:
                return {}
    return {}


def cleanup_old_staged_updates(updates_dir: Path, keep_name: str = "") -> None:
    if not updates_dir.exists():
        return
    for item in updates_dir.iterdir():
        if not item.is_file():
            continue
        if keep_name and item.name == keep_name:
            continue
        try:
            item.unlink(missing_ok=True)
        except OSError:
            pass


def check_for_updates(beta_channel: Optional[bool] = None) -> Dict:
    """Consulta la última release (o prerelease si beta está activo) en GitHub."""
    env = get_update_environment_info()
    include_beta = (
        bool(load_settings().get("beta_updates_channel", False))
        if beta_channel is None
        else bool(beta_channel)
    )
    env["beta_updates_channel"] = include_beta
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": f"Aula-Scrapt-Updater/{APP_VERSION}",
    }

    target_url = (
        f"{GITHUB_ALL_RELEASES_API_URL}?per_page=10"
        if include_beta
        else GITHUB_LATEST_API_URL
    )

    try:
        res = requests.get(target_url, headers=headers, timeout=12)
    except requests.RequestException as exc:
        return {
            **env,
            "ok": False,
            "update_available": False,
            "error": f"No se pudo conectar con GitHub: {exc}",
        }

    if res.status_code == 404:
        return {
            **env,
            "ok": True,
            "no_releases": True,
            "update_available": False,
            "latest_version": APP_VERSION,
            "message": "Aún no hay releases publicadas en el repositorio.",
        }

    if res.status_code in (403, 429):
        return {
            **env,
            "ok": False,
            "update_available": False,
            "error": "GitHub limitó temporalmente las consultas. Intenta nuevamente en unos minutos.",
        }

    if res.status_code != 200:
        return {
            **env,
            "ok": False,
            "update_available": False,
            "error": f"Respuesta inesperada de GitHub (HTTP {res.status_code}).",
        }

    raw_payload = res.json()
    if include_beta and isinstance(raw_payload, list):
        candidates = [rel for rel in raw_payload if isinstance(rel, dict) and not rel.get("draft")]
        if not candidates:
            return {
                **env,
                "ok": True,
                "no_releases": True,
                "update_available": False,
                "latest_version": APP_VERSION,
                "message": "Aún no hay releases publicadas en el repositorio.",
            }
        data = candidates[0]
    elif isinstance(raw_payload, dict):
        data = raw_payload
    else:
        return {
            **env,
            "ok": False,
            "update_available": False,
            "error": "Formato inesperado de releases en GitHub.",
        }

    tag = str(data.get("tag_name") or "").strip()
    latest_clean = tag.lstrip("vV") or APP_VERSION
    update_available = bool(tag) and is_newer_version(latest_clean, APP_VERSION)
    assets = data.get("assets", []) or []
    asset = select_windows_asset(assets, env["package_mode"])
    if asset:
        checksums = _fetch_release_checksums(assets, headers)
        asset["sha256"] = checksums.get(asset["name"].lower(), "")

    return {
        **env,
        "ok": True,
        "no_releases": False,
        "update_available": update_available,
        "is_prerelease": bool(data.get("prerelease", False)),
        "latest_version": latest_clean,
        "tag_name": tag or f"v{latest_clean}",
        "release_name": data.get("name") or f"v{latest_clean}",
        "published_at": data.get("published_at") or "",
        "changelog": (data.get("body") or "").strip(),
        "html_url": data.get("html_url") or GITHUB_RELEASES_URL,
        "asset": asset,
    }


def download_update_asset(
    download_url: str,
    asset_name: str,
    expected_size: int = 0,
    on_progress: Optional[Callable[[int, int, int], None]] = None,
    expected_sha256: str = "",
) -> Path:
    """Descarga un binario .exe o .zip de actualización verificando firma mágica y SHA-256."""
    if not download_url.startswith("https://"):
        raise ValueError("La URL de actualización debe usar HTTPS.")

    updates_dir = DATA_DIR / "updates"
    updates_dir.mkdir(parents=True, exist_ok=True)
    safe_name = os.path.basename(asset_name) or "Aula-Scrapt-update.exe"
    cleanup_old_staged_updates(updates_dir, keep_name="")
    target_path = updates_dir / safe_name

    headers = {"User-Agent": f"Aula-Scrapt-Updater/{APP_VERSION}"}
    hasher = hashlib.sha256()
    with requests.get(download_url, headers=headers, stream=True, timeout=60) as resp:
        resp.raise_for_status()
        total = int(resp.headers.get("content-length") or expected_size or 0)
        downloaded = 0
        with open(target_path, "wb") as fh:
            for chunk in resp.iter_content(chunk_size=131072):
                if not chunk:
                    continue
                fh.write(chunk)
                hasher.update(chunk)
                downloaded += len(chunk)
                if on_progress:
                    pct = int((downloaded / total) * 100) if total > 0 else 0
                    on_progress(downloaded, total, min(pct, 99))

    file_size = target_path.stat().st_size
    if file_size < 512 * 1024:
        target_path.unlink(missing_ok=True)
        raise RuntimeError("El archivo descargado es inválido o está incompleto.")

    header_bytes = target_path.read_bytes()[:2]
    suffix = target_path.suffix.lower()
    if suffix == ".exe" and header_bytes != b"MZ":
        target_path.unlink(missing_ok=True)
        raise RuntimeError("El archivo descargado no es un ejecutable de Windows (.exe) válido.")
    if suffix == ".zip" and header_bytes != b"PK":
        target_path.unlink(missing_ok=True)
        raise RuntimeError("El paquete descargado no es un archivo .zip válido.")

    clean_expected = (expected_sha256 or "").strip().lower()
    if clean_expected:
        actual_sha256 = hasher.hexdigest().lower()
        if actual_sha256 != clean_expected:
            target_path.unlink(missing_ok=True)
            raise RuntimeError(
                f"Verificación SHA-256 fallida para {safe_name}. Descarga abortada por seguridad."
            )

    if on_progress:
        on_progress(file_size, file_size, 100)

    return target_path


def _ps_quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def launch_windows_updater(staged_path: Path) -> Dict:
    """
    Genera y ejecuta un script PowerShell independiente que espera el cierre de este proceso,
    aplica la actualización (.exe onefile o .zip onedir) y reinicia la aplicación.
    Si el directorio requiere permisos de administrador, solicita elevación UAC.
    """
    if os.name != "nt":
        raise RuntimeError("La auto-actualización de escritorio solo está soportada en Windows.")
    if not getattr(sys, "frozen", False):
        raise RuntimeError(
            "Estás ejecutando desde código fuente Python. Actualiza con 'git pull' o usa el .exe."
        )

    current_pid = os.getpid()
    current_exe = Path(sys.executable).resolve()
    app_dir = APP_ROOT.resolve()
    requires_uac = not can_write_to_app_dir()
    script_path = Path(tempfile.gettempdir()) / f"aula_scrapt_updater_{current_pid}.ps1"
    log_path = Path(tempfile.gettempdir()) / f"aula_scrapt_updater_{current_pid}.log"

    if staged_path.suffix.lower() == ".exe":
        apply_block = f"""
$targetExe = {_ps_quote(str(current_exe))}
$backupExe = "$targetExe.bak"
$moved = $false
for ($r = 0; $r -lt 20; $r++) {{
    try {{
        if (Test-Path $backupExe) {{ Remove-Item -Force $backupExe -ErrorAction SilentlyContinue }}
        if (Test-Path $targetExe) {{ Move-Item -Force $targetExe $backupExe }}
        $moved = $true
        break
    }} catch {{
        Start-Sleep -Milliseconds 400
    }}
}}
if (-not $moved) {{ throw 'No se pudo reemplazar el ejecutable porque sigue en uso.' }}
try {{
    Copy-Item -Force $stagedFile $targetExe
    Start-Sleep -Milliseconds 300
    Remove-Item -Force $backupExe -ErrorAction SilentlyContinue
}} catch {{
    if ((Test-Path $backupExe) -and -not (Test-Path $targetExe)) {{
        Move-Item -Force $backupExe $targetExe -ErrorAction SilentlyContinue
    }}
    throw
}}
Remove-Item -Force $stagedFile -ErrorAction SilentlyContinue
Start-Process -FilePath $targetExe -WorkingDirectory $appDir
"""
    else:
        extract_dir = Path(tempfile.gettempdir()) / f"aula_scrapt_extract_{current_pid}"
        apply_block = f"""
$extractDir = {_ps_quote(str(extract_dir))}
if (Test-Path $extractDir) {{ Remove-Item -Recurse -Force $extractDir }}
Expand-Archive -Path $stagedFile -DestinationPath $extractDir -Force
$exeCandidate = Get-ChildItem -Path $extractDir -Filter 'Aula-Scrapt*.exe' -Recurse | Select-Object -First 1
if (-not $exeCandidate) {{ throw 'No se encontró Aula-Scrapt.exe dentro del ZIP.' }}
$sourceRoot = $exeCandidate.Directory.FullName
for ($r = 0; $r -lt 15; $r++) {{
    try {{
        Get-ChildItem -Path $sourceRoot -Force | ForEach-Object {{
            if ($_.Name -ieq 'data') {{ return }}
            $dest = Join-Path $appDir $_.Name
            if ($_.PSIsContainer) {{
                Copy-Item -Path $_.FullName -Destination $appDir -Recurse -Force
            }} else {{
                Copy-Item -Path $_.FullName -Destination $dest -Force
            }}
        }}
        break
    }} catch {{
        if ($r -eq 14) {{ throw }}
        Start-Sleep -Milliseconds 400
    }}
}}
$launchExe = Join-Path $appDir $exeCandidate.Name
Remove-Item -Recurse -Force $extractDir -ErrorAction SilentlyContinue
Remove-Item -Force $stagedFile -ErrorAction SilentlyContinue
Start-Process -FilePath $launchExe -WorkingDirectory $appDir
"""

    script_content = f"""$ErrorActionPreference = 'Stop'
$parentPid = {current_pid}
$stagedFile = {_ps_quote(str(staged_path.resolve()))}
$appDir = {_ps_quote(str(app_dir))}
$logFile = {_ps_quote(str(log_path))}

try {{
    for ($i = 0; $i -lt 100; $i++) {{
        $proc = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
        if (-not $proc) {{ break }}
        Start-Sleep -Milliseconds 300
    }}
    Start-Sleep -Milliseconds 500
    # Limpiar variables heredadas de PyInstaller (v4-v6) antes de relanzar el nuevo binario
    Remove-Item Env:_MEIPASS2 -ErrorAction SilentlyContinue
    Remove-Item Env:_PYI_ARCHIVE_FILE -ErrorAction SilentlyContinue
    Remove-Item Env:_PYI_APPLICATION_HOME_DIR -ErrorAction SilentlyContinue
    Remove-Item Env:_PYI_PARENT_PROCESS_LEVEL -ErrorAction SilentlyContinue
    Remove-Item Env:_PYI_SPLASH_IPC -ErrorAction SilentlyContinue
    {apply_block}
}} catch {{
    $_ | Out-File -FilePath $logFile -Encoding utf8
}} finally {{
    Remove-Item -Force $MyInvocation.MyCommand.Path -ErrorAction SilentlyContinue
}}
"""
    script_path.write_text(script_content, encoding="utf-8-sig")

    ps_args = f'-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{script_path}"'
    if requires_uac:
        # Solicita UAC ANTES de cerrar la app: si el usuario cancela (<= 32), no cerramos el programa
        rc = ctypes.windll.shell32.ShellExecuteW(
            None,
            "runas",
            "powershell.exe",
            ps_args,
            str(app_dir),
            0,
        )
        if rc <= 32:
            script_path.unlink(missing_ok=True)
            raise PermissionError(
                "No se concedieron permisos de administrador (UAC) en Windows."
            )
    else:
        # Usar solo CREATE_NO_WINDOW (nunca combinar con DETACHED_PROCESS: Win32 provoca salida silenciosa en 0)
        creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-WindowStyle",
                "Hidden",
                "-File",
                str(script_path),
            ],
            cwd=str(app_dir),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=creation_flags,
            close_fds=True,
        )

    return {
        "launched": True,
        "requires_elevation": requires_uac,
        "staged_path": str(staged_path),
    }

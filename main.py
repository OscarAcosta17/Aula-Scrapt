import asyncio
import hmac
import io
import os
import secrets
import signal
import socket
import subprocess
import sys
import base64
import threading
import time
from pathlib import Path
from typing import Dict, List, Optional
import qrcode
import uvicorn
import json
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.requests import Request
from pydantic import BaseModel

if sys.stdout is None:
    sys.stdout = io.StringIO()
elif hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

if sys.stderr is None:
    sys.stderr = io.StringIO()
elif hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from config import (
    APP_VERSION,
    BASE_DIR,
    SCAN_CACHE_FILE,
    get_download_root,
    list_existing_subfolders,
    load_settings,
    resolve_course_preferences,
    save_settings,
)
from scraper.auth import (
    clear_session,
    launch_interactive_browser_login,
    load_saved_session,
    save_access_token,
    save_manual_cookie,
    verify_session,
)
from scraper.moodle_client import get_enrolled_courses, scan_course_contents
from scraper.notifier import (
    add_notification,
    clear_notifications,
    compute_scan_notifications,
    list_notifications,
    mark_all_notifications_read,
)
from scraper.obsidian_sync import (
    download_item_to_obsidian,
    enrich_items_with_status,
    export_course_resources_markdown,
    mark_items_as_seen,
)
from scraper.updater import (
    check_for_updates,
    download_update_asset,
    get_update_environment_info,
    launch_windows_updater,
)

app = FastAPI(title="Aula-Scrapt USM", version=APP_VERSION)
_active_webview_window = None
_force_exit = False
_tray_icon = None
_tray_ready = False

_PAIRING_LOCK = threading.Lock()
_PAIRING_CODES: Dict[str, dict] = {}
_PAIRING_FAILED_ATTEMPTS = 0
_PAIRING_TTL_SECONDS = 300
_PAIRING_MAX_ATTEMPTS = 5
_LAST_SCAN_LOCK = threading.Lock()
_LAST_BACKGROUND_SCAN_TS = 0.0

STATIC_DIR = BASE_DIR / "web" / "static"
TEMPLATES_DIR = BASE_DIR / "web" / "templates"
STATIC_DIR.mkdir(parents=True, exist_ok=True)
TEMPLATES_DIR.mkdir(parents=True, exist_ok=True)

app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))


def get_local_ip() -> str:
    """Detecta la dirección IP de la red local (Wi-Fi / LAN) para acceso desde el teléfono."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip


def generate_qr_base64(url: str) -> str:
    """Genera un código QR en base64 para mostrarlo en la interfaz web."""
    qr = qrcode.QRCode(version=1, box_size=6, border=2)
    qr.add_data(url)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("utf-8")


def _open_native_folder_dialog(initial_dir: str) -> Optional[str]:
    """Abre el selector nativo de carpetas del sistema operativo."""
    try:
        import tkinter as tk
        from tkinter import filedialog

        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        selected = filedialog.askdirectory(
            initialdir=initial_dir if Path(initial_dir).exists() else str(Path.home()),
            title="Seleccionar carpeta de destino para Aula-Scrapt",
        )
        root.destroy()
        return selected if selected else None
    except Exception:
        return None


class CookieInput(BaseModel):
    cookie_value: str


class TokenInput(BaseModel):
    token_value: str


class SettingsUpdateRequest(BaseModel):
    download_root: Optional[str] = None
    course_id: Optional[int] = None
    course_folder: Optional[str] = None
    course_subfolder: Optional[str] = None
    course_organize_by_section: Optional[bool] = None
    course_hidden: Optional[bool] = None
    auto_check_updates: Optional[bool] = None
    beta_updates_channel: Optional[bool] = None
    default_subfolder: Optional[str] = None
    default_organize_by_section: Optional[bool] = None
    skip_already_downloaded: Optional[bool] = None
    skip_seen_on_select: Optional[bool] = None
    auto_export_links_to_obsidian: Optional[bool] = None
    auto_export_forums_to_obsidian: Optional[bool] = None
    theme_mode: Optional[str] = None
    accent_color: Optional[str] = None
    default_tab: Optional[str] = None
    hide_empty_sections: Optional[bool] = None
    hidden_courses: Optional[List[int]] = None
    preferred_extensions: Optional[List[str]] = None
    max_auto_select_mb: Optional[int] = None
    notify_native_enabled: Optional[bool] = None
    notify_on_new_files: Optional[bool] = None
    notify_on_download_done: Optional[bool] = None
    notify_on_deadlines: Optional[bool] = None
    background_sync_hours: Optional[int] = None
    minimize_to_tray: Optional[bool] = None


class ApplyUpdateRequest(BaseModel):
    download_url: str
    asset_name: str
    size: int = 0
    sha256: str = ""


class DownloadItemRequest(BaseModel):
    id: str
    title: str
    section: str
    url: str
    obsidian_folder: str
    target_subfolder: str = ""
    organize_by_section: bool = True
    file_name: str = ""
    type: str = "file"


class BatchDownloadRequest(BaseModel):
    items: List[DownloadItemRequest]


class MarkSeenRequest(BaseModel):
    items: List[Dict]


class OpenFileRequest(BaseModel):
    path: str
    reveal: bool = False


def _build_settings_response(settings: Optional[Dict] = None) -> Dict:
    cfg = settings if settings is not None else load_settings()
    return {
        "download_root": cfg.get("download_root", ""),
        "course_folders": cfg.get("course_folders", {}),
        "course_subfolders": cfg.get("course_subfolders", {}),
        "course_org_sections": cfg.get("course_org_sections", {}),
        "hidden_courses": cfg.get("hidden_courses", []),
        "existing_subfolders": list_existing_subfolders(),
        "auto_check_updates": bool(cfg.get("auto_check_updates", True)),
        "beta_updates_channel": bool(cfg.get("beta_updates_channel", False)),
        "default_subfolder": cfg.get("default_subfolder", ""),
        "default_organize_by_section": bool(cfg.get("default_organize_by_section", True)),
        "skip_already_downloaded": bool(cfg.get("skip_already_downloaded", True)),
        "skip_seen_on_select": bool(cfg.get("skip_seen_on_select", True)),
        "auto_export_links_to_obsidian": bool(cfg.get("auto_export_links_to_obsidian", True)),
        "auto_export_forums_to_obsidian": bool(cfg.get("auto_export_forums_to_obsidian", True)),
        "theme_mode": cfg.get("theme_mode", "dark"),
        "accent_color": cfg.get("accent_color", "blue"),
        "default_tab": cfg.get("default_tab", "new"),
        "hide_empty_sections": bool(cfg.get("hide_empty_sections", True)),
        "preferred_extensions": cfg.get("preferred_extensions", []),
        "max_auto_select_mb": int(cfg.get("max_auto_select_mb", 0)),
        "notify_native_enabled": bool(cfg.get("notify_native_enabled", True)),
        "notify_on_new_files": bool(cfg.get("notify_on_new_files", True)),
        "notify_on_download_done": bool(cfg.get("notify_on_download_done", True)),
        "notify_on_deadlines": bool(cfg.get("notify_on_deadlines", True)),
        "background_sync_hours": int(cfg.get("background_sync_hours", 0)),
        "minimize_to_tray": bool(cfg.get("minimize_to_tray", False)),
        "unread_notifications": list_notifications()["unread_count"],
        "app_info": get_update_environment_info(),
    }


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    local_ip = get_local_ip()
    mobile_url = f"http://{local_ip}:8000"
    qr_b64 = generate_qr_base64(mobile_url)
    return templates.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "mobile_url": mobile_url,
            "qr_b64": qr_b64,
            "download_root": str(get_download_root()),
            "app_version": APP_VERSION,
        },
    )


@app.get("/api/settings")
async def api_get_settings():
    return _build_settings_response()


@app.post("/api/settings")
async def api_update_settings(payload: SettingsUpdateRequest):
    settings = load_settings()
    if payload.download_root is not None:
        clean_path = payload.download_root.strip()
        if not clean_path:
            raise HTTPException(status_code=400, detail="La ruta no puede estar vacía.")
        settings["download_root"] = str(Path(clean_path))

    if payload.course_id is not None:
        cid_key = str(payload.course_id)
        if payload.course_folder is not None:
            settings.setdefault("course_folders", {})[cid_key] = payload.course_folder.strip()
        if payload.course_subfolder is not None:
            settings.setdefault("course_subfolders", {})[cid_key] = payload.course_subfolder.strip()
        if payload.course_organize_by_section is not None:
            settings.setdefault("course_org_sections", {})[cid_key] = bool(
                payload.course_organize_by_section
            )
        if payload.course_hidden is not None:
            hidden = {int(c) for c in (settings.get("hidden_courses") or []) if str(c).isdigit()}
            if payload.course_hidden:
                hidden.add(int(payload.course_id))
            else:
                hidden.discard(int(payload.course_id))
            settings["hidden_courses"] = sorted(hidden)

    if payload.hidden_courses is not None:
        settings["hidden_courses"] = sorted({int(c) for c in payload.hidden_courses})

    bool_fields = [
        "auto_check_updates",
        "beta_updates_channel",
        "default_organize_by_section",
        "skip_already_downloaded",
        "skip_seen_on_select",
        "auto_export_links_to_obsidian",
        "auto_export_forums_to_obsidian",
        "hide_empty_sections",
        "notify_native_enabled",
        "notify_on_new_files",
        "notify_on_download_done",
        "notify_on_deadlines",
        "minimize_to_tray",
    ]
    for field in bool_fields:
        val = getattr(payload, field)
        if val is not None:
            settings[field] = bool(val)

    if payload.default_subfolder is not None:
        settings["default_subfolder"] = payload.default_subfolder.strip()
    if payload.theme_mode in {"system", "dark", "light"}:
        settings["theme_mode"] = payload.theme_mode
    if payload.accent_color in {"blue", "emerald", "violet", "amber", "rose"}:
        settings["accent_color"] = payload.accent_color
    if payload.default_tab in {"new", "all", "files", "deadlines"}:
        settings["default_tab"] = payload.default_tab
    if payload.preferred_extensions is not None:
        settings["preferred_extensions"] = sorted(
            {
                str(ext).strip().lower().lstrip(".")
                for ext in payload.preferred_extensions
                if str(ext).strip()
            }
        )
    if payload.max_auto_select_mb is not None:
        settings["max_auto_select_mb"] = max(0, int(payload.max_auto_select_mb))
    if payload.background_sync_hours is not None:
        allowed_hours = {0, 2, 6, 12, 24}
        hrs = int(payload.background_sync_hours)
        settings["background_sync_hours"] = hrs if hrs in allowed_hours else 0

    save_settings(settings)
    return _build_settings_response(settings)


@app.get("/api/updates/check")
async def api_check_updates(beta: Optional[bool] = None):
    return await asyncio.to_thread(check_for_updates, beta)


@app.post("/api/updates/apply")
async def api_apply_update(payload: ApplyUpdateRequest):
    """Descarga con progreso SSE, lanza el script de actualización (con UAC si hace falta) y cierra para reiniciar."""
    import queue as queue_mod
    import threading

    progress_queue: queue_mod.Queue = queue_mod.Queue()

    def worker():
        try:
            progress_queue.put(
                {"event": "status", "percent": 0, "message": f"Conectando para descargar {payload.asset_name}..."}
            )

            def on_progress(downloaded: int, total: int, pct: int):
                mb_done = downloaded / (1024 * 1024)
                mb_tot = total / (1024 * 1024) if total > 0 else 0
                txt = (
                    f"Descargando: {mb_done:.1f} MB / {mb_tot:.1f} MB"
                    if total > 0
                    else f"Descargando: {mb_done:.1f} MB"
                )
                progress_queue.put({"event": "progress", "percent": pct, "message": txt})

            staged = download_update_asset(
                payload.download_url,
                payload.asset_name,
                expected_size=payload.size,
                on_progress=on_progress,
                expected_sha256=payload.sha256,
            )
            progress_queue.put(
                {
                    "event": "progress",
                    "percent": 100,
                    "message": "Aplicando actualización y solicitando permisos si corresponde...",
                }
            )
            launch_info = launch_windows_updater(staged)
            progress_queue.put(
                {
                    "event": "ready_restart",
                    "percent": 100,
                    "message": "Actualización lista. Reiniciando Aula-Scrapt...",
                    **launch_info,
                }
            )
        except Exception as exc:
            progress_queue.put({"event": "error", "message": str(exc)})
        finally:
            progress_queue.put(None)

    threading.Thread(target=worker, daemon=True).start()

    async def event_stream():
        should_restart = False
        while True:
            item = await asyncio.to_thread(progress_queue.get)
            if item is None:
                break
            if item.get("event") == "ready_restart":
                should_restart = True
            yield f"data: {json.dumps(item, ensure_ascii=False)}\n\n"

        if should_restart:
            def stop_for_update():
                global _force_exit
                _force_exit = True
                time.sleep(0.7)
                _dispose_tray_icon()
                try:
                    if _active_webview_window is not None:
                        _active_webview_window.destroy()
                except Exception:
                    pass
                os._exit(0)

            threading.Thread(target=stop_for_update, daemon=True).start()

    return StreamingResponse(event_stream(), media_type="text/event-stream")


@app.post("/api/settings/pick-folder")
async def api_pick_folder():
    settings = load_settings()
    current_dir = settings.get("download_root", str(Path.home()))
    chosen = await asyncio.to_thread(_open_native_folder_dialog, current_dir)
    if chosen:
        settings["download_root"] = str(Path(chosen))
        save_settings(settings)
    return {
        "changed": bool(chosen),
        "download_root": settings["download_root"],
        "existing_subfolders": list_existing_subfolders(),
    }


@app.get("/api/session")
async def api_check_session():
    return await asyncio.to_thread(verify_session)


@app.post("/api/login/browser")
async def api_login_browser():
    result = await asyncio.to_thread(launch_interactive_browser_login)
    return result


@app.post("/api/login/cookie")
async def api_login_cookie(payload: CookieInput):
    if not payload.cookie_value.strip():
        raise HTTPException(
            status_code=400, detail="El valor de la cookie no puede estar vacío."
        )
    return await asyncio.to_thread(save_manual_cookie, payload.cookie_value)


@app.post("/api/login/token")
async def api_login_token(payload: TokenInput):
    if not payload.token_value.strip():
        raise HTTPException(
            status_code=400, detail="El token de acceso no puede estar vacío."
        )
    return await asyncio.to_thread(save_access_token, payload.token_value)


@app.post("/api/logout")
async def api_logout():
    clear_session()
    return {"authenticated": False, "reason": "Sesión cerrada correctamente."}


def _load_scan_cache() -> Optional[Dict]:
    if not SCAN_CACHE_FILE.exists():
        return None
    try:
        data = json.loads(SCAN_CACHE_FILE.read_text(encoding="utf-8"))
        if isinstance(data, dict) and isinstance(data.get("courses"), list):
            return data
    except Exception:
        pass
    return None


def _save_scan_cache(payload: Dict) -> None:
    try:
        SCAN_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)
        cache_obj = {
            "courses": payload.get("courses", []),
            "download_root": payload.get("download_root", str(get_download_root())),
            "existing_subfolders": payload.get("existing_subfolders", []),
            "summary": payload.get("summary", {}),
            "cached_at": int(payload.get("cached_at") or time.time()),
        }
        SCAN_CACHE_FILE.write_text(
            json.dumps(cache_obj, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    except Exception:
        pass


def _summarize_scan_results(results: List[Dict]) -> Dict:
    now = time.time()
    total_files = 0
    total_new_files = 0
    upcoming_deadlines_count = 0
    urgent_deadlines_count = 0

    for entry in results:
        total_files += int(entry.get("downloadable_count", 0))
        total_new_files += int(entry.get("new_files_count", 0))
        for item in entry.get("items") or []:
            if item.get("type") in {"assign", "quiz"}:
                due_ts = item.get("due_timestamp")
                if isinstance(due_ts, (int, float)) and due_ts >= now:
                    upcoming_deadlines_count += 1
                    if due_ts - now <= 48 * 3600:
                        urgent_deadlines_count += 1

    return {
        "total_courses": len(results),
        "total_files": total_files,
        "total_new_files": total_new_files,
        "upcoming_deadlines_count": upcoming_deadlines_count,
        "urgent_deadlines_count": urgent_deadlines_count,
    }


def _re_enrich_cached_courses(cached: Dict, allow_network_head: bool = False) -> Dict:
    root = get_download_root()
    updated_courses = []
    for entry in cached.get("courses") or []:
        if not isinstance(entry, dict):
            continue
        course = dict(entry.get("course") or {})
        cid = int(course.get("id") or 0)
        fullname = str(course.get("fullname") or "")
        prefs = resolve_course_preferences(cid, fullname)
        course.update(prefs)
        raw_items = entry.get("items") or []
        enriched = enrich_items_with_status(
            raw_items,
            course.get("obsidian_folder", fullname),
            allow_network_head=allow_network_head,
        )
        new_files_count = sum(
            1 for i in enriched if i.get("downloadable") and not i.get("is_downloaded")
        )
        downloadable_count = sum(1 for i in enriched if i.get("downloadable"))
        updated_courses.append(
            {
                **entry,
                "course": course,
                "items": enriched,
                "new_files_count": new_files_count,
                "downloadable_count": downloadable_count,
            }
        )

    payload = {
        "courses": updated_courses,
        "download_root": str(root),
        "existing_subfolders": list_existing_subfolders(),
        "summary": _summarize_scan_results(updated_courses),
        "cached_at": cached.get("cached_at") or int(time.time()),
    }
    _save_scan_cache(payload)
    return payload


def _sync_existing_course_markdowns(results: List[Dict]) -> None:
    settings = load_settings()
    if not (
        settings.get("auto_export_links_to_obsidian", True)
        or settings.get("auto_export_forums_to_obsidian", True)
    ):
        return
    root = get_download_root()
    for entry in results:
        course = entry.get("course") or {}
        if course.get("is_hidden"):
            continue
        folder_name = course.get("obsidian_folder")
        if not folder_name:
            continue
        course_dir = root / folder_name
        if course_dir.exists() and course_dir.is_dir():
            try:
                export_course_resources_markdown(
                    obsidian_folder_name=folder_name,
                    target_subfolder=course.get("target_subfolder", ""),
                    course_items=entry.get("items") or [],
                )
            except Exception:
                pass


def _execute_full_scan_sync(fire_notifications: bool = True) -> Dict:
    global _LAST_BACKGROUND_SCAN_TS
    previous_cache = _load_scan_cache()
    courses = get_enrolled_courses()
    results: List[Dict] = []

    for course in courses:
        try:
            raw_items = scan_course_contents(course["id"], course["fullname"])
            enriched = enrich_items_with_status(
                raw_items, course["obsidian_folder"], allow_network_head=False
            )
            new_files_count = sum(
                1 for i in enriched if i.get("downloadable") and not i.get("is_downloaded")
            )
            downloadable_count = sum(1 for i in enriched if i.get("downloadable"))
            results.append(
                {
                    "course": course,
                    "items": enriched,
                    "new_files_count": new_files_count,
                    "downloadable_count": downloadable_count,
                }
            )
        except Exception as e:
            results.append(
                {
                    "course": course,
                    "items": [],
                    "error": str(e),
                    "new_files_count": 0,
                    "downloadable_count": 0,
                }
            )

    _sync_existing_course_markdowns(results)
    payload = {
        "courses": results,
        "download_root": str(get_download_root()),
        "existing_subfolders": list_existing_subfolders(),
        "summary": _summarize_scan_results(results),
        "cached_at": int(time.time()),
    }
    _save_scan_cache(payload)
    if fire_notifications:
        created = compute_scan_notifications(results, previous_cache, fire_toast=True)
        payload["new_notifications"] = created
    payload["unread_notifications"] = list_notifications()["unread_count"]
    with _LAST_SCAN_LOCK:
        _LAST_BACKGROUND_SCAN_TS = time.time()
    return payload


@app.get("/api/scan/cached")
async def api_get_cached_scan():
    cached = _load_scan_cache()
    if not cached:
        return {
            "has_cache": False,
            "cached": False,
            "courses": [],
            "download_root": str(get_download_root()),
            "existing_subfolders": list_existing_subfolders(),
            "unread_notifications": list_notifications()["unread_count"],
        }
    current_root = str(get_download_root())
    if cached.get("download_root") != current_root:
        cached = await asyncio.to_thread(_re_enrich_cached_courses, cached, False)
    return {
        **cached,
        "has_cache": True,
        "cached": True,
        "unread_notifications": list_notifications()["unread_count"],
    }


@app.get("/api/scan")
async def api_scan_all():
    global _LAST_BACKGROUND_SCAN_TS
    previous_cache = _load_scan_cache()
    try:
        courses = await asyncio.to_thread(get_enrolled_courses)
    except PermissionError as e:
        raise HTTPException(status_code=401, detail=str(e))
    except Exception as e:
        raise HTTPException(
            status_code=500, detail=f"Error al obtener cursos: {str(e)}"
        )

    async def scan_single_course(course):
        try:
            raw_items = await asyncio.to_thread(
                scan_course_contents, course["id"], course["fullname"]
            )
            enriched = await asyncio.to_thread(
                enrich_items_with_status, raw_items, course["obsidian_folder"], True
            )
            new_files_count = sum(
                1 for i in enriched if i.get("downloadable") and not i.get("is_downloaded")
            )
            downloadable_count = sum(1 for i in enriched if i.get("downloadable"))
            return {
                "course": course,
                "items": enriched,
                "new_files_count": new_files_count,
                "downloadable_count": downloadable_count,
            }
        except Exception as e:
            return {
                "course": course,
                "items": [],
                "error": str(e),
                "new_files_count": 0,
                "downloadable_count": 0,
            }

    results = list(await asyncio.gather(*(scan_single_course(c) for c in courses)))
    await asyncio.to_thread(_sync_existing_course_markdowns, results)

    payload = {
        "courses": results,
        "download_root": str(get_download_root()),
        "existing_subfolders": list_existing_subfolders(),
        "summary": _summarize_scan_results(results),
        "cached_at": int(time.time()),
    }
    await asyncio.to_thread(_save_scan_cache, payload)
    created_notifs = await asyncio.to_thread(
        compute_scan_notifications, results, previous_cache, True
    )
    payload["new_notifications"] = created_notifs
    payload["unread_notifications"] = list_notifications()["unread_count"]
    with _LAST_SCAN_LOCK:
        _LAST_BACKGROUND_SCAN_TS = time.time()
    return payload


@app.post("/api/rescan-local")
async def api_rescan_local():
    cached = _load_scan_cache()
    if not cached:
        return {
            "has_cache": False,
            "courses": [],
            "download_root": str(get_download_root()),
            "existing_subfolders": list_existing_subfolders(),
        }
    refreshed = await asyncio.to_thread(_re_enrich_cached_courses, cached, False)
    return {
        **refreshed,
        "has_cache": True,
        "cached": True,
        "rescan": True,
        "unread_notifications": list_notifications()["unread_count"],
    }


@app.post("/api/open-file")
async def api_open_file(payload: OpenFileRequest):
    raw_path = (payload.path or "").strip()
    if not raw_path:
        raise HTTPException(status_code=400, detail="Ruta vacía.")
    root = get_download_root().resolve()
    try:
        target = Path(raw_path).resolve()
    except OSError as exc:
        raise HTTPException(status_code=400, detail=f"Ruta inválida: {exc}")

    try:
        is_inside = os.path.commonpath([str(target), str(root)]) == str(root)
    except ValueError:
        is_inside = False

    if not is_inside:
        raise HTTPException(
            status_code=403,
            detail="Solo se permite abrir archivos dentro de la carpeta de descarga configurada.",
        )
    if not target.exists():
        raise HTTPException(status_code=404, detail="El archivo o carpeta ya no existe en disco.")

    if sys.platform == "win32":
        if payload.reveal:
            if target.is_dir():
                os.startfile(str(target))
            else:
                subprocess.Popen(["explorer", "/select,", str(target)])
        else:
            os.startfile(str(target))
    else:
        opener = "open" if sys.platform == "darwin" else "xdg-open"
        subprocess.Popen([opener, str(target.parent if payload.reveal else target)])

    return {"ok": True, "path": str(target)}


@app.get("/api/notifications")
async def api_list_notifications():
    return list_notifications()


@app.post("/api/notifications/read-all")
async def api_mark_notifications_read():
    return mark_all_notifications_read()


@app.delete("/api/notifications")
async def api_clear_notifications():
    return clear_notifications()


@app.post("/api/notifications/test")
async def api_test_notification():
    entry = add_notification(
        title="Notificación de prueba",
        body="Las notificaciones de escritorio de Aula-Scrapt están activas.",
        kind="info",
        fire_toast=True,
    )
    return {"ok": True, "notification": entry, **list_notifications()}


def _purge_expired_pairings_unlocked(now: float) -> None:
    expired = [
        pin
        for pin, info in _PAIRING_CODES.items()
        if float(info.get("expires_at") or 0) <= now
    ]
    for pin in expired:
        _PAIRING_CODES.pop(pin, None)


@app.post("/api/pair/create")
async def api_pair_create():
    session_data = load_saved_session() or {}
    if not session_data.get("token") and not session_data.get("cookies"):
        raise HTTPException(
            status_code=401,
            detail="Inicia sesión en el PC antes de vincular la app móvil.",
        )

    now = time.time()
    pin = f"{secrets.randbelow(900000) + 100000}"
    expires_at = int(now + _PAIRING_TTL_SECONDS)
    local_ip = get_local_ip()
    base_url = f"http://{local_ip}:8000"

    with _PAIRING_LOCK:
        _purge_expired_pairings_unlocked(now)
        global _PAIRING_FAILED_ATTEMPTS
        _PAIRING_FAILED_ATTEMPTS = 0
        _PAIRING_CODES[pin] = {
            "expires_at": expires_at,
            "base_url": base_url,
        }

    qr_payload = json.dumps(
        {"t": "aula-pair", "u": base_url, "p": pin},
        separators=(",", ":"),
    )
    qr_b64 = generate_qr_base64(qr_payload)
    return {
        "ok": True,
        "pin": pin,
        "base_url": base_url,
        "expires_at": expires_at,
        "ttl_seconds": _PAIRING_TTL_SECONDS,
        "qr_b64": qr_b64,
    }


@app.get("/api/pair/claim")
async def api_pair_claim(pin: str):
    clean_pin = (pin or "").strip()
    now = time.time()
    with _PAIRING_LOCK:
        global _PAIRING_FAILED_ATTEMPTS
        _purge_expired_pairings_unlocked(now)

        matched_key = None
        for key in _PAIRING_CODES:
            if hmac.compare_digest(key, clean_pin):
                matched_key = key
                break

        if not matched_key:
            _PAIRING_FAILED_ATTEMPTS += 1
            if _PAIRING_FAILED_ATTEMPTS >= _PAIRING_MAX_ATTEMPTS:
                _PAIRING_CODES.clear()
            raise HTTPException(
                status_code=401,
                detail="PIN inválido o expirado. Genera un nuevo código en el PC.",
            )

        _PAIRING_CODES.pop(matched_key, None)
        _PAIRING_FAILED_ATTEMPTS = 0

    session_data = load_saved_session() or {}
    if not session_data.get("token") and not session_data.get("cookies"):
        raise HTTPException(status_code=401, detail="El PC ya no tiene una sesión activa.")

    settings = load_settings()
    return {
        "ok": True,
        "auth": {
            "token": session_data.get("token"),
            "cookies": session_data.get("cookies") or [],
        },
        "settings": {
            "course_folders": settings.get("course_folders", {}),
            "course_subfolders": settings.get("course_subfolders", {}),
            "course_org_sections": settings.get("course_org_sections", {}),
            "hidden_courses": settings.get("hidden_courses", []),
            "default_subfolder": settings.get("default_subfolder", ""),
            "default_organize_by_section": bool(
                settings.get("default_organize_by_section", True)
            ),
            "skip_already_downloaded": bool(settings.get("skip_already_downloaded", True)),
            "skip_seen_on_select": bool(settings.get("skip_seen_on_select", True)),
            "auto_export_links_to_obsidian": bool(
                settings.get("auto_export_links_to_obsidian", True)
            ),
            "auto_export_forums_to_obsidian": bool(
                settings.get("auto_export_forums_to_obsidian", True)
            ),
            "preferred_extensions": settings.get("preferred_extensions", []),
            "max_auto_select_mb": int(settings.get("max_auto_select_mb", 0)),
        },
    }


@app.post("/api/download/stream")
async def api_download_stream(payload: BatchDownloadRequest):
    """
    Descarga archivos con streaming de eventos en tiempo real (Server-Sent Events)
    para informar el porcentaje y archivo exacto en descarga.
    """
    if not payload.items:
        raise HTTPException(status_code=400, detail="No se seleccionaron archivos.")

    async def event_generator():
        total = len(payload.items)
        downloaded = []
        errors = []

        for idx, req_item in enumerate(payload.items):
            current_num = idx + 1
            start_payload = {
                "event": "start_file",
                "index": current_num,
                "total": total,
                "percent": int(((current_num - 1) / total) * 100),
                "item_id": req_item.id,
                "title": req_item.title,
                "section": req_item.section,
                "obsidian_folder": req_item.obsidian_folder,
            }
            yield f"data: {json.dumps(start_payload, ensure_ascii=False)}\n\n"

            try:
                res = await asyncio.to_thread(
                    download_item_to_obsidian,
                    item=req_item.model_dump(),
                    obsidian_folder_name=req_item.obsidian_folder,
                    target_subfolder=req_item.target_subfolder,
                    organize_by_section=req_item.organize_by_section,
                )
                downloaded.append(res)
                file_done_payload = {
                    "event": "file_done",
                    "index": current_num,
                    "total": total,
                    "percent": int((current_num / total) * 100),
                    "item_id": req_item.id,
                    "title": req_item.title,
                    "filename": res.get("filename", ""),
                    "saved_path": res.get("saved_path", ""),
                }
                yield f"data: {json.dumps(file_done_payload, ensure_ascii=False)}\n\n"
            except Exception as e:
                err_info = {"id": req_item.id, "title": req_item.title, "error": str(e)}
                errors.append(err_info)
                file_err_payload = {
                    "event": "file_error",
                    "index": current_num,
                    "total": total,
                    "percent": int((current_num / total) * 100),
                    "item_id": req_item.id,
                    "title": req_item.title,
                    "error": str(e),
                }
                yield f"data: {json.dumps(file_err_payload, ensure_ascii=False)}\n\n"

        if downloaded and load_settings().get("notify_on_download_done", True):
            first_file = downloaded[0].get("filename") or downloaded[0].get("title") or ""
            body_text = (
                f"Guardado: {first_file}"
                if len(downloaded) == 1
                else f"Descargados {len(downloaded)} de {total} archivos seleccionados."
            )
            add_notification(
                title=f"Descarga completada ({len(downloaded)})",
                body=body_text,
                kind="download",
                fire_toast=True,
            )

        complete_payload = {
            "event": "complete",
            "total": total,
            "downloaded_count": len(downloaded),
            "errors": errors,
            "downloaded": downloaded,
            "unread_notifications": list_notifications()["unread_count"],
        }
        yield f"data: {json.dumps(complete_payload, ensure_ascii=False)}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")


@app.post("/api/download")
async def api_download_batch(payload: BatchDownloadRequest):
    if not payload.items:
        raise HTTPException(status_code=400, detail="No se seleccionaron archivos.")

    downloaded = []
    errors = []

    for req_item in payload.items:
        try:
            res = await asyncio.to_thread(
                download_item_to_obsidian,
                item=req_item.model_dump(),
                obsidian_folder_name=req_item.obsidian_folder,
                target_subfolder=req_item.target_subfolder,
                organize_by_section=req_item.organize_by_section,
            )
            downloaded.append(res)
        except Exception as e:
            errors.append(
                {"id": req_item.id, "title": req_item.title, "error": str(e)}
            )

    return {
        "downloaded_count": len(downloaded),
        "downloaded": downloaded,
        "errors": errors,
    }


def _dispose_tray_icon() -> None:
    global _tray_icon, _tray_ready
    icon_obj = _tray_icon
    _tray_icon = None
    _tray_ready = False
    if icon_obj is not None:
        try:
            icon_obj.Visible = False
            icon_obj.Dispose()
        except Exception:
            pass


def _start_windows_tray_icon(icon_path: Optional[str]) -> None:
    if sys.platform != "win32":
        return

    def tray_runner():
        global _tray_icon, _tray_ready, _force_exit
        try:
            import clr

            clr.AddReference("System.Windows.Forms")
            clr.AddReference("System.Drawing")
            import System.Drawing as Drawing
            import System.Windows.Forms as WinForms

            notify = WinForms.NotifyIcon()
            notify.Text = f"Aula-Scrapt USM v{APP_VERSION}"
            if icon_path and os.path.exists(icon_path):
                notify.Icon = Drawing.Icon(icon_path)
            else:
                notify.Icon = Drawing.SystemIcons.Application

            menu = WinForms.ContextMenuStrip()

            def on_show(_sender, _args):
                try:
                    if _active_webview_window is not None:
                        _active_webview_window.show()
                except Exception:
                    pass

            def on_sync(_sender, _args):
                threading.Thread(
                    target=lambda: _execute_full_scan_sync(fire_notifications=True),
                    daemon=True,
                ).start()

            def on_exit(_sender, _args):
                global _force_exit
                _force_exit = True
                _dispose_tray_icon()
                try:
                    WinForms.Application.ExitThread()
                except Exception:
                    pass
                try:
                    if _active_webview_window is not None:
                        _active_webview_window.destroy()
                except Exception:
                    pass
                os._exit(0)

            menu.Items.Add("Abrir Aula-Scrapt", None, on_show)
            menu.Items.Add("Buscar archivos ahora", None, on_sync)
            menu.Items.Add("Salir", None, on_exit)
            notify.ContextMenuStrip = menu
            notify.DoubleClick += on_show
            notify.Visible = True

            _tray_icon = notify
            _tray_ready = True
            WinForms.Application.Run()
        except Exception:
            _tray_ready = False

    threading.Thread(target=tray_runner, daemon=True).start()


def _on_window_closing():
    if not _force_exit and _tray_ready and load_settings().get("minimize_to_tray", False):
        try:
            if _active_webview_window is not None:
                _active_webview_window.hide()
            return False
        except Exception:
            pass
    return True


def _start_background_sync_thread() -> None:
    def sync_loop():
        global _LAST_BACKGROUND_SCAN_TS
        with _LAST_SCAN_LOCK:
            if _LAST_BACKGROUND_SCAN_TS <= 0:
                _LAST_BACKGROUND_SCAN_TS = time.time()
        while True:
            time.sleep(30)
            try:
                hours = int(load_settings().get("background_sync_hours", 0))
                if hours <= 0:
                    continue
                with _LAST_SCAN_LOCK:
                    last_ts = _LAST_BACKGROUND_SCAN_TS
                if time.time() - last_ts >= hours * 3600:
                    _execute_full_scan_sync(fire_notifications=True)
            except Exception:
                with _LAST_SCAN_LOCK:
                    _LAST_BACKGROUND_SCAN_TS = time.time()

    threading.Thread(target=sync_loop, daemon=True).start()


@app.post("/api/mark-seen")
async def api_mark_seen(payload: MarkSeenRequest):
    await asyncio.to_thread(mark_items_as_seen, payload.items)
    return {"ok": True}


@app.post("/api/shutdown")
async def api_shutdown():
    """Permite cerrar la aplicación limpiamente desde el navegador."""
    def stop():
        global _force_exit
        _force_exit = True
        time.sleep(0.5)
        _dispose_tray_icon()
        try:
            if _active_webview_window is not None:
                _active_webview_window.destroy()
        except Exception:
            pass
        os.kill(os.getpid(), signal.SIGTERM)

    threading.Thread(target=stop, daemon=True).start()
    return {"status": "ok", "message": "Cerrando aplicación..."}


def print_startup_banner(host_ip: str, port: int):
    url_pc = f"http://localhost:{port}"
    url_mobile = f"http://{host_ip}:{port}"
    print("\n" + "=" * 62)
    print(" AULA-SCRAPT USM")
    print("=" * 62)
    print(f" Acceso en este PC  : {url_pc}")
    print(f" Acceso en Telefono : {url_mobile} (misma red Wi-Fi)")
    print("-" * 62)
    qr = qrcode.QRCode(version=1, border=1)
    qr.add_data(url_mobile)
    qr.make(fit=True)
    qr.print_ascii(invert=True)
    print("=" * 62 + "\n")


if __name__ == "__main__":
    port = 8000
    local_ip = get_local_ip()
    print_startup_banner(local_ip, port)
    _start_background_sync_thread()

    use_browser_only = "--browser" in sys.argv or "--no-gui" in sys.argv
    has_webview = False

    if not use_browser_only:
        try:
            import webview
            has_webview = True
        except ImportError:
            has_webview = False

    if has_webview:
        import urllib.request

        def run_server():
            uvicorn.run(app, host="0.0.0.0", port=port, log_level="warning")

        server_thread = threading.Thread(target=run_server, daemon=True)
        server_thread.start()

        # Esperar brevemente a que uvicorn levante
        for _ in range(40):
            try:
                urllib.request.urlopen(f"http://127.0.0.1:{port}/api/settings", timeout=0.5)
                break
            except Exception:
                time.sleep(0.1)

        # Crear y abrir ventana nativa de escritorio
        icon_path = str(BASE_DIR / "icon.ico") if (BASE_DIR / "icon.ico").exists() else None
        _active_webview_window = webview.create_window(
            title=f"Aula-Scrapt USM v{APP_VERSION}",
            url=f"http://127.0.0.1:{port}",
            width=1280,
            height=820,
            min_size=(800, 600),
            background_color="#0d1117",
        )
        _active_webview_window.events.closing += _on_window_closing
        # Iniciar tray icon recién cuando pywebview haya cargado pythonnet/clr en el hilo principal
        webview.start(func=lambda: _start_windows_tray_icon(icon_path), icon=icon_path)
        _dispose_tray_icon()
        sys.exit(0)
    else:
        # Modo estándar con apertura de navegador predeterminado
        import webbrowser

        def open_browser():
            time.sleep(1.2)
            try:
                webbrowser.open(f"http://localhost:{port}")
            except Exception:
                pass

        threading.Thread(target=open_browser, daemon=True).start()
        uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")

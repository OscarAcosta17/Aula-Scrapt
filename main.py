import asyncio
import io
import socket
import sys
import base64
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

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

from config import (
    BASE_DIR,
    get_download_root,
    list_existing_subfolders,
    load_settings,
    save_settings,
)
from scraper.auth import (
    clear_session,
    launch_interactive_browser_login,
    save_access_token,
    save_manual_cookie,
    verify_session,
)
from scraper.moodle_client import get_enrolled_courses, scan_course_contents
from scraper.obsidian_sync import (
    download_item_to_obsidian,
    enrich_items_with_status,
    mark_items_as_seen,
)

app = FastAPI(title="Aula-Scrapt USM", version="1.1.0")

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


class DownloadItemRequest(BaseModel):
    id: str
    title: str
    section: str
    url: str
    obsidian_folder: str
    target_subfolder: str = ""
    organize_by_section: bool = True


class BatchDownloadRequest(BaseModel):
    items: List[DownloadItemRequest]


class MarkSeenRequest(BaseModel):
    items: List[Dict]


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
        },
    )


@app.get("/api/settings")
async def api_get_settings():
    settings = load_settings()
    return {
        "download_root": settings.get("download_root", ""),
        "course_folders": settings.get("course_folders", {}),
        "existing_subfolders": list_existing_subfolders(),
    }


@app.post("/api/settings")
async def api_update_settings(payload: SettingsUpdateRequest):
    settings = load_settings()
    if payload.download_root is not None:
        clean_path = payload.download_root.strip()
        if not clean_path:
            raise HTTPException(status_code=400, detail="La ruta no puede estar vacía.")
        settings["download_root"] = str(Path(clean_path))

    if payload.course_id is not None and payload.course_folder is not None:
        settings.setdefault("course_folders", {})[str(payload.course_id)] = (
            payload.course_folder.strip()
        )

    save_settings(settings)
    return {
        "download_root": settings["download_root"],
        "course_folders": settings.get("course_folders", {}),
        "existing_subfolders": list_existing_subfolders(),
    }


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


@app.get("/api/scan")
async def api_scan_all():
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
                enrich_items_with_status, raw_items, course["obsidian_folder"]
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

    results = await asyncio.gather(*(scan_single_course(c) for c in courses))
    total_files = sum(r.get("downloadable_count", 0) for r in results)
    total_new_files = sum(r.get("new_files_count", 0) for r in results)

    return {
        "courses": list(results),
        "download_root": str(get_download_root()),
        "existing_subfolders": list_existing_subfolders(),
        "summary": {
            "total_courses": len(results),
            "total_files": total_files,
            "total_new_files": total_new_files,
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

        complete_payload = {
            "event": "complete",
            "total": total,
            "downloaded_count": len(downloaded),
            "errors": errors,
            "downloaded": downloaded,
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


@app.post("/api/mark-seen")
async def api_mark_seen(payload: MarkSeenRequest):
    await asyncio.to_thread(mark_items_as_seen, payload.items)
    return {"ok": True}


@app.post("/api/shutdown")
async def api_shutdown():
    """Permite cerrar la aplicación limpiamente desde el navegador."""
    def stop():
        import time
        import os
        import signal
        time.sleep(0.6)
        os.kill(os.getpid(), signal.SIGTERM)

    import threading
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

    use_browser_only = "--browser" in sys.argv or "--no-gui" in sys.argv
    has_webview = False

    if not use_browser_only:
        try:
            import webview
            has_webview = True
        except ImportError:
            has_webview = False

    if has_webview:
        import threading
        import time
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
        webview.create_window(
            title="Aula-Scrapt USM",
            url=f"http://127.0.0.1:{port}",
            width=1280,
            height=820,
            min_size=(800, 600),
            background_color="#0d1117",
        )
        webview.start()
        sys.exit(0)
    else:
        # Modo estándar con apertura de navegador predeterminado
        import threading
        import webbrowser

        def open_browser():
            import time
            time.sleep(1.2)
            try:
                webbrowser.open(f"http://localhost:{port}")
            except Exception:
                pass

        threading.Thread(target=open_browser, daemon=True).start()
        uvicorn.run(app, host="0.0.0.0", port=port, log_level="info")

import json
import re
import time
from datetime import datetime
from typing import Dict, Optional, Tuple
import requests
from bs4 import BeautifulSoup

from config import AULA_BASE_URL, AULA_LOGIN_URL, SESSION_FILE

USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)


def load_saved_session() -> Optional[Dict]:
    """Carga los datos de sesión guardados localmente si existen."""
    if not SESSION_FILE.exists():
        return None
    try:
        with open(SESSION_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def save_session_data(
    cookies: Dict[str, str], sesskey: str = "", user_name: str = "", user_id: int = 0, token: str = ""
) -> Dict:
    """Guarda las cookies o token de sesión en el archivo local privado."""
    data = {
        "cookies": cookies or {},
        "sesskey": sesskey,
        "token": token,
        "user_name": user_name,
        "user_id": user_id,
        "updated_at": datetime.now().isoformat(timespec="seconds"),
    }
    SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(SESSION_FILE, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    return data


def clear_session() -> None:
    """Elimina la sesión local guardada."""
    if SESSION_FILE.exists():
        SESSION_FILE.unlink()


def get_requests_session() -> Optional[requests.Session]:
    """Construye un objeto requests.Session con las cookies almacenadas y User-Agent válido."""
    saved = load_saved_session()
    if not saved or not saved.get("cookies"):
        return None

    req_session = requests.Session()
    req_session.headers.update({"User-Agent": USER_AGENT})
    for k, v in saved["cookies"].items():
        req_session.cookies.set(k, v, domain="aula.usm.cl")
    return req_session


def is_authenticated_moodle_html(url: str, html: str) -> bool:
    """
    Comprueba de forma estricta si la respuesta corresponde a una sesión autenticada real en Aula USM.
    Nota de debugging: Aula USM redirige a '/portada/index.php' cuando no hay sesión, y esa portada
    incluye un 'sesskey' de invitado en el botón de Microsoft OAuth. Por eso verificamos:
    1. Que la URL no sea '/portada/', '/login/' ni '/auth/'.
    2. Que no exista el formulario 'manual-login-form'.
    3. Que exista 'logout.php' o un 'userid' > 0 en la configuración M.cfg de Moodle.
    """
    lower_url = url.lower()
    if any(p in lower_url for p in ["/portada", "/login", "/auth/", "microsoftonline.com"]):
        return False
    if "manual-login-form" in html:
        return False

    userid_match = re.search(r'"userid"\s*:\s*([1-9]\d*)', html)
    has_logout = "logout.php" in html
    return bool(userid_match or has_logout)


def extract_session_details(html: str) -> Tuple[Optional[str], Optional[str], int]:
    """Extrae sesskey real, nombre del usuario y userid desde una página autenticada de Moodle."""
    # Preferir sesskey dentro de M.cfg o del enlace de logout
    sesskey_match = re.search(r'"sesskey"\s*:\s*"([^"]+)"', html)
    if not sesskey_match:
        sesskey_match = re.search(r'logout\.php\?sesskey=([a-zA-Z0-9]+)', html)
    if not sesskey_match:
        sesskey_match = re.search(r'sesskey=([a-zA-Z0-9]+)', html)
    sesskey = sesskey_match.group(1) if sesskey_match else None

    userid_match = re.search(r'"userid"\s*:\s*(\d+)', html)
    user_id = int(userid_match.group(1)) if userid_match else 0

    soup = BeautifulSoup(html, "lxml")
    user_name = None

    # Buscar nombre de usuario en elementos propios de Moodle 4.x / 3.x
    for selector in [
        ".usermenu .usertext",
        ".userbutton .usertext",
        "[data-region='usermenu'] .usertext",
        ".logininfo a[href*='user/profile.php']",
    ]:
        el = soup.select_one(selector)
        if el and el.get_text(strip=True):
            user_name = el.get_text(" ", strip=True)
            break

    if not user_name:
        # Buscar en el atributo aria-label o title del botón de menú de usuario
        btn = soup.select_one("#user-menu-toggle, .usermenu button")
        if btn:
            label = btn.get("aria-label") or btn.get("title") or ""
            if label and "menú de usuario" not in label.lower():
                user_name = label.strip()

    return sesskey, user_name, user_id


def verify_session() -> Dict:
    """
    Verifica en vivo si la sesión activa es válida, ya sea por wstoken o por cookies.
    """
    saved = load_saved_session()
    if not saved:
        return {"authenticated": False, "reason": "Sin sesión activa."}

    # 1. Verificación por wstoken si existe
    if saved.get("token"):
        ws_url = f"{AULA_BASE_URL}/webservice/rest/server.php"
        params = {
            "wstoken": saved["token"],
            "wsfunction": "core_webservice_get_site_info",
            "moodlewsrestformat": "json",
        }
        try:
            resp = requests.post(ws_url, data=params, headers={"User-Agent": USER_AGENT}, timeout=12)
            data = resp.json()
            if "errorcode" not in data and "userid" in data:
                return {
                    "authenticated": True,
                    "user_name": data.get("fullname", saved.get("user_name")),
                    "user_id": data.get("userid", saved.get("user_id")),
                    "token_type": "wstoken",
                    "updated_at": saved.get("updated_at"),
                }
            else:
                clear_session()
                return {"authenticated": False, "reason": "Token de acceso expirado o inválido."}
        except Exception:
            return {
                "authenticated": True,
                "user_name": saved.get("user_name"),
                "user_id": saved.get("user_id"),
                "token_type": "wstoken",
            }

    # 2. Verificación por cookies contra aula.usm.cl/my/courses.php
    req_session = get_requests_session()
    if not req_session or not saved.get("cookies"):
        return {"authenticated": False, "reason": "Sin sesión activa."}

    try:
        resp = req_session.get(f"{AULA_BASE_URL}/my/courses.php", allow_redirects=True, timeout=12)
        if not is_authenticated_moodle_html(resp.url, resp.text):
            clear_session()
            return {
                "authenticated": False,
                "reason": "Sesión no iniciada o expirada (redirigido a portada de acceso).",
            }

        sesskey, user_name, user_id = extract_session_details(resp.text)
        if not sesskey:
            clear_session()
            return {"authenticated": False, "reason": "No se encontró token de sesión válido."}

        cookies_dict = req_session.cookies.get_dict()
        display_name = user_name or saved.get("user_name") or f"Usuario ID {user_id}"
        updated = save_session_data(
            cookies=cookies_dict,
            sesskey=sesskey,
            user_name=display_name,
            user_id=user_id,
        )
        return {
            "authenticated": True,
            "user_name": updated["user_name"],
            "user_id": updated["user_id"],
            "sesskey": updated["sesskey"],
            "updated_at": updated["updated_at"],
        }
    except Exception as e:
        return {"authenticated": False, "reason": f"Error de conexión: {str(e)}"}


def save_access_token(token_value: str) -> Dict:
    """Valida y almacena un token de acceso (wstoken) de Moodle."""
    clean_val = token_value.strip()
    if not clean_val:
        return {"authenticated": False, "reason": "El token de acceso no puede estar vacío."}

    ws_url = f"{AULA_BASE_URL}/webservice/rest/server.php"
    params = {
        "wstoken": clean_val,
        "wsfunction": "core_webservice_get_site_info",
        "moodlewsrestformat": "json",
    }
    try:
        resp = requests.post(ws_url, data=params, headers={"User-Agent": USER_AGENT}, timeout=12)
        data = resp.json()
        if "errorcode" in data:
            return {"authenticated": False, "reason": f"Token inválido: {data.get('message', data.get('errorcode'))}"}

        user_name = data.get("fullname", data.get("username", "Usuario"))
        user_id = data.get("userid", 0)
        updated = save_session_data(
            cookies={},
            sesskey="",
            user_name=user_name,
            user_id=user_id,
            token=clean_val,
        )
        return {
            "authenticated": True,
            "user_name": updated["user_name"],
            "user_id": updated["user_id"],
            "token_type": "wstoken",
            "updated_at": updated["updated_at"],
        }
    except Exception as e:
        return {"authenticated": False, "reason": f"Error de validación: {str(e)}"}


def save_manual_cookie(moodle_session_value: str) -> Dict:
    """Guarda el valor de la cookie MoodleSession ingresada manualmente y la verifica."""
    clean_val = moodle_session_value.strip()
    if "=" in clean_val:
        clean_val = clean_val.split("=", 1)[1].strip()
    save_session_data(cookies={"MoodleSession": clean_val})
    return verify_session()


def launch_interactive_browser_login(timeout_seconds: int = 300) -> Dict:
    """
    Abre una ventana de navegador (Edge o Chrome) en la portada de Aula USM.
    Espera hasta que el usuario complete el login (manual o Microsoft 365 + 2FA)
    y llegue efectivamente al panel interno (/my/ o página con logout.php / userid > 0).
    """
    from playwright.sync_api import sync_playwright

    clear_session()

    with sync_playwright() as p:
        browser = None
        for channel in ["msedge", "chrome", None]:
            try:
                if channel:
                    browser = p.chromium.launch(headless=False, channel=channel)
                else:
                    browser = p.chromium.launch(headless=False)
                break
            except Exception:
                continue

        if browser is None:
            return {
                "authenticated": False,
                "reason": "No se pudo abrir Edge ni Chrome en este equipo.",
            }

        context = browser.new_context(user_agent=USER_AGENT)
        page = context.new_page()
        page.goto(AULA_LOGIN_URL)

        start_time = time.time()
        captured_cookies = {}
        sesskey = ""
        user_name = ""
        user_id = 0

        try:
            while time.time() - start_time < timeout_seconds:
                if page.is_closed():
                    break
                current_url = page.url
                # Solo inspeccionar cuando esté dentro de aula.usm.cl y fuera de /portada, /login y /auth
                if (
                    "aula.usm.cl" in current_url
                    and "/portada" not in current_url.lower()
                    and "/login" not in current_url.lower()
                    and "/auth/" not in current_url.lower()
                ):
                    try:
                        page.wait_for_load_state("domcontentloaded", timeout=3000)
                        html = page.content()
                        if is_authenticated_moodle_html(current_url, html):
                            ext_sesskey, ext_user, ext_uid = extract_session_details(html)
                            if ext_sesskey:
                                sesskey = ext_sesskey
                                user_id = ext_uid
                                user_name = ext_user or f"Usuario ID {ext_uid}"
                                for c in context.cookies():
                                    if "aula.usm.cl" in c.get("domain", ""):
                                        captured_cookies[c["name"]] = c["value"]
                                break
                    except Exception:
                        pass
                page.wait_for_timeout(1000)
        except Exception:
            pass
        finally:
            try:
                browser.close()
            except Exception:
                pass

        if captured_cookies and sesskey:
            save_session_data(
                cookies=captured_cookies,
                sesskey=sesskey,
                user_name=user_name,
                user_id=user_id,
            )
            return verify_session()

        return {
            "authenticated": False,
            "reason": "No se completó el inicio de sesión antes de cerrar el navegador.",
        }

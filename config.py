import json
import re
import sys
import unicodedata
from pathlib import Path
from typing import Dict, List

# Rutas base adaptadas para ejecución como script o ejecutable empaquetado (.exe)
if getattr(sys, "frozen", False):
    APP_ROOT = Path(sys.executable).resolve().parent
    BUNDLE_DIR = Path(getattr(sys, "_MEIPASS", APP_ROOT))
else:
    APP_ROOT = Path(__file__).resolve().parent
    BUNDLE_DIR = APP_ROOT

BASE_DIR = BUNDLE_DIR
DATA_DIR = APP_ROOT / "data"
DATA_DIR.mkdir(parents=True, exist_ok=True)

SESSION_FILE = DATA_DIR / "session.json"
HISTORY_FILE = DATA_DIR / "download_history.json"
SETTINGS_FILE = DATA_DIR / "settings.json"
SCAN_CACHE_FILE = DATA_DIR / "scan_cache.json"
NOTIFICATIONS_FILE = DATA_DIR / "notifications.json"
SHARED_INDEX_FILENAME = ".aula-scrapt-index.json"

# Versión y repositorio oficial para verificación y actualización automática
APP_VERSION = "1.3.0"
GITHUB_REPO = "OscarAcosta17/Aula-Scrapt"
GITHUB_RELEASES_URL = f"https://github.com/{GITHUB_REPO}/releases"
GITHUB_LATEST_API_URL = f"https://api.github.com/repos/{GITHUB_REPO}/releases/latest"
GITHUB_ALL_RELEASES_API_URL = f"https://api.github.com/repos/{GITHUB_REPO}/releases?per_page=10"

# URLs de Aula USM
AULA_BASE_URL = "https://aula.usm.cl"
AULA_LOGIN_URL = f"{AULA_BASE_URL}/login/index.php"
AULA_MY_URL = f"{AULA_BASE_URL}/my/"

# Carpeta por defecto para cualquier usuario nuevo si no ha configurado una ruta
DEFAULT_DOWNLOAD_DIR = Path.home() / "Documents" / "Aula-USM"


def _normalize_text(text: str) -> str:
    """Convierte a minúsculas y elimina tildes para comparar nombres de carpetas."""
    nfkd = unicodedata.normalize("NFKD", text.lower())
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def clean_course_display_name(fullname: str) -> str:
    """
    Limpia el año, semestre, código/sigla y paralelos del nombre del curso de Moodle,
    dejando únicamente el nombre limpio del ramo.
    Ejemplo: '(202602)(INF266) SISTEMAS DE GESTIÓN|Paralelos:200/201' -> 'Sistemas de Gestión'
    """
    s = fullname.strip()
    # 1. Remover prefijos de año/semestre entre paréntesis o corchetes: (202602), [2026-2], etc.
    s = re.sub(r"^\s*[\(\[]\s*\d{4,6}[A-Za-z0-9\-_]*\s*[\)\]]", "", s)
    # 2. Remover siglas/códigos entre paréntesis o corchetes: (INF266), (INF-266), etc.
    s = re.sub(
        r"^\s*[\(\[]\s*[A-Za-z]{2,5}\s*-?\s*\d{2,4}[A-Za-z0-9]*\s*[\)\]]", "", s
    )
    # 3. Remover sufijos de paralelos: |Paralelos:200/201, _Paralelos_200, - Paralelo 1, etc.
    s = re.sub(
        r"[\s\|\-_]+(?:Paralelos?|paralelos?|PARALELOS?)\s*[:_\-]?\s*[\d\/\-_A-Za-z]+.*$",
        "",
        s,
    )
    # Limpiar separadores y espacios sobrantes
    s = re.sub(r"\s+", " ", s).strip(" |-_")

    if not s:
        return fullname.strip()

    # Si todo el nombre está en mayúsculas, convertir a formato título respetando preposiciones en español
    if s.isupper():
        words = s.lower().split()
        lower_words = {
            "de",
            "del",
            "y",
            "e",
            "en",
            "el",
            "la",
            "los",
            "las",
            "un",
            "una",
            "por",
            "para",
            "al",
            "con",
        }
        res = [
            w.capitalize() if idx == 0 or w not in lower_words else w
            for idx, w in enumerate(words)
        ]
        s = " ".join(res)

    return s


def sanitize_folder_name(name: str) -> str:
    """Limpia caracteres inválidos para nombres de carpetas o archivos en Windows."""
    invalid_chars = '<>:"/\\|?*'
    clean = "".join(c if c not in invalid_chars else "_" for c in name)
    clean = re.sub(r"\s+", " ", clean).strip().rstrip(".")
    return clean or "Curso_Aula"


def get_default_settings() -> Dict:
    """Devuelve la estructura completa de configuración predeterminada."""
    return {
        "download_root": str(DEFAULT_DOWNLOAD_DIR),
        "course_folders": {},
        "course_subfolders": {},
        "course_org_sections": {},
        "hidden_courses": [],
        "auto_check_updates": True,
        "beta_updates_channel": False,
        # Reglas globales de guardado
        "default_subfolder": "Aula",
        "default_organize_by_section": True,
        "skip_already_downloaded": True,
        "skip_seen_on_select": False,
        "auto_export_links_to_obsidian": True,
        "auto_export_forums_to_obsidian": True,
        # Apariencia
        "theme_mode": "dark",
        "accent_color": "blue",
        # Preferencias de visualización y filtros
        "default_tab": "files",
        "hide_empty_sections": True,
        "preferred_extensions": [],
        "max_auto_select_mb": 0,
        # Notificaciones y segundo plano
        "notify_native_enabled": True,
        "notify_on_new_files": True,
        "notify_on_download_done": True,
        "notify_on_deadlines": True,
        "background_sync_hours": 0,
        "minimize_to_tray": False,
    }


def _apply_settings_defaults(data: Dict) -> Dict:
    defaults = get_default_settings()
    for key, default_val in defaults.items():
        if key not in data or data[key] is None:
            data[key] = default_val
    if not str(data.get("download_root", "")).strip():
        data["download_root"] = str(DEFAULT_DOWNLOAD_DIR)
    return data


def load_settings() -> Dict:
    """Carga la configuración local del usuario con valores por defecto actualizados."""
    if SETTINGS_FILE.exists():
        try:
            with open(SETTINGS_FILE, "r", encoding="utf-8") as f:
                data = json.load(f)
                if isinstance(data, dict):
                    return _apply_settings_defaults(data)
        except Exception:
            pass

    default_data = get_default_settings()
    save_settings(default_data)
    return default_data


def save_settings(settings: Dict) -> Dict:
    """Guarda la configuración local del usuario."""
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with open(SETTINGS_FILE, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2, ensure_ascii=False)
    return settings


def get_download_root() -> Path:
    """Obtiene la ruta raíz actual donde se guardan los archivos descargados."""
    settings = load_settings()
    return Path(settings.get("download_root", str(DEFAULT_DOWNLOAD_DIR)))


def list_existing_subfolders() -> List[str]:
    """Lista las subcarpetas existentes dentro de la carpeta raíz seleccionada."""
    root = get_download_root()
    if not root.exists() or not root.is_dir():
        return []
    return sorted([p.name for p in root.iterdir() if p.is_dir() and not p.name.startswith(".")])


def resolve_course_folder(course_id: int, course_name: str) -> str:
    """
    Determina la carpeta de destino para un curso:
    1. Si el usuario configuró manualmente una carpeta para este course_id, usa esa.
    2. Si en el directorio destino ya existe una carpeta cuyo nombre coincide con el ramo limpio, la asocia automáticamente.
    3. De lo contrario, usa el nombre limpio del curso (sin año, sigla ni paralelos).
    """
    settings = load_settings()
    custom_map = settings.get("course_folders", {})
    str_id = str(course_id)
    if str_id in custom_map and custom_map[str_id].strip():
        return custom_map[str_id].strip()

    clean_name = clean_course_display_name(course_name)
    existing_dirs = list_existing_subfolders()
    norm_course = _normalize_text(clean_name)

    for folder in existing_dirs:
        norm_folder = _normalize_text(folder)
        if not norm_folder:
            continue
        # Coincidencia directa o por palabras significativas (> 3 letras)
        if norm_folder in norm_course or norm_course in norm_folder:
            return folder
        words = [w for w in re.split(r"[^a-z0-9]+", norm_folder) if len(w) > 3]
        if words and all(w in norm_course for w in words):
            return folder

    return sanitize_folder_name(clean_name)


def resolve_course_preferences(course_id: int, course_name: str) -> Dict:
    """Devuelve carpeta, subcarpeta, organización por sección y visibilidad para un curso."""
    settings = load_settings()
    str_id = str(course_id)
    course_subfolders = settings.get("course_subfolders", {})
    course_org = settings.get("course_org_sections", {})
    hidden = {int(c) for c in settings.get("hidden_courses", []) if str(c).isdigit()}

    target_sub = (
        course_subfolders[str_id]
        if str_id in course_subfolders
        else settings.get("default_subfolder", "Aula")
    )
    organize = (
        bool(course_org[str_id])
        if str_id in course_org
        else bool(settings.get("default_organize_by_section", True))
    )
    return {
        "obsidian_folder": resolve_course_folder(course_id, course_name),
        "target_subfolder": str(target_sub),
        "organize_by_section": organize,
        "is_hidden": int(course_id) in hidden,
    }

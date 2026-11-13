import concurrent.futures
import json
import os
import re
import unicodedata
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import unquote, urljoin, urlparse
import requests
from bs4 import BeautifulSoup

from config import (
    AULA_BASE_URL,
    HISTORY_FILE,
    SCAN_CACHE_FILE,
    SHARED_INDEX_FILENAME,
    get_download_root,
    load_settings,
)
from scraper.auth import (
    USER_AGENT,
    get_requests_session,
    load_saved_session,
)


def _sanitize_filename(name: str) -> str:
    """Limpia caracteres inválidos para nombres de archivos o carpetas en Windows."""
    invalid = '<>:"/\\|?*'
    cleaned = "".join(c if c not in invalid else "_" for c in name)
    cleaned = re.sub(r"\s+", " ", cleaned).strip().rstrip(".")
    return cleaned or "Archivo_Aula"


def _slugify_tag(text: str) -> str:
    """Convierte un texto en un tag válido para Obsidian/YAML."""
    slug = re.sub(r"[^a-zA-Z0-9áéíóúñÁÉÍÓÚÑ]+", "-", text.lower()).strip("-")
    return slug or "curso"


def normalize_match_key(text: str, strip_ext: bool = False) -> str:
    """Normaliza títulos y nombres de archivo (sin tildes, puntuación ni guiones) para matching inteligente."""
    if not text:
        return ""
    val = text.strip()
    if strip_ext:
        suffix = Path(val).suffix
        if 1 <= len(suffix) <= 6 and suffix[1:].isalnum():
            val = Path(val).stem
    nfkd = unicodedata.normalize("NFKD", val.lower())
    ascii_ish = "".join(c for c in nfkd if not unicodedata.combining(c))
    cleaned = re.sub(r"[_\-./\\()\[\],:;]+", " ", ascii_ish)
    return re.sub(r"\s+", " ", cleaned).strip()


def _match_tokens(norm_key: str) -> set:
    return {t for t in norm_key.split() if len(t) >= 2}


def format_file_size(size_bytes: int) -> str:
    """Convierte bytes a formato legible (KB, MB, GB)."""
    if not size_bytes or size_bytes <= 0:
        return ""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    if size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    if size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    return f"{size_bytes / (1024 * 1024 * 1024):.2f} GB"


def _infer_ext(item: Dict, local_path: Optional[str] = None) -> str:
    for candidate in (
        local_path or "",
        item.get("file_name", ""),
        item.get("title", ""),
    ):
        if candidate:
            ext = Path(str(candidate)).suffix.lstrip(".").lower()
            if 1 <= len(ext) <= 6 and ext.isalnum() and ext != "php":
                return ext
    url = str(item.get("url") or "")
    if url:
        tail = unquote(urlparse(url).path.split("/")[-1])
        ext = Path(tail).suffix.lstrip(".").lower()
        if 1 <= len(ext) <= 6 and ext.isalnum() and ext != "php":
            return ext
    return str(item.get("file_ext") or "").lower()


def load_history() -> Dict:
    """Carga el historial local de recursos vistos, descargados y tamaños en bytes."""
    if not HISTORY_FILE.exists():
        return {"downloaded_ids": {}, "seen_ids": {}, "file_sizes": {}}
    try:
        with open(HISTORY_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
            data.setdefault("downloaded_ids", {})
            data.setdefault("seen_ids", {})
            data.setdefault("file_sizes", {})
            return data
    except Exception:
        return {"downloaded_ids": {}, "seen_ids": {}, "file_sizes": {}}


def save_history(history: Dict) -> None:
    """Guarda el historial de descargas y elementos vistos."""
    HISTORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(HISTORY_FILE, "w", encoding="utf-8") as f:
        json.dump(history, f, indent=2, ensure_ascii=False)


def _shared_index_path(download_root: Path) -> Path:
    return download_root / SHARED_INDEX_FILENAME


def load_shared_index(download_root: Optional[Path] = None) -> Dict:
    """Carga el índice compartido de sincronización PC <-> Móvil dentro de la carpeta seleccionada."""
    root = download_root or get_download_root()
    idx_file = _shared_index_path(root)
    if not idx_file.exists():
        return {"version": 1, "items": {}}
    try:
        data = json.loads(idx_file.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            data.setdefault("version", 1)
            data.setdefault("items", {})
            return data
    except Exception:
        pass
    return {"version": 1, "items": {}}


def save_shared_index_entry(
    download_root: Path,
    item_id: str,
    entry: Dict,
) -> None:
    """Actualiza de forma segura una entrada en .aula-scrapt-index.json dentro de download_root."""
    if not download_root.exists():
        return
    data = load_shared_index(download_root)
    data["updated_at"] = datetime.now().isoformat(timespec="seconds")
    data.setdefault("items", {})[item_id] = entry
    try:
        _shared_index_path(download_root).write_text(
            json.dumps(data, indent=2, ensure_ascii=False),
            encoding="utf-8",
        )
    except OSError:
        pass


def _is_inside_dir(candidate: Path, parent: Path) -> bool:
    try:
        candidate.resolve().relative_to(parent.resolve())
        return True
    except Exception:
        return False


def _scan_course_local_entries(
    download_root: Path, obsidian_folder_name: str
) -> List[Dict]:
    """
    Escanea únicamente la carpeta del curso dentro del download_root seleccionado
    y devuelve metadatos normalizados para matching inteligente.
    """
    sanitized = _sanitize_filename(obsidian_folder_name)
    candidates = [download_root / obsidian_folder_name]
    if sanitized != obsidian_folder_name:
        candidates.append(download_root / sanitized)

    seen_dirs = set()
    entries: List[Dict] = []

    for course_dir in candidates:
        if not course_dir.exists() or not course_dir.is_dir():
            continue
        res_dir = str(course_dir.resolve())
        if res_dir in seen_dirs:
            continue
        seen_dirs.add(res_dir)

        for root, _, files in os.walk(course_dir):
            root_path = Path(root)
            for file in files:
                if (
                    file.startswith("00 - Indice")
                    or file.startswith("00 - Seccion")
                    or file.startswith(".")
                ):
                    continue
                fp = root_path / file
                try:
                    sz = fp.stat().st_size
                except OSError:
                    sz = 0
                norm_stem = normalize_match_key(file, strip_ext=True)
                norm_full = normalize_match_key(file, strip_ext=False)
                entries.append(
                    {
                        "path": str(fp),
                        "rel_path": fp.relative_to(download_root).as_posix(),
                        "name_low": file.lower(),
                        "stem_low": fp.stem.lower(),
                        "norm_name": norm_full,
                        "norm_stem": norm_stem,
                        "compact_stem": norm_stem.replace(" ", ""),
                        "tokens": _match_tokens(norm_stem),
                        "size": sz,
                    }
                )
    return entries


def get_existing_obsidian_files(obsidian_folder_name: str) -> List[str]:
    """Compatibilidad: devuelve nombres de archivos ya presentes en la carpeta del curso."""
    download_root = get_download_root()
    out: List[str] = []
    for e in _scan_course_local_entries(download_root, obsidian_folder_name):
        out.append(e["name_low"])
        out.append(e["stem_low"])
    return out


def _match_item_against_local_entries(item: Dict, entries: List[Dict]) -> Optional[Dict]:
    """Busca un archivo físico existente que corresponda a un ítem de Aula."""
    if not entries:
        return None

    title = str(item.get("title") or "").strip()
    file_name = str(item.get("file_name") or "").strip()

    raw_candidates = [c for c in (file_name, title) if c]
    low_keys = set()
    norm_keys = set()
    compact_keys = set()
    token_sets = []

    for cand in raw_candidates:
        clean = _sanitize_filename(cand).lower()
        stem = Path(clean).stem.lower()
        if clean:
            low_keys.add(clean)
        if stem:
            low_keys.add(stem)
        nk = normalize_match_key(cand, strip_ext=True)
        if nk:
            norm_keys.add(nk)
            compact_keys.add(nk.replace(" ", ""))
            toks = _match_tokens(nk)
            if len(toks) >= 2:
                token_sets.append(toks)

    # 1. Coincidencia exacta por nombre / stem o clave normalizada sin tildes/guiones
    for entry in entries:
        if entry["name_low"] in low_keys or entry["stem_low"] in low_keys:
            return entry
        if entry["norm_stem"] in norm_keys or entry["norm_name"] in norm_keys:
            return entry

    # 2. Coincidencia compacta (ignora separadores: 'Guia1Intro' vs 'Guía 1 - Intro')
    for ck in compact_keys:
        if len(ck) >= 6:
            for entry in entries:
                if entry["compact_stem"] == ck:
                    return entry

    # 3. Coincidencia única por subconjunto de palabras significativas (>= 2 palabras)
    for toks in token_sets:
        matches = [
            e
            for e in entries
            if toks.issubset(e["tokens"]) or (len(e["tokens"]) >= 2 and e["tokens"].issubset(toks))
        ]
        if len(matches) == 1:
            return matches[0]

    return None


def enrich_items_with_status(
    items: List[Dict],
    obsidian_folder_name: str,
    allow_network_head: bool = True,
) -> List[Dict]:
    """
    Compara los ítems extraídos de Aula USM contra:
    1) Historial local dentro de la carpeta seleccionada (download_root)
    2) Índice compartido .aula-scrapt-index.json (sincronizado entre PC y Android)
    3) Archivos físicos dentro de <download_root>/<ramo> mediante matching inteligente
    """
    download_root = get_download_root()
    history = load_history()
    downloaded_ids = history.get("downloaded_ids", {})
    seen_ids = history.get("seen_ids", {})
    file_sizes = history.setdefault("file_sizes", {})

    shared_index = load_shared_index(download_root)
    shared_items = shared_index.get("items", {})
    local_entries = _scan_course_local_entries(download_root, obsidian_folder_name)

    enriched = []
    need_size_fetch = []

    for item in items:
        item_id = item["id"]
        is_downloaded = False
        local_path: Optional[str] = None
        size_bytes = int(item.get("size_bytes") or 0)

        # 1. Revisar historial local validando que pertenezca a la carpeta seleccionada actual
        if item_id in downloaded_ids:
            saved_info = downloaded_ids[item_id] or {}
            saved_path_str = str(saved_info.get("path") or "").strip()
            saved_rel = str(saved_info.get("relative_path") or "").strip()
            candidate_file: Optional[Path] = None

            if saved_path_str:
                p = Path(saved_path_str)
                if p.exists() and p.is_file() and _is_inside_dir(p, download_root):
                    candidate_file = p
            if candidate_file is None and saved_rel:
                rel_p = download_root / saved_rel
                if rel_p.exists() and rel_p.is_file():
                    candidate_file = rel_p

            if candidate_file is not None:
                is_downloaded = True
                local_path = str(candidate_file)
                try:
                    size_bytes = candidate_file.stat().st_size
                    file_sizes[item_id] = size_bytes
                except OSError:
                    pass

        # 2. Revisar índice compartido de la carpeta seleccionada (.aula-scrapt-index.json)
        if not is_downloaded and item_id in shared_items:
            rel = str(shared_items[item_id].get("relative_path") or "").strip()
            if rel:
                rel_file = download_root / rel
                if rel_file.exists() and rel_file.is_file():
                    is_downloaded = True
                    local_path = str(rel_file)
                    try:
                        size_bytes = rel_file.stat().st_size
                        file_sizes[item_id] = size_bytes
                    except OSError:
                        pass

        # 3. Matching inteligente directo en la carpeta del ramo seleccionada
        if not is_downloaded:
            matched_entry = _match_item_against_local_entries(item, local_entries)
            if matched_entry is not None:
                is_downloaded = True
                local_path = matched_entry["path"]
                if matched_entry["size"] > 0:
                    size_bytes = matched_entry["size"]
                    file_sizes[item_id] = size_bytes

        if not size_bytes and item_id in file_sizes:
            size_bytes = int(file_sizes[item_id] or 0)

        is_new = (not is_downloaded) and (item_id not in seen_ids)

        enriched_item = dict(item)
        enriched_item["is_downloaded"] = is_downloaded
        enriched_item["is_new"] = is_new
        enriched_item["local_path"] = local_path
        enriched_item["obsidian_folder"] = obsidian_folder_name
        enriched_item["size_bytes"] = size_bytes
        enriched_item["size_human"] = format_file_size(size_bytes)
        enriched_item["file_ext"] = _infer_ext(enriched_item, local_path=local_path)
        enriched.append(enriched_item)

        if (
            allow_network_head
            and item.get("downloadable")
            and not size_bytes
            and item.get("url")
        ):
            need_size_fetch.append(enriched_item)

    if need_size_fetch:
        req_session = get_requests_session()
        if req_session:
            def _fetch_head_size(it):
                try:
                    r = req_session.head(it["url"], allow_redirects=True, timeout=3.5)
                    cl = r.headers.get("Content-Length")
                    if cl and cl.isdigit():
                        return it["id"], int(cl)
                except Exception:
                    pass
                return it["id"], 0

            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
                results = list(ex.map(_fetch_head_size, need_size_fetch))

            has_new_sizes = False
            size_map = dict(results)
            for it in need_size_fetch:
                sz = size_map.get(it["id"], 0)
                if sz > 0:
                    it["size_bytes"] = sz
                    it["size_human"] = format_file_size(sz)
                    file_sizes[it["id"]] = sz
                    has_new_sizes = True

            if has_new_sizes:
                save_history(history)

    return enriched


def mark_items_as_seen(items: List[Dict]) -> None:
    """Marca una lista de elementos como vistos en el historial."""
    history = load_history()
    now_str = datetime.now().isoformat(timespec="seconds")
    for item in items:
        item_id = item.get("id")
        if item_id and item_id not in history["seen_ids"]:
            history["seen_ids"][item_id] = {
                "title": item.get("title", ""),
                "first_seen": now_str,
            }
    save_history(history)


def _fix_encoding(text: str) -> str:
    """Corrige problemas de decodificación latin1 vs utf-8 comunes en cabeceras HTTP."""
    if not text:
        return ""
    try:
        return text.encode("latin1").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return text


def _extract_filename_from_response(resp, fallback_title: str) -> str:
    """Obtiene el nombre real del archivo desde Content-Disposition o desde la URL final."""
    cd = resp.headers.get("Content-Disposition", "")
    if cd:
        match_utf8 = re.search(r"filename\*=UTF-8''([^;\r\n]+)", cd, re.IGNORECASE)
        if match_utf8:
            return _sanitize_filename(unquote(match_utf8.group(1)))
        match_std = re.search(r'filename="?([^";\r\n]+)"?', cd, re.IGNORECASE)
        if match_std:
            raw_fn = unquote(match_std.group(1))
            return _sanitize_filename(_fix_encoding(raw_fn))

    parsed_url = urlparse(resp.url)
    url_filename = unquote(Path(parsed_url.path).name)
    if url_filename and "." in url_filename and not url_filename.endswith(".php"):
        return _sanitize_filename(_fix_encoding(url_filename))

    clean_fallback = _sanitize_filename(_fix_encoding(fallback_title))
    content_type = resp.headers.get("Content-Type", "").lower()
    if "." not in clean_fallback:
        if "pdf" in content_type:
            clean_fallback += ".pdf"
        elif "presentation" in content_type or "powerpoint" in content_type:
            clean_fallback += ".pptx"
        elif "word" in content_type:
            clean_fallback += ".docx"
        elif "zip" in content_type:
            clean_fallback += ".zip"
        elif "sheet" in content_type or "excel" in content_type:
            clean_fallback += ".xlsx"
    return clean_fallback


def _load_cached_course_extras(obsidian_folder_name: str) -> Tuple[List[Dict], List[Dict]]:
    """Recupera links y foros guardados en scan_cache.json para enriquecer el grafo Obsidian."""
    if not SCAN_CACHE_FILE.exists():
        return [], []
    try:
        cache = json.loads(SCAN_CACHE_FILE.read_text(encoding="utf-8"))
        for entry in cache.get("courses", []):
            course = entry.get("course", {})
            if course.get("obsidian_folder") == obsidian_folder_name:
                items = entry.get("items", [])
                links = [i for i in items if i.get("type") in {"url", "link"}]
                forums = [i for i in items if i.get("type") == "forum"]
                return links, forums
    except Exception:
        pass
    return [], []


def _rebuild_course_graph_markdown(
    course_dir: Path,
    obsidian_folder_name: str,
    target_subfolder: str,
    course_items: Optional[List[Dict]] = None,
) -> Path:
    """
    Genera o sobrescribe los archivos Markdown (.md) de índice y conexión de grafo
    para Obsidian y búsqueda eficiente por IA, incluyendo enlaces y foros si está habilitado.
    """
    settings = load_settings()
    history = load_history()
    downloaded_ids = history.get("downloaded_ids", {})

    meta_by_path: Dict[str, Dict] = {}
    for _, info in downloaded_ids.items():
        p = info.get("path", "")
        if p:
            try:
                norm_p = str(Path(p).resolve())
                meta_by_path[norm_p] = info
            except Exception:
                pass

    base_scan_dir = (
        course_dir / _sanitize_filename(target_subfolder.strip())
        if target_subfolder and target_subfolder.strip()
        else course_dir
    )
    if not base_scan_dir.exists():
        base_scan_dir.mkdir(parents=True, exist_ok=True)

    course_index_name = f"00 - Indice Aula - {_sanitize_filename(obsidian_folder_name)}"
    course_index_file = base_scan_dir / f"{course_index_name}.md"
    course_tag = _slugify_tag(obsidian_folder_name)
    now_iso = datetime.now().strftime("%Y-%m-%d %H:%M")

    sections_dict: Dict[str, List[Path]] = {}
    for root, _, files in os.walk(base_scan_dir):
        root_path = Path(root)
        for f in sorted(files):
            if f.endswith(".md") and (
                f.startswith("00 - Indice Aula") or f.startswith("00 - Seccion -")
            ):
                continue
            if f.startswith("."):
                continue
            full_p = root_path / f
            rel_dir = root_path.relative_to(base_scan_dir).as_posix()
            sec_label = "General" if rel_dir == "." else rel_dir
            sections_dict.setdefault(sec_label, []).append(full_p)

    total_files = sum(len(flist) for flist in sections_dict.values())
    section_node_links = []

    for sec_label, file_paths in sorted(sections_dict.items()):
        if sec_label != "General":
            sec_dir = base_scan_dir / sec_label
            sec_clean_title = _sanitize_filename(Path(sec_label).name)
            sec_md_name = f"00 - Seccion - {sec_clean_title}"
            sec_md_path = sec_dir / f"{sec_md_name}.md"
            rel_sec_md = sec_md_path.relative_to(base_scan_dir).with_suffix("").as_posix()
            section_node_links.append((sec_label, rel_sec_md, sec_md_name))

            sec_lines = [
                "---",
                "type: aula-section-index",
                f'course: "{obsidian_folder_name}"',
                f'section: "{sec_label}"',
                f'updated_at: "{now_iso}"',
                f"file_count: {len(file_paths)}",
                f"tags: [aula-usm, seccion-aula, {course_tag}]",
                "---",
                "",
                f"# Seccion: {sec_label}",
                "",
                f"Indice superior: [[{course_index_name}]]",
                "",
                "## Archivos en esta seccion",
                "",
            ]
            for fp in file_paths:
                norm_fp = str(fp.resolve())
                meta = meta_by_path.get(norm_fp, {})
                aula_title = meta.get("title", fp.stem)
                downloaded_at = meta.get("downloaded_at", "")[:10]
                rel_from_course = fp.relative_to(base_scan_dir).as_posix()
                sec_lines.append(
                    f"- [[{rel_from_course}|{fp.name}]] — *{aula_title}*"
                    + (f" ({downloaded_at})" if downloaded_at else "")
                )

            sec_md_path.write_text("\n".join(sec_lines) + "\n", encoding="utf-8")

    lines = [
        "---",
        "type: aula-course-index",
        f'course: "{obsidian_folder_name}"',
        f'updated_at: "{now_iso}"',
        f"total_files: {total_files}",
        f"total_sections: {len(sections_dict)}",
        f"tags: [aula-usm, indice-ia, {course_tag}]",
        "---",
        "",
        f"# Indice de Material Aula USM — {obsidian_folder_name}",
        "",
        "> Nodo central de navegacion y contexto para busqueda por grafo e IA. Este archivo se actualiza y sobrescribe automaticamente al descargar material.",
        "",
    ]

    if section_node_links:
        lines.append("## Nodos de Secciones")
        lines.append("")
        for sec_label, rel_sec_md, _ in section_node_links:
            lines.append(f"- [[{rel_sec_md}|{sec_label}]]")
        lines.append("")

    if sections_dict:
        lines.append("## Mapa de Archivos por Seccion")
        lines.append("")
        for sec_label, file_paths in sorted(sections_dict.items()):
            lines.append(f"### {sec_label}")
            lines.append("")
            lines.append("| Recurso en Aula | Archivo Vinculado (Grafo) | Tamaño | Ruta Relativa | Fecha |")
            lines.append("| :--- | :--- | :--- | :--- | :--- |")
            for fp in file_paths:
                norm_fp = str(fp.resolve())
                meta = meta_by_path.get(norm_fp, {})
                aula_title = meta.get("title", fp.stem).replace("|", "-")
                downloaded_at = meta.get("downloaded_at", now_iso)[:10]
                sz_bytes = os.path.getsize(fp) if fp.exists() else 0
                sz_human = format_file_size(sz_bytes) or "-"
                rel_from_base = fp.relative_to(base_scan_dir).as_posix()
                lines.append(
                    f"| {aula_title} | [[{rel_from_base}\\|{fp.name}]] | {sz_human} | `{rel_from_base}` | {downloaded_at} |"
                )
            lines.append("")

    # Enlaces y Anuncios desde Aula (Opción B)
    if course_items is not None:
        links = [i for i in course_items if i.get("type") in {"url", "link"}]
        forums = [i for i in course_items if i.get("type") == "forum"]
    else:
        links, forums = _load_cached_course_extras(obsidian_folder_name)

    if settings.get("auto_export_links_to_obsidian", True) and links:
        lines.append("## Enlaces y Clases (URL)")
        lines.append("")
        for lk in links:
            sec_txt = lk.get("section", "General")
            lines.append(f"- [{lk.get('title', 'Enlace')}]({lk.get('url', '')}) — *{sec_txt}*")
        lines.append("")

    if settings.get("auto_export_forums_to_obsidian", True) and forums:
        lines.append("## Foros y Anuncios")
        lines.append("")
        for fm in forums:
            sec_txt = fm.get("section", "General")
            lines.append(f"- [{fm.get('title', 'Foro')}]({fm.get('url', '')}) — *{sec_txt}*")
        lines.append("")

    course_index_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return course_index_file


def export_course_resources_markdown(
    obsidian_folder_name: str,
    target_subfolder: str,
    course_items: List[Dict],
) -> Optional[Path]:
    """Actualiza el índice Markdown de un ramo si su carpeta ya existe en disco o tiene contenido."""
    download_root = get_download_root()
    course_dir = download_root / _sanitize_filename(obsidian_folder_name)
    if not course_dir.exists():
        return None
    return _rebuild_course_graph_markdown(
        course_dir=course_dir,
        obsidian_folder_name=obsidian_folder_name,
        target_subfolder=target_subfolder,
        course_items=course_items,
    )


def download_item_to_obsidian(
    item: Dict,
    obsidian_folder_name: str,
    target_subfolder: str = "Aula",
    organize_by_section: bool = True,
) -> Dict:
    """
    Descarga un archivo desde Aula USM (por Cookie o wstoken) hacia la carpeta seleccionada.
    Actualiza el historial local, el índice compartido PC <-> Android y el grafo Obsidian.
    """
    saved_session = load_saved_session() or {}
    token = (saved_session.get("token") or "").strip()
    req_session = get_requests_session()

    if not req_session and not token:
        raise PermissionError("No hay sesión activa en Aula USM.")

    url = item["url"]
    if token and not req_session:
        sep = "&" if "?" in url else "?"
        if "token=" not in url:
            url = f"{url}{sep}token={token}"
        resp = requests.get(url, stream=True, allow_redirects=True, headers={"User-Agent": USER_AGENT}, timeout=30)
    else:
        if "pluginfile.php" in url and "forcedownload=" not in url:
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}forcedownload=1"
        elif "/mod/resource/view.php" in url and "redirect=" not in url:
            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}redirect=1"

        resp = req_session.get(url, stream=True, allow_redirects=True, timeout=30)

        content_type = resp.headers.get("Content-Type", "").lower()
        if "text/html" in content_type:
            html_text = resp.text
            if "/login/" in resp.url or "/portada/" in resp.url:
                raise PermissionError("La sesión de Aula USM expiró.")
            soup = BeautifulSoup(html_text, "lxml")
            direct_el = soup.select_one(
                "a[href*='pluginfile.php'], object[data*='pluginfile.php'], iframe[src*='pluginfile.php'], embed[src*='pluginfile.php']"
            )
            if direct_el:
                direct_url = (
                    direct_el.get("href") or direct_el.get("data") or direct_el.get("src")
                )
                direct_url = urljoin(AULA_BASE_URL, direct_url)
                resp = req_session.get(
                    direct_url, stream=True, allow_redirects=True, timeout=30
                )
            else:
                raise ValueError(
                    f"No se encontró un archivo descargable directo en '{item['title']}'."
                )

    filename = _extract_filename_from_response(resp, item["title"])
    download_root = get_download_root()

    course_dir = download_root / _sanitize_filename(obsidian_folder_name)
    dest_dir = course_dir
    if target_subfolder and target_subfolder.strip():
        dest_dir = dest_dir / _sanitize_filename(target_subfolder.strip())
    if organize_by_section and item.get("section"):
        sec_clean = _sanitize_filename(item["section"])
        dest_dir = dest_dir / sec_clean

    dest_dir.mkdir(parents=True, exist_ok=True)
    dest_file = dest_dir / filename

    with open(dest_file, "wb") as f:
        for chunk in resp.iter_content(chunk_size=16384):
            if chunk:
                f.write(chunk)

    history = load_history()
    now_str = datetime.now().isoformat(timespec="seconds")
    file_size_bytes = os.path.getsize(dest_file) if dest_file.exists() else 0
    rel_path = dest_file.relative_to(download_root).as_posix()

    history.setdefault("file_sizes", {})[item["id"]] = file_size_bytes
    history_entry = {
        "title": item["title"],
        "section": item.get("section", "General"),
        "filename": filename,
        "course_folder": obsidian_folder_name,
        "path": str(dest_file),
        "relative_path": rel_path,
        "size_bytes": file_size_bytes,
        "downloaded_at": now_str,
        "device": "windows",
    }
    history["downloaded_ids"][item["id"]] = history_entry
    history["seen_ids"][item["id"]] = {
        "title": item["title"],
        "first_seen": now_str,
    }
    save_history(history)

    save_shared_index_entry(
        download_root,
        item["id"],
        {
            "title": item["title"],
            "filename": filename,
            "course_folder": obsidian_folder_name,
            "relative_path": rel_path,
            "size_bytes": file_size_bytes,
            "downloaded_at": now_str,
            "device": "windows",
        },
    )

    index_md = _rebuild_course_graph_markdown(
        course_dir=course_dir,
        obsidian_folder_name=obsidian_folder_name,
        target_subfolder=target_subfolder,
    )

    return {
        "success": True,
        "item_id": item["id"],
        "filename": filename,
        "saved_path": str(dest_file),
        "index_md": str(index_md),
        "relative_obsidian_path": rel_path,
    }

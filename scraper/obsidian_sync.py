import concurrent.futures
import json
import os
import re
from datetime import datetime
from pathlib import Path
from typing import Dict, List
from urllib.parse import unquote, urljoin, urlparse
from bs4 import BeautifulSoup

from config import AULA_BASE_URL, HISTORY_FILE, get_download_root
from scraper.auth import get_requests_session


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


def format_file_size(size_bytes: int) -> str:
    """Convierte bytes a formato legible (KB, MB, GB)."""
    if not size_bytes or size_bytes <= 0:
        return ""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    else:
        return f"{size_bytes / (1024 * 1024 * 1024):.2f} GB"


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


def get_existing_obsidian_files(obsidian_folder_name: str) -> List[str]:
    """Devuelve una lista con los nombres de archivos (en minúsculas) ya presentes en la carpeta del curso."""
    download_root = get_download_root()
    course_dir = download_root / obsidian_folder_name
    if not course_dir.exists():
        return []
    existing = []
    for root, _, files in os.walk(course_dir):
        for file in files:
            if file.startswith("00 - Indice") or file.startswith("00 - Seccion"):
                continue
            existing.append(file.lower())
            existing.append(Path(file).stem.lower())
    return existing


def enrich_items_with_status(items: List[Dict], obsidian_folder_name: str) -> List[Dict]:
    """
    Compara los ítems extraídos de Aula USM contra el historial local y la carpeta
    de destino para marcar cuáles están descargados, cuáles no, y calcula sus tamaños.
    """
    history = load_history()
    downloaded_ids = history.get("downloaded_ids", {})
    seen_ids = history.get("seen_ids", {})
    file_sizes = history.setdefault("file_sizes", {})
    existing_files = set(get_existing_obsidian_files(obsidian_folder_name))

    enriched = []
    need_size_fetch = []

    for item in items:
        item_id = item["id"]
        title_clean = _sanitize_filename(item["title"]).lower()
        title_stem = Path(title_clean).stem.lower()

        is_downloaded = False
        local_path = None
        size_bytes = 0

        if item_id in downloaded_ids:
            saved_path = downloaded_ids[item_id].get("path", "")
            if saved_path and Path(saved_path).exists():
                is_downloaded = True
                local_path = saved_path
                try:
                    size_bytes = os.path.getsize(saved_path)
                    file_sizes[item_id] = size_bytes
                except Exception:
                    pass
        elif title_clean in existing_files or title_stem in existing_files:
            is_downloaded = True

        if not size_bytes and item_id in file_sizes:
            size_bytes = file_sizes[item_id]

        is_new = (not is_downloaded) and (item_id not in seen_ids)

        enriched_item = dict(item)
        enriched_item["is_downloaded"] = is_downloaded
        enriched_item["is_new"] = is_new
        enriched_item["local_path"] = local_path
        enriched_item["obsidian_folder"] = obsidian_folder_name
        enriched_item["size_bytes"] = size_bytes
        enriched_item["size_human"] = format_file_size(size_bytes)
        enriched.append(enriched_item)

        if item.get("downloadable") and not size_bytes and item.get("url"):
            need_size_fetch.append(enriched_item)

    # Si hay archivos descargables con tamaño desconocido, obtener Content-Length por HEAD concurrente
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


def _rebuild_course_graph_markdown(
    course_dir: Path,
    obsidian_folder_name: str,
    target_subfolder: str,
) -> Path:
    """
    Genera o sobrescribe los archivos Markdown (.md) de índice y conexión de grafo
    para Obsidian y búsqueda eficiente por IA:
    1. En cada subcarpeta de sección: '00 - Seccion - <Nombre>.md' conectado al índice del ramo y a sus archivos.
    2. En la raíz de la carpeta de descarga del ramo: '00 - Indice Aula - <Ramo>.md' conectado a todas las secciones y archivos.
    """
    history = load_history()
    downloaded_ids = history.get("downloaded_ids", {})

    # Mapear metadata conocida por ruta de archivo
    meta_by_path: Dict[str, Dict] = {}
    for item_id, info in downloaded_ids.items():
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
        base_scan_dir = course_dir

    course_index_name = f"00 - Indice Aula - {_sanitize_filename(obsidian_folder_name)}"
    course_index_file = base_scan_dir / f"{course_index_name}.md"
    course_tag = _slugify_tag(obsidian_folder_name)
    now_iso = datetime.now().strftime("%Y-%m-%d %H:%M")

    # Recolectar todos los archivos agrupados por su carpeta/sección relativa a base_scan_dir
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

    # 1. Crear o sobrescribir el .md de cada sección/carpeta para formar sub-nodos del grafo
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

    # 2. Crear o sobrescribir el .md maestro del ramo (nodo central para el grafo y para IA)
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
        for sec_label, rel_sec_md, sec_md_name in section_node_links:
            lines.append(f"- [[{rel_sec_md}|{sec_label}]]")
        lines.append("")

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

    course_index_file.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return course_index_file


def download_item_to_obsidian(
    item: Dict,
    obsidian_folder_name: str,
    target_subfolder: str = "Aula",
    organize_by_section: bool = True,
) -> Dict:
    """
    Descarga un archivo desde Aula USM hacia la carpeta seleccionada por el usuario.
    Si el archivo ya existe, lo sobrescribe y actualiza el grafo Markdown (.md) del curso.
    """
    req_session = get_requests_session()
    if not req_session:
        raise PermissionError("No hay sesión activa en Aula USM.")

    url = item["url"]
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

    # Escribir o sobrescribir el archivo descargado
    with open(dest_file, "wb") as f:
        for chunk in resp.iter_content(chunk_size=16384):
            if chunk:
                f.write(chunk)

    history = load_history()
    now_str = datetime.now().isoformat(timespec="seconds")
    file_size_bytes = os.path.getsize(dest_file) if dest_file.exists() else 0
    history.setdefault("file_sizes", {})[item["id"]] = file_size_bytes
    history["downloaded_ids"][item["id"]] = {
        "title": item["title"],
        "section": item.get("section", "General"),
        "filename": filename,
        "course_folder": obsidian_folder_name,
        "path": str(dest_file),
        "size_bytes": file_size_bytes,
        "downloaded_at": now_str,
    }
    history["seen_ids"][item["id"]] = {
        "title": item["title"],
        "first_seen": now_str,
    }
    save_history(history)

    # Regenerar/sobrescribir los índices .md conectados para el grafo de Obsidian e IA
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
        "relative_obsidian_path": str(dest_file.relative_to(download_root)),
    }

import concurrent.futures
import re
from typing import Dict, List
from urllib.parse import unquote, urljoin, urlparse
from bs4 import BeautifulSoup

from config import AULA_BASE_URL, clean_course_display_name, resolve_course_folder
from scraper.auth import (
    get_requests_session,
    is_authenticated_moodle_html,
    verify_session,
)


def _clean_moodle_title(raw_title: str) -> str:
    """Limpia sufijos de accesibilidad que Moodle agrega a los títulos."""
    text = re.sub(r"\s+", " ", raw_title).strip()
    suffixes = [
        " Archivo",
        " Documento PDF",
        " Carpeta",
        " Tarea",
        " Foro",
        " URL",
        " Página",
        " File",
        " Folder",
        " Assignment",
    ]
    for s in suffixes:
        if text.endswith(s):
            text = text[: -len(s)].strip()
    return text


def get_enrolled_courses() -> List[Dict]:
    """
    Obtiene todos los cursos inscritos del usuario en Aula USM combinando
    el endpoint AJAX interno de Moodle y el análisis del DOM de /my/courses.php.
    """
    status = verify_session()
    if not status.get("authenticated"):
        raise PermissionError(status.get("reason", "Sesión no iniciada en Aula USM."))

    req_session = get_requests_session()
    sesskey = status.get("sesskey", "")
    courses_by_id: Dict[int, Dict] = {}

    # 1. Consulta vía AJAX interno de Moodle (classifications: inprogress y all)
    if sesskey:
        ajax_url = (
            f"{AULA_BASE_URL}/lib/ajax/service.php"
            f"?sesskey={sesskey}&info=core_course_get_enrolled_courses_by_timeline_classification"
        )
        for classification in ["inprogress", "all"]:
            payload = [
                {
                    "index": 0,
                    "methodname": "core_course_get_enrolled_courses_by_timeline_classification",
                    "args": {
                        "offset": 0,
                        "limit": 0,
                        "classification": classification,
                        "sort": "fullname",
                        "customfieldname": "",
                        "customfieldvalue": "",
                    },
                }
            ]
            try:
                resp = req_session.post(ajax_url, json=payload, timeout=12)
                if resp.status_code == 200:
                    data = resp.json()
                    if isinstance(data, list) and data and not data[0].get("error"):
                        raw_courses = data[0].get("data", {}).get("courses", [])
                        for c in raw_courses:
                            cid = int(c["id"])
                            if cid == 1:
                                continue
                            fullname = c.get("fullname", f"Curso {cid}").strip()
                            clean_name = clean_course_display_name(fullname)
                            if cid not in courses_by_id:
                                courses_by_id[cid] = {
                                    "id": cid,
                                    "fullname": fullname,
                                    "clean_name": clean_name,
                                    "shortname": c.get("shortname", ""),
                                    "url": c.get(
                                        "viewurl", f"{AULA_BASE_URL}/course/view.php?id={cid}"
                                    ),
                                    "obsidian_folder": resolve_course_folder(cid, fullname),
                                }
            except Exception:
                pass

    # 2. Complemento por HTML en /my/courses.php y /my/
    for page_path in ["/my/courses.php", "/my/"]:
        try:
            resp = req_session.get(f"{AULA_BASE_URL}{page_path}", timeout=12)
            if not is_authenticated_moodle_html(resp.url, resp.text):
                continue
            soup = BeautifulSoup(resp.text, "lxml")
            for a in soup.select('a[href*="/course/view.php?id="]'):
                href = a.get("href", "")
                match = re.search(r"[?&]id=(\d+)", href)
                if not match:
                    continue
                cid = int(match.group(1))
                if cid == 1 or cid in courses_by_id:
                    continue
                name = _clean_moodle_title(a.get_text(" ", strip=True))
                if not name or len(name) < 3:
                    continue
                clean_name = clean_course_display_name(name)
                courses_by_id[cid] = {
                    "id": cid,
                    "fullname": name,
                    "clean_name": clean_name,
                    "shortname": name,
                    "url": f"{AULA_BASE_URL}/course/view.php?id={cid}",
                    "obsidian_folder": resolve_course_folder(cid, name),
                }
        except Exception:
            pass

    return list(courses_by_id.values())


def _extract_folder_files(
    req_session, folder_url: str, section_name: str, folder_title: str
) -> List[Dict]:
    """Entra a un módulo tipo Carpeta (/mod/folder/view.php) y extrae cada archivo individual."""
    items = []
    try:
        resp = req_session.get(folder_url, timeout=12)
        if not is_authenticated_moodle_html(resp.url, resp.text):
            return items
        soup = BeautifulSoup(resp.text, "lxml")
        for a in soup.select('a[href*="pluginfile.php"]'):
            href = a.get("href", "")
            if not href:
                continue
            filename = a.select_one(".fp-filename")
            title = filename.get_text(strip=True) if filename else a.get_text(strip=True)
            if not title:
                parsed_path = urlparse(href).path
                title = unquote(parsed_path.split("/")[-1])
            item_id = f"folderfile_{re.sub(r'[^a-zA-Z0-9]', '_', href.split('?')[0][-60:])}"
            items.append(
                {
                    "id": item_id,
                    "title": title,
                    "section": f"{section_name} / {folder_title}",
                    "type": "file",
                    "url": href,
                    "downloadable": True,
                }
            )
    except Exception:
        pass
    return items


def _parse_activities_from_soup(
    req_session, soup: BeautifulSoup, seen_urls: set, default_section: str = "General"
) -> List[Dict]:
    """Extrae módulos y archivos desde un árbol DOM de Moodle."""
    items: List[Dict] = []
    sections = soup.select("li.section.main, div.course-section, [data-region='section']")
    if not sections:
        sections = [soup]

    for idx, sec in enumerate(sections):
        sec_title_el = sec.select_one(
            ".sectionname, .course-section-header h3, [data-region='section-title'], h3.sectionname"
        )
        section_name = (
            _clean_moodle_title(sec_title_el.get_text(" ", strip=True))
            if sec_title_el
            else (default_section if len(sections) == 1 else f"Sección {idx}")
        )

        activities = sec.select("li.activity, .activity-item, [data-region='activity-item']")
        if not activities:
            activities = sec.select("a[href*='/mod/'], a[href*='pluginfile.php']")

        for act in activities:
            link = (
                act
                if act.name == "a"
                else act.select_one(
                    "a.aalink, a[href*='/mod/'], a[href*='pluginfile.php']"
                )
            )
            if not link:
                continue
            href = link.get("href", "").strip()
            if not href:
                continue
            href = urljoin(AULA_BASE_URL, href)
            if href in seen_urls:
                continue
            seen_urls.add(href)

            instancename = link.select_one(".instancename")
            if instancename:
                for hidden in instancename.select(".accesshide"):
                    hidden.decompose()
                title = instancename.get_text(" ", strip=True)
            else:
                title = _clean_moodle_title(link.get_text(" ", strip=True))

            if not title:
                title = "Recurso sin título"

            if "/mod/resource/" in href or "pluginfile.php" in href:
                mod_id_match = re.search(r"[?&]id=(\d+)", href)
                item_id = (
                    f"res_{mod_id_match.group(1)}"
                    if mod_id_match
                    else f"file_{abs(hash(href))}"
                )
                items.append(
                    {
                        "id": item_id,
                        "title": title,
                        "section": section_name,
                        "type": "file",
                        "url": href,
                        "downloadable": True,
                    }
                )
            elif "/mod/folder/" in href:
                folder_files = _extract_folder_files(
                    req_session, href, section_name, title
                )
                for ff in folder_files:
                    if ff["url"] not in seen_urls:
                        seen_urls.add(ff["url"])
                        items.append(ff)
            elif "/mod/assign/" in href:
                mod_id_match = re.search(r"[?&]id=(\d+)", href)
                item_id = (
                    f"assign_{mod_id_match.group(1)}"
                    if mod_id_match
                    else f"assign_{abs(hash(href))}"
                )
                items.append(
                    {
                        "id": item_id,
                        "title": title,
                        "section": section_name,
                        "type": "assignment",
                        "url": href,
                        "downloadable": False,
                    }
                )
            elif "/mod/url/" in href:
                mod_id_match = re.search(r"[?&]id=(\d+)", href)
                item_id = (
                    f"url_{mod_id_match.group(1)}"
                    if mod_id_match
                    else f"url_{abs(hash(href))}"
                )
                items.append(
                    {
                        "id": item_id,
                        "title": title,
                        "section": section_name,
                        "type": "link",
                        "url": href,
                        "downloadable": False,
                    }
                )
            elif "/mod/forum/" in href:
                mod_id_match = re.search(r"[?&]id=(\d+)", href)
                item_id = (
                    f"forum_{mod_id_match.group(1)}"
                    if mod_id_match
                    else f"forum_{abs(hash(href))}"
                )
                items.append(
                    {
                        "id": item_id,
                        "title": title,
                        "section": section_name,
                        "type": "forum",
                        "url": href,
                        "downloadable": False,
                    }
                )

    return items


def scan_course_contents(course_id: int, course_name: str = "") -> List[Dict]:
    """
    Escanea un curso en Aula USM y devuelve todos los recursos, carpetas, tareas y avisos.
    Soporta tanto formato de secciones en una página como formato por pestañas (onetopic).
    """
    req_session = get_requests_session()
    if not req_session:
        raise PermissionError("Sesión no disponible.")

    course_url = f"{AULA_BASE_URL}/course/view.php?id={course_id}"
    resp = req_session.get(course_url, timeout=15)
    if not is_authenticated_moodle_html(resp.url, resp.text):
        raise PermissionError("La sesión de Aula USM no es válida o expiró.")

    soup = BeautifulSoup(resp.text, "lxml")
    seen_urls = set()
    items = _parse_activities_from_soup(req_session, soup, seen_urls)

    # Detectar si el curso usa pestañas por sección (/course/view.php?id=X&section=Y o /course/section.php?id=Y)
    tab_links = []
    seen_tab_urls = {course_url}
    for a in soup.select(
        f'a[href*="/course/view.php?id={course_id}&section="], a[href*="/course/section.php?id="]'
    ):
        href = urljoin(AULA_BASE_URL, a.get("href", "").split("#")[0])
        tab_title = _clean_moodle_title(a.get_text(" ", strip=True))
        if href and href not in seen_tab_urls:
            seen_tab_urls.add(href)
            tab_links.append((href, tab_title or "Pestaña"))

    if tab_links:
        def _fetch_sub_tab(tab_item):
            t_url, t_title = tab_item
            try:
                t_resp = req_session.get(t_url, timeout=8)
                if is_authenticated_moodle_html(t_resp.url, t_resp.text):
                    t_soup = BeautifulSoup(t_resp.text, "lxml")
                    return _parse_activities_from_soup(
                        req_session, t_soup, seen_urls, default_section=t_title
                    )
            except Exception:
                pass
            return []

        with concurrent.futures.ThreadPoolExecutor(max_workers=min(6, len(tab_links))) as ex:
            sub_results = list(ex.map(_fetch_sub_tab, tab_links[:12]))

        for sub in sub_results:
            items.extend(sub)

    return items

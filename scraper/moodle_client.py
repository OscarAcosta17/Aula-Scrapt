import concurrent.futures
import re
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from urllib.parse import unquote, urljoin, urlparse
import requests
from bs4 import BeautifulSoup

from config import (
    AULA_BASE_URL,
    clean_course_display_name,
    resolve_course_preferences,
)
from scraper.auth import (
    USER_AGENT,
    get_requests_session,
    is_authenticated_moodle_html,
    load_saved_session,
    verify_session,
)

_SPANISH_MONTHS = {
    "enero": 1, "ene": 1,
    "febrero": 2, "feb": 2,
    "marzo": 3, "mar": 3,
    "abril": 4, "abr": 4,
    "mayo": 5, "may": 5,
    "junio": 6, "jun": 6,
    "julio": 7, "jul": 7,
    "agosto": 8, "ago": 8,
    "septiembre": 9, "sep": 9, "setiembre": 9,
    "octubre": 10, "oct": 10,
    "noviembre": 11, "nov": 11,
    "diciembre": 12, "dic": 12,
    "january": 1, "jan": 1,
    "february": 2,
    "march": 3,
    "april": 4,
    "june": 6,
    "july": 7,
    "august": 8, "aug": 8,
    "september": 9,
    "october": 10,
    "november": 11,
    "december": 12, "dec": 12,
}


def _clean_moodle_title(raw_title: str) -> str:
    """Limpia sufijos de accesibilidad que Moodle agrega a los títulos."""
    text = re.sub(r"\s+", " ", raw_title).strip()
    suffixes = [
        " Archivo",
        " Documento PDF",
        " Carpeta",
        " Tarea",
        " Cuestionario",
        " Foro",
        " URL",
        " Página",
        " File",
        " Folder",
        " Assignment",
        " Quiz",
    ]
    for s in suffixes:
        if text.endswith(s):
            text = text[: -len(s)].strip()
    return text


def _infer_file_ext(title: str = "", file_name: str = "", url: str = "") -> str:
    """Infiere la extensión de archivo en minúsculas sin punto (ej. 'pdf')."""
    for candidate in (file_name, title):
        if candidate:
            ext = Path(candidate.strip()).suffix.lstrip(".").lower()
            if 1 <= len(ext) <= 6 and ext.isalnum():
                return ext
    if url:
        parsed_name = unquote(urlparse(url).path.split("/")[-1])
        ext = Path(parsed_name).suffix.lstrip(".").lower()
        if 1 <= len(ext) <= 6 and ext.isalnum() and ext != "php":
            return ext
    return ""


def _parse_due_timestamp_from_text(text: str) -> Optional[int]:
    """Convierte cadenas de fecha de Moodle en timestamp Unix (segundos)."""
    if not text:
        return None
    low = text.lower()

    # Formato: "15 de noviembre de 2026, 23:59" o "15 noviembre 2026 23:59"
    m = re.search(
        r"(\d{1,2})\s+(?:de\s+)?([a-záéíóúñ]+)\.?\s+(?:de\s+)?(\d{4})(?:[,\s]+(\d{1,2}):(\d{2}))?",
        low,
    )
    if m:
        day = int(m.group(1))
        month_name = m.group(2)
        year = int(m.group(3))
        hour = int(m.group(4) or 23)
        minute = int(m.group(5) or 59)
        month = _SPANISH_MONTHS.get(month_name)
        if month:
            try:
                return int(datetime(year, month, day, hour, minute).timestamp())
            except ValueError:
                pass

    # Formato numérico dd/mm/yyyy HH:MM o dd-mm-yyyy
    m2 = re.search(r"(\d{1,2})[/-](\d{1,2})[/-](\d{4})(?:[,\s]+(\d{1,2}):(\d{2}))?", low)
    if m2:
        day, month, year = int(m2.group(1)), int(m2.group(2)), int(m2.group(3))
        hour = int(m2.group(4) or 23)
        minute = int(m2.group(5) or 59)
        try:
            return int(datetime(year, month, day, hour, minute).timestamp())
        except ValueError:
            pass

    return None


def _extract_activity_due_info(act_el) -> Tuple[Optional[int], str]:
    """Extrae fecha límite (timestamp + texto legible) desde el DOM de una actividad Moodle."""
    if act_el is None or getattr(act_el, "name", None) == "a":
        return None, ""

    date_box = act_el.select_one(
        '[data-region="activity-dates"], .activity-dates, .description-inner, .description'
    )
    if not date_box:
        return None, ""

    ts_el = date_box.select_one("[data-timestamp]")
    ts_val: Optional[int] = None
    if ts_el and ts_el.get("data-timestamp"):
        try:
            ts_val = int(ts_el["data-timestamp"])
        except ValueError:
            ts_val = None

    raw_text = re.sub(r"\s+", " ", date_box.get_text(" ", strip=True)).strip()
    if not raw_text:
        return ts_val, ""

    best_line = ""
    for chunk in re.split(r"[\n\r]+|(?=(?:Cierra|Vence|Entrega|Due|Closes)\s*:)", raw_text, flags=re.I):
        c = chunk.strip(" |-•")
        if any(k in c.lower() for k in ("cierra", "vence", "entrega", "due", "closes")):
            best_line = c
            parsed = _parse_due_timestamp_from_text(c)
            if parsed and not ts_val:
                ts_val = parsed
            break

    if not best_line:
        best_line = raw_text[:120]
    if not ts_val:
        ts_val = _parse_due_timestamp_from_text(best_line)
    if ts_val and not best_line:
        best_line = datetime.fromtimestamp(ts_val).strftime("%d/%m/%Y %H:%M")

    return ts_val, best_line


def _moodle_ws_call(token: str, wsfunction: str, extra_params: Optional[Dict] = None):
    """Ejecuta una llamada REST contra el webservice de Moodle USM."""
    ws_url = f"{AULA_BASE_URL}/webservice/rest/server.php"
    payload = {
        "wstoken": token,
        "wsfunction": wsfunction,
        "moodlewsrestformat": "json",
    }
    if extra_params:
        payload.update(extra_params)
    resp = requests.post(
        ws_url, data=payload, headers={"User-Agent": USER_AGENT}, timeout=18
    )
    data = resp.json()
    if isinstance(data, dict) and data.get("errorcode"):
        raise RuntimeError(data.get("message") or data["errorcode"])
    return data


def _build_course_dict(
    cid: int, fullname: str, shortname: str = "", view_url: str = ""
) -> Dict:
    clean_name = clean_course_display_name(fullname)
    prefs = resolve_course_preferences(cid, fullname)
    return {
        "id": cid,
        "fullname": fullname,
        "clean_name": clean_name,
        "shortname": shortname,
        "url": view_url or f"{AULA_BASE_URL}/course/view.php?id={cid}",
        "obsidian_folder": prefs["obsidian_folder"],
        "target_subfolder": prefs["target_subfolder"],
        "organize_by_section": prefs["organize_by_section"],
        "is_hidden": prefs["is_hidden"],
    }


def _fetch_ws_deadlines_map(token: str, course_ids: List[int]) -> Dict[str, Tuple[int, str]]:
    """Obtiene fechas límite (assign y quiz) vía WebService para enriquecer ítems."""
    deadlines: Dict[str, Tuple[int, str]] = {}
    if not course_ids or not token:
        return deadlines

    course_params = {f"courseids[{i}]": cid for i, cid in enumerate(course_ids)}

    try:
        assign_data = _moodle_ws_call(token, "mod_assign_get_assignments", course_params)
        for c in assign_data.get("courses", []):
            for a in c.get("assignments", []):
                cmid = a.get("cmid")
                duedate = int(a.get("duedate") or 0)
                if cmid and duedate > 0:
                    label = "Entrega: " + datetime.fromtimestamp(duedate).strftime(
                        "%d/%m/%Y %H:%M"
                    )
                    deadlines[f"assign_{cmid}"] = (duedate, label)
    except Exception:
        pass

    try:
        quiz_data = _moodle_ws_call(token, "mod_quiz_get_quizzes_by_courses", course_params)
        for q in quiz_data.get("quizzes", []):
            cmid = q.get("coursemodule")
            timeclose = int(q.get("timeclose") or 0)
            if cmid and timeclose > 0:
                label = "Cierra: " + datetime.fromtimestamp(timeclose).strftime(
                    "%d/%m/%Y %H:%M"
                )
                deadlines[f"quiz_{cmid}"] = (timeclose, label)
    except Exception:
        pass

    return deadlines


def get_enrolled_courses() -> List[Dict]:
    """
    Obtiene todos los cursos inscritos del usuario en Aula USM soportando
    sesión por Cookie (AJAX + DOM) y sesión por Access Token (wstoken).
    """
    status = verify_session()
    if not status.get("authenticated"):
        raise PermissionError(status.get("reason", "Sesión no iniciada en Aula USM."))

    saved = load_saved_session() or {}
    token = (saved.get("token") or "").strip()

    if token:
        user_id = status.get("user_id") or saved.get("user_id")
        if not user_id:
            info = _moodle_ws_call(token, "core_webservice_get_site_info")
            user_id = info.get("userid")
        raw_courses = _moodle_ws_call(
            token, "core_enrol_get_users_courses", {"userid": user_id}
        )
        courses: List[Dict] = []
        for c in raw_courses or []:
            cid = int(c.get("id") or 0)
            if cid <= 1:
                continue
            fullname = str(c.get("fullname") or f"Curso {cid}").strip()
            courses.append(
                _build_course_dict(
                    cid=cid,
                    fullname=fullname,
                    shortname=str(c.get("shortname") or ""),
                )
            )
        return courses

    req_session = get_requests_session()
    sesskey = status.get("sesskey", "")
    courses_by_id: Dict[int, Dict] = {}

    if sesskey and req_session:
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
                            if cid == 1 or cid in courses_by_id:
                                continue
                            fullname = c.get("fullname", f"Curso {cid}").strip()
                            courses_by_id[cid] = _build_course_dict(
                                cid=cid,
                                fullname=fullname,
                                shortname=c.get("shortname", ""),
                                view_url=c.get("viewurl", ""),
                            )
            except Exception:
                pass

    if req_session:
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
                    courses_by_id[cid] = _build_course_dict(
                        cid=cid, fullname=name, shortname=name
                    )
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
            filename_el = a.select_one(".fp-filename")
            title = filename_el.get_text(strip=True) if filename_el else a.get_text(strip=True)
            parsed_path = urlparse(href).path
            url_name = unquote(parsed_path.split("/")[-1]) if parsed_path else ""
            if not title:
                title = url_name
            file_name = url_name or title
            item_id = f"folderfile_{re.sub(r'[^a-zA-Z0-9]', '_', href.split('?')[0][-60:])}"
            items.append(
                {
                    "id": item_id,
                    "title": title,
                    "file_name": file_name,
                    "file_ext": _infer_file_ext(title, file_name, href),
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
    """Extrae módulos, archivos y fechas de entrega desde un árbol DOM de Moodle."""
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

            mod_id_match = re.search(r"[?&]id=(\d+)", href)
            mod_id = mod_id_match.group(1) if mod_id_match else str(abs(hash(href)))

            if "/mod/resource/" in href or "pluginfile.php" in href:
                parsed_name = unquote(urlparse(href).path.split("/")[-1])
                file_name = parsed_name if "pluginfile.php" in href and parsed_name else title
                items.append(
                    {
                        "id": f"res_{mod_id}" if mod_id_match else f"file_{mod_id}",
                        "title": title,
                        "file_name": file_name,
                        "file_ext": _infer_file_ext(title, file_name, href),
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
                due_ts, due_text = _extract_activity_due_info(act)
                items.append(
                    {
                        "id": f"assign_{mod_id}",
                        "title": title,
                        "section": section_name,
                        "type": "assignment",
                        "url": href,
                        "downloadable": False,
                        "due_timestamp": due_ts,
                        "due_text": due_text,
                    }
                )
            elif "/mod/quiz/" in href:
                due_ts, due_text = _extract_activity_due_info(act)
                items.append(
                    {
                        "id": f"quiz_{mod_id}",
                        "title": title,
                        "section": section_name,
                        "type": "quiz",
                        "url": href,
                        "downloadable": False,
                        "due_timestamp": due_ts,
                        "due_text": due_text,
                    }
                )
            elif "/mod/url/" in href:
                items.append(
                    {
                        "id": f"url_{mod_id}",
                        "title": title,
                        "section": section_name,
                        "type": "link",
                        "url": href,
                        "downloadable": False,
                    }
                )
            elif "/mod/forum/" in href:
                items.append(
                    {
                        "id": f"forum_{mod_id}",
                        "title": title,
                        "section": section_name,
                        "type": "forum",
                        "url": href,
                        "downloadable": False,
                    }
                )

    return items


def _scan_course_contents_token(
    token: str, course_id: int, deadlines_map: Optional[Dict[str, Tuple[int, str]]] = None
) -> List[Dict]:
    """Escanea los módulos de un curso mediante Moodle REST API (wstoken)."""
    data = _moodle_ws_call(token, "core_course_get_contents", {"courseid": course_id})
    items: List[Dict] = []
    deadlines_map = deadlines_map or {}

    for sec in data or []:
        raw_sec_name = str(sec.get("name") or "").strip()
        sec_name = raw_sec_name or "General"
        for mod in sec.get("modules") or []:
            mod_id = int(mod.get("id") or 0)
            mod_name = str(mod.get("name") or "").strip()
            mod_type = str(mod.get("modname") or "").strip()
            mod_url = str(mod.get("url") or "").strip()
            contents = mod.get("contents") or []

            if mod_type == "folder" and contents:
                for c in contents:
                    file_url = str(c.get("fileurl") or "").strip()
                    file_name = str(c.get("filename") or mod_name).strip()
                    file_size = int(c.get("filesize") or 0)
                    if not file_url:
                        continue
                    items.append(
                        {
                            "id": f"folderfile_{mod_id}_{abs(hash(file_name))}",
                            "title": file_name,
                            "file_name": file_name,
                            "file_ext": _infer_file_ext(file_name, file_name, file_url),
                            "section": f"{sec_name} / {mod_name}" if mod_name else sec_name,
                            "type": "file",
                            "url": file_url,
                            "downloadable": True,
                            "size_bytes": file_size,
                        }
                    )
            elif mod_type == "url":
                link_url = (
                    str(contents[0].get("fileurl") or mod_url) if contents else mod_url
                )
                if link_url:
                    items.append(
                        {
                            "id": f"url_{mod_id}",
                            "title": mod_name or "Enlace externo",
                            "section": sec_name,
                            "type": "link",
                            "url": link_url,
                            "downloadable": False,
                        }
                    )
            elif mod_type == "assign":
                key = f"assign_{mod_id}"
                due_ts, due_text = deadlines_map.get(key, (None, ""))
                items.append(
                    {
                        "id": key,
                        "title": mod_name or "Tarea",
                        "section": sec_name,
                        "type": "assignment",
                        "url": mod_url,
                        "downloadable": False,
                        "due_timestamp": due_ts,
                        "due_text": due_text,
                    }
                )
            elif mod_type == "quiz":
                key = f"quiz_{mod_id}"
                due_ts, due_text = deadlines_map.get(key, (None, ""))
                items.append(
                    {
                        "id": key,
                        "title": mod_name or "Cuestionario",
                        "section": sec_name,
                        "type": "quiz",
                        "url": mod_url,
                        "downloadable": False,
                        "due_timestamp": due_ts,
                        "due_text": due_text,
                    }
                )
            elif mod_type == "forum":
                items.append(
                    {
                        "id": f"forum_{mod_id}",
                        "title": mod_name or "Foro",
                        "section": sec_name,
                        "type": "forum",
                        "url": mod_url,
                        "downloadable": False,
                    }
                )
            elif contents and mod_type != "page":
                for idx, c in enumerate(contents):
                    file_url = str(c.get("fileurl") or "").strip()
                    file_name = str(c.get("filename") or mod_name).strip()
                    file_size = int(c.get("filesize") or 0)
                    if not file_url:
                        continue
                    title = mod_name if (len(contents) == 1 and mod_name) else file_name
                    items.append(
                        {
                            "id": f"res_{mod_id}" if len(contents) == 1 else f"res_{mod_id}_{idx}",
                            "title": title,
                            "file_name": file_name,
                            "file_ext": _infer_file_ext(title, file_name, file_url),
                            "section": sec_name,
                            "type": "file",
                            "url": file_url,
                            "downloadable": True,
                            "size_bytes": file_size,
                        }
                    )

    return items


def scan_course_contents(
    course_id: int,
    course_name: str = "",
    deadlines_map: Optional[Dict[str, Tuple[int, str]]] = None,
) -> List[Dict]:
    """
    Escanea un curso en Aula USM y devuelve todos los recursos, carpetas, tareas, cuestionarios y avisos.
    Soporta tanto formato web (Cookie + onetopic) como WebService (wstoken).
    """
    saved = load_saved_session() or {}
    token = (saved.get("token") or "").strip()
    if token:
        return _scan_course_contents_token(token, course_id, deadlines_map=deadlines_map)

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

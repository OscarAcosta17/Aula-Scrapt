import json
import os
import subprocess
import sys
import threading
import time
import uuid
import xml.sax.saxutils as xml_utils
from typing import Optional

from config import NOTIFICATIONS_FILE, load_settings

MAX_NOTIFICATIONS = 80
_NOTIF_LOCK = threading.Lock()
_DEDUP_WINDOW_SECONDS = 12 * 3600
_DEADLINE_DEDUP_SECONDS = 24 * 3600


def _load_notifications_unlocked() -> list[dict]:
    if not NOTIFICATIONS_FILE.exists():
        return []
    try:
        data = json.loads(NOTIFICATIONS_FILE.read_text(encoding="utf-8"))
        if isinstance(data, list):
            return [item for item in data if isinstance(item, dict)]
    except Exception:
        pass
    return []


def _save_notifications_unlocked(items: list[dict]) -> None:
    NOTIFICATIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
    capped = items[:MAX_NOTIFICATIONS]
    NOTIFICATIONS_FILE.write_text(
        json.dumps(capped, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )


def load_notifications() -> list[dict]:
    with _NOTIF_LOCK:
        return _load_notifications_unlocked()


def list_notifications() -> dict:
    with _NOTIF_LOCK:
        items = _load_notifications_unlocked()
    unread_count = sum(1 for item in items if not item.get("read"))
    return {
        "notifications": items,
        "unread_count": unread_count,
    }


def mark_all_notifications_read() -> dict:
    with _NOTIF_LOCK:
        items = _load_notifications_unlocked()
        for item in items:
            item["read"] = True
        _save_notifications_unlocked(items)
    return {
        "notifications": items,
        "unread_count": 0,
    }


def clear_notifications() -> dict:
    with _NOTIF_LOCK:
        _save_notifications_unlocked([])
    return {
        "notifications": [],
        "unread_count": 0,
    }


def _send_windows_toast_sync(title: str, message: str) -> bool:
    if sys.platform != "win32" or os.environ.get("AULA_DISABLE_NATIVE_TOAST") == "1":
        return False

    safe_title = xml_utils.escape((title or "Aula-Scrapt USM").strip()[:140])
    safe_body = xml_utils.escape((message or "").strip()[:320])
    # Uses PowerShell AUMID registered natively on Windows 10/11 so toasts display without Start Menu setup.
    app_id = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\\WindowsPowerShell\\v1.0\\powershell.exe"
    ps_script = (
        "$ErrorActionPreference='SilentlyContinue';"
        "[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]|Out-Null;"
        "[Windows.Data.Xml.Dom.XmlDocument,Windows.Data.Xml.Dom.XmlDocument,ContentType=WindowsRuntime]|Out-Null;"
        f"$xml='<toast><visual><binding template=\"ToastGeneric\"><text>{safe_title}</text><text>{safe_body}</text></binding></visual></toast>';"
        "$doc=New-Object Windows.Data.Xml.Dom.XmlDocument;"
        "$doc.LoadXml($xml);"
        "$toast=[Windows.UI.Notifications.ToastNotification]::new($doc);"
        f"[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{app_id}').Show($toast);"
    )
    creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
    try:
        subprocess.Popen(
            [
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-WindowStyle",
                "Hidden",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                ps_script,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            creationflags=creation_flags,
        )
        return True
    except Exception:
        return False


def send_windows_toast(title: str, message: str) -> bool:
    """Fire a native Windows toast notification without blocking the caller."""
    if sys.platform != "win32" or os.environ.get("AULA_DISABLE_NATIVE_TOAST") == "1":
        return False
    thread = threading.Thread(
        target=_send_windows_toast_sync,
        args=(title, message),
        daemon=True,
    )
    thread.start()
    return True


def add_notification(
    title: str,
    body: str,
    kind: str = "info",
    course_name: str = "",
    url: str = "",
    fire_toast: bool = True,
    dedup_key: str = "",
    dedup_window_seconds: Optional[int] = None,
) -> Optional[dict]:
    now = time.time()
    window = (
        _DEADLINE_DEDUP_SECONDS
        if kind == "deadline" and dedup_window_seconds is None
        else (dedup_window_seconds if dedup_window_seconds is not None else _DEDUP_WINDOW_SECONDS)
    )

    with _NOTIF_LOCK:
        items = _load_notifications_unlocked()
        if dedup_key:
            for existing in items:
                if existing.get("dedup_key") == dedup_key:
                    age = now - float(existing.get("created_at") or 0)
                    if age < window:
                        return None

        entry = {
            "id": uuid.uuid4().hex[:12],
            "title": str(title).strip(),
            "body": str(body).strip(),
            "kind": kind,
            "course_name": str(course_name).strip(),
            "url": str(url).strip(),
            "dedup_key": dedup_key,
            "created_at": int(now),
            "read": False,
        }
        items.insert(0, entry)
        _save_notifications_unlocked(items)

    if fire_toast:
        settings = load_settings()
        if settings.get("notify_native_enabled", True):
            send_windows_toast(entry["title"], entry["body"])
    return entry


def compute_scan_notifications(
    courses_results: list[dict],
    previous_cache: Optional[dict],
    fire_toast: bool = True,
) -> list[dict]:
    """Detect newly published files and upcoming deadlines compared to cached scan state."""
    settings = load_settings()
    notify_new = bool(settings.get("notify_on_new_files", True))
    notify_deadlines = bool(settings.get("notify_on_deadlines", True))
    created: list[dict] = []

    prev_ids_by_course: dict[int, set[str]] = {}
    has_previous_courses = False
    if isinstance(previous_cache, dict):
        prev_courses = previous_cache.get("courses")
        if isinstance(prev_courses, list) and prev_courses:
            has_previous_courses = True
            for prev_course in prev_courses:
                if not isinstance(prev_course, dict):
                    continue
                cid = int(prev_course.get("id") or 0)
                seen_ids = {
                    str(it.get("id") or "")
                    for it in (prev_course.get("items") or [])
                    if isinstance(it, dict) and it.get("id")
                }
                prev_ids_by_course[cid] = seen_ids

    now = time.time()
    downloadable_types = {"file", "folder_file", "assign_file"}

    for course in courses_results:
        if not isinstance(course, dict) or course.get("is_hidden"):
            continue
        cid = int(course.get("id") or 0)
        course_name = str(course.get("obsidian_folder") or course.get("fullname") or "Ramo")
        items = course.get("items") or []

        if notify_new and has_previous_courses and cid in prev_ids_by_course:
            known_ids = prev_ids_by_course[cid]
            new_items = [
                it for it in items
                if isinstance(it, dict)
                and it.get("type") in downloadable_types
                and str(it.get("id") or "") not in known_ids
                and not it.get("downloaded")
                and not it.get("seen")
            ]
            if new_items:
                first_title = str(new_items[0].get("title") or "Archivo")
                if len(new_items) == 1:
                    title = f"Nuevo archivo en {course_name}"
                    body = first_title
                else:
                    title = f"{len(new_items)} archivos nuevos en {course_name}"
                    body = f"Incluye: {first_title}"
                entry = add_notification(
                    title=title,
                    body=body,
                    kind="new_file",
                    course_name=course_name,
                    url=str(new_items[0].get("url") or ""),
                    fire_toast=fire_toast,
                    dedup_key=f"new:{cid}:{new_items[0].get('id')}:{len(new_items)}",
                )
                if entry:
                    created.append(entry)

        if notify_deadlines:
            for it in items:
                if not isinstance(it, dict) or it.get("type") not in {"assign", "quiz"}:
                    continue
                due_ts = it.get("due_timestamp")
                if not isinstance(due_ts, (int, float)) or due_ts <= 0:
                    continue
                seconds_left = float(due_ts) - now
                if 0 < seconds_left <= 48 * 3600:
                    hours_left = max(1, int(round(seconds_left / 3600)))
                    due_label = str(it.get("due_text") or "").strip()
                    suffix = f" ({due_label})" if due_label else ""
                    entry = add_notification(
                        title=f"Entrega próxima en {hours_left}h",
                        body=f"{course_name}: {it.get('title', 'Actividad')}{suffix}",
                        kind="deadline",
                        course_name=course_name,
                        url=str(it.get("url") or ""),
                        fire_toast=fire_toast,
                        dedup_key=f"due:{it.get('id')}:{int(due_ts)}",
                    )
                    if entry:
                        created.append(entry)

    return created

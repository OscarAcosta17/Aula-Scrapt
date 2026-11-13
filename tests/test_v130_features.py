import hashlib
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from bs4 import BeautifulSoup
from fastapi.testclient import TestClient

os.environ["AULA_DISABLE_NATIVE_TOAST"] = "1"

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import config  # noqa: E402
import main  # noqa: E402
from scraper import moodle_client, notifier, obsidian_sync, updater  # noqa: E402


class LocalMatcherAndSharedIndexTests(unittest.TestCase):
    def test_fuzzy_normalization_matches_external_file_scoped_to_download_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root_a = Path(tmp) / "VaultA"
            root_b = Path(tmp) / "VaultB"
            course_dir = root_a / "Matematicas" / "Aula" / "Semana 1"
            course_dir.mkdir(parents=True)
            pdf_file = course_dir / "Guia 01 - Integrales Impropias (2026) v2.pdf"
            pdf_file.write_bytes(b"%PDF-1.4 sample")

            raw_items = [
                {
                    "id": "cmid_101",
                    "type": "file",
                    "title": "Guia 01 Integrales Impropias",
                    "file_name": "",
                    "section": "Semana 1",
                    "url": "https://aula.usm.cl/mod/resource/view.php?id=101",
                    "downloadable": True,
                }
            ]

            with patch.object(obsidian_sync, "get_download_root", return_value=root_a), patch.object(
                obsidian_sync, "load_history", return_value={"downloaded_ids": {}, "seen_ids": {}}
            ):
                enriched_a = obsidian_sync.enrich_items_with_status(
                    raw_items, "Matematicas", allow_network_head=False
                )

            self.assertTrue(enriched_a[0]["is_downloaded"])
            self.assertEqual(Path(enriched_a[0]["local_path"]).resolve(), pdf_file.resolve())

            # Al cambiar de download_root hacia una carpeta vacia, no debe marcarlo como descargado.
            root_b.mkdir(parents=True)
            obsidian_sync.save_shared_index_entry(
                root_a,
                "cmid_101",
                {
                    "filename": pdf_file.name,
                    "title": "Guia 01 Integrales Impropias",
                    "rel_path": "Matematicas/Aula/Semana 1/" + pdf_file.name,
                },
            )
            with patch.object(obsidian_sync, "get_download_root", return_value=root_b), patch.object(
                obsidian_sync, "load_history", return_value={"downloaded_ids": {"cmid_101": {"filename": pdf_file.name}}, "seen_ids": {}}
            ):
                enriched_b = obsidian_sync.enrich_items_with_status(
                    raw_items, "Matematicas", allow_network_head=False
                )

            self.assertFalse(enriched_b[0]["is_downloaded"])
            self.assertFalse(enriched_b[0]["local_path"])

    def test_shared_index_detects_pc_and_mobile_relative_path(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Downloads"
            saved_dir = root / "Fisica" / "Clases"
            saved_dir.mkdir(parents=True)
            saved_file = saved_dir / "documento_descargado_movil.pptx"
            saved_file.write_bytes(b"PK\x03\x04dummy")

            obsidian_sync.save_shared_index_entry(
                root,
                "res_555",
                {
                    "filename": "documento_descargado_movil.pptx",
                    "title": "Clase 12 Electromagnetismo",
                    "relative_path": "Fisica/Clases/documento_descargado_movil.pptx",
                },
            )

            raw_items = [
                {
                    "id": "res_555",
                    "type": "file",
                    "title": "Apuntes Semanales Fisica",
                    "section": "Clases",
                    "url": "https://aula.usm.cl/mod/resource/view.php?id=555",
                    "downloadable": True,
                }
            ]

            with patch.object(obsidian_sync, "get_download_root", return_value=root), patch.object(
                obsidian_sync, "load_history", return_value={"downloaded_ids": {}, "seen_ids": {}}
            ):
                enriched = obsidian_sync.enrich_items_with_status(
                    raw_items, "Fisica", allow_network_head=False
                )

            self.assertTrue(enriched[0]["is_downloaded"])
            self.assertEqual(Path(enriched[0]["local_path"]).resolve(), saved_file.resolve())


class DeadlinesAndObsidianExportTests(unittest.TestCase):
    def test_parse_spanish_moodle_deadline_html(self):
        html = """
        <div class="activity assign" id="module-900">
          <div class="activityname"><a href="https://aula.usm.cl/mod/assign/view.php?id=900">Entrega Proyecto 1</a></div>
          <div class="description">
            <div>Fecha de entrega: viernes, 15 de noviembre de 2026, 23:59</div>
          </div>
        </div>
        """
        soup = BeautifulSoup(html, "html.parser")
        due_ts, due_text = moodle_client._extract_activity_due_info(soup.find(id="module-900"))
        self.assertIsNotNone(due_ts)
        self.assertGreater(due_ts, 1700000000)
        self.assertIn("2026", due_text)

    def test_export_links_and_forums_to_obsidian_index(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Obsidian"
            (root / "Estructuras").mkdir(parents=True)
            items = [
                {
                    "id": "url_1",
                    "type": "url",
                    "title": "Grabacion Clase 3",
                    "section": "Unidad 1",
                    "url": "https://aula.usm.cl/mod/url/view.php?id=1",
                    "downloadable": False,
                },
                {
                    "id": "forum_1",
                    "type": "forum",
                    "title": "Foro Consultas Certamen",
                    "section": "General",
                    "url": "https://aula.usm.cl/mod/forum/view.php?id=2",
                    "downloadable": False,
                },
            ]
            with patch.object(obsidian_sync, "get_download_root", return_value=root), patch.object(
                obsidian_sync,
                "load_settings",
                return_value={
                    "auto_export_links_to_obsidian": True,
                    "auto_export_forums_to_obsidian": True,
                },
            ):
                md_path = obsidian_sync.export_course_resources_markdown("Estructuras", "", items)

            content = md_path.read_text(encoding="utf-8")
            self.assertIn("## Enlaces y Clases (URL)", content)
            self.assertIn("Grabacion Clase 3", content)
            self.assertIn("## Foros y Anuncios", content)
            self.assertIn("Foro Consultas Certamen", content)


class NotificationsAndUpdaterSecurityTests(unittest.TestCase):
    def test_compute_scan_notifications_and_dedup(self):
        with tempfile.TemporaryDirectory() as tmp:
            notif_file = Path(tmp) / "notifications.json"
            now = __import__("time").time()
            with patch.object(notifier, "NOTIFICATIONS_FILE", notif_file), patch.object(
                notifier,
                "load_settings",
                return_value={
                    "notify_native_enabled": False,
                    "notify_on_new_files": True,
                    "notify_on_deadlines": True,
                },
            ):
                prev_cache = {
                    "courses": [
                        {
                            "id": 42,
                            "items": [{"id": "old_1"}],
                        }
                    ]
                }
                current_courses = [
                    {
                        "id": 42,
                        "obsidian_folder": "Sistemas Operativos",
                        "is_hidden": False,
                        "items": [
                            {"id": "old_1", "type": "file", "title": "Intro", "downloaded": True, "seen": True},
                            {"id": "new_2", "type": "file", "title": "Lab Threads.pdf", "downloaded": False, "seen": False, "url": "https://aula.usm.cl/f2"},
                            {
                                "id": "due_3",
                                "type": "assign",
                                "title": "Entrega Lab 1",
                                "due_timestamp": int(now + 10 * 3600),
                                "due_text": "Mañana 23:59",
                                "url": "https://aula.usm.cl/a3",
                            },
                        ],
                    }
                ]
                created_first = notifier.compute_scan_notifications(current_courses, prev_cache, fire_toast=False)
                self.assertEqual(len(created_first), 2)
                # Segunda corrida inmediata debe deduplicar
                created_second = notifier.compute_scan_notifications(current_courses, prev_cache, fire_toast=False)
                self.assertEqual(len(created_second), 0)

                listed = notifier.list_notifications()
                self.assertEqual(listed["unread_count"], 2)

    def test_updater_sha256_verification_and_beta_channel(self):
        raw_checks = "deadbeef" * 8 + "  Aula-Scrapt-Windows.exe\n" + "a" * 64 + " *Aula-Scrapt-Android.apk\n"
        parsed = updater.parse_checksums_text(raw_checks)
        self.assertEqual(parsed["aula-scrapt-windows.exe"], "deadbeef" * 8)
        self.assertEqual(parsed["aula-scrapt-android.apk"], "a" * 64)

        payload_bytes = b"MZ" + b"\x90" * (600 * 1024)
        good_hash = hashlib.sha256(payload_bytes).hexdigest()

        fake_resp = Mock()
        fake_resp.raise_for_status = Mock()
        fake_resp.headers = {"content-length": str(len(payload_bytes))}
        fake_resp.iter_content = Mock(return_value=[payload_bytes])
        fake_resp.__enter__ = Mock(return_value=fake_resp)
        fake_resp.__exit__ = Mock(return_value=False)

        with tempfile.TemporaryDirectory() as tmp, patch.object(
            updater, "DATA_DIR", Path(tmp)
        ), patch("scraper.updater.requests.get", return_value=fake_resp):
            with self.assertRaises(RuntimeError):
                updater.download_update_asset(
                    "https://example.com/Aula-Scrapt-Windows.exe",
                    "Aula-Scrapt-Windows.exe",
                    expected_sha256="0" * 64,
                )

            staged = updater.download_update_asset(
                "https://example.com/Aula-Scrapt-Windows.exe",
                "Aula-Scrapt-Windows.exe",
                expected_sha256=good_hash,
            )
            self.assertTrue(staged.exists())

        beta_resp = Mock()
        beta_resp.status_code = 200
        beta_resp.json.return_value = [
            {
                "tag_name": "v9.9.0-beta.1",
                "name": "v9.9.0 Beta",
                "prerelease": True,
                "draft": False,
                "assets": [
                    {
                        "name": "Aula-Scrapt-Windows.exe",
                        "browser_download_url": "https://example.com/beta.exe",
                        "size": 1000000,
                    }
                ],
            }
        ]
        with patch("scraper.updater.requests.get", return_value=beta_resp):
            res = updater.check_for_updates(beta_channel=True)
            self.assertTrue(res["ok"])
            self.assertTrue(res["update_available"])
            self.assertTrue(res["is_prerelease"])


class FastApiV130RoutesTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)

    def test_open_file_rejects_path_traversal_outside_download_root(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "Root"
            root.mkdir()
            outside = Path(tmp) / "secret.txt"
            outside.write_text("top secret", encoding="utf-8")

            with patch.object(main, "get_download_root", return_value=root):
                res = self.client.post("/api/open-file", json={"path": str(outside), "reveal": False})
                self.assertEqual(res.status_code, 403)

    def test_lan_pairing_create_claim_and_lockout(self):
        with patch.object(
            main,
            "load_saved_session",
            return_value={"token": "test_ws_token_123", "cookies": []},
        ):
            with main._PAIRING_LOCK:
                main._PAIRING_CODES.clear()
                main._PAIRING_FAILED_ATTEMPTS = 0

            created = self.client.post("/api/pair/create")
            self.assertEqual(created.status_code, 200)
            payload = created.json()
            pin = payload["pin"]
            self.assertEqual(len(pin), 6)

            bad = self.client.get("/api/pair/claim", params={"pin": "000000"})
            self.assertEqual(bad.status_code, 401)

            claimed = self.client.get("/api/pair/claim", params={"pin": pin})
            self.assertEqual(claimed.status_code, 200)
            claim_data = claimed.json()
            self.assertEqual(claim_data["auth"]["token"], "test_ws_token_123")

            # Un solo uso: reclamar por segunda vez debe fallar
            replay = self.client.get("/api/pair/claim", params={"pin": pin})
            self.assertEqual(replay.status_code, 401)

    def test_rescan_local_updates_cache_for_switched_folder(self):
        with tempfile.TemporaryDirectory() as tmp:
            cache_file = Path(tmp) / "scan_cache.json"
            root_empty = Path(tmp) / "Empty"
            root_with_file = Path(tmp) / "Populated"
            root_empty.mkdir()
            sub = root_with_file / "Redes" / "Apuntes"
            sub.mkdir(parents=True)
            (sub / "Resumen TCP.pdf").write_bytes(b"%PDF")

            cached_payload = {
                "courses": [
                    {
                        "course": {"id": 77, "fullname": "Redes de Computadores", "obsidian_folder": "Redes"},
                        "items": [
                            {
                                "id": "f77",
                                "type": "file",
                                "title": "Resumen TCP",
                                "section": "Apuntes",
                                "url": "https://aula.usm.cl/mod/resource/view.php?id=77",
                                "downloadable": True,
                            }
                        ],
                        "new_files_count": 1,
                        "downloadable_count": 1,
                    }
                ],
                "download_root": str(root_empty),
                "summary": {"total_courses": 1, "total_files": 1, "total_new_files": 1},
            }
            cache_file.write_text(json.dumps(cached_payload), encoding="utf-8")

            with patch.object(main, "SCAN_CACHE_FILE", cache_file), patch.object(
                main, "get_download_root", return_value=root_with_file
            ), patch.object(
                obsidian_sync, "get_download_root", return_value=root_with_file
            ), patch.object(
                obsidian_sync, "load_history", return_value={"downloaded_ids": {}, "seen_ids": {}}
            ), patch.object(
                main, "list_existing_subfolders", return_value=["Redes"]
            ), patch.object(
                main, "resolve_course_preferences",
                return_value={
                    "obsidian_folder": "Redes",
                    "target_subfolder": "Apuntes",
                    "organize_by_section": True,
                    "is_hidden": False,
                },
            ):
                res = self.client.post("/api/rescan-local")
                self.assertEqual(res.status_code, 200)
                data = res.json()
                self.assertEqual(data["summary"]["total_new_files"], 0)
                self.assertTrue(data["courses"][0]["items"][0]["is_downloaded"])


if __name__ == "__main__":
    unittest.main()

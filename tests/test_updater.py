import json
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from fastapi.testclient import TestClient

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import config  # noqa: E402
import main  # noqa: E402
from scraper import updater  # noqa: E402


class UpdaterLogicTests(unittest.TestCase):
    def test_parse_semver_variants(self):
        self.assertEqual(updater.parse_semver("v1.2.0"), (1, 2, 0))
        self.assertEqual(updater.parse_semver("1.2.0+3"), (1, 2, 0))
        self.assertEqual(updater.parse_semver("V2.10.4-rc1"), (2, 10, 4))
        self.assertEqual(updater.parse_semver(""), (0, 0, 0))

    def test_is_newer_version(self):
        self.assertTrue(updater.is_newer_version("v1.2.1", "1.2.0"))
        self.assertTrue(updater.is_newer_version("1.3.0+1", "1.2.0"))
        self.assertFalse(updater.is_newer_version("v1.2.0", "1.2.0"))
        self.assertFalse(updater.is_newer_version("1.1.9", "1.2.0"))

    def test_select_windows_asset_matches_package_mode(self):
        assets = [
            {
                "name": "Aula-Scrapt-Android.apk",
                "browser_download_url": "https://example.com/android.apk",
                "size": 25_000_000,
            },
            {
                "name": "Aula-Scrapt-Android-v7a.apk",
                "browser_download_url": "https://example.com/android-v7a.apk",
                "size": 22_000_000,
            },
            {
                "name": "Aula-Scrapt-Windows.exe",
                "browser_download_url": "https://example.com/Aula-Scrapt-Windows.exe",
                "size": 85_000_000,
            },
            {
                "name": "Aula-Scrapt-Windows.zip",
                "browser_download_url": "https://example.com/Aula-Scrapt-Windows.zip",
                "size": 95_000_000,
            },
        ]

        onefile_asset = updater.select_windows_asset(assets, "onefile")
        self.assertIsNotNone(onefile_asset)
        self.assertEqual(onefile_asset["name"], "Aula-Scrapt-Windows.exe")
        self.assertEqual(onefile_asset["kind"], "exe")

        onedir_asset = updater.select_windows_asset(assets, "onedir")
        self.assertIsNotNone(onedir_asset)
        self.assertEqual(onedir_asset["name"], "Aula-Scrapt-Windows.zip")
        self.assertEqual(onedir_asset["kind"], "zip")

        exe_only = [a for a in assets if a["name"].endswith(".exe")]
        fallback = updater.select_windows_asset(exe_only, "onedir")
        self.assertEqual(fallback["name"], "Aula-Scrapt-Windows.exe")

    def test_launch_windows_updater_flags_and_pyi_env_cleanup(self):
        import os
        import subprocess
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            app_dir = Path(tmp)
            staged = app_dir / "Aula-Scrapt-Windows.exe"
            staged.write_bytes(b"MZ" + b"\x00" * 1024)
            created_ps1 = []

            def fake_popen(cmd, **kwargs):
                ps1 = Path(cmd[-1])
                created_ps1.append((ps1, ps1.read_text(encoding="utf-8-sig"), kwargs))
                return Mock()

            with (
                patch.object(updater.sys, "frozen", True, create=True),
                patch.object(updater.sys, "executable", str(app_dir / "Aula-Scrapt-Windows.exe")),
                patch.object(updater, "APP_ROOT", app_dir),
                patch.object(updater, "can_write_to_app_dir", return_value=True),
                patch.object(updater.subprocess, "Popen", side_effect=fake_popen),
            ):
                info = updater.launch_windows_updater(staged)

            self.assertTrue(info["launched"])
            self.assertFalse(info["requires_elevation"])
            self.assertEqual(len(created_ps1), 1)
            ps1_path, script_text, popen_kwargs = created_ps1[0]
            ps1_path.unlink(missing_ok=True)

            flags = popen_kwargs.get("creationflags", 0)
            detached = getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
            no_window = getattr(subprocess, "CREATE_NO_WINDOW", 0x08000000)
            self.assertEqual(flags & detached, 0)
            self.assertEqual(flags & no_window, no_window)
            self.assertIn("Env:_MEIPASS2", script_text)
            self.assertIn("Env:_PYI_APPLICATION_HOME_DIR", script_text)
            self.assertIn("Env:_PYI_ARCHIVE_FILE", script_text)
            self.assertIn("Env:_PYI_PARENT_PROCESS_LEVEL", script_text)

    def test_launch_windows_updater_uac_calls_ctypes_and_handles_cancel(self):
        import tempfile

        with tempfile.TemporaryDirectory() as tmp:
            app_dir = Path(tmp)
            staged = app_dir / "Aula-Scrapt-Windows.exe"
            staged.write_bytes(b"MZ" + b"\x00" * 1024)
            fake_shell32 = Mock()
            fake_shell32.ShellExecuteW.return_value = 5  # UAC cancelado

            with (
                patch.object(updater.sys, "frozen", True, create=True),
                patch.object(updater.sys, "executable", str(app_dir / "Aula-Scrapt-Windows.exe")),
                patch.object(updater, "APP_ROOT", app_dir),
                patch.object(updater, "can_write_to_app_dir", return_value=False),
                patch.object(updater.ctypes.windll, "shell32", fake_shell32),
            ):
                with self.assertRaises(PermissionError):
                    updater.launch_windows_updater(staged)

            fake_shell32.ShellExecuteW.assert_called_once()
            script_leftover = list(
                Path(tempfile.gettempdir()).glob(f"aula_scrapt_updater_{updater.os.getpid()}.ps1")
            )
            self.assertEqual(script_leftover, [])


class UpdaterApiTests(unittest.TestCase):
    def setUp(self):
        self.client = TestClient(main.app)

    def test_settings_endpoint_exposes_app_info_and_updates_toggle(self):
        res = self.client.get("/api/settings")
        self.assertEqual(res.status_code, 200)
        payload = res.json()
        self.assertIn("app_info", payload)
        self.assertEqual(payload["app_info"]["current_version"], config.APP_VERSION)
        self.assertEqual(payload["app_info"]["repo"], config.GITHUB_REPO)
        self.assertIn("auto_check_updates", payload)

        original_auto = bool(payload["auto_check_updates"])
        try:
            upd = self.client.post(
                "/api/settings",
                json={"auto_check_updates": not original_auto},
            )
            self.assertEqual(upd.status_code, 200)
            res2 = self.client.get("/api/settings").json()
            self.assertEqual(res2["auto_check_updates"], not original_auto)
        finally:
            self.client.post(
                "/api/settings",
                json={"auto_check_updates": original_auto},
            )

    def test_updates_check_detects_new_release(self):
        fake_response = Mock()
        fake_response.status_code = 200
        fake_response.json.return_value = {
            "tag_name": "v9.9.9",
            "name": "Aula-Scrapt v9.9.9",
            "published_at": "2026-11-13T12:00:00Z",
            "body": "- Mejoras de prueba",
            "html_url": "https://github.com/OscarAcosta17/Aula-Scrapt/releases/tag/v9.9.9",
            "assets": [
                {
                    "name": "Aula-Scrapt-Windows.exe",
                    "browser_download_url": "https://github.com/OscarAcosta17/Aula-Scrapt/releases/download/v9.9.9/Aula-Scrapt-Windows.exe",
                    "size": 80 * 1024 * 1024,
                }
            ],
        }
        with patch("scraper.updater.requests.get", return_value=fake_response):
            res = self.client.get("/api/updates/check")

        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertTrue(data["ok"])
        self.assertTrue(data["update_available"])
        self.assertEqual(data["latest_version"], "9.9.9")
        self.assertEqual(data["asset"]["name"], "Aula-Scrapt-Windows.exe")

    def test_updates_check_handles_no_releases(self):
        fake_response = Mock()
        fake_response.status_code = 404
        with patch("scraper.updater.requests.get", return_value=fake_response):
            res = self.client.get("/api/updates/check")

        self.assertEqual(res.status_code, 200)
        data = res.json()
        self.assertTrue(data["ok"])
        self.assertTrue(data["no_releases"])
        self.assertFalse(data["update_available"])

    def test_updates_apply_rejects_non_https_url(self):
        res = self.client.post(
            "/api/updates/apply",
            json={
                "download_url": "http://insecure.example.com/Aula-Scrapt-Windows.exe",
                "asset_name": "Aula-Scrapt-Windows.exe",
                "size": 1000,
            },
        )
        # Puede responder 400 si no es frozen o SSE error si valida antes
        self.assertIn(res.status_code, (200, 400))
        if res.status_code == 200:
            lines = [
                line[6:]
                for line in res.text.splitlines()
                if line.startswith("data: ")
            ]
            events = [json.loads(line) for line in lines]
            self.assertTrue(any(e.get("event") == "error" for e in events))


if __name__ == "__main__":
    unittest.main()

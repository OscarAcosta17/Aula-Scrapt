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

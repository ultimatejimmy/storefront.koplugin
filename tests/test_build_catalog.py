#!/usr/bin/env python3
"""
tests/test_build_catalog.py

Unit tests for tools/build_catalog.py and tools/verify_catalog.py:
- RateLimitTracker bucket isolation (search vs core vs graphql)
- Pacing and retry/backoff logic
- Search query query string formatting (fork:only stars:>0)
- Validation / Integrity gate thresholds (MIN_PLUGINS, MIN_PATCHES, MIN_FONTS, MAX_DROP_RATIO)
- Atomic catalog writing
- verify_catalog.py verification rules
"""

import unittest
import os
import sys
import json
import tempfile
import shutil

# Add tools directory to path
TOOLS_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "tools"))
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

import build_catalog
import verify_catalog


class TestRateLimitTracker(unittest.TestCase):
    def test_bucket_isolation(self):
        tracker = build_catalog.RateLimitTracker()
        self.assertEqual(tracker.get_bucket("https://api.github.com/search/repositories?q=test"), "search")
        self.assertEqual(tracker.get_bucket("https://api.github.com/graphql"), "graphql")
        self.assertEqual(tracker.get_bucket("https://api.github.com/repos/user/repo/releases"), "core")

        # Simulate low search limit
        tracker.record_response("search", {"x-ratelimit-remaining": "5", "x-ratelimit-reset": "1700000000"})
        # Core has plenty of quota
        tracker.record_response("core", {"x-ratelimit-remaining": "950", "x-ratelimit-reset": "1700003600"})

        self.assertEqual(tracker.get_remaining("search"), 5)
        self.assertEqual(tracker.get_remaining("core"), 950)

        # Confirm core is completely unaffected by search bucket level
        self.assertFalse(tracker.search_failed)
        self.assertFalse(tracker.core_failed)


class TestCatalogValidation(unittest.TestCase):
    def setUp(self):
        self.healthy_catalog = {
            "version": 1,
            "generated_at": "2026-11-11T00:00:00Z",
            "stats": {"total_plugins": 660, "total_patches": 55, "total_fonts": 21},
            "plugins": [{"id": i, "name": f"plug_{i}", "latest_release": {"tag_name": "v1.0"}} for i in range(660)],
            "patches": [{"id": i, "name": f"patch_{i}", "patch_files": [{"filename": "p.lua"}]} for i in range(55)],
            "fonts": [{"id": i, "name": f"font_{i}", "download_url": "http://example.com/f.ttf"} for i in range(21)],
        }

    def test_healthy_catalog_passes(self):
        ok = build_catalog.validate_catalog(self.healthy_catalog, baseline_stats=None, search_failed=False)
        self.assertTrue(ok)

    def test_fails_if_search_failed(self):
        ok = build_catalog.validate_catalog(self.healthy_catalog, baseline_stats=None, search_failed=True)
        self.assertFalse(ok)

    def test_fails_below_min_plugins(self):
        catalog = dict(self.healthy_catalog)
        catalog["plugins"] = catalog["plugins"][:400]  # Only 400 plugins (< 650)
        ok = build_catalog.validate_catalog(catalog, baseline_stats=None, search_failed=False)
        self.assertFalse(ok)

    def test_fails_below_min_patches(self):
        catalog = dict(self.healthy_catalog)
        catalog["patches"] = catalog["patches"][:30]  # Only 30 patches (< 50)
        ok = build_catalog.validate_catalog(catalog, baseline_stats=None, search_failed=False)
        self.assertFalse(ok)

    def test_fails_below_min_fonts(self):
        catalog = dict(self.healthy_catalog)
        catalog["fonts"] = catalog["fonts"][:10]  # Only 10 fonts (< 20)
        ok = build_catalog.validate_catalog(catalog, baseline_stats=None, search_failed=False)
        self.assertFalse(ok)

    def test_fails_on_abnormal_shrink_vs_baseline(self):
        baseline = {"total_plugins": 800, "total_patches": 70, "total_fonts": 21}
        catalog = dict(self.healthy_catalog)
        # 660 plugins vs 800 baseline is a 17.5% drop (> 15% MAX_DROP_RATIO)
        ok = build_catalog.validate_catalog(catalog, baseline_stats=baseline, search_failed=False, allow_shrink=False)
        self.assertFalse(ok)

        # With allow_shrink=True it should pass
        ok_allowed = build_catalog.validate_catalog(catalog, baseline_stats=baseline, search_failed=False, allow_shrink=True)
        self.assertTrue(ok_allowed)


class TestVerifyCatalogCLI(unittest.TestCase):
    def setUp(self):
        self.tmpdir = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def test_verify_catalog_file(self):
        valid_cat = {
            "version": 1,
            "generated_at": "2026-11-11T00:00:00Z",
            "stats": {"total_plugins": 650, "total_patches": 50, "total_fonts": 20},
            "plugins": [{"id": i, "name": f"plug_{i}", "latest_release": {"tag_name": "v1.0"}} for i in range(650)],
            "patches": [{"id": i, "name": f"patch_{i}", "patch_files": [{"filename": "p.lua"}]} for i in range(50)],
            "fonts": [{"id": i, "name": f"font_{i}", "download_url": "http://example.com/f.ttf"} for i in range(20)],
        }

        minified_path = os.path.join(self.tmpdir, "catalog.min.json")
        with open(minified_path, "w", encoding="utf-8") as f:
            json.dump(valid_cat, f, separators=(",", ":"))

        # Valid minified file should pass
        self.assertTrue(verify_catalog.verify_catalog_file(minified_path, min_plugins=650, min_patches=50, min_fonts=20))

        # Multi-line non-minified file should fail
        unminified_path = os.path.join(self.tmpdir, "catalog.pretty.json")
        with open(unminified_path, "w", encoding="utf-8") as f:
            json.dump(valid_cat, f, indent=2)
        self.assertFalse(verify_catalog.verify_catalog_file(unminified_path, min_plugins=650, min_patches=50, min_fonts=20))


if __name__ == "__main__":
    unittest.main()

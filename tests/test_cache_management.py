import os
import unittest
import pathlib

class TestCacheManagement(unittest.TestCase):
    def setUp(self):
        self.base_dir = pathlib.Path(__file__).parents[1] / "storefront.koplugin"

    def test_files_exist(self):
        dialog_file = self.base_dir / "storefront_clear_cache_dialog.lua"
        self.assertTrue(dialog_file.exists(), "storefront_clear_cache_dialog.lua must exist")
        limit_file = self.base_dir / "storefront_cache_limit.lua"
        self.assertTrue(limit_file.exists(), "storefront_cache_limit.lua must exist")

    def test_cache_limit_exports(self):
        content = (self.base_dir / "storefront_cache_limit.lua").read_text(encoding="utf-8")
        self.assertIn("function StorefrontCacheLimit.getLimitMB()", content)
        self.assertIn("function StorefrontCacheLimit.setLimitMB(mb)", content)
        self.assertIn("function StorefrontCacheLimit.nextPreset(current_mb)", content)
        self.assertIn("function StorefrontCacheLimit.enforce(force, override_mb, override_age)", content)
        self.assertIn("function StorefrontCacheLimit.collectFiles(roots, protected_keys)", content)
        self.assertIn("DEFAULT_MB = 100", content)
        self.assertIn("MAX_AGE_DAYS = 30", content)

    def test_repo_content_delegates_to_cache_limit(self):
        content = (self.base_dir / "storefront_repo_content.lua").read_text(encoding="utf-8")
        self.assertIn("storefront_cache_limit", content)
        self.assertIn("StorefrontCacheLimit.enforce", content)

    def test_repo_content_exports(self):
        content = (self.base_dir / "storefront_repo_content.lua").read_text(encoding="utf-8")
        self.assertIn("function RepoContent.getReadmeCacheStats()", content)
        self.assertIn("function RepoContent.clearReadmeCache()", content)
        self.assertIn("function RepoContent.getWikiCacheStats()", content)
        self.assertIn("function RepoContent.clearWikiCache()", content)

    def test_screensavers_ui_exports(self):
        content = (self.base_dir / "storefront_screensavers_ui.lua").read_text(encoding="utf-8")
        self.assertIn("function StorefrontScreensavers.getThumbnailsCacheStats()", content)
        self.assertIn("function StorefrontScreensavers.clearThumbnailsCache()", content)

    def test_settings_card_renames_and_triggers(self):
        content = (self.base_dir / "storefront_settings_card.lua").read_text(encoding="utf-8")
        self.assertIn('Refresh catalog', content)
        self.assertIn('Clear cache…', content)
        self.assertIn('Cache limit', content)
        self.assertIn('storefront_clear_cache_dialog', content)
        self.assertIn('storefront_cache_limit', content)

    def test_active_screensaver_protection(self):
        ui_content = (self.base_dir / "storefront_screensavers_ui.lua").read_text(encoding="utf-8")
        self.assertIn("getActiveScreensaverIdentifiers", ui_content)
        self.assertIn("protected_keys[entry_lower]", ui_content)
        self.assertIn("protected_count", ui_content)

        mgr_content = (self.base_dir / "storefront_screensaver_mgr.lua").read_text(encoding="utf-8")
        self.assertIn("function StorefrontScreensaverMgr.getActiveScreensaverIdentifiers()", mgr_content)
        self.assertIn("function StorefrontScreensaverMgr.countLocalScreensavers(custom_dir)", mgr_content)

        dialog_content = (self.base_dir / "storefront_clear_cache_dialog.lua").read_text(encoding="utf-8")
        self.assertIn("active preserved", dialog_content)
        self.assertIn("active thumbnails preserved", dialog_content)

if __name__ == "__main__":
    unittest.main()


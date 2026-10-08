import os
import unittest
import pathlib

class TestCacheManagement(unittest.TestCase):
    def setUp(self):
        self.base_dir = pathlib.Path(__file__).parents[1] / "storefront.koplugin"

    def test_files_exist(self):
        dialog_file = self.base_dir / "storefront_clear_cache_dialog.lua"
        self.assertTrue(dialog_file.exists(), "storefront_clear_cache_dialog.lua must exist")

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
        self.assertIn('storefront_clear_cache_dialog', content)

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


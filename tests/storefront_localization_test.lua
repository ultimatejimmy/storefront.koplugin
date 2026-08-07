-- Unit and Integration tests for Storefront Localization System

local script_dir = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
package.path = script_dir .. "../storefront.koplugin/?.lua;" .. script_dir .. "?.lua;" .. package.path

require("spec_helper")

local function runTests()
    print("==================================================")
    print("  RUNNING STOREFRONT LOCALIZATION TEST SUITE      ")
    print("==================================================")

    local passed = 0
    local failed = 0

    local function assertTest(condition, name, msg)
        if condition then
            passed = passed + 1
            print(" [PASS] " .. name)
        else
            failed = failed + 1
            print(" [FAIL] " .. name .. (msg and (" - " .. tostring(msg)) or ""))
        end
    end

    local Localization = require("localization_storefront")

    -- ----------------------------------------------------
    -- TEST 1: PO Parser & Language Discovery
    -- ----------------------------------------------------
    print("\n--- TEST 1: PO Parser & Language Discovery ---")
    
    local path = script_dir .. "../storefront.koplugin/storefront.koplugin"
    local f_check = io.open(path .. "/languages/en.po", "r")
    if f_check then
        f_check:close()
    else
        path = script_dir .. "../storefront.koplugin"
    end
    Localization:init(path)

    assertTest(#Localization.available_languages == 18, "Discovered 18 Languages", "Found " .. tostring(#Localization.available_languages))
    assertTest(Localization:languageExists("en"), "Language 'en' Exists")
    assertTest(Localization:languageExists("de"), "Language 'de' Exists")
    assertTest(Localization:languageExists("es"), "Language 'es' Exists")
    assertTest(Localization:languageExists("fr"), "Language 'fr' Exists")
    assertTest(Localization:languageExists("zh_CN"), "Language 'zh_CN' Exists")
    assertTest(Localization:languageExists("pt_br"), "Language 'pt_br' Exists")

    -- ----------------------------------------------------
    -- TEST 2: System Language Detection & Normalization
    -- ----------------------------------------------------
    print("\n--- TEST 2: System Language Auto-Detection ---")

    _G.G_reader_settings = {
        readSetting = function(self, key)
            if key == "language" then return "es_ES" end
            return nil
        end
    }
    local detected_es = Localization:detectSystemLanguage()
    assertTest(detected_es == "es", "Detects KOReader Spanish 'es_ES' System Language", "Got: " .. tostring(detected_es))

    _G.G_reader_settings = {
        readSetting = function(self, key)
            if key == "language" then return "de" end
            return nil
        end
    }
    local detected_de = Localization:detectSystemLanguage()
    assertTest(detected_de == "de", "Detects KOReader German System Language", "Got: " .. tostring(detected_de))

    _G.G_reader_settings = {
        readSetting = function(self, key)
            if key == "language" then return "zh_CN" end
            return nil
        end
    }
    local detected_zh = Localization:detectSystemLanguage()
    assertTest(detected_zh == "zh_CN", "Detects KOReader Simplified Chinese System Language", "Got: " .. tostring(detected_zh))

    _G.G_reader_settings = {
        readSetting = function(self, key)
            if key == "language" then return "pt_BR" end
            return nil
        end
    }
    local detected_pt = Localization:detectSystemLanguage()
    assertTest(detected_pt == "pt_br", "Normalizes 'pt_BR' to 'pt_br'", "Got: " .. tostring(detected_pt))

    _G.G_reader_settings = {
        readSetting = function(self, key)
            if key == "language" then return "unknown_xyz" end
            return nil
        end
    }
    local detected_unk = Localization:detectSystemLanguage()
    assertTest(detected_unk == "en", "Falls back to 'en' for unknown system language", "Got: " .. tostring(detected_unk))

    -- Restore default english
    _G.G_reader_settings = nil

    -- ----------------------------------------------------
    -- TEST 3: String Lookup & Formatting
    -- ----------------------------------------------------
    print("\n--- TEST 3: Translation Lookup & String Formatting ---")

    Localization.current_language = "en"
    Localization:loadTranslations()

    local str_title = Localization:t("storefront_title")
    assertTest(str_title == "Storefront", "Lookup 'storefront_title'", "Got: " .. tostring(str_title))

    local str_install = Localization:t("confirm_install", "TestPlugin")
    assertTest(str_install == "Install 'TestPlugin'?", "Format Specifier %s Injection", "Got: " .. tostring(str_install))

    local str_update = Localization:t("confirm_update", "TestPlugin", "1.0", "2.0")
    assertTest(str_update == "Update 'TestPlugin' from v1.0 to v2.0?", "Multi-Argument Format Specifiers", "Got: " .. tostring(str_update))

    -- Quoted msgids must unescape correctly so install notifications do not
    -- fall back to English in translated locales.
    Localization.current_language = "es"
    Localization:loadTranslations()
    local str_es_install = Localization:t("Installed plugin \"%s\" (version %s).", "koinsight", "0.2.3")
    assertTest(str_es_install == "Conector \"koinsight\" (versión 0.2.3) instalado.", "Spanish quoted install notification", "Got: " .. tostring(str_es_install))

    -- Test German translation loading
    Localization.current_language = "de"
    Localization:loadTranslations()
    local str_de_install = Localization:t("btn_install")
    assertTest(str_de_install == "Installieren", "German Translation 'btn_install'", "Got: " .. tostring(str_de_install))

    -- Test French translation loading
    Localization.current_language = "fr"
    Localization:loadTranslations()
    local str_fr_cancel = Localization:t("btn_cancel")
    assertTest(str_fr_cancel == "Annuler", "French Translation 'btn_cancel'", "Got: " .. tostring(str_fr_cancel))

    -- ----------------------------------------------------
    -- TEST 4: Fallback to English Master & Hardcoded Table
    -- ----------------------------------------------------
    print("\n--- TEST 4: Missing Key Fallback ---")

    Localization.current_language = "de"
    Localization:loadTranslations()
    
    local fallback_val = Localization:t("non_existent_key_test")
    assertTest(fallback_val == "non_existent_key_test", "Returns key name for completely missing key", "Got: " .. tostring(fallback_val))

    -- ----------------------------------------------------
    -- TEST 5: Windows CRLF Line Endings & Trailing Whitespace
    -- ----------------------------------------------------
    print("\n--- TEST 5: CRLF & Trailing Whitespace Regression ---")

    local tmp_po_path = script_dir .. "test_crlf_sample.po"
    local f_tmp = io.open(tmp_po_path, "w")
    if f_tmp then
        f_tmp:write("msgid \"crlf_key\"\r\nmsgstr \"crlf_val\"\r\n\r\nmsgid \"space_key\"   \r\nmsgstr \"space_val\"   \r\n")
        f_tmp:close()

        local parsed = Localization:parsePO(tmp_po_path)
        os.remove(tmp_po_path)

        assertTest(parsed ~= nil, "CRLF PO File Parsed Successfully")
        assertTest(parsed and parsed["crlf_key"] == "crlf_val", "Parses msgid/msgstr with Windows CRLF \\r\\n", "Got: " .. tostring(parsed and parsed["crlf_key"]))
        assertTest(parsed and parsed["space_key"] == "space_val", "Parses msgid/msgstr with trailing spaces", "Got: " .. tostring(parsed and parsed["space_key"]))
    else
        print(" [WARN] Could not create temp CRLF test file")
    end

    -- ----------------------------------------------------
    -- TEST 6: All Discovered Languages Translation Load Check
    -- ----------------------------------------------------
    print("\n--- TEST 6: General Translation Load Check Across All Languages ---")

    Localization:init(path)
    assertTest(Localization:languageExists("ko"), "Korean 'ko' language exists in discovered languages")

    for _, lang in ipairs(Localization.available_languages) do
        Localization.current_language = lang
        Localization:loadTranslations()

        local count = Localization:tableSize(Localization.translations)
        assertTest(count > 0, string.format("Language '%s' loaded translations (%d keys)", lang, count), "Loaded 0 keys")
        
        local title = Localization:t("storefront_title")
        assertTest(type(title) == "string" and #title > 0, string.format("Language '%s' translates 'storefront_title'", lang))
    end

    print("\n==================================================")
    print("  STOREFRONT LOCALIZATION TEST SUITE COMPLETE     ")
    print(string.format("  Passed: %d, Failed: %d", passed, failed))
    print("==================================================")

    if failed > 0 then
        error(string.format("Localization test suite failed with %d errors.", failed))
    end
end

runTests()

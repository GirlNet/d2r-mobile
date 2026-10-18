// Host language settings: language IDs/code layout follow the public libnx
// SetLanguage enum. These public SDK wrappers otherwise open Horizon's set service.
// https://github.com/switchbrew/libnx/blob/master/nx/include/switch/services/set.h
#include "hle.h"

static const char language_codes[][8] = {
    "ja", "en-US", "fr", "de", "it", "es", "zh-CN", "ko", "nl",
    "pt", "ru", "zh-TW", "en-GB", "fr-CA", "es-419", "zh-Hans", "zh-Hant", "pt-BR"
};
enum { LANGUAGE_COUNT = sizeof language_codes / sizeof language_codes[0] };

static uint64_t language_code(int language) {
    if (language < 0 || language >= LANGUAGE_COUNT) die("Unsupported language enum: %d", language);
    uint64_t code; memcpy(&code, language_codes[language], sizeof code); return code;
}
HLE_FORCE_OPTIONAL("_ZN2nn8settings12LanguageCode4MakeENS0_8LanguageE",
    "Host language code mapping; no settings service IPC", uint64_t, h_settings_MakeCode, int language) {
    return language_code(language);
}
HLE_FORCE_OPTIONAL("_ZN2nn8settings25GetAvailableLanguageCodesEPNS0_12LanguageCodeEi",
    "Host supported language roster; bounded eight-byte output entries", int, h_settings_Available, void *output, int capacity) {
    if (!output || capacity <= 0) return 0;
    int count = capacity < LANGUAGE_COUNT ? capacity : LANGUAGE_COUNT;
    memcpy(output, language_codes, (size_t)count * 8); return count;
}
static unsigned language_equal(const int *language, const void *code) {
    if (!language || !code || *language < 0 || *language >= LANGUAGE_COUNT) return 0;
    return !memcmp(code, language_codes[*language], 8);
}
HLE_FORCE_OPTIONAL("_ZN2nn8settingseqERKNS0_8LanguageERKNS0_12LanguageCodeE",
    "Compare host language enum/code without SDK settings cache initialization", unsigned, h_settings_EqualLanguage, const int *language, const void *code) {
    return language_equal(language, code);
}
HLE_FORCE_OPTIONAL("_ZN2nn8settingseqERKNS0_12LanguageCodeERKNS0_8LanguageE",
    "Compare host language code/enum without SDK settings cache initialization", unsigned, h_settings_EqualCode, const void *code, const int *language) {
    return language_equal(language, code);
}

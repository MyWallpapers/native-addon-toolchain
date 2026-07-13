#include <mywallpaper_windhawk.hpp>

BOOL Wh_ModInit() {
    Wh_Log(L"MyWallpaper native hook build smoke loaded");
    return TRUE;
}

void Wh_ModAfterInit() {
    mywallpaper::windhawk::emit_event("smoke.ready", R"({"ready":true})");
}

void Wh_ModSettingsChanged() {
    const auto settings = mywallpaper::windhawk::settings_json();
    const auto revision = mywallpaper::windhawk::setting_int(L"revision");
    Wh_Log(L"MyWallpaper settings updated (%zu UTF-8 bytes)", settings.size());
    const auto payload = std::string(R"({"revision":)") + std::to_string(revision) +
                         R"(,"settings":)" + settings + "}";
    mywallpaper::windhawk::emit_event("smoke.settings", payload);
}

void Wh_ModUninit() {
    mywallpaper::windhawk::emit_event("smoke.unload", R"({"clean":true})");
    Wh_Log(L"MyWallpaper native hook build smoke unloaded");
}

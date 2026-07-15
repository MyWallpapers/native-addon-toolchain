#include <mywallpaper_settings.hpp>
#include <mywallpaper_windhawk.hpp>

BOOL Wh_ModInit() {
    Wh_Log(L"MyWallpaper native hook build smoke loaded");
    return TRUE;
}

void Wh_ModAfterInit() {
    mywallpaper::windhawk::emit_event("mywallpaper.smoke/v1/ready", R"({"ready":true})");
}

void Wh_ModSettingsChanged() {
    const auto settings = mywallpaper::settings::json();
    const auto revision = mywallpaper::settings::get_revision();
    Wh_Log(L"MyWallpaper settings updated (%zu UTF-8 bytes)", settings.size());
    const auto payload = std::string(R"({"revision":)") + std::to_string(revision) +
                         R"(,"settings":)" + settings + "}";
    mywallpaper::windhawk::emit_event("mywallpaper.smoke/v1/settings", payload);
}

void Wh_ModUninit() {
    mywallpaper::windhawk::emit_event("mywallpaper.smoke/v1/unload", R"({"clean":true})");
    Wh_Log(L"MyWallpaper native hook build smoke unloaded");
}

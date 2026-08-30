#include <windows.h>
// ==WindhawkMod==
// @id              build-smoke
// @name            MyWallpaper native hook build smoke
// @description     Exercises the official Windhawk build and bundle pipeline.
// @version         1.0.0
// @author          MyWallpaper
// @include         explorer.exe
// ==/WindhawkMod==

BOOL Wh_ModInit() {
    Wh_Log(L"MyWallpaper native hook build smoke loaded");
    return TRUE;
}

void Wh_ModAfterInit() {
    Wh_Log(L"MyWallpaper native hook build smoke ready");
}

void Wh_ModSettingsChanged() {
    const int revision = Wh_GetIntSetting(L"revision");
    Wh_Log(L"MyWallpaper settings updated (revision %d)", revision);
}

void Wh_ModUninit() {
    Wh_Log(L"MyWallpaper native hook build smoke unloaded");
}

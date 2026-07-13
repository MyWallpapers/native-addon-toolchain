// SPDX-License-Identifier: MIT
// Copyright (c) MyWallpaper contributors

#pragma once

// Header-only client for the MyWallpaper Windhawk protocol.
// Add-on settings use Windhawk's native settings store, so
// Wh_ModSettingsChanged is called without polling. Only bounded hook events
// cross the authenticated named pipe.

#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "windhawk_api.h"

namespace mywallpaper::windhawk {

inline constexpr std::uint32_t protocol_version = 1;
inline constexpr wchar_t hook_key_setting[] = L"__mywallpaper_hook_key";
inline constexpr wchar_t pipe_name_setting[] = L"__mywallpaper_pipe_name";
inline constexpr wchar_t nonce_setting[] = L"__mywallpaper_nonce";
inline constexpr wchar_t settings_json_setting[] = L"__mywallpaper_settings_json";
inline constexpr std::size_t max_event_bytes = 64 * 1024;
inline constexpr std::size_t max_topic_bytes = 128;
inline constexpr std::size_t max_queued_events = 64;

namespace detail {

inline std::wstring setting_or(PCWSTR key, std::wstring_view fallback = {}) {
    PCWSTR value = Wh_GetStringSetting(key);
    std::wstring result = value && *value ? value : std::wstring(fallback);
    if (value) {
        Wh_FreeStringSetting(value);
    }
    return result;
}

inline std::string wide_to_utf8(std::wstring_view input) {
    if (input.empty()) {
        return {};
    }
    const int size = WideCharToMultiByte(
        CP_UTF8, WC_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()),
        nullptr, 0, nullptr, nullptr);
    if (size <= 0) {
        return {};
    }
    std::string output(static_cast<std::size_t>(size), '\0');
    if (WideCharToMultiByte(
            CP_UTF8, WC_ERR_INVALID_CHARS, input.data(), static_cast<int>(input.size()),
            output.data(), size, nullptr, nullptr) != size) {
        return {};
    }
    return output;
}

inline std::string json_escape(std::string_view input) {
    constexpr char hex[] = "0123456789abcdef";
    std::string output;
    output.reserve(input.size() + 8);
    for (unsigned char value : input) {
        switch (value) {
            case '"': output += "\\\""; break;
            case '\\': output += "\\\\"; break;
            case '\b': output += "\\b"; break;
            case '\f': output += "\\f"; break;
            case '\n': output += "\\n"; break;
            case '\r': output += "\\r"; break;
            case '\t': output += "\\t"; break;
            default:
                if (value < 0x20) {
                    output += "\\u00";
                    output += hex[value >> 4];
                    output += hex[value & 0x0f];
                } else {
                    output += static_cast<char>(value);
                }
        }
    }
    return output;
}

inline void send_event(std::string_view request) {
    const std::wstring pipe = setting_or(pipe_name_setting);
    if (pipe.empty() || request.empty() || request.size() > max_event_bytes) {
        return;
    }
    std::string framed_request(request.size() + 4, '\0');
    const auto length = static_cast<std::uint32_t>(request.size());
    framed_request[0] = static_cast<char>(length & 0xff);
    framed_request[1] = static_cast<char>((length >> 8) & 0xff);
    framed_request[2] = static_cast<char>((length >> 16) & 0xff);
    framed_request[3] = static_cast<char>((length >> 24) & 0xff);
    request.copy(framed_request.data() + 4, request.size());
    std::array<char, 64> response{};
    DWORD bytes_read = 0;
    CallNamedPipeW(
        pipe.c_str(), framed_request.data(),
        static_cast<DWORD>(framed_request.size()), response.data(),
        static_cast<DWORD>(response.size()), &bytes_read, 250);
}

inline std::string next_event_id() {
    static std::atomic<std::uint64_t> sequence{0};
    return std::to_string(GetCurrentProcessId()) + "-" +
           std::to_string(GetTickCount64()) + "-" +
           std::to_string(sequence.fetch_add(1, std::memory_order_relaxed));
}

}  // namespace detail

inline std::wstring setting_string(PCWSTR name, std::wstring_view fallback = {}) {
    return detail::setting_or(name, fallback);
}

inline int setting_int(PCWSTR name, int fallback = 0) {
    return Wh_GetIntSetting(name, fallback);
}

inline bool setting_bool(PCWSTR name, bool fallback = false) {
    return setting_int(name, fallback ? 1 : 0) != 0;
}

inline std::string settings_json() {
    return detail::wide_to_utf8(detail::setting_or(settings_json_setting, L"{}"));
}

namespace detail {

struct event_queue {
    std::mutex mutex;
    std::array<std::string, max_queued_events> requests;
    std::size_t head = 0;
    std::size_t count = 0;
    bool worker_running = false;
};

inline event_queue& queued_events() {
    static event_queue queue;
    return queue;
}

inline DWORD WINAPI drain_queued_events(void* module_handle) {
    const auto module = static_cast<HMODULE>(module_handle);
    auto& queue = queued_events();
    for (;;) {
        std::string request;
        bool finished = false;
        {
            std::lock_guard lock(queue.mutex);
            if (queue.count == 0) {
                queue.worker_running = false;
                finished = true;
            } else {
                request = std::move(queue.requests[queue.head]);
                queue.requests[queue.head].clear();
                queue.head = (queue.head + 1) % max_queued_events;
                --queue.count;
            }
        }
        if (finished) {
            FreeLibraryAndExitThread(module, 0);
        }
        send_event(request);
    }
}

inline bool enqueue_event(std::string request) {
    auto& queue = queued_events();
    bool start_worker = false;
    {
        std::lock_guard lock(queue.mutex);
        if (queue.count == max_queued_events) {
            return false;
        }
        const auto tail = (queue.head + queue.count) % max_queued_events;
        queue.requests[tail] = std::move(request);
        ++queue.count;
        if (!queue.worker_running) {
            queue.worker_running = true;
            start_worker = true;
        }
    }
    if (!start_worker) {
        return true;
    }
    HMODULE module = nullptr;
    if (!GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,
            reinterpret_cast<LPCWSTR>(&drain_queued_events),
            &module)) {
        module = nullptr;
    }
    HANDLE worker = module
        ? CreateThread(nullptr, 0, drain_queued_events, module, 0, nullptr)
        : nullptr;
    if (worker) {
        CloseHandle(worker);
        return true;
    }
    if (module) {
        FreeLibrary(module);
    }
    std::lock_guard lock(queue.mutex);
    queue.worker_running = false;
    queue.head = 0;
    queue.count = 0;
    for (auto& queued : queue.requests) {
        queued.clear();
    }
    return false;
}

}  // namespace detail

inline bool emit_event(std::string_view topic, std::string_view json_payload) {
    const std::string hook_key = detail::wide_to_utf8(detail::setting_or(hook_key_setting));
    const std::string nonce = detail::wide_to_utf8(detail::setting_or(nonce_setting));
    if (hook_key.empty() || nonce.empty() || topic.empty() ||
        topic.size() > max_topic_bytes || json_payload.empty()) {
        return false;
    }
    const std::string event_id = detail::next_event_id();
    std::string request =
        R"({"kind":"emit-event","protocolVersion":)" +
        std::to_string(protocol_version) + R"(,"hookKey":")" +
        detail::json_escape(hook_key) + R"(","eventId":")" +
        detail::json_escape(event_id) + R"(","topic":")" +
        detail::json_escape(topic) + R"(","payload":)" +
        std::string(json_payload) + R"(,"nonce":")" +
        detail::json_escape(nonce) + R"("})";
    if (request.size() > max_event_bytes) {
        return false;
    }
    return detail::enqueue_event(std::move(request));
}

}  // namespace mywallpaper::windhawk

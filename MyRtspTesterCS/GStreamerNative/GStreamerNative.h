#pragma once

#include <cstdint>

#ifdef GSTREAMERNATIVE_EXPORTS
#define GSTREAMERNATIVE_API __declspec(dllexport)
#else
#define GSTREAMERNATIVE_API __declspec(dllimport)
#endif

extern "C" {

struct GstPlayerFrameInfo {
    std::uint32_t width;
    std::uint32_t height;
    std::uint32_t stride;
    std::uint32_t frameRateNumerator;
    std::uint32_t frameRateDenominator;
    std::uint64_t sequence;
};

struct GstPlayerEvent {
    std::int32_t type;
    std::int32_t oldState;
    std::int32_t newState;
    std::uint32_t width;
    std::uint32_t height;
    std::uint32_t frameRateNumerator;
    std::uint32_t frameRateDenominator;
    char message[512];
};

GSTREAMERNATIVE_API void* gst_player_create();
GSTREAMERNATIVE_API std::int32_t gst_player_start(void* player, const char* url, std::uint32_t latencyMilliseconds);
GSTREAMERNATIVE_API void gst_player_stop(void* player);
GSTREAMERNATIVE_API void gst_player_destroy(void* player);
GSTREAMERNATIVE_API std::int32_t gst_player_copy_latest_frame(
    void* player, std::uint8_t* destination, std::uint64_t capacity, GstPlayerFrameInfo* info);
GSTREAMERNATIVE_API std::int32_t gst_player_poll_event(void* player, GstPlayerEvent* event);

}
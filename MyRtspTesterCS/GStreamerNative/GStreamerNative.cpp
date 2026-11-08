#include "GStreamerNative.h"

#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>

#include <algorithm>
#include <array>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <new>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

namespace {

enum EventType : std::int32_t {
    EventStateChanged = 1,
    EventWarning = 2,
    EventError = 3,
    EventEndOfStream = 4,
    EventVideoInfo = 5
};

std::once_flag g_gstreamerInit;

class Player final {
public:
    Player() {
        std::call_once(g_gstreamerInit, [] { gst_init(nullptr, nullptr); });
    }

    ~Player() {
        Stop();
    }

    std::int32_t Start(const char* url, std::uint32_t latency) {
        if (url == nullptr || *url == '\0') {
            PushEvent(EventError, "An RTSP URL is required.");
            return -1;
        }

        std::lock_guard<std::mutex> guard(_lifecycleMutex);
        if (_closed)
            return -1;
        StopPipeline();
        ClearLatestFrame();

        GstElement* pipeline = gst_pipeline_new("rtsp-camera-player");
        GstElement* source = gst_element_factory_make("rtspsrc", "rtsp-source");
        GstElement* depay = gst_element_factory_make("rtph264depay", "h264-depay");
        GstElement* parser = gst_element_factory_make("h264parse", "h264-parser");
        GstElement* decoder = gst_element_factory_make("avdec_h264", "h264-decoder");
        GstElement* convert = gst_element_factory_make("videoconvert", "video-converter");
        GstElement* capsFilter = gst_element_factory_make("capsfilter", "bgra-filter");
        GstElement* queue = gst_element_factory_make("queue", "latest-frame-queue");
        GstElement* sink = gst_element_factory_make("appsink", "frame-sink");

        if (pipeline == nullptr || source == nullptr || depay == nullptr || parser == nullptr ||
            decoder == nullptr || convert == nullptr || capsFilter == nullptr || queue == nullptr || sink == nullptr) {
            if (pipeline != nullptr) gst_object_unref(pipeline);
            for (GstElement* element : { source, depay, parser, decoder, convert, capsFilter, queue, sink }) {
                if (element != nullptr) gst_object_unref(element);
            }
            PushEvent(EventError, "A required GStreamer element is unavailable.");
            return -1;
        }

        g_object_set(source,
            "location", url,
            "protocols", 4,
            "latency", latency,
            "drop-on-latency", TRUE,
            nullptr);
        g_object_set(queue,
            "max-size-buffers", 1,
            "max-size-bytes", 0,
            "max-size-time", static_cast<guint64>(0),
            "leaky", 2,
            nullptr);
        g_object_set(sink,
            "emit-signals", FALSE,
            "sync", FALSE,
            "async", FALSE,
            "enable-last-sample", FALSE,
            "max-buffers", 1u,
            "leaky-type", 2,
            nullptr);

        GstCaps* caps = gst_caps_from_string("video/x-raw,format=BGRA");
        g_object_set(capsFilter, "caps", caps, nullptr);
        gst_caps_unref(caps);

        gst_bin_add_many(GST_BIN(pipeline), source, depay, parser, decoder, convert, capsFilter, queue, sink, nullptr);
        if (!gst_element_link_many(depay, parser, decoder, convert, capsFilter, queue, sink, nullptr)) {
            gst_object_unref(pipeline);
            PushEvent(EventError, "Could not link the H.264 decode pipeline.");
            return -1;
        }

        GstAppSinkCallbacks callbacks{};
        callbacks.new_sample = &Player::OnNewSample;
        gst_app_sink_set_callbacks(GST_APP_SINK(sink), &callbacks, this, nullptr);
        g_signal_connect(source, "pad-added", G_CALLBACK(&Player::OnRtspPadAdded), depay);

        GstBus* bus = gst_element_get_bus(pipeline);
        if (bus == nullptr) {
            gst_object_unref(pipeline);
            PushEvent(EventError, "Could not acquire the GStreamer bus.");
            return -1;
        }

        _pipeline = pipeline;
        _bus = bus;
        _busStop = false;
        _busThread = std::thread(&Player::BusLoop, this, bus);
        PushEvent(EventStateChanged, "Connecting to RTSP camera.", GST_STATE_NULL, GST_STATE_READY);

        const GstStateChangeReturn result = gst_element_set_state(pipeline, GST_STATE_PLAYING);
        if (result == GST_STATE_CHANGE_FAILURE) {
            PushEvent(EventError, "GStreamer could not start the RTSP pipeline.");
            StopPipeline();
            return -1;
        }
        return 0;
    }

    void Stop() {
        std::lock_guard<std::mutex> guard(_lifecycleMutex);
        StopPipeline();
        ClearLatestFrame();
    }

    void Close() {
        std::lock_guard<std::mutex> guard(_lifecycleMutex);
        _closed = true;
        StopPipeline();
        ClearLatestFrame();
    }

    std::int32_t CopyLatestFrame(std::uint8_t* destination, std::uint64_t capacity, GstPlayerFrameInfo* info) {
        if (info == nullptr)
            return -1;

        std::lock_guard<std::mutex> guard(_frameMutex);
        if (_frame.empty() || _frameSequence == _copiedSequence)
            return 0;

        info->width = _width;
        info->height = _height;
        info->stride = _stride;
        info->frameRateNumerator = _fpsNumerator;
        info->frameRateDenominator = _fpsDenominator;
        info->sequence = _frameSequence;
        if (destination == nullptr || capacity < _frame.size())
            return -2;

        std::memcpy(destination, _frame.data(), _frame.size());
        _copiedSequence = _frameSequence;
        return 1;
    }

    std::int32_t PollEvent(GstPlayerEvent* event) {
        if (event == nullptr)
            return -1;

        std::lock_guard<std::mutex> guard(_eventMutex);
        if (_events.empty())
            return 0;
        *event = _events.front();
        _events.pop_front();
        return 1;
    }

private:
    static GstFlowReturn OnNewSample(GstAppSink* sink, gpointer userData) {
        auto* self = static_cast<Player*>(userData);
        GstSample* sample = gst_app_sink_pull_sample(sink);
        if (sample == nullptr)
            return GST_FLOW_EOS;

        GstCaps* caps = gst_sample_get_caps(sample);
        GstBuffer* buffer = gst_sample_get_buffer(sample);
        GstVideoInfo videoInfo;
        GstVideoFrame frame;
        GstFlowReturn result = GST_FLOW_OK;

        if (caps == nullptr || buffer == nullptr || !gst_video_info_from_caps(&videoInfo, caps) ||
            !gst_video_frame_map(&frame, &videoInfo, buffer, GST_MAP_READ)) {
            self->PushEvent(EventWarning, "Could not map a decoded video frame.");
            result = GST_FLOW_ERROR;
        } else {
            const guint width = GST_VIDEO_INFO_WIDTH(&videoInfo);
            const guint height = GST_VIDEO_INFO_HEIGHT(&videoInfo);
            const guint stride = width * 4;
            const auto* source = static_cast<const std::uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0));
            const gint sourceStride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
            bool formatChanged;
            {
                std::lock_guard<std::mutex> guard(self->_frameMutex);
                formatChanged = self->_width != width || self->_height != height ||
                    self->_fpsNumerator != static_cast<std::uint32_t>(GST_VIDEO_INFO_FPS_N(&videoInfo)) ||
                    self->_fpsDenominator != static_cast<std::uint32_t>(GST_VIDEO_INFO_FPS_D(&videoInfo));
                self->_width = width;
                self->_height = height;
                self->_stride = stride;
                self->_fpsNumerator = GST_VIDEO_INFO_FPS_N(&videoInfo);
                self->_fpsDenominator = GST_VIDEO_INFO_FPS_D(&videoInfo);
                self->_frame.resize(static_cast<std::size_t>(stride) * height);
                for (guint row = 0; row < height; ++row)
                    std::memcpy(self->_frame.data() + static_cast<std::size_t>(row) * stride,
                        source + static_cast<std::ptrdiff_t>(row) * sourceStride, stride);
                ++self->_frameSequence;
            }
            if (formatChanged) {
                GstPlayerEvent event{};
                event.type = EventVideoInfo;
                event.width = width;
                event.height = height;
                event.frameRateNumerator = GST_VIDEO_INFO_FPS_N(&videoInfo);
                event.frameRateDenominator = GST_VIDEO_INFO_FPS_D(&videoInfo);
                std::snprintf(event.message, sizeof(event.message), "Negotiated %ux%u at %u/%u fps.",
                    width, height, event.frameRateNumerator, event.frameRateDenominator);
                self->PushEvent(event);
            }
            gst_video_frame_unmap(&frame);
        }

        gst_sample_unref(sample);
        return result;
    }

    static void OnRtspPadAdded(GstElement*, GstPad* sourcePad, gpointer userData) {
        auto* depay = GST_ELEMENT(userData);
        GstPad* sinkPad = gst_element_get_static_pad(depay, "sink");
        if (sinkPad == nullptr || gst_pad_is_linked(sinkPad)) {
            if (sinkPad != nullptr) gst_object_unref(sinkPad);
            return;
        }

        GstCaps* caps = gst_pad_get_current_caps(sourcePad);
        if (caps == nullptr)
            caps = gst_pad_query_caps(sourcePad, nullptr);
        const GstStructure* structure = caps != nullptr && gst_caps_get_size(caps) > 0
            ? gst_caps_get_structure(caps, 0) : nullptr;
        const gchar* encoding = structure == nullptr ? nullptr : gst_structure_get_string(structure, "encoding-name");
        const gchar* media = structure == nullptr ? nullptr : gst_structure_get_string(structure, "media");
        if (encoding != nullptr && media != nullptr && g_str_equal(encoding, "H264") && g_str_equal(media, "video"))
            gst_pad_link(sourcePad, sinkPad);
        if (caps != nullptr)
            gst_caps_unref(caps);
        gst_object_unref(sinkPad);
    }

    void BusLoop(GstBus* bus) {
        while (!_busStop.load()) {
            GstMessage* message = gst_bus_timed_pop_filtered(bus, 100 * GST_MSECOND,
                static_cast<GstMessageType>(GST_MESSAGE_ERROR | GST_MESSAGE_WARNING | GST_MESSAGE_EOS | GST_MESSAGE_STATE_CHANGED));
            if (message == nullptr)
                continue;

            switch (GST_MESSAGE_TYPE(message)) {
            case GST_MESSAGE_ERROR: {
                GError* error = nullptr;
                gchar* debug = nullptr;
                gst_message_parse_error(message, &error, &debug);
                PushEvent(EventError, error == nullptr ? "GStreamer pipeline error." : error->message);
                if (error != nullptr) g_error_free(error);
                g_free(debug);
                break;
            }
            case GST_MESSAGE_WARNING: {
                GError* error = nullptr;
                gchar* debug = nullptr;
                gst_message_parse_warning(message, &error, &debug);
                PushEvent(EventWarning, error == nullptr ? "GStreamer pipeline warning." : error->message);
                if (error != nullptr) g_error_free(error);
                g_free(debug);
                break;
            }
            case GST_MESSAGE_EOS:
                PushEvent(EventEndOfStream, "The RTSP stream ended.");
                break;
            case GST_MESSAGE_STATE_CHANGED:
                if (GST_MESSAGE_SRC(message) == GST_OBJECT(_pipeline)) {
                    GstState oldState, newState, pending;
                    gst_message_parse_state_changed(message, &oldState, &newState, &pending);
                    const gchar* oldName = gst_element_state_get_name(oldState);
                    const gchar* newName = gst_element_state_get_name(newState);
                    char text[128];
                    std::snprintf(text, sizeof(text), "Pipeline state: %s -> %s.", oldName, newName);
                    PushEvent(EventStateChanged, text, oldState, newState);
                }
                break;
            default:
                break;
            }
            gst_message_unref(message);
        }
    }

    void PushEvent(std::int32_t type, const char* message, std::int32_t oldState = 0, std::int32_t newState = 0) {
        GstPlayerEvent event{};
        event.type = type;
        event.oldState = oldState;
        event.newState = newState;
        if (message != nullptr)
            std::snprintf(event.message, sizeof(event.message), "%s", message);
        PushEvent(event);
    }

    void PushEvent(const GstPlayerEvent& event) {
        std::lock_guard<std::mutex> guard(_eventMutex);
        if (_events.size() == 64)
            _events.pop_front();
        _events.push_back(event);
    }

    void ClearLatestFrame() {
        std::lock_guard<std::mutex> guard(_frameMutex);
        _frame.clear();
        _width = _height = _stride = _fpsNumerator = _fpsDenominator = 0;
        _copiedSequence = _frameSequence;
    }

    void StopPipeline() {
        _busStop = true;
        if (_pipeline != nullptr)
            gst_element_set_state(_pipeline, GST_STATE_NULL);
        if (_busThread.joinable())
            _busThread.join();
        if (_bus != nullptr) {
            gst_object_unref(_bus);
            _bus = nullptr;
        }
        if (_pipeline != nullptr) {
            gst_object_unref(_pipeline);
            _pipeline = nullptr;
        }
    }

    std::mutex _lifecycleMutex;
    std::mutex _frameMutex;
    std::mutex _eventMutex;
    std::atomic<bool> _busStop{ true };
    bool _closed = false;
    GstElement* _pipeline = nullptr;
    GstBus* _bus = nullptr;
    std::thread _busThread;
    std::deque<GstPlayerEvent> _events;
    std::vector<std::uint8_t> _frame;
    std::uint32_t _width = 0;
    std::uint32_t _height = 0;
    std::uint32_t _stride = 0;
    std::uint32_t _fpsNumerator = 0;
    std::uint32_t _fpsDenominator = 0;
    std::uint64_t _frameSequence = 0;
    std::uint64_t _copiedSequence = 0;
};

std::mutex g_handlesMutex;
std::unordered_map<void*, std::shared_ptr<Player>> g_handles;
std::uintptr_t g_nextHandle = 1;

std::shared_ptr<Player> Acquire(void* handle) {
    std::lock_guard<std::mutex> guard(g_handlesMutex);
    const auto found = g_handles.find(handle);
    return found == g_handles.end() ? nullptr : found->second;
}

}

extern "C" {

void* gst_player_create() {
    try {
        auto player = std::make_shared<Player>();
        std::lock_guard<std::mutex> guard(g_handlesMutex);
        void* handle = reinterpret_cast<void*>(g_nextHandle++);
        if (handle == nullptr)
            handle = reinterpret_cast<void*>(g_nextHandle++);
        g_handles.emplace(handle, std::move(player));
        return handle;
    }
    catch (...) { return nullptr; }
}

std::int32_t gst_player_start(void* player, const char* url, std::uint32_t latencyMilliseconds) {
    const auto instance = Acquire(player);
    return instance == nullptr ? -1 : instance->Start(url, latencyMilliseconds);
}

void gst_player_stop(void* player) {
    if (const auto instance = Acquire(player)) instance->Stop();
}

void gst_player_destroy(void* player) {
    std::shared_ptr<Player> instance;
    {
        std::lock_guard<std::mutex> guard(g_handlesMutex);
        const auto found = g_handles.find(player);
        if (found == g_handles.end())
            return;
        instance = std::move(found->second);
        g_handles.erase(found);
    }
    instance->Close();
}

std::int32_t gst_player_copy_latest_frame(void* player, std::uint8_t* destination,
    std::uint64_t capacity, GstPlayerFrameInfo* info) {
    const auto instance = Acquire(player);
    return instance == nullptr ? -1 : instance->CopyLatestFrame(destination, capacity, info);
}

std::int32_t gst_player_poll_event(void* player, GstPlayerEvent* event) {
    const auto instance = Acquire(player);
    return instance == nullptr ? -1 : instance->PollEvent(event);
}

}
#import "GStreamerVideoPlayer.h"

#import <gst/gst.h>
#import <gst/video/video.h>
#import <gst/video/videooverlay.h>

#include <atomic>

namespace {
constexpr NSTimeInterval kWatchdogInterval = 0.5;
constexpr NSTimeInterval kBackoffDelays[] = {0.25, 0.5, 1.0, 2.0};

NSString *GSTMessageDescription(GstMessage *message) {
    GError *error = nullptr;
    gchar *debug = nullptr;
    gst_message_parse_error(message, &error, &debug);
    NSString *description = [NSString stringWithFormat:@"%@%@",
                              error ? [NSString stringWithUTF8String:error->message] : @"Unknown GStreamer error",
                              debug ? [NSString stringWithFormat:@" (%s)", debug] : @""];
    if (error != nullptr) {
        g_error_free(error);
    }
    if (debug != nullptr) {
        g_free(debug);
    }
    return description;
}

BOOL EnsureGStreamerInitialized(NSString **errorMessage) {
    static dispatch_once_t onceToken;
    static BOOL initialized = NO;
    static NSString *initializationError;
    dispatch_once(&onceToken, ^{
        GError *error = nullptr;
        initialized = gst_init_check(nullptr, nullptr, &error);
        if (!initialized) {
            initializationError = error ? [NSString stringWithUTF8String:error->message] : @"Unable to initialize GStreamer.";
        }
        if (error != nullptr) {
            g_error_free(error);
        }
    });
    if (!initialized && errorMessage != nullptr) {
        *errorMessage = initializationError;
    }
    return initialized;
}
}

static GstPadProbeReturn FrameProbe(GstPad *pad, GstPadProbeInfo *info, gpointer userData);

@interface GStreamerVideoPlayer () {
    dispatch_queue_t _pipelineQueue;
    GstElement *_pipeline;
    GstElement *_videoSink;
    GstBus *_bus;
    GstPad *_videoSinkPad;
    gulong _frameProbeID;
    dispatch_source_t _busTimer;
    dispatch_source_t _watchdogTimer;
    dispatch_block_t _reconnectBlock;
    NSString *_URLString;
    NSString *_transport;
    NSInteger _latencyMilliseconds;
    NSTimeInterval _stallTimeoutSeconds;
    guintptr _renderHandle;
    gint _renderWidth;
    gint _renderHeight;
    std::atomic<NSUInteger> _generation;
    NSUInteger _backoffIndex;
    NSUInteger _reconnectCount;
    NSUInteger _frameCount;
    NSInteger _publishedWidth;
    NSInteger _publishedHeight;
    double _publishedFrameRate;
    NSTimeInterval _frameRateWindowStart;
    NSTimeInterval _lastFrameTimestamp;
    NSTimeInterval _playingStartedTimestamp;
    BOOL _hasReceivedFrame;
    BOOL _isPlaying;
    BOOL _manualStop;
    BOOL _isTearingDown;
    std::atomic_bool _frameProbePending;
}
- (void)enqueueFrameFromPad:(GstPad *)pad;
- (void)recordFrameFromPad:(GstPad *)pad;
@end

@implementation GStreamerVideoPlayer

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _pipelineQueue = dispatch_queue_create("dev.myRTSPTester.gstreamer.pipeline", DISPATCH_QUEUE_SERIAL);
        _generation.store(0);
        _frameProbePending.store(false);
    }
    return self;
}

- (void)dealloc {
    dispatch_sync(_pipelineQueue, ^{
        self->_manualStop = YES;
        [self teardownPipeline];
    });
}

- (void)startWithURLString:(NSString *)URLString
                 transport:(NSString *)transport
       latencyMilliseconds:(NSInteger)latencyMilliseconds
       stallTimeoutSeconds:(NSTimeInterval)stallTimeoutSeconds
                renderView:(NSView *)renderView {
    NSString *trimmedURL = [URLString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmedURL.length == 0) {
        [self publishError:@"Enter a valid RTSP URL."];
        [self publishState:GStreamerVideoPlayerStateFailed];
        return;
    }

    const NSRect renderBounds = renderView.bounds;
    const guintptr renderHandle = reinterpret_cast<guintptr>(renderView);
    dispatch_async(_pipelineQueue, ^{
        self->_URLString = trimmedURL;
        self->_transport = [transport.lowercaseString isEqualToString:@"udp"] ? @"udp" : @"tcp";
        self->_latencyMilliseconds = MAX(0, latencyMilliseconds);
        self->_stallTimeoutSeconds = MAX(1.0, stallTimeoutSeconds);
        self->_renderHandle = renderHandle;
        self->_renderWidth = static_cast<gint>(NSWidth(renderBounds));
        self->_renderHeight = static_cast<gint>(NSHeight(renderBounds));
        self->_manualStop = NO;
        self->_backoffIndex = 0;
        [self teardownPipeline];
        [self createAndStartPipeline];
    });
}

- (void)stop {
    dispatch_async(_pipelineQueue, ^{
        self->_manualStop = YES;
        self->_backoffIndex = 0;
        [self teardownPipeline];
        [self publishState:GStreamerVideoPlayerStateStopped];
    });
}

- (void)reconnect {
    dispatch_async(_pipelineQueue, ^{
        if (self->_URLString.length == 0) {
            [self publishError:@"Start video before reconnecting."];
            return;
        }
        self->_manualStop = NO;
        self->_backoffIndex = 0;
        [self teardownPipeline];
        [self createAndStartPipeline];
    });
}

- (void)setRenderView:(NSView *)renderView {
    const NSRect renderBounds = renderView == nil ? NSZeroRect : renderView.bounds;
    const guintptr renderHandle = reinterpret_cast<guintptr>(renderView);
    dispatch_block_t updateView = ^{
        self->_renderHandle = renderHandle;
        self->_renderWidth = static_cast<gint>(NSWidth(renderBounds));
        self->_renderHeight = static_cast<gint>(NSHeight(renderBounds));
        [self attachRenderViewIfPossible];
    };
    if (renderView == nil) {
        dispatch_sync(_pipelineQueue, updateView);
    } else {
        dispatch_async(_pipelineQueue, updateView);
    }
}

- (void)createAndStartPipeline {
    if (_manualStop) {
        return;
    }

    NSString *initializationError = nil;
    if (!EnsureGStreamerInitialized(&initializationError)) {
        [self handleUnexpectedFailure:initializationError ?: @"Unable to initialize GStreamer."];
        return;
    }

    if (_renderHandle == 0) {
        [self handleUnexpectedFailure:@"The embedded video view is not available."];
        return;
    }

    const char *decoder = "avdec_h264";
    GstElementFactory *videoToolboxDecoder = gst_element_factory_find("vtdec");
    if (videoToolboxDecoder != nullptr) {
        decoder = "vtdec";
        gst_object_unref(videoToolboxDecoder);
    }
    const char *protocol = [_transport isEqualToString:@"udp"] ? "udp" : "tcp";
    gchar *escapedURL = g_strescape(_URLString.UTF8String, nullptr);
    gchar *pipelineDescription = g_strdup_printf(
        "rtspsrc location=\"%s\" protocols=%s latency=%ld drop-on-latency=true "
        "! rtph264depay ! h264parse ! %s ! videoconvert "
        "! glimagesink name=videoSink sync=false force-aspect-ratio=true",
        escapedURL, protocol, static_cast<long>(_latencyMilliseconds), decoder);
    g_free(escapedURL);
    GError *error = nullptr;
    _pipeline = gst_parse_launch(pipelineDescription, &error);
    g_free(pipelineDescription);
    if (_pipeline == nullptr || error != nullptr) {
        NSString *message = error ? [NSString stringWithUTF8String:error->message] : @"Unable to create the GStreamer pipeline.";
        if (error != nullptr) {
            g_error_free(error);
        }
        [self handleUnexpectedFailure:message];
        return;
    }

    _generation.fetch_add(1);
    _videoSink = gst_bin_get_by_name(GST_BIN(_pipeline), "videoSink");
    if (_videoSink == nullptr || !GST_IS_VIDEO_OVERLAY(_videoSink)) {
        [self handleUnexpectedFailure:@"glimagesink does not provide GstVideoOverlay on this installation."];
        return;
    }
    [self attachRenderViewIfPossible];

    _videoSinkPad = gst_element_get_static_pad(_videoSink, "sink");
    if (_videoSinkPad != nullptr) {
        _frameProbeID = gst_pad_add_probe(_videoSinkPad, GST_PAD_PROBE_TYPE_BUFFER,
                                          FrameProbe, (__bridge void *)self, nullptr);
    }
    _bus = gst_element_get_bus(_pipeline);
    [self installBusTimer];
    [self publishState:GStreamerVideoPlayerStateConnecting];

    GstStateChangeReturn result = gst_element_set_state(_pipeline, GST_STATE_PLAYING);
    if (result == GST_STATE_CHANGE_FAILURE) {
        [self handleUnexpectedFailure:@"GStreamer could not transition the RTSP pipeline to PLAYING."];
    }
}

- (void)attachRenderViewIfPossible {
    if (_videoSink == nullptr || _renderHandle == 0 || !GST_IS_VIDEO_OVERLAY(_videoSink)) {
        return;
    }

    gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(_videoSink), _renderHandle);
    gst_video_overlay_set_render_rectangle(GST_VIDEO_OVERLAY(_videoSink), 0, 0, _renderWidth, _renderHeight);
    gst_video_overlay_expose(GST_VIDEO_OVERLAY(_videoSink));
}

- (void)installBusTimer {
    if (_bus == nullptr) {
        return;
    }
    _busTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pipelineQueue);
    dispatch_source_set_timer(_busTimer, DISPATCH_TIME_NOW, NSEC_PER_MSEC * 100, NSEC_PER_MSEC * 20);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_busTimer, ^{
        [weakSelf drainBus];
    });
    dispatch_resume(_busTimer);
}

- (void)drainBus {
    if (_bus == nullptr) {
        return;
    }
    GstMessage *message = nullptr;
    while ((message = gst_bus_pop_filtered(_bus, static_cast<GstMessageType>(
        GST_MESSAGE_ERROR | GST_MESSAGE_EOS | GST_MESSAGE_STATE_CHANGED))) != nullptr) {
        [self handleBusMessage:message];
        gst_message_unref(message);
        if (_pipeline == nullptr) {
            return;
        }
    }
}

- (void)handleBusMessage:(GstMessage *)message {
    switch (GST_MESSAGE_TYPE(message)) {
        case GST_MESSAGE_ERROR:
            [self handleUnexpectedFailure:GSTMessageDescription(message)];
            break;
        case GST_MESSAGE_EOS:
            [self handleUnexpectedFailure:@"The RTSP stream ended unexpectedly."];
            break;
        case GST_MESSAGE_STATE_CHANGED: {
            if (GST_MESSAGE_SRC(message) != GST_OBJECT(_pipeline)) {
                break;
            }
            GstState oldState = GST_STATE_NULL;
            GstState newState = GST_STATE_NULL;
            gst_message_parse_state_changed(message, &oldState, &newState, nullptr);
            if (newState == GST_STATE_PLAYING) {
                _isPlaying = YES;
                _playingStartedTimestamp = NSDate.timeIntervalSinceReferenceDate;
                [self installWatchdogTimer];
                [self publishState:GStreamerVideoPlayerStatePlaying];
            } else if (_isPlaying && newState <= GST_STATE_READY && !_manualStop && !_isTearingDown) {
                [self handleUnexpectedFailure:@"The RTSP pipeline left PLAYING unexpectedly."];
            }
            break;
        }
        default:
            break;
    }
}

- (void)enqueueFrameFromPad:(GstPad *)pad {
    if (_frameProbePending.exchange(true)) {
        return;
    }
    const NSUInteger generation = _generation.load();
    GstPad *retainedPad = GST_PAD(gst_object_ref(pad));
    dispatch_async(_pipelineQueue, ^{
        if (self->_generation.load() == generation) {
            [self recordFrameFromPad:retainedPad];
        }
        gst_object_unref(retainedPad);
        self->_frameProbePending.store(false);
    });
}

- (void)recordFrameFromPad:(GstPad *)pad {
    if (_pipeline == nullptr || _manualStop) {
        return;
    }
    const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    _lastFrameTimestamp = now;
    _hasReceivedFrame = YES;
    _frameCount += 1;
    if (_frameRateWindowStart == 0) {
        _frameRateWindowStart = now;
    }

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (caps != nullptr && gst_caps_get_size(caps) > 0) {
        GstStructure *structure = gst_caps_get_structure(caps, 0);
        gint width = 0;
        gint height = 0;
        gint numerator = 0;
        gint denominator = 1;
        gst_structure_get_int(structure, "width", &width);
        gst_structure_get_int(structure, "height", &height);
        gst_structure_get_fraction(structure, "framerate", &numerator, &denominator);
        const double frameRate = denominator > 0 ? static_cast<double>(numerator) / denominator : 0;
        if (width > 0 && height > 0 &&
            (width != _publishedWidth || height != _publishedHeight || frameRate != _publishedFrameRate)) {
            _publishedWidth = width;
            _publishedHeight = height;
            _publishedFrameRate = frameRate;
            [self publishVideoWidth:width height:height frameRate:frameRate];
        }
        gst_caps_unref(caps);
    }

    if (now - _frameRateWindowStart >= 1.0) {
        const double measuredRate = _frameCount / (now - _frameRateWindowStart);
        _frameCount = 0;
        _publishedWidth = 0;
        _publishedHeight = 0;
        _publishedFrameRate = 0;
        _frameProbePending.store(false);
        _frameRateWindowStart = now;
        [self publishMeasuredFrameRate:measuredRate lastFrameTime:[NSDate date]];
    }
}

- (void)installWatchdogTimer {
    if (_watchdogTimer != nil) {
        return;
    }
    _watchdogTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pipelineQueue);
    dispatch_source_set_timer(_watchdogTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 500),
                              NSEC_PER_MSEC * 500, NSEC_PER_MSEC * 50);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_watchdogTimer, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf->_isPlaying || strongSelf->_manualStop) {
            return;
        }
        const NSTimeInterval referenceTime = strongSelf->_hasReceivedFrame
            ? strongSelf->_lastFrameTimestamp
            : strongSelf->_playingStartedTimestamp;
        if (referenceTime > 0 &&
            NSDate.timeIntervalSinceReferenceDate - referenceTime > strongSelf->_stallTimeoutSeconds) {
            [strongSelf handleUnexpectedFailure:@"The RTSP stream stopped delivering video frames."];
        }
    });
    dispatch_resume(_watchdogTimer);
}

- (void)handleUnexpectedFailure:(NSString *)message {
    if (_manualStop || _isTearingDown) {
        return;
    }
    [self publishError:message];
    [self publishState:GStreamerVideoPlayerStateReconnecting];
    [self teardownPipeline];
    [self scheduleReconnect];
}

- (void)scheduleReconnect {
    if (_manualStop || _reconnectBlock != nil) {
        return;
    }
    const NSUInteger delayIndex = MIN(_backoffIndex, sizeof(kBackoffDelays) / sizeof(kBackoffDelays[0]) - 1);
    const NSTimeInterval delay = kBackoffDelays[delayIndex];
    _backoffIndex += 1;
    _reconnectCount += 1;
    __weak typeof(self) weakSelf = self;
    _reconnectBlock = dispatch_block_create(DISPATCH_BLOCK_ASSIGN_CURRENT, ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil || strongSelf->_manualStop) {
            return;
        }
        strongSelf->_reconnectBlock = nil;
        [strongSelf createAndStartPipeline];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(delay * NSEC_PER_SEC)),
                   _pipelineQueue, _reconnectBlock);
}

- (void)teardownPipeline {
    _isTearingDown = YES;
    _isPlaying = NO;
    _hasReceivedFrame = NO;
    _lastFrameTimestamp = 0;
    _playingStartedTimestamp = 0;
    _frameRateWindowStart = 0;
    _frameCount = 0;
    _generation.fetch_add(1);

    if (_reconnectBlock != nil) {
        dispatch_block_cancel(_reconnectBlock);
        _reconnectBlock = nil;
    }
    if (_watchdogTimer != nil) {
        dispatch_source_cancel(_watchdogTimer);
        _watchdogTimer = nil;
    }
    if (_busTimer != nil) {
        dispatch_source_cancel(_busTimer);
        _busTimer = nil;
    }
    if (_videoSinkPad != nullptr) {
        if (_frameProbeID != 0) {
            gst_pad_remove_probe(_videoSinkPad, _frameProbeID);
            _frameProbeID = 0;
        }
        gst_object_unref(_videoSinkPad);
        _videoSinkPad = nullptr;
    }
    if (_pipeline != nullptr) {
        gst_element_set_state(_pipeline, GST_STATE_NULL);
    }
    if (_bus != nullptr) {
        gst_object_unref(_bus);
        _bus = nullptr;
    }
    if (_videoSink != nullptr) {
        gst_object_unref(_videoSink);
        _videoSink = nullptr;
    }
    if (_pipeline != nullptr) {
        gst_object_unref(_pipeline);
        _pipeline = nullptr;
    }
    _isTearingDown = NO;
}

- (void)publishState:(GStreamerVideoPlayerState)state {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        [strongSelf.delegate videoPlayer:strongSelf didChangeState:state];
    });
}

- (void)publishVideoWidth:(NSInteger)width height:(NSInteger)height frameRate:(double)frameRate {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        [strongSelf.delegate videoPlayer:strongSelf didUpdateVideoWidth:width height:height frameRate:frameRate];
    });
}

- (void)publishMeasuredFrameRate:(double)frameRate lastFrameTime:(NSDate *)lastFrameTime {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        [strongSelf.delegate videoPlayer:strongSelf didUpdateMeasuredFrameRate:frameRate lastFrameTime:lastFrameTime];
    });
}

- (void)publishError:(NSString *)message {
    NSLog(@"GStreamer RTSP player: %@", message);
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        [strongSelf.delegate videoPlayer:strongSelf didReceiveError:message];
    });
}

static GstPadProbeReturn FrameProbe(GstPad *pad, GstPadProbeInfo *, gpointer userData) {
    GStreamerVideoPlayer *player = (__bridge GStreamerVideoPlayer *)userData;
    [player enqueueFrameFromPad:pad];
    return GST_PAD_PROBE_OK;
}

@end

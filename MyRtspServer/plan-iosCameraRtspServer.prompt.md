# Plan: iOS Camera RTSP Server

Build the pipeline incrementally around one rear-camera capture session and one hardware H.264 encoder. Each RTSP client gets independent RTP state and bounded network buffering. The Default preset starts at 720p, 30 fps and 2 Mbps.

### Steps

1. Add `VideoStreamConfiguration` and presets; validate exact rear wide-angle camera formats in `CameraCapture.swift`.
2. Implement NV12 capture and `H264Encoder.swift`, including hardware availability, timestamped NAL extraction, SPS/PPS, and runtime bitrate updates.
3. Build `H264RTPPacketizer.swift` with single-NAL and FU-A packets, per-client RTP state, and access-unit marker semantics.
4. Implement `RTSPServer.swift`: persistent request parsing, OPTIONS/DESCRIBE, SDP, SETUP/PLAY, and interleaved TCP transport.
5. Add remaining RTSP methods, IDR-gated client startup, basic RTCP, bounded client queues, and disconnect handling.
6. Connect lifecycle, statistics, thermal monitoring and cleanup in `StreamController.swift`; update [ContentView.swift](MyRtspServer/ContentView.swift), permissions, and automated protocol tests.

### Further Considerations

1. Use 30 frames as the default keyframe interval, including High FPS; that preset therefore has a half-second interval.
2. Keep streaming foreground-only initially; iOS limits camera access when the app enters the background.
3. The current [project settings](MyRtspServer.xcodeproj/project.xcproj) specify iOS 27.2 and multiple platforms. Confirm the intended minimum iOS version and restrict the app to iOS.

Is this draft plan suitable for review?
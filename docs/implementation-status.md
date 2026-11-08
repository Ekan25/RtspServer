# Implementation Status

Updated: 2026-11-08

## Windows WPF Client

RTSP playback implementation is present in `MyRtspTesterCS`. It uses a native x64 C++ DLL with GStreamer’s C API and P/Invoke from the .NET 10 WPF application. The native API owns initialization, pipeline lifecycle, bus monitoring, decoded-frame storage, and cleanup; it exposes no GStreamer types to C# and uses no managed callback delegates.

The initial pipeline is RTSP over TCP at `rtsp://<saved-camera-host>:8554/camera`, with configurable latency, H.264 RTP depayloading/parsing, software decoding with `avdec_h264`, conversion to BGRA, and an appsink. The installed GStreamer 1.28.8 x64 environment has all required elements (`rtspsrc`, `rtph264depay`, `h264parse`, `avdec_h264`, `videoconvert`, `appsink`). Hardware decode and UDP transport are not enabled.

Frames are held in a reusable, latest-frame native buffer. A one-buffer leaky queue and appsink discard stale frames. C# polls off the WPF dispatcher and writes reusable BGRA storage into a `WriteableBitmap` through one pending dispatcher render operation. The WPF `Image` uses `Stretch=Uniform`, preserving aspect ratio and adapting to negotiated resolution changes.

Playback state handling includes Disconnected, Connecting, Playing, Reconnecting, Stopped, and Error. It polls control status before playback, requests server start only if needed, waits up to 30 seconds for readiness, creates a fresh pipeline for each retry, retries with bounded delays, treats 20 seconds without an initial frame as a connection failure, and detects a 5-second frame stall. Auto Connect and Auto Stream settings, host, port, and latency are persisted in the existing local connection settings file. Auto Connect uses the saved manually entered endpoint; Bonjour discovery is not present in this checkout. An explicit stop suppresses Auto Stream for the current connection lifecycle.

The iOS control protocol now includes a separate optional `streamStatus` payload and advertises `startStream`/`stopStream`; these changes bridge to the existing `StreamController` lifecycle. A remote `stopStream` stops media capture/RTSP while retaining the camera-control listener and device handle, so the same control connection can query status and request a later start. The iOS app's own stop/background action still closes the listener. These changes do not alter encoding or server UI. The Swift changes have editor diagnostics only and have not been built with Xcode in this Windows environment.

### Verification

- Verified: x64 Release native and WPF solution build with Visual Studio 18 MSBuild.
- Verified: managed P/Invoke loads GStreamer, creates and destroys a native player.
- Verified: native pipeline construction and repeated start/stop against localhost without an RTSP server.
- Verified: CameraControlTests, 15/15; CameraUiTests, all six scenarios, including persisted Auto Connect/Auto Stream/latency settings.
- Not verified: live iPhone RTSP connection, rendered camera frames, window resizing during live playback, network interruption recovery, changed camera resolution, and end-to-end latency.

Known limitations: playback requires the x64 GStreamer runtime and its plugins to be installed; only RTSP/TCP and software H.264 decoding are configured. Direct3D rendering, hardware decoding, Bonjour discovery, and fullscreen support are not implemented. During local native smoke testing, GStreamer reported that its optional GIO proxy module could not load because `pxbackend-1.0.dll` is unavailable; the configured direct RTSP pipeline still constructed and stopped, but proxy integration remains untested.

## iOS and macOS Applications

No broader implementation-status claims are made here for the iOS or macOS applications. Only the minimal iOS camera-control protocol extension described above was changed for Windows stream orchestration.
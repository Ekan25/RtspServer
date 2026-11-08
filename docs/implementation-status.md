# Implementation Status

This document tracks the implementation status of the three applications.

Last updated: 2026-11-08

Status definitions:
- **Implemented** — Feature is implemented in source code.
- **Partial** — Feature exists but is incomplete.
- **Planned** — Feature has not yet been implemented.
- **Unknown** — Implementation has not been verified.

## iOS — MyRtspServer

| Feature | Status | Notes |
|---|---|---|
| Camera capture | Implemented | AVFoundation video capture |
| H.264 encoding | Implemented | VideoToolbox |
| RTSP server | Implemented | Port 8554 |
| TCP control server | Implemented | Port 8555 |
| Bonjour discovery | Implemented | `_lvi-camera._tcp` |
| Remote start/stop streaming | Implemented | Control listener remains available while streaming is stopped |
| Zoom controls | Implemented | |
| Configurable zoom limits | Unknown | |
| High-resolution image capture | Implemented | `AVCapturePhotoOutput`; JPEG and processed BGRA8, independent of H.264 resolution |
| Command log GUI | Unknown | |

## macOS — MyRtspTester

| Feature | Status | Notes |
|---|---|---|
| RTSP playback | Implemented | GStreamer |
| TCP control client | Implemented | |
| Bonjour discovery | Implemented | |
| Auto Connect | Partial | |
| Auto Stream | Partial | |
| High-resolution image reception | Implemented | Binary v1 TCP transfer; retains original JPEG/BGRA data |
| Image magnification | Implemented | Scrollable magnifiable photo viewer |
| Save image dialog | Implemented | NSSavePanel; JPEG copied directly, BGRA saved as PNG |

## Windows — MyRtspTesterCS

| Feature | Status | Notes |
|---|---|---|
| RTSP playback | Implemented | GStreamer RTSP/TCP via native x64 C++ bridge |
| TCP control client | Implemented | P/Invoke control lifecycle |
| Bonjour discovery | Planned | Not present in the merged Windows implementation |
| Auto Connect | Implemented | Persisted manual endpoint |
| Auto Stream | Implemented | Explicit stop suppresses automatic start for the connection lifecycle |
| Front/rear camera switching | Implemented | Capability-gated; refreshes active-camera modes after switching; physical-device verification pending |
| Resolution and frame-rate selection | Implemented | Uses advertised active-camera ranges and whole-number fps; playback reconnects after reconfiguration; physical-device verification pending |
| High-resolution image reception | Implemented | Authenticated `LVP1` TCP transfer; JPEG and BGRA with bounded payload and validated dimensions/stride; physical-device verification pending |
| Image magnification | Partial | Aspect-preserving preview; dedicated zoom interaction not implemented |
| Save image dialog | Implemented | JPEG saved directly; BGRA converted to PNG; physical-device verification pending |

## Known Issues

- Photo capture requires physical-device verification for camera-specific maximum resolution, concurrent RTSP behavior, and BGRA channel/stride output.
- Image transfer v1 is plaintext and intended only for trusted local networks; see `docs/protocol.md`.
- Windows photo transfer and WPF preview have loopback/UI coverage, but still need physical iPhone verification for full-resolution capture, concurrent RTSP behavior, and BGRA channel/stride output.
- Windows camera switching and video mode selection have loopback/UI coverage; physical iPhone verification, including playback reconnection and impact on other RTSP viewers, is pending.

## Next Steps

Record planned work and priorities here.

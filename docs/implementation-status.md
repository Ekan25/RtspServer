# Implementation Status

This document tracks the implementation status of the three applications.

Last updated: 2026-11-07

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
| Remote start/stop streaming | Unknown | |
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
| RTSP playback | Unknown | GStreamer |
| TCP control client | Partial | |
| Bonjour discovery | Unknown | |
| Auto Connect | Unknown | |
| Auto Stream | Unknown | |
| High-resolution image reception | Unknown | |
| Image magnification | Unknown | |
| Save image dialog | Unknown | |

## Known Issues

- Photo capture requires physical-device verification for camera-specific maximum resolution, concurrent RTSP behavior, and BGRA channel/stride output.
- Image transfer v1 is plaintext and intended only for trusted local networks; see `docs/protocol.md`.

## Next Steps

Record planned work and priorities here.

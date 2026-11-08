# MyRtspServer — Copilot Instructions

This repository contains an iPhone camera streaming server and a macOS test client.

## Architecture

- iOS server written in Swift.
- AVFoundation for camera capture and controls.
- VideoToolbox for hardware H.264 encoding.
- Custom RTSP/RTP server using Network.framework.
- RTSP port: 8554.
- TCP JSON camera control port: 8555.
- Bonjour/mDNS for camera discovery.
- macOS MyRtspTester uses SwiftUI and GStreamer.
- Windows MyRtspTesterCS uses C#

## Platform-Specific Development

When running Copilot CLI on macOS:

- Work only on `MyRtspServer` (iOS) and `MyRtspTester` (macOS).
- Do not modify, build, or test `MyRtspTesterCS` (Windows) unless explicitly requested.
- Shared protocol changes must remain compatible with Windows, but Windows implementation is handled separately.
- Update `docs/implementation-status.md` for the projects actually modified.
- Do not mark Windows features as implemented unless verified in the Windows source code.

## Priorities

1. Minimize end-to-end video latency.
2. Maintain reliable continuous streaming.
3. Preserve compatibility with standard RTSP clients.
4. Keep camera capture, encoding, networking and UI independent.
5. Avoid unnecessary buffering and memory copies.
6. Support multiple clients without allowing slow clients to block others.

## Camera features

- Configurable resolution, frame rate and H.264 bitrate.
- AVFoundation optical/digital zoom.
- Configurable zoom limits.
- Autofocus and manual focus.
- Front/rear camera switching.
- Torch control.
- Remote start/stop streaming.
- High-resolution photo capture for OCR and magnification.

## Development guidelines

- Inspect existing code before modifying it.
- Prefer native Apple APIs.
- Keep changes small and incremental.
- Preserve existing control protocol compatibility.
- Handle camera and network errors gracefully.
- Do not rewrite working components unnecessarily.
- Update project documentation when protocols or architecture change.

## Implementation Tracking

The file `docs/implementation-status.md` is the authoritative record of implemented, partially implemented, and planned features across all three projects.

At the beginning of a task:
- Read `docs/implementation-status.md`.
- Inspect relevant source code to verify the current implementation.

After completing a task:
- Update `docs/implementation-status.md` to reflect the changes.
- Record any remaining limitations or incomplete functionality.
- Do not mark a feature as implemented unless the source code supports it.
- Do not claim a feature has been tested unless tests were actually executed.

Keep the document synchronized with the source code.

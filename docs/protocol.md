# Camera Control and Photo Transfer Protocol

## Control channel

Control remains newline-delimited UTF-8 JSON on TCP port 8555. Existing clients remain compatible.

### Camera and video mode

`capabilities` returns a `capabilities` object containing supported `commands`, camera descriptors in `cameras`, video mode ranges for the active camera in `videoModes`, and the current `status`. Camera descriptors report `position` as `back` or `front`; status reports `camera` and `videoMode`. `getVideoModes` returns the active camera's ranges in a top-level `videoModes` array. Each range contains `width`, `height`, `minFrameRate`, and `maxFrameRate`.

```json
{"id":"camera-1","command":"setCamera","position":"front"}
{"id":"mode-1","command":"setVideoMode","width":1280,"height":720,"fps":30}
```

Video mode requests require a positive whole-number `fps` within an advertised range for the selected dimensions. A camera switch may select a fallback mode if the previous mode is unavailable; clients should read the returned status and refresh the active camera's modes. Both commands disconnect existing RTSP viewers for reconfiguration, including viewers other than the requesting client. A viewer that was playing should reconnect without stopping the shared stream. Errors use the existing error envelope; a failure can occur after viewers have already been disconnected.

### `capturePhoto`

```json
{"id":20,"command":"capturePhoto","format":"jpeg"}
```

`format` is optional and defaults to `jpeg`. Supported values are `jpeg` (high-quality JPEG) and `bgra` (full-resolution processed BGRA8).

A successful response includes the request ID and a one-time transfer descriptor:

```json
{"id":20,"ok":true,"photo":{"transferId":"uuid","transferHost":"192.168.1.2","transferPort":8556,"transferToken":"random-token","format":"jpeg"}}
```

Errors use the existing `{ "ok": false, "error": { "code": "...", "message": "..." } }` envelope. Relevant codes are `capture_in_progress`, `capture_failed`, `capture_cancelled`, `stream_not_running`, and `invalid_parameters`.

## Image transfer v1

The image listener is TCP port 8556, bound to the same configured Wi-Fi interface as control. It does not use mDNS because the response carries the endpoint.

All multibyte integers are unsigned big-endian. The client sends:

| Field | Bytes |
|---|---:|
| Magic `LVP1` | 4 |
| Version | 2 |
| Transfer-ID UTF-8 length | 2 |
| Token UTF-8 length | 2 |
| Reserved | 2 |
| Transfer ID | variable |
| Token | variable |

The server replies with a fixed 32-byte header followed by exactly `payloadByteCount` bytes:

| Field | Bytes |
|---|---:|
| Magic `LVP1` | 4 |
| Version | 2 |
| Status (`0` success) | 2 |
| Pixel format (`1` JPEG, `2` BGRA8) | 2 |
| Reserved | 2 |
| Width | 4 |
| Height | 4 |
| Row stride | 4 |
| Payload byte count | 8 |

JPEG has row stride `0`. BGRA8 is little-endian `premultipliedFirst` BGRA and requires `payloadByteCount == rowStride * height`. Clients must handle partial reads and reject incorrect magic/version/status, invalid dimensions, stride, or payload length.

Transfers are limited to 100 MiB on the macOS client. The server accepts one capture at a time, expires unclaimed transfers after 30 seconds, consumes each descriptor once, and cancels pending data on stream shutdown.

## Security

v1 is plaintext TCP intended only for trusted local networks. The random one-time, short-lived token prevents accidental or cross-request reads but does not encrypt traffic or authenticate the peer. Do not expose ports 8555 or 8556 to untrusted or routed networks.

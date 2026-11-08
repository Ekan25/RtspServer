# GStreamerNative

`GStreamerNative` is a standard x64 C++ DLL. It uses GStreamer’s native C API and exposes an opaque-handle C ABI declared in `GStreamerNative.h`. The managed WPF client calls this interface through P/Invoke. No GStreamer types or managed callback delegates cross the ABI.

## Build and Deployment

Install the x64 MSVC GStreamer development/runtime distribution with these elements available: `rtspsrc`, `rtph264depay`, `h264parse`, `avdec_h264`, `videoconvert`, and `appsink`. The project uses `GSTREAMER_1_0_ROOT_MSVC_X86_64` when set and otherwise defaults to `C:\Program Files\gstreamer\1.0\msvc_x86_64`.

Build the Windows solution with Visual Studio MSBuild and the x64 platform:

```powershell
MSBuild.exe MyRtspTesterCS\MyRtspTester.slnx /p:Platform=x64 /p:Configuration=Release /t:Build
```

The solution builds `GStreamerNative.dll` into the WPF application output directory. At runtime, the managed loader resolves that DLL beside the WPF assembly and adds the configured GStreamer `bin` directory to Windows DLL lookup. Keep the matching GStreamer runtime libraries and plugin tree installed at the configured root; do not copy DLLs from a different architecture or GStreamer release into the application directory.

## API and Error Handling

- `gst_player_create` returns an opaque handle or null.
- `gst_player_start` accepts an RTSP URL and latency in milliseconds. It returns nonzero for synchronous creation/link/state failures; retrieve the accompanying diagnostic with `gst_player_poll_event`.
- `gst_player_stop` is safe to call repeatedly. A fresh start replaces the existing pipeline.
- `gst_player_copy_latest_frame` returns 1 for a copied BGRA frame, 0 when no new frame is available, -2 when the destination is too small (frame metadata is returned), or -1 for an invalid handle/argument.
- `gst_player_poll_event` returns 1 for an event, 0 when the bounded event queue is empty, or -1 for invalid arguments.
- `gst_player_destroy` removes the handle, stops the pipeline, waits for its bus thread, and releases native resources. Handle lookup and active operations are synchronized so calls already in progress cannot use freed player storage.

Event types are state change (1), warning (2), error (3), end-of-stream (4), and negotiated video format (5). The appsink callback copies into a reusable latest-frame buffer and never calls managed code. A bounded post-decode queue and one-buffer appsink are configured to drop stale frames; the RTSP source uses TCP with `drop-on-latency` and the selected latency.

The managed client also emits diagnostics through `System.Diagnostics.Trace`. A runtime loader error normally indicates a missing/mismatched GStreamer runtime, plugin, MSVC runtime, or an incorrect `GSTREAMER_1_0_ROOT_MSVC_X86_64` setting.
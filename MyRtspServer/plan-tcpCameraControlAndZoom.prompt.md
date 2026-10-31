## Plan: TCP Camera Control and Zoom

Start with the independent TCP server, status, capabilities and zoom controls. Reuse the existing capture session and serialize camera operations separately from frame delivery. Add focus, torch and camera switching in a later increment.

### Steps

1. Extend [CameraCapture.swift](MyRtspServer/CameraCapture.swift) with virtual-camera discovery, exact-format selection and a serial configuration queue.
2. Add device-derived zoom limits, absolute zoom, ramp controls and zoom status without restarting capture or encoding.
3. Create `CameraCommandHandler.swift` with Codable messages, validated zoom commands, status and capabilities.
4. Create `CameraControlServer.swift` with bounded newline framing, client isolation, structured errors and disconnect cleanup.
5. Update [StreamController.swift](MyRtspServer/StreamController.swift) to start and stop both servers together, including failure cleanup.
6. Add protocol and concurrency regression tests; plan focus, torch and camera switching as the next increment.

### Further Considerations

1. Bind to a selected local interface and document that unauthenticated control is for trusted networks; binding alone cannot prevent routing exposure.
2. Use last-command-wins zoom ownership; disconnecting the current ramp owner stops its ramp.
3. AVFoundation ramp rates are logarithmic, not constant zoom-factor units per second. Should `speed` use native ramp-rate semantics?

Is this draft suitable for review?

Windows WPF UI behavioral harness

From the repository root, with the .NET 10 SDK and Windows Desktop runtime:

  dotnet build MyRtspTesterCS\CameraUiTests\CameraUiTests.csproj --artifacts-path MyRtspTesterCS\CameraUiTests\artifacts
  dotnet MyRtspTesterCS\CameraUiTests\artifacts\bin\CameraUiTests\debug\CameraUiTests.dll

Exit code 0 means all scenarios passed. The fake server binds only to loopback
on an ephemeral port. The STA dispatcher hosts an off-screen WPF window; mouse
events are synthetic and no camera or physical input is required. WPF window
creation and mouse capture still require a usable Windows GUI session.

Connection, initialization, persistence, disconnection, and window close use
the actual UI handlers. A non-public constructor supplies an isolated temporary
settings path so the test cannot overwrite the user's saved connection.

The fake server can delay individual responses and process later requests,
allowing verification that a written ramp is followed promptly by stop even
when its response is delayed, and that stale responses do not restore old UI.

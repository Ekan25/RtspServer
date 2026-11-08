using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using CameraController;

internal static class Program
{
    private static readonly TimeSpan Timeout = TimeSpan.FromSeconds(4);
    private const BindingFlags PrivateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
    private static int _failures;

    [STAThread]
    private static int Main()
    {
        Dispatcher dispatcher = Dispatcher.CurrentDispatcher;
        dispatcher.BeginInvoke(async () =>
        {
            try
            {
                await Run("connection, gating and status", ConnectionAndGating);
                await Run("camera and video mode controls", CameraAndVideoModeControls);
                await Run("camera capability gating and explicit playback stop", CameraControlsAndPlaybackStop);
                await Run("camera change disconnect cancellation", CameraChangeDisconnect);
                await Run("photo command gating and BGRA display", PhotoCommandAndBgraDisplay);
                await Run("BGRA frame render buffer layout", FrameRenderBufferLayout);
                await Run("background camera response dispatch", BackgroundCameraResponseDispatch);
                await Run("debounce and stale status", SliderAndStaleStatus);
                await Run("hold/release and deactivation", HoldAndDeactivate);
                await Run("queued hold and failed stop", QueuedHoldAndFailedStop);
                await Run("disconnect, cancellation and reconnect", DisconnectAndReconnect);
                await Run("window close stops active ramp", WindowCloseStopsRamp);
            }
            finally { dispatcher.BeginInvokeShutdown(DispatcherPriority.Background); }
        });
        Dispatcher.Run();
        Console.WriteLine(_failures == 0 ? "All UI tests passed." : $"{_failures} UI test(s) failed.");
        return _failures == 0 ? 0 : 1;
    }

    private static async Task Run(string name, Func<Task> test)
    {
        try { await test(); Console.WriteLine($"PASS {name}"); }
        catch (Exception ex) { _failures++; Console.Error.WriteLine($"FAIL {name}: {ex}"); }
    }

    private static async Task ConnectionAndGating()
    {
        await using var camera = new FakeCamera("status", "setZoom", "capturePhoto");
        await using var ui = new Ui();
        Check(!ui.Slider.IsEnabled && !ui.In.IsEnabled && !ui.Refresh.IsEnabled, "controls initially disabled");
        Check(!ui.Camera.IsEnabled && !ui.Resolution.IsEnabled, "camera controls initially disabled");
        ui.Host.Text = " ";
        Click(ui.Connection);
        Check(ui.Status.Text == "Connection failed" && ui.Error.Text.Contains("Enter an IP address"),
            "connection validation is shown in UI");
        var capabilities = camera.DelayNext("capabilities");
        Task connecting = ui.Connect(camera);
        await capabilities.Received.Task.WaitAsync(Timeout);
        Check(!ui.Slider.IsEnabled && !ui.In.IsEnabled, "controls disabled until capabilities arrive");
        capabilities.Open();
        await connecting;
        Check(ui.Status.Text == "Connected", "connection status");
        Check(string.IsNullOrEmpty(ui.Error.Text), "status-free capabilities and stream responses are accepted");
        Check(ui.Slider.IsEnabled && !ui.In.IsEnabled && !ui.Out.IsEnabled && !ui.Speed.IsEnabled,
            "partial capabilities gate controls");
        Check(ui.CapturePhoto.IsEnabled, "photo capture is enabled only when advertised");
        Check(ui.Refresh.IsEnabled && ui.Device.Text == "Device: Fake camera", "status and refresh");
        Check(!ui.Camera.IsEnabled && !ui.Resolution.IsEnabled, "legacy server cannot enable unsupported camera controls");
        Check(ui.Range.Text == "Zoom range: 1.0x - 8.0x" && ui.Switch.Text.Contains("2.0x") &&
            ui.Ramping.Text == "Ramping: No" && ui.Zoom.Text == "Current zoom: 2.00x", "status fields");
        Check(ui.Slider.Minimum == 1 && ui.Slider.Maximum == 8 && ui.Slider.Value == 2, "slider range");
          Check(camera.Count("getStreamStatus") == 1 && camera.Count("capabilities") == 1 &&
              camera.Count("status") == 1 && camera.Count("setZoom") == 0,
             "initial requests do not feed slider changes back");
        using (var settings = JsonDocument.Parse(File.ReadAllText(ui.SettingsPath)))
        {
            Check(settings.RootElement.GetProperty("Host").GetString() == "127.0.0.1" &&
                  settings.RootElement.GetProperty("Port").GetInt32() == camera.Port, "connection settings saved");
        }
                ui.AutoConnect.IsChecked = true;
                ui.AutoStream.IsChecked = true;
                using (var settings = JsonDocument.Parse(File.ReadAllText(ui.SettingsPath)))
                {
                        Check(settings.RootElement.GetProperty("AutoConnect").GetBoolean() &&
                                    settings.RootElement.GetProperty("AutoStream").GetBoolean() &&
                                    settings.RootElement.GetProperty("LatencyMilliseconds").GetUInt32() == 20,
                                "automation and latency settings saved");
                }
                ui.AutoStream.IsChecked = false;
                ui.AutoConnect.IsChecked = false;
        camera.Commands = new[] { "status", "rampZoom", "stopZoom" };
        await ui.Disconnect();
        await ui.Connect(camera);
        Check(!ui.Slider.IsEnabled && !ui.In.IsEnabled, "ramp requires setZoom capability");
        Check(!ui.CapturePhoto.IsEnabled, "photo capture is disabled when not advertised");
    }

    private static async Task CameraAndVideoModeControls()
    {
        await using var camera = new FakeCamera("status", "setZoom", "setCamera", "getVideoModes", "setVideoMode");
        await using var ui = new Ui();
        await ui.Connect(camera);
        await Until(() => ui.Camera.IsEnabled && ui.Resolution.IsEnabled, "camera and video controls enabled");
        Check(ui.Camera.Items.Count == 2 && ui.Camera.SelectedItem?.ToString() == "Rear camera",
            "current camera and advertised positions displayed");
        Check(ui.Resolution.SelectedItem?.ToString() == "1280 x 720" &&
              ui.FrameRate.Text == "30" && ui.FrameRateRange.Text.Contains("30-60"),
            "active mode and integral fps range displayed");
        Check(camera.Count("setCamera") == 0 && camera.Count("setVideoMode") == 0,
            "initial selection does not send changes");

        ui.FrameRate.Text = "29";
        Click(ui.ApplyVideoMode);
        Check(ui.Error.Text.Contains("whole-number") && camera.Count("setVideoMode") == 0,
            "fps below fractional minimum rejected");
        ui.Resolution.SelectedIndex = 0;
        Check(ui.FrameRateRange.Text.Contains("1-30"), "zero lower bound is clamped to a positive integral fps");
        ui.FrameRate.Text = "25";
        var delayedMode = camera.DelayNext("setVideoMode");
        Click(ui.ApplyVideoMode);
        await delayedMode.Received.Task.WaitAsync(Timeout);
        Check(!ui.Camera.IsEnabled && !ui.Resolution.IsEnabled, "changes disabled while a command is pending");
        Click(ui.ApplyVideoMode);
        delayedMode.Open();
        await Until(() => ui.Resolution.IsEnabled && ui.ActiveMode.Text.Contains("640 x 480 at 25"),
            "updated mode displayed");
        JsonElement mode = camera.Requests.Last(r => Command(r) == "setVideoMode");
        Check(camera.Count("setVideoMode") == 1 && mode.GetProperty("width").GetInt32() == 640 &&
              mode.GetProperty("height").GetInt32() == 480 && mode.GetProperty("fps").GetInt32() == 25,
            "mode command has exact selected dimensions and fps");

        typeof(MainWindow).GetField("_playbackRequested", PrivateInstance)!.SetValue(ui.Window, true);
        ui.Camera.SelectedIndex = 1;
        Click(ui.ApplyCamera);
        await Until(() => camera.Count("getVideoModes") == 1 && ui.Resolution.IsEnabled &&
                          ui.ActiveMode.Text.Contains("1920 x 1080 at 30"), "camera switch refresh");
        JsonElement change = camera.Requests.Last(r => Command(r) == "setCamera");
        Check(change.GetProperty("position").GetString() == "front", "front position sent");
        Check(ui.Resolution.Items.Count == 1 && ui.Resolution.SelectedItem?.ToString() == "1920 x 1080",
            "front camera modes and fallback active mode replace rear modes");
        Check((bool)typeof(MainWindow).GetField("_playbackRequested", PrivateInstance)!.GetValue(ui.Window)! &&
              camera.Count("stopStream") == 0 && camera.Count("startStream") == 0,
            "reconfiguration preserves playback intent without changing shared stream state");
        typeof(MainWindow).GetField("_playbackRequested", PrivateInstance)!.SetValue(ui.Window, false);

        camera.RejectNext("setCamera");
        ui.Camera.SelectedIndex = 0;
        Click(ui.ApplyCamera);
        await Until(() => camera.Count("getVideoModes") == 2 && ui.Camera.IsEnabled &&
                          ui.Error.Text.Contains("Camera change failed"), "failed change refresh and error");
        Check(ui.Resolution.SelectedItem?.ToString() == "1920 x 1080" &&
              ui.Camera.SelectedItem?.ToString() == "Front camera",
            "failed camera change restores actual camera and modes");
    }

    private static async Task CameraChangeDisconnect()
    {
        await using var camera = new FakeCamera("status", "setCamera", "getVideoModes", "setVideoMode");
        await using var ui = new Ui();
        await ui.Connect(camera);
        await Until(() => ui.Camera.IsEnabled, "camera controls initialized");
        var delayed = camera.DelayNext("setCamera");
        ui.Camera.SelectedIndex = 1;
        Click(ui.ApplyCamera);
        await delayed.Received.Task.WaitAsync(Timeout);
        await ui.Disconnect();
        delayed.Open();
        await Task.Delay(100);
        Check(!ui.Camera.IsEnabled && camera.Count("getVideoModes") == 0,
            "disconnect cancels in-flight change without refreshing old session");
    }

    private static async Task CameraControlsAndPlaybackStop()
    {
        await using var camera = new FakeCamera("status", "setCamera", "getVideoModes");
        await using var ui = new Ui();
        await ui.Connect(camera);
        await Until(() => ui.Camera.IsEnabled, "camera controls initialized");
        Check(!ui.Resolution.IsEnabled, "video mode selection requires advertised setVideoMode");
        typeof(MainWindow).GetField("_playbackRequested", PrivateInstance)!.SetValue(ui.Window, true);
        Invoke(ui.Window, "UpdateControls");
        var delayed = camera.DelayNext("setCamera");
        ui.Camera.SelectedIndex = 1;
        Click(ui.ApplyCamera);
        await delayed.Received.Task.WaitAsync(Timeout);
        Click(ui.Playback);
        delayed.Open();
        await Until(() => camera.Count("stopStream") == 1 && ui.Camera.IsEnabled, "explicit stop after reconfiguration");
        Check(!(bool)typeof(MainWindow).GetField("_playbackRequested", PrivateInstance)!.GetValue(ui.Window)! &&
              camera.Count("startStream") == 0, "explicit stop is not undone by camera reconfiguration");
    }

    private static async Task PhotoCommandAndBgraDisplay()
    {
        var photo = new ReceivedPhoto("bgra", 2, 1, 8, [255, 0, 0, 255, 0, 255, 0, 255]);
        BitmapSource bitmap = (BitmapSource)typeof(MainWindow)
            .GetMethod("DecodePhoto", BindingFlags.Static | BindingFlags.NonPublic)!
            .Invoke(null, [photo])!;
        byte[] png = (byte[])typeof(MainWindow)
            .GetMethod("EncodePng", BindingFlags.Static | BindingFlags.NonPublic)!
            .Invoke(null, [bitmap])!;
        Check(bitmap.PixelWidth == 2 && bitmap.PixelHeight == 1, "BGRA photo dimensions are preserved");
        Check(png.Length > 8 && png.Take(8).SequenceEqual(new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }),
            "BGRA photos are encoded as PNG for saving");

        await using var ui = new Ui();
        Check(ui.PhotoFormat.SelectedIndex == 0 && ((ComboBoxItem)ui.PhotoFormat.SelectedItem).Tag?.ToString() == "jpeg",
            "JPEG is the default capture format");
    }

    private static async Task SliderAndStaleStatus()
    {
        await using var camera = FullCamera();
        await using var ui = new Ui();
        await ui.Connect(camera);
        ui.Slider.Value = 3;
        await Task.Delay(40);
        ui.Slider.Value = 4;
        await Task.Delay(40);
        ui.Slider.Value = 5.5;
        await Until(() => camera.Count("setZoom") == 1 && ui.Zoom.Text.Contains("5.50"), "debounced setZoom");
        Check(camera.Requests.Last(r => Command(r) == "setZoom").GetProperty("factor").GetDouble() == 5.5,
            "last slider value sent");
        await Task.Delay(250);
        Check(camera.Count("setZoom") == 1, "only one debounced request");

        var oldStatus = camera.DelayNext("status");
        Click(ui.Refresh);
        await oldStatus.Received.Task.WaitAsync(Timeout);
        var setGate = camera.DelayNext("setZoom");
        ui.Slider.Value = 6.5;
        oldStatus.Open();
        await setGate.Received.Task.WaitAsync(Timeout);
        Check(ui.Slider.Value == 6.5, "old refresh must not overwrite newer slider input");
        setGate.Open();
        await Until(() => ui.Zoom.Text.Contains("6.50"), "new slider response");
    }

    private static async Task BackgroundCameraResponseDispatch()
    {
        await using var camera = FullCamera();
        await using var ui = new Ui();
        await ui.Connect(camera);
        object session = typeof(MainWindow).GetField("_session", PrivateInstance)!.GetValue(ui.Window)!;
        Task initialize = Task.Run(() => (Task)Invoke(ui.Window, "InitializeCameraControlsAsync", session)!);
        await initialize.WaitAsync(Timeout);
        Check(ui.Device.Text == "Device: Fake camera" && string.IsNullOrEmpty(ui.Error.Text),
            "background camera responses are applied on the WPF dispatcher");
    }

    private static async Task FrameRenderBufferLayout()
    {
        await using var ui = new Ui();
        byte[] frame = new byte[2 * 2 * 4];
        var frameInfo = new RtspVideoPlayer.RtspFrameInfo
        {
            Width = 2,
            Height = 2,
            Stride = 2 * 4,
            Sequence = 1
        };
        typeof(MainWindow).GetField("_renderBuffer", PrivateInstance)!.SetValue(ui.Window, frame);
        typeof(MainWindow).GetField("_latestFrameInfo", PrivateInstance)!.SetValue(ui.Window, frameInfo);
        await ui.Window.Dispatcher.InvokeAsync(() => Invoke(ui.Window, "RenderLatestFrame"));
        Check(ui.Video.Source is System.Windows.Media.Imaging.WriteableBitmap { PixelWidth: 2, PixelHeight: 2 },
            "WriteableBitmap accepts the packed BGRA row stride and zero array offset");
    }

    private static async Task HoldAndDeactivate()
    {
        await using var camera = FullCamera();
        await using var ui = new Ui();
        await ui.Connect(camera);
        var delayed = camera.DelayNext("rampZoom");
        ui.Speed.Value = 3;
        Mouse(ui.In, true);
        await delayed.Received.Task.WaitAsync(Timeout);
        Mouse(ui.In, false);
        await Until(() => camera.Count("stopZoom") == 1 && ui.Ramping.Text == "Ramping: No", "release stops delayed ramp");
        delayed.Open();
        await Task.Delay(100);
        Check(ui.Ramping.Text == "Ramping: No", "late ramp response must not restore ramping");
        var requests = camera.Requests.Where(r => Command(r) is "rampZoom" or "stopZoom").ToArray();
        Check(Command(requests[0]) == "rampZoom" && Command(requests[1]) == "stopZoom", "ramp precedes stop");
        Check(requests[0].GetProperty("factor").GetDouble() == 8 &&
              requests[0].GetProperty("speed").GetDouble() == 3, "ramp target and speed");
        Mouse(ui.Out, true);
        await Until(() => camera.Count("rampZoom") == 2, "outward ramp");
        Invoke(ui.Window, "Window_Deactivated", ui.Window, EventArgs.Empty);
        await Until(() => camera.Count("stopZoom") == 2, "deactivation stops ramp");
        Check(camera.Requests.Last(r => Command(r) == "rampZoom").GetProperty("factor").GetDouble() == 1,
            "zoom out targets minimum");

        var status = camera.DelayNext("status");
        Click(ui.Refresh);
        await status.Received.Task.WaitAsync(Timeout);
        Mouse(ui.In, true);
        Mouse(ui.In, false);
        status.Open();
        await Task.Delay(250);
        Check(camera.Count("rampZoom") == 2 && camera.Count("stopZoom") == 2,
            "released queued ramp must never start later");
    }

    private static async Task DisconnectAndReconnect()
    {
        await using var camera = FullCamera();
        await using var ui = new Ui();
        await ui.Connect(camera);
        ui.Slider.Value = 7;
        await ui.Disconnect();
        await Task.Delay(250);
        Check(camera.Count("setZoom") == 0, "disconnect cancels debounce");
        Check(!ui.Slider.IsEnabled && ui.Device.Text == "Connect to load camera status.", "disconnect clears UI");
        await ui.Connect(camera);
        Check(ui.Slider.Value == 2 && ui.Slider.IsEnabled && ui.Status.Text == "Connected", "reconnect reloads state");

        var delayed = camera.DelayNext("status");
        Click(ui.Refresh);
        await delayed.Received.Task.WaitAsync(Timeout);
        await ui.Disconnect();
        delayed.Open();
        await ui.Connect(camera);
        await Task.Delay(150);
        Check(ui.Status.Text == "Connected" && ui.Device.Text == "Device: Fake camera" && ui.Slider.Value == 2,
            "cancelled old session cannot overwrite reconnect");
    }

    private static async Task QueuedHoldAndFailedStop()
    {
        await using var camera = FullCamera();
        await using var ui = new Ui();
        await ui.Connect(camera);
        Mouse(ui.In, true);
        await Until(() => camera.Count("rampZoom") == 1, "initial ramp");
        var delayedStop = camera.DelayNext("stopZoom");
        Mouse(ui.In, false);
        await delayedStop.Received.Task.WaitAsync(Timeout);
        Mouse(ui.Out, true);
        await Task.Delay(100);
        Check(camera.Count("rampZoom") == 1, "new ramp waits for preceding stop");
        Mouse(ui.Out, false);
        Mouse(ui.In, true);
        await Task.Delay(100);
        Check(camera.Count("rampZoom") == 1, "released queued hold preserves preceding stop barrier");
        delayedStop.Open();
        await Until(() => camera.Count("rampZoom") == 2, "held direction starts after stop");
        camera.RejectNextStop();
        Mouse(ui.In, false);
        await Until(() => ui.Status.Text == "Connection failed" &&
                          ui.Error.Text.Contains("disconnected for safety"), "failed stop disconnects");
        Check(!ui.Slider.IsEnabled, "controls disabled after failed stop");
    }

    private static async Task WindowCloseStopsRamp()
    {
        await using var camera = FullCamera();
        await using var ui = new Ui();
        await ui.Connect(camera);
        var delayed = camera.DelayNext("rampZoom");
        Mouse(ui.In, true);
        await delayed.Received.Task.WaitAsync(Timeout);
        await ui.CloseAsync();
        Check(camera.Count("stopZoom") == 1, "window close stops the active ramp before disconnecting");
        delayed.Open();
    }

    private static FakeCamera FullCamera() => new("status", "setZoom", "rampZoom", "stopZoom");
    private static string? Command(System.Text.Json.JsonElement request) => request.GetProperty("command").GetString();
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static void Click(Button button) => button.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
    private static void Mouse(Button button, bool down)
    {
        var args = new MouseButtonEventArgs(System.Windows.Input.Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left)
        { RoutedEvent = down ? UIElement.PreviewMouseLeftButtonDownEvent : UIElement.PreviewMouseLeftButtonUpEvent };
        button.RaiseEvent(args);
    }
    private static object? Invoke(object target, string name, params object?[] args) =>
        target.GetType().GetMethod(name, PrivateInstance)!.Invoke(target, args);
    private static async Task Until(Func<bool> predicate, string description)
    {
        var watch = Stopwatch.StartNew();
        while (!predicate())
        {
            if (watch.Elapsed > Timeout) throw new TimeoutException(description);
            await Task.Delay(10);
        }
    }

    private sealed class Ui : IAsyncDisposable
    {
        private readonly string _directory = Path.Combine(Path.GetTempPath(), "RtspTesterUiTests", Guid.NewGuid().ToString("N"));
        private bool _closed;
        public string SettingsPath => Path.Combine(_directory, "connection.json");
        public MainWindow Window { get; }
        public Ui()
        {
            Window = (MainWindow)Activator.CreateInstance(typeof(MainWindow),
                BindingFlags.Instance | BindingFlags.NonPublic, null, [SettingsPath], null)!;
            Window.ShowInTaskbar = false;
            Window.WindowStartupLocation = WindowStartupLocation.Manual;
            Window.Left = -32000;
            Window.Top = -32000;
            Window.ShowActivated = false;
            Window.Show();
        }
        private T Find<T>(string name) where T : class => (T)Window.FindName(name);
        public Slider Slider => Find<Slider>("ZoomSlider");
        public Slider Speed => Find<Slider>("SpeedSlider");
        public CheckBox AutoConnect => Find<CheckBox>("AutoConnectCheckBox");
        public CheckBox AutoStream => Find<CheckBox>("AutoStreamCheckBox");
        public Button In => Find<Button>("ZoomInButton");
        public Button Out => Find<Button>("ZoomOutButton");
        public Button Refresh => Find<Button>("RefreshButton");
        public Button Connection => Find<Button>("ConnectionButton");
        public Button CapturePhoto => Find<Button>("CapturePhotoButton");
        public Button Playback => Find<Button>("PlaybackButton");
        public ComboBox PhotoFormat => Find<ComboBox>("PhotoFormatComboBox");
        public ComboBox Camera => Find<ComboBox>("CameraComboBox");
        public ComboBox Resolution => Find<ComboBox>("ResolutionComboBox");
        public TextBox FrameRate => Find<TextBox>("FrameRateTextBox");
        public TextBlock FrameRateRange => Find<TextBlock>("FrameRateRangeTextBlock");
        public TextBlock ActiveMode => Find<TextBlock>("ActiveVideoModeTextBlock");
        public Button ApplyCamera => Find<Button>("ApplyCameraButton");
        public Button ApplyVideoMode => Find<Button>("ApplyVideoModeButton");
        public TextBox Host => Find<TextBox>("HostTextBox");
        public TextBlock Error => Find<TextBlock>("ErrorTextBlock");
        public TextBlock Status => Find<TextBlock>("StatusTextBlock");
        public TextBlock Device => Find<TextBlock>("DeviceTextBlock");
        public TextBlock Range => Find<TextBlock>("RangeTextBlock");
        public TextBlock Switch => Find<TextBlock>("SwitchOverTextBlock");
        public TextBlock Ramping => Find<TextBlock>("RampingTextBlock");
        public TextBlock Zoom => Find<TextBlock>("ZoomTextBlock");
        public Image Video => Find<Image>("VideoImage");

        public async Task Connect(FakeCamera camera)
        {
            int previous = camera.Count("status");
            Host.Text = "127.0.0.1";
            Find<TextBox>("PortTextBox").Text = camera.Port.ToString();
            Click(Connection);
            await Until(() => Status.Text == "Connected" && camera.Count("status") > previous &&
                              Device.Text == "Device: Fake camera", "connection and initial status");
        }
        public async Task Disconnect()
        {
            Click(Connection);
            await Until(() => Status.Text == "Disconnected", "disconnect");
        }

        public async Task CloseAsync()
        {
            if (_closed)
                return;
            var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            Window.Closed += (_, _) => closed.TrySetResult();
            Window.Close();
            await closed.Task.WaitAsync(Timeout);
            _closed = true;
        }

        public async ValueTask DisposeAsync()
        {
            await CloseAsync();
            if (Directory.Exists(_directory))
                Directory.Delete(_directory, true);
        }
    }
}

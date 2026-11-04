using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
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
        await using var camera = new FakeCamera("status", "setZoom");
        await using var ui = new Ui();
        Check(!ui.Slider.IsEnabled && !ui.In.IsEnabled && !ui.Refresh.IsEnabled, "controls initially disabled");
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
        Check(ui.Slider.IsEnabled && !ui.In.IsEnabled && !ui.Out.IsEnabled && !ui.Speed.IsEnabled,
            "partial capabilities gate controls");
        Check(ui.Refresh.IsEnabled && ui.Device.Text == "Device: Fake camera", "status and refresh");
        Check(ui.Range.Text == "Zoom range: 1.0x - 8.0x" && ui.Switch.Text.Contains("2.0x") &&
            ui.Ramping.Text == "Ramping: No" && ui.Zoom.Text == "Current zoom: 2.00x", "status fields");
        Check(ui.Slider.Minimum == 1 && ui.Slider.Maximum == 8 && ui.Slider.Value == 2, "slider range");
        Check(camera.Count("capabilities") == 1 && camera.Count("status") == 1 && camera.Count("setZoom") == 0,
             "initial requests do not feed slider changes back");
        using (var settings = JsonDocument.Parse(File.ReadAllText(ui.SettingsPath)))
        {
            Check(settings.RootElement.GetProperty("Host").GetString() == "127.0.0.1" &&
                  settings.RootElement.GetProperty("Port").GetInt32() == camera.Port, "connection settings saved");
        }
        camera.Commands = new[] { "status", "rampZoom", "stopZoom" };
        await ui.Disconnect();
        await ui.Connect(camera);
        Check(!ui.Slider.IsEnabled && !ui.In.IsEnabled, "ramp requires setZoom capability");
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
        public Button In => Find<Button>("ZoomInButton");
        public Button Out => Find<Button>("ZoomOutButton");
        public Button Refresh => Find<Button>("RefreshButton");
        public Button Connection => Find<Button>("ConnectionButton");
        public TextBox Host => Find<TextBox>("HostTextBox");
        public TextBlock Error => Find<TextBlock>("ErrorTextBlock");
        public TextBlock Status => Find<TextBlock>("StatusTextBlock");
        public TextBlock Device => Find<TextBlock>("DeviceTextBlock");
        public TextBlock Range => Find<TextBlock>("RangeTextBlock");
        public TextBlock Switch => Find<TextBlock>("SwitchOverTextBlock");
        public TextBlock Ramping => Find<TextBlock>("RampingTextBlock");
        public TextBlock Zoom => Find<TextBlock>("ZoomTextBlock");

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

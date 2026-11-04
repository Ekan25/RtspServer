using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace CameraController;

public partial class MainWindow : Window
{
    private readonly CameraControlClient _client = new();
    private readonly CancellationTokenSource _windowCancellation = new();
    private CameraSession? _session;
    private ZoomPress? _zoomPress;
    private Task _stopTask = Task.CompletedTask;
    private CancellationTokenSource? _sliderCancellation;
    private bool _updatingSlider;
    private bool _busy;
    private bool _connecting;
    private bool _closing;
    private bool _allowClose;
    private bool _connectionFailed;

    private static string DefaultSettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "RtspTester", "connection.json");
    private readonly string _settingsPath;

    public MainWindow() : this(DefaultSettingsPath)
    {
    }

    internal MainWindow(string settingsPath)
    {
        _settingsPath = settingsPath;
        InitializeComponent();
        _client.ConnectionChanged += Client_ConnectionChanged;
        _client.Error += Client_Error;
        LoadSettings();
    }

    private void LoadSettings()
    {
        try
        {
            if (!File.Exists(_settingsPath))
                return;
            var settings = JsonSerializer.Deserialize<ConnectionSettings>(File.ReadAllText(_settingsPath))
                ?? throw new JsonException("Connection settings are empty.");
            HostTextBox.Text = settings.Host;
            PortTextBox.Text = settings.Port.ToString(CultureInfo.InvariantCulture);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            ErrorTextBlock.Text = $"Could not load connection settings: {ex.Message}";
        }
    }

    private void SaveSettings(string host, int port)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_settingsPath)!);
        File.WriteAllText(_settingsPath, JsonSerializer.Serialize(new ConnectionSettings(host, port)));
    }

    private async void ConnectionButton_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _closing)
            return;

        _busy = true;
        ErrorTextBlock.Text = "";
        _connectionFailed = false;
        try
        {
            if (_client.IsConnected)
            {
                CancelSlider();
                await StopContinuousZoomAsync();
                ClearSession();
                await _client.DisconnectAsync();
            }
            else
            {
                string host = HostTextBox.Text.Trim();
                if (string.IsNullOrWhiteSpace(host))
                    throw new ArgumentException("Enter an IP address or hostname.");
                if (!int.TryParse(PortTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out int port) ||
                    port is < 1 or > 65535)
                    throw new ArgumentException("Enter a TCP port from 1 to 65535.");

                SaveSettings(host, port);
                HostTextBox.Text = host;
                _connecting = true;
                UpdateControls();
                await _client.ConnectAsync(host, port, _windowCancellation.Token);
                if (!_client.IsConnected || _closing)
                    return;

                ClearSession();
                var session = new CameraSession();
                _session = session;
                _ = InitializeCameraAsync(session);
            }
        }
        catch (OperationCanceledException) when (_closing)
        {
        }
        catch (Exception ex)
        {
            if (!_closing)
            {
                _connectionFailed = true;
                ErrorTextBlock.Text = ex.Message;
            }
        }
        finally
        {
            _connecting = false;
            _busy = false;
            if (!_closing)
                UpdateControls();
        }
    }

    private async Task InitializeCameraAsync(CameraSession session)
    {
        var capabilities = await RunCommandAsync(session, "capabilities");
        if (capabilities is null || !IsCurrent(session))
            return;
        if (capabilities.Commands is null)
        {
            ErrorTextBlock.Text = "The camera did not report its supported commands.";
            return;
        }
        session.Commands = new HashSet<string>(capabilities.Commands, StringComparer.Ordinal);
        UpdateControls();
        await RunCommandAsync(session, "status", revision: session.Revision);
    }

    private async Task<CameraResponse?> RunCommandAsync(
        CameraSession session, string command, object? parameters = null,
        CancellationToken cancellationToken = default, long? revision = null)
    {
        if (!IsCurrent(session))
            return null;

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(session.Token, cancellationToken);
        try
        {
            await session.CommandLock.WaitAsync(linked.Token);
            try
            {
                if (!IsCurrent(session))
                    return null;
                CameraResponse response = await _client.SendCommandAsync(command, parameters, linked.Token);
                if (IsCurrent(session) && !linked.IsCancellationRequested)
                    ApplyResponse(session, response, revision);
                return response;
            }
            finally
            {
                session.CommandLock.Release();
            }
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception ex)
        {
            if (IsCurrent(session) && !_closing)
                ErrorTextBlock.Text = ex.Message;
            return null;
        }
    }

    private void ApplyResponse(CameraSession session, CameraResponse response, long? revision)
    {
        if (response.Status is not { } status)
            throw new InvalidDataException("The camera response did not include status.");
        if (!double.IsFinite(status.MinFactor) || !double.IsFinite(status.MaxFactor) ||
            !double.IsFinite(status.Factor) || status.MinFactor <= 0 ||
            status.MaxFactor < status.MinFactor || status.Factor < status.MinFactor ||
            status.Factor > status.MaxFactor || status.DeviceName is null ||
            status.SwitchOverFactors is null || status.SwitchOverFactors.Any(f => !double.IsFinite(f)))
            throw new InvalidDataException("The camera reported invalid status.");
        if (revision.HasValue && revision.Value != session.Revision)
            return;

        session.Status = status;
        DeviceTextBlock.Text = $"Device: {status.DeviceName}";
        RangeTextBlock.Text = $"Zoom range: {status.MinFactor:0.0}x - {status.MaxFactor:0.0}x";
        SwitchOverTextBlock.Text = status.SwitchOverFactors.Length == 0 ? "" :
            "Lens switch-over: " + string.Join(", ", status.SwitchOverFactors.Select(f => $"{f:0.0}x"));
        RampingTextBlock.Text = $"Ramping: {(status.IsRamping ? "Yes" : "No")}";
        ZoomTextBlock.Text = $"Current zoom: {status.Factor:0.00}x";
        _updatingSlider = true;
        try
        {
            // Set the maximum first so WPF never coerces the minimum against an old maximum.
            ZoomSlider.Minimum = Math.Min(ZoomSlider.Minimum, status.MinFactor);
            ZoomSlider.Maximum = status.MaxFactor;
            ZoomSlider.Minimum = status.MinFactor;
            ZoomSlider.Value = status.Factor;
        }
        finally
        {
            _updatingSlider = false;
        }
        UpdateControls();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        if (_session is { } session)
        {
            ErrorTextBlock.Text = "";
            await RunCommandAsync(session, "status", revision: session.Revision);
        }
    }

    private async void ZoomSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (_updatingSlider || _session is not { } session || !CanSetZoom(session))
            return;

        CancelSlider();
        var cancellation = new CancellationTokenSource();
        _sliderCancellation = cancellation;
        ++session.Revision;
        double factor = e.NewValue;
        try
        {
            await Task.Delay(150, cancellation.Token);
            await StopContinuousZoomAsync();
            if (!cancellation.IsCancellationRequested && IsCurrent(session))
            {
                long revision = ++session.Revision;
                await RunCommandAsync(session, "setZoom", new { factor }, cancellation.Token, revision);
            }
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
        {
        }
        finally
        {
            if (ReferenceEquals(_sliderCancellation, cancellation))
                _sliderCancellation = null;
            cancellation.Dispose();
        }
    }

    private void CancelSlider()
    {
        _sliderCancellation?.Cancel();
        _sliderCancellation = null;
    }

    private void SpeedSlider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (SpeedTextBlock is not null)
            SpeedTextBlock.Text = e.NewValue.ToString("0.0", CultureInfo.CurrentCulture);
    }

    private bool CanSetZoom(CameraSession session) =>
        IsCurrent(session) && session.Status is not null && session.Commands.Contains("setZoom");

    private bool CanRampZoom(CameraSession session) =>
        CanSetZoom(session) && session.Commands.Contains("rampZoom") && session.Commands.Contains("stopZoom");

    private void StartContinuousZoom(Button button, TouchDevice? touch)
    {
        if (_session is not { } session || !CanRampZoom(session) || session.Status is not { } status)
            return;

        if (_zoomPress is { } current)
        {
            if (ReferenceEquals(current.Button, button))
                return;
            _ = StopContinuousZoomAsync();
        }
        CancelSlider();
        long revision = ++session.Revision;
        var press = new ZoomPress(session, button, touch, _stopTask);
        _zoomPress = press;
        bool captured = touch is null ? button.CaptureMouse() : touch.Capture(button);
        if (!captured)
        {
            _zoomPress = null;
            ErrorTextBlock.Text = "Could not capture zoom input.";
            return;
        }

        double factor = (string)button.Tag == "in" ? status.MaxFactor : status.MinFactor;
        double speed = SpeedSlider.Value;
        press.StartTask = RunRampAsync(press, factor, speed, revision);
        _ = ObserveStartAsync(press);
    }

    private async Task<CameraResponse?> RunRampAsync(ZoomPress press, double factor, double speed, long revision)
    {
        CameraSession session = press.Session;
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(session.Token, press.StartCancellation.Token);
        Task<CameraResponse>? request = null;
        try
        {
            await press.PreviousStop.WaitAsync(linked.Token);
            await session.CommandLock.WaitAsync(linked.Token);
            try
            {
                if (!IsCurrent(session))
                    return null;
                request = _client.SendCommandWithWriteNotificationAsync(
                    "rampZoom", new { factor, speed }, press.Written, linked.Token);
                await press.Written.Task;
            }
            finally
            {
                session.CommandLock.Release();
            }

            var response = await request;
            if (IsCurrent(session) && !linked.IsCancellationRequested)
                ApplyResponse(session, response, revision);
            return response;
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception ex)
        {
            if (IsCurrent(session) && !_closing)
                ErrorTextBlock.Text = ex.Message;
            return null;
        }
        finally
        {
            press.Written.TrySetResult(false);
            press.StartCancellation.Dispose();
        }
    }

    private async Task ObserveStartAsync(ZoomPress press)
    {
        var response = await press.StartTask;
        if (response is null && ReferenceEquals(_zoomPress, press))
            await StopContinuousZoomAsync();
    }

    private Task StopContinuousZoomAsync()
    {
        ZoomPress? press = _zoomPress;
        if (press is null)
            return _stopTask;

        _zoomPress = null;
        long revision = ++press.Session.Revision;
        if (!press.Written.Task.IsCompleted)
            press.StartCancellation.Cancel();
        _stopTask = StopZoomCoreAsync(press, revision);
        if (press.Touch is null && press.Button.IsMouseCaptured)
            press.Button.ReleaseMouseCapture();
        else if (press.Touch?.Captured == press.Button)
            press.Touch.Capture(null);
        return _stopTask;
    }

    private async Task StopZoomCoreAsync(ZoomPress press, long revision)
    {
        // Never allow a queued ramp to start after release; stop promptly once a ramp was written.
        if (!await press.Written.Task)
        {
            await press.PreviousStop;
            return;
        }
        if (!IsCurrent(press.Session))
            return;
        try
        {
            CameraResponse response = await _client.SendCommandAsync("stopZoom", cancellationToken: press.Session.Token);
            if (IsCurrent(press.Session))
                ApplyResponse(press.Session, response, revision);
        }
        catch (OperationCanceledException) when (press.Session.Token.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            if (IsCurrent(press.Session))
            {
                await _client.DisconnectAsync();
                if (ReferenceEquals(_session, press.Session))
                    ClearSession();
                if (!_closing)
                {
                    _connectionFailed = true;
                    ErrorTextBlock.Text = $"Zoom stop failed; disconnected for safety: {ex.Message}";
                    UpdateControls();
                }
            }
        }
    }

    private void Zoom_PreviewMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.StylusDevice is not null)
            return;
        e.Handled = true;
        StartContinuousZoom((Button)sender, null);
    }

    private void Zoom_PreviewMouseLeftButtonUp(object sender, MouseButtonEventArgs e)
    {
        if (e.StylusDevice is not null)
            return;
        e.Handled = true;
        if (_zoomPress is { Touch: null } press && ReferenceEquals(press.Button, sender))
            _ = StopContinuousZoomAsync();
    }

    private void Zoom_MouseLeave(object sender, MouseEventArgs e)
    {
        if (_zoomPress is { Touch: null } press && ReferenceEquals(press.Button, sender))
            _ = StopContinuousZoomAsync();
    }

    private void Zoom_LostMouseCapture(object sender, MouseEventArgs e)
    {
        if (_zoomPress is { Touch: null } press && ReferenceEquals(press.Button, sender))
            _ = StopContinuousZoomAsync();
    }

    private void Zoom_PreviewTouchDown(object sender, TouchEventArgs e)
    {
        e.Handled = true;
        StartContinuousZoom((Button)sender, e.TouchDevice);
    }

    private void Zoom_PreviewTouchUp(object sender, TouchEventArgs e)
    {
        e.Handled = true;
        StopTouchZoom(sender, e.TouchDevice);
    }

    private void Zoom_TouchLeave(object sender, TouchEventArgs e) => StopTouchZoom(sender, e.TouchDevice);
    private void Zoom_LostTouchCapture(object sender, TouchEventArgs e) => StopTouchZoom(sender, e.TouchDevice);

    private void StopTouchZoom(object sender, TouchDevice touch)
    {
        if (_zoomPress is { } press && ReferenceEquals(press.Button, sender) &&
            ReferenceEquals(press.Touch, touch))
            _ = StopContinuousZoomAsync();
    }

    private void Window_Deactivated(object? sender, EventArgs e) => _ = StopContinuousZoomAsync();

    private void Client_ConnectionChanged(object? sender, EventArgs e)
    {
        _ = Dispatcher.BeginInvoke(() =>
        {
            if (_closing)
                return;
            if (!_client.IsConnected)
                ClearSession();
            UpdateControls();
        });
    }

    private void Client_Error(object? sender, string message)
    {
        _ = Dispatcher.BeginInvoke(() =>
        {
            if (!_closing)
            {
                _connectionFailed = !_client.IsConnected;
                ErrorTextBlock.Text = message;
                UpdateControls();
            }
        });
    }

    private bool IsCurrent(CameraSession session) =>
        ReferenceEquals(_session, session) && !session.Token.IsCancellationRequested && _client.IsConnected;

    private void ClearSession()
    {
        CancelSlider();
        _session?.Cancellation.Cancel();
        _session = null;
        ZoomPress? press = _zoomPress;
        _zoomPress = null;
        if (press?.Touch is null && press?.Button.IsMouseCaptured == true)
            press.Button.ReleaseMouseCapture();
        else if (press?.Touch?.Captured == press?.Button)
            press?.Touch?.Capture(null);
        _stopTask = Task.CompletedTask;
        DeviceTextBlock.Text = "Connect to load camera status.";
        RangeTextBlock.Text = "";
        SwitchOverTextBlock.Text = "";
        RampingTextBlock.Text = "";
        ZoomTextBlock.Text = "Current zoom: not reported";
    }

    private void UpdateControls()
    {
        bool connected = _client.IsConnected;
        ConnectionButton.Content = connected ? "Disconnect" : "Connect";
        ConnectionButton.IsEnabled = !_busy && !_closing;
        HostTextBox.IsEnabled = !_busy && !connected && !_closing;
        PortTextBox.IsEnabled = !_busy && !connected && !_closing;
        bool available = !_busy && !_closing && _session is { } session && IsCurrent(session);
        RefreshButton.IsEnabled = available;
        bool canSet = available && CanSetZoom(_session!);
        bool canRamp = available && CanRampZoom(_session!);
        ZoomSlider.IsEnabled = canSet;
        SpeedSlider.IsEnabled = canRamp;
        ZoomInButton.IsEnabled = canRamp;
        ZoomOutButton.IsEnabled = canRamp;
        StatusTextBlock.Text = _connecting ? "Connecting..." : connected ? "Connected" :
            _connectionFailed ? "Connection failed" : "Disconnected";
    }

    protected override async void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (e.Cancel || _allowClose)
            return;

        e.Cancel = true;
        if (_closing)
            return;

        _closing = true;
        _windowCancellation.Cancel();
        CancelSlider();
        UpdateControls();
        try
        {
            await StopContinuousZoomAsync();
            ClearSession();
            _client.ConnectionChanged -= Client_ConnectionChanged;
            _client.Error -= Client_Error;
            await _client.DisposeAsync();
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Could not disconnect", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        finally
        {
            _windowCancellation.Dispose();
            _allowClose = true;
            _ = Dispatcher.BeginInvoke(new Action(Close));
        }
    }

    private sealed record ConnectionSettings(string Host, int Port);

    private sealed class CameraSession
    {
        public CancellationTokenSource Cancellation { get; } = new();
        public CancellationToken Token => Cancellation.Token;
        public SemaphoreSlim CommandLock { get; } = new(1, 1);
        public HashSet<string> Commands { get; set; } = new(StringComparer.Ordinal);
        public CameraStatus? Status { get; set; }
        public long Revision { get; set; }
    }

    private sealed class ZoomPress(CameraSession session, Button button, TouchDevice? touch, Task previousStop)
    {
        public CameraSession Session { get; } = session;
        public Button Button { get; } = button;
        public TouchDevice? Touch { get; } = touch;
        public Task PreviousStop { get; } = previousStop;
        public CancellationTokenSource StartCancellation { get; } = new();
        public TaskCompletionSource<bool> Written { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task<CameraResponse?> StartTask { get; set; } = Task.FromResult<CameraResponse?>(null);
    }
}

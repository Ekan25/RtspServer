using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Microsoft.Win32;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

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
    private bool _updatingCameraControls;
    private bool _reconfiguring;
    private bool _busy;
    private bool _connecting;
    private bool _closing;
    private bool _allowClose;
    private bool _connectionFailed;
    private bool _settingsLoaded;
    private volatile bool _suppressAutoConnect;
    private volatile bool _playbackRequested;
    private bool _suppressAutoStream;
    private CancellationTokenSource? _autoConnectCancellation;
    private Task? _autoConnectTask;
    private CancellationTokenSource? _playbackCancellation;
    private Task? _playbackTask;
    private readonly object _renderLock = new();
    private byte[]? _renderBuffer;
    private RtspVideoPlayer.RtspFrameInfo _latestFrameInfo;
    private ulong _renderedSequence;
    private int _renderPending;
    private WriteableBitmap? _videoBitmap;
    private ReceivedPhoto? _capturedPhoto;
    private BitmapSource? _capturedImage;
    private bool _capturingPhoto;
    private readonly Action _renderLatestFrameAction;
    private PlaybackState _playbackState = PlaybackState.Disconnected;

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
        _renderLatestFrameAction = RenderLatestFrame;
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
            AutoConnectCheckBox.IsChecked = settings.AutoConnect;
            AutoStreamCheckBox.IsChecked = settings.AutoStream;
            LatencyTextBox.Text = settings.LatencyMilliseconds.ToString(CultureInfo.InvariantCulture);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            ErrorTextBlock.Text = $"Could not load connection settings: {ex.Message}";
        }
    }

    private void SaveSettings(string host, int port)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_settingsPath)!);
        File.WriteAllText(_settingsPath, JsonSerializer.Serialize(new ConnectionSettings
        {
            Host = host,
            Port = port,
            AutoConnect = AutoConnectCheckBox.IsChecked == true,
            AutoStream = AutoStreamCheckBox.IsChecked == true,
            LatencyMilliseconds = ParseLatency()
        }));
    }

    private void Window_Loaded(object sender, RoutedEventArgs e)
    {
        _settingsLoaded = true;
        if (AutoConnectCheckBox.IsChecked == true)
            StartAutoConnectLoop();
        UpdateControls();
    }

    private void AutoConnect_Changed(object sender, RoutedEventArgs e)
    {
        if (!_settingsLoaded)
            return;
        SaveCurrentSettings();
        if (AutoConnectCheckBox.IsChecked == true)
        {
            _suppressAutoConnect = false;
            StartAutoConnectLoop();
        }
        else
            CancelAutoConnectLoop();
    }

    private void AutoStream_Changed(object sender, RoutedEventArgs e)
    {
        if (!_settingsLoaded)
            return;
        SaveCurrentSettings();
        if (AutoStreamCheckBox.IsChecked == true && _session is { } session && IsCurrent(session))
        {
            _suppressAutoStream = false;
            StartPlayback();
        }
    }

    private void SaveCurrentSettings()
    {
        if (!int.TryParse(PortTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out int port) ||
            port is < 1 or > 65535)
            return;
        try { _ = ParseLatency(); }
        catch (ArgumentException) { return; }
        try { SaveSettings(HostTextBox.Text.Trim(), port); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            ErrorTextBlock.Text = $"Could not save settings: {ex.Message}";
        }
    }

    private void StartAutoConnectLoop()
    {
        if (_closing || _suppressAutoConnect || AutoConnectCheckBox.IsChecked != true ||
            _client.IsConnected || _autoConnectTask is { IsCompleted: false })
            return;

        _autoConnectCancellation?.Cancel();
        _autoConnectCancellation?.Dispose();
        var cancellation = new CancellationTokenSource();
        _autoConnectCancellation = cancellation;
        _autoConnectTask = AutoConnectLoopAsync(cancellation.Token);
    }

    private void CancelAutoConnectLoop()
    {
        _autoConnectCancellation?.Cancel();
        _autoConnectCancellation = null;
    }

    private async Task AutoConnectLoopAsync(CancellationToken cancellationToken)
    {
        bool autoConnectEnabled = AutoConnectCheckBox.IsChecked == true;
        string host = HostTextBox.Text.Trim();
        if (!autoConnectEnabled || string.IsNullOrWhiteSpace(host) ||
            !int.TryParse(PortTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out int port) ||
            port is < 1 or > 65535)
            return;

        TimeSpan retryDelay = TimeSpan.FromSeconds(2);
        while (!cancellationToken.IsCancellationRequested && !_closing && !_suppressAutoConnect &&
             autoConnectEnabled && !_client.IsConnected)
        {
            try
            {
                await Dispatcher.InvokeAsync(() =>
                {
                    _connecting = true;
                    UpdateControls();
                    ErrorTextBlock.Text = "";
                });
                await _client.ConnectAsync(host, port, cancellationToken).ConfigureAwait(false);
                await Dispatcher.InvokeAsync(() =>
                {
                    if (_closing || !_client.IsConnected)
                        return;
                    _connecting = false;
                    _connectionFailed = false;
                    ClearSession();
                    _session = new CameraSession();
                    UpdateControls();
                    _ = InitializeCameraAsync(_session);
                });
                return;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                await Dispatcher.InvokeAsync(() =>
                {
                    if (!_closing && !_suppressAutoConnect)
                    {
                        _connecting = false;
                        _connectionFailed = true;
                        ErrorTextBlock.Text = $"Auto Connect: {ex.Message}";
                        UpdateControls();
                    }
                });
                try { await Task.Delay(retryDelay, cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                retryDelay = TimeSpan.FromSeconds(Math.Min(retryDelay.TotalSeconds * 2, 15));
            }
        }
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
                _suppressAutoConnect = true;
                CancelAutoConnectLoop();
                CancelSlider();
                await StopContinuousZoomAsync();
                await StopPlaybackAsync(sendServerStop: false);
                ClearSession();
                await _client.DisconnectAsync();
            }
            else
            {
                CancelAutoConnectLoop();
                string host = HostTextBox.Text.Trim();
                if (string.IsNullOrWhiteSpace(host))
                    throw new ArgumentException("Enter an IP address or hostname.");
                if (!int.TryParse(PortTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out int port) ||
                    port is < 1 or > 65535)
                    throw new ArgumentException("Enter a TCP port from 1 to 65535.");

                _ = ParseLatency();
                _suppressAutoConnect = false;
                _suppressAutoStream = false;
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
        CameraResponse? response = await RunStreamCommandAsync(session, "getStreamStatus", session.Token);
        if (response is null || !IsCurrent(session))
            return;

        session.Commands.UnionWith(["getStreamStatus", "startStream", "stopStream"]);
        CameraStreamStatus? streamStatus = response.Stream ?? response.StreamStatus;
        if (streamStatus is null)
        {
            ErrorTextBlock.Text = "The camera did not report stream status.";
            return;
        }
        UpdateControls();

        if (streamStatus.IsReady)
            await InitializeCameraControlsAsync(session);

        if (AutoStreamCheckBox.IsChecked == true && !_suppressAutoStream && IsCurrent(session))
            StartPlayback();
    }

    private async Task InitializeCameraControlsAsync(CameraSession session)
    {
        var capabilities = await RunCommandAsync(session, "capabilities");
        if (capabilities is null || !IsCurrent(session))
            return;
        await Dispatcher.InvokeAsync(() =>
        {
            if (!IsCurrent(session))
                return;
            if (capabilities.Commands is not null)
                session.Commands.UnionWith(capabilities.Commands);
            UpdateControls();
        }).Task.ConfigureAwait(false);
        await RunCommandAsync(session, "status").ConfigureAwait(false);
    }

    private void PlaybackButton_Click(object sender, RoutedEventArgs e)
    {
        if (_playbackRequested)
            _ = StopPlaybackAsync(sendServerStop: true);
        else
        {
            _suppressAutoStream = false;
            StartPlayback();
        }
    }

    private async void CapturePhoto_Click(object sender, RoutedEventArgs e)
    {
        if (_capturingPhoto || _closing || _session is not { } session || !IsCurrent(session))
            return;
        if (!session.Commands.Contains("capturePhoto"))
        {
            ErrorTextBlock.Text = "The camera does not support high-resolution photo capture.";
            return;
        }

        string format = (PhotoFormatComboBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "jpeg";
        _capturingPhoto = true;
        PhotoStatusTextBlock.Text = "Capturing full-resolution image...";
        ErrorTextBlock.Text = "";
        UpdateControls();
        try
        {
            CameraResponse? response = await RunCommandAsync(session, "capturePhoto", new { format }, session.Token);
            if (response?.Photo is not { } transferInfo || !IsCurrent(session))
                return;

            PhotoStatusTextBlock.Text = "Receiving image...";
            ReceivedPhoto photo = await PhotoTransferClient.ReceiveAsync(transferInfo, session.Token);
            BitmapSource image = await Task.Run(() => DecodePhoto(photo), session.Token);
            if (!IsCurrent(session))
                return;

            _capturedPhoto = photo;
            _capturedImage = image;
            PhotoImage.Source = image;
            PhotoImage.Visibility = Visibility.Visible;
            VideoImage.Visibility = Visibility.Collapsed;
            VideoStateTextBlock.Visibility = Visibility.Collapsed;
            PhotoStatusTextBlock.Text = $"{photo.Width} x {photo.Height} {photo.Format.ToUpperInvariant()}";
            UpdateControls();
        }
        catch (OperationCanceledException) when (session.Token.IsCancellationRequested || _closing)
        {
        }
        catch (Exception ex)
        {
            PhotoStatusTextBlock.Text = "Photo capture failed.";
            ErrorTextBlock.Text = ex.Message;
        }
        finally
        {
            _capturingPhoto = false;
            UpdateControls();
        }
    }

    private void ShowLiveVideo_Click(object sender, RoutedEventArgs e)
    {
        PhotoImage.Visibility = Visibility.Collapsed;
        VideoImage.Visibility = Visibility.Visible;
        VideoStateTextBlock.Visibility = _playbackState == PlaybackState.Playing
            ? Visibility.Collapsed : Visibility.Visible;
    }

    private async void SavePhoto_Click(object sender, RoutedEventArgs e)
    {
        if (_capturedPhoto is not { } photo || _capturedImage is not { } image)
            return;

        bool isJpeg = photo.Format == "jpeg";
        var dialog = new SaveFileDialog
        {
            FileName = $"capture-{DateTime.Now:yyyyMMdd-HHmmss}.{(isJpeg ? "jpg" : "png")}",
            Filter = isJpeg ? "JPEG image|*.jpg;*.jpeg" : "PNG image|*.png",
            DefaultExt = isJpeg ? ".jpg" : ".png",
            AddExtension = true,
            OverwritePrompt = true
        };
        if (dialog.ShowDialog(this) != true)
            return;

        try
        {
            byte[] data = isJpeg ? photo.Data : await Task.Run(() => EncodePng(image));
            await File.WriteAllBytesAsync(dialog.FileName, data);
            PhotoStatusTextBlock.Text = $"Saved {Path.GetFileName(dialog.FileName)}";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException)
        {
            ErrorTextBlock.Text = $"Could not save photo: {ex.Message}";
        }
    }

    private static BitmapSource DecodePhoto(ReceivedPhoto photo)
    {
        if (photo.Format == "jpeg")
        {
            using var stream = new MemoryStream(photo.Data, writable: false);
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = stream;
            image.EndInit();
            image.Freeze();
            return image;
        }

        var bitmap = new WriteableBitmap(photo.Width, photo.Height, 96, 96,
            System.Windows.Media.PixelFormats.Pbgra32, null);
        bitmap.WritePixels(new Int32Rect(0, 0, photo.Width, photo.Height), photo.Data, photo.RowStride, 0);
        bitmap.Freeze();
        return bitmap;
    }

    private static byte[] EncodePng(BitmapSource image)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(image));
        using var stream = new MemoryStream();
        encoder.Save(stream);
        return stream.ToArray();
    }

    private void StartPlayback()
    {
        if (_closing || _playbackRequested || _session is not { } session || !IsCurrent(session))
            return;
        if (!session.Commands.Contains("startStream") || !session.Commands.Contains("stopStream"))
        {
            ErrorTextBlock.Text = "The camera does not support remote stream control.";
            return;
        }

        uint latency;
        try { latency = ParseLatency(); }
        catch (ArgumentException ex)
        {
            ErrorTextBlock.Text = ex.Message;
            return;
        }

        string host = HostTextBox.Text.Trim();
        string url = new UriBuilder("rtsp", host, 8554, "camera").Uri.AbsoluteUri;
        _playbackRequested = true;
        _playbackCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            session.Token, _windowCancellation.Token);
        CancellationToken token = _playbackCancellation.Token;
        _playbackTask = Task.Run(() => PlaybackLoopAsync(session, url, latency, token));
        UpdateControls();
    }

    private async Task StopPlaybackAsync(bool sendServerStop)
    {
        CameraSession? session = _session;
        _playbackRequested = false;
        if (sendServerStop)
            _suppressAutoStream = true;
        _playbackCancellation?.Cancel();
        if (_playbackTask is { } task)
        {
            try { await task; }
            catch (Exception ex) { Trace.TraceWarning($"Playback shutdown failed: {ex.Message}"); }
        }
        _playbackCancellation?.Dispose();
        _playbackCancellation = null;
        _playbackTask = null;

        if (sendServerStop && session is not null && IsCurrent(session) && session.Commands.Contains("stopStream"))
        {
            try { await RunStreamCommandAsync(session, "stopStream", CancellationToken.None); }
            catch (Exception ex) { ErrorTextBlock.Text = $"Could not stop the camera stream: {ex.Message}"; }
        }
        await SetPlaybackStateAsync(_client.IsConnected ? PlaybackState.Stopped : PlaybackState.Disconnected);
    }

    private async Task PlaybackLoopAsync(CameraSession session, string url, uint latency, CancellationToken cancellationToken)
    {
        int failures = 0;
        while (!cancellationToken.IsCancellationRequested && _playbackRequested &&
               !session.Token.IsCancellationRequested && _client.IsConnected)
        {
            try
            {
                await SetPlaybackStateAsync(failures == 0 ? PlaybackState.Connecting : PlaybackState.Reconnecting);
                await WaitForStreamReadyAsync(session, cancellationToken).ConfigureAwait(false);

                using var player = new RtspVideoPlayer();
                Trace.TraceInformation($"RTSP connect attempt: {url}, latency={latency}ms.");
                await Task.Run(() => player.Start(url, latency), CancellationToken.None).ConfigureAwait(false);

                bool receivedFrame = false;
                bool enteredPlaying = false;
                long lastFrameTimestamp = Stopwatch.GetTimestamp();
                long attemptStarted = Stopwatch.GetTimestamp();
                while (_playbackRequested && !cancellationToken.IsCancellationRequested &&
                       !session.Token.IsCancellationRequested && _client.IsConnected)
                {
                    while (player.TryPollEvent(out var playerEvent))
                    {
                        TracePlayerEvent(playerEvent);
                        if (playerEvent.Type is 3 or 4)
                            throw new IOException(playerEvent.Message ?? "The GStreamer pipeline ended.");
                    }

                    int result;
                    RtspVideoPlayer.RtspFrameInfo frameInfo;
                    lock (_renderLock)
                    {
                        byte[] destination = _renderBuffer ?? Array.Empty<byte>();
                        result = player.CopyLatestFrame(destination, out frameInfo);
                        if (result == -2)
                        {
                            int frameBytes = checked((int)(frameInfo.Stride * frameInfo.Height));
                            if (_renderBuffer is null || _renderBuffer.Length != frameBytes)
                                _renderBuffer = new byte[frameBytes];
                            result = player.CopyLatestFrame(_renderBuffer, out frameInfo);
                        }
                        if (result == 1)
                            _latestFrameInfo = frameInfo;
                    }

                    if (result < 0)
                        throw new IOException("Could not retrieve a decoded video frame.");
                    if (result == 1)
                    {
                        receivedFrame = true;
                        lastFrameTimestamp = Stopwatch.GetTimestamp();
                        QueueFrameRender();
                        failures = 0;
                        if (!enteredPlaying)
                        {
                            enteredPlaying = true;
                            await SetPlaybackStateAsync(PlaybackState.Playing).ConfigureAwait(false);
                        }
                    }
                    else if (!receivedFrame && Stopwatch.GetElapsedTime(attemptStarted).TotalSeconds > 20)
                        throw new TimeoutException("No decoded video frames arrived within 20 seconds.");
                    else if (receivedFrame && Stopwatch.GetElapsedTime(lastFrameTimestamp).TotalSeconds > 5)
                    {
                        Trace.TraceWarning("RTSP playback stalled; replacing the pipeline.");
                        throw new TimeoutException("Video frames stopped arriving for 5 seconds.");
                    }

                    await Task.Delay(16, cancellationToken).ConfigureAwait(false);
                }

                if (!_client.IsConnected || session.Token.IsCancellationRequested)
                    break;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                if (cancellationToken.IsCancellationRequested || session.Token.IsCancellationRequested)
                    break;
                failures++;
                Trace.TraceError($"RTSP playback failure: {ex.Message}");
                await SetPlaybackStateAsync(PlaybackState.Error, ex.Message).ConfigureAwait(false);
                if (!_playbackRequested)
                    break;
                await SetPlaybackStateAsync(PlaybackState.Reconnecting).ConfigureAwait(false);
                int delayMilliseconds = Math.Min(500 * (1 << Math.Min(failures, 4)), 8000);
                Trace.TraceInformation($"RTSP reconnect attempt {failures} in {delayMilliseconds} ms.");
                try { await Task.Delay(delayMilliseconds, cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }

        if (!_closing)
            await SetPlaybackStateAsync(_client.IsConnected ? PlaybackState.Stopped : PlaybackState.Disconnected);
        await Dispatcher.InvokeAsync(() =>
        {
            if (_playbackCancellation?.Token == cancellationToken)
            {
                _playbackCancellation.Dispose();
                _playbackCancellation = null;
                _playbackTask = null;
            }
        }).Task.ConfigureAwait(false);
    }

    private async Task WaitForStreamReadyAsync(CameraSession session, CancellationToken cancellationToken)
    {
        CameraResponse status = await RunStreamCommandAsync(session, "getStreamStatus", cancellationToken).ConfigureAwait(false)
            ?? throw new IOException("Could not query camera stream status.");
        CameraStreamStatus stream = status.Stream ?? status.StreamStatus
            ?? throw new InvalidDataException("The camera did not report stream readiness.");
        if (stream.IsReady)
        {
            await InitializeCameraControlsAsync(session).ConfigureAwait(false);
            return;
        }
        if (stream.State is not ("starting" or "stopping"))
            _ = await RunStreamCommandAsync(session, "startStream", cancellationToken).ConfigureAwait(false)
                ?? throw new IOException("Could not request camera stream startup.");

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        while (true)
        {
            await Task.Delay(250, timeout.Token).ConfigureAwait(false);
            status = await RunStreamCommandAsync(session, "getStreamStatus", timeout.Token).ConfigureAwait(false)
                ?? throw new IOException("Could not query camera stream status.");
            stream = status.Stream ?? status.StreamStatus
                ?? throw new InvalidDataException("The camera did not report stream readiness.");
            if (stream.IsReady)
            {
                await InitializeCameraControlsAsync(session).ConfigureAwait(false);
                return;
            }
            if (stream.State == "error")
                throw new IOException(stream.Message ?? "The camera could not start its video stream.");
            if (stream.State is not ("starting" or "stopping"))
                _ = await RunStreamCommandAsync(session, "startStream", timeout.Token).ConfigureAwait(false)
                    ?? throw new IOException("Could not request camera stream startup.");
        }
    }

    private async Task<CameraResponse?> RunStreamCommandAsync(
        CameraSession session, string command, CancellationToken cancellationToken)
    {
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(session.Token, cancellationToken);
        await session.CommandLock.WaitAsync(linked.Token).ConfigureAwait(false);
        try
        {
            CameraResponse response = await _client.SendCommandAsync(command, cancellationToken: linked.Token)
                .ConfigureAwait(false);
            await Dispatcher.InvokeAsync(() =>
            {
                if (IsCurrent(session))
                    ApplyResponse(session, response, null);
            }).Task.ConfigureAwait(false);
            return response;
        }
        catch (OperationCanceledException) when (linked.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception ex)
        {
            await Dispatcher.InvokeAsync(() =>
            {
                if (IsCurrent(session) && !_closing)
                    ErrorTextBlock.Text = ex.Message;
            }).Task.ConfigureAwait(false);
            return null;
        }
        finally
        {
            session.CommandLock.Release();
        }
    }

    private void TracePlayerEvent(RtspVideoPlayer.RtspPlayerEvent playerEvent)
    {
        string message = playerEvent.Message ?? "";
        switch (playerEvent.Type)
        {
            case 1:
                Trace.TraceInformation(message);
                break;
            case 2:
                Trace.TraceWarning(message);
                break;
            case 3:
                Trace.TraceError(message);
                break;
            case 4:
                Trace.TraceWarning(message);
                break;
            case 5:
                Trace.TraceInformation(message);
                break;
        }
    }

    private void QueueFrameRender()
    {
        if (Interlocked.Exchange(ref _renderPending, 1) == 0)
            _ = Dispatcher.BeginInvoke(DispatcherPriority.Render, _renderLatestFrameAction);
    }

    private void RenderLatestFrame()
    {
        try
        {
            lock (_renderLock)
            {
                var info = _latestFrameInfo;
                if (_renderBuffer is null || info.Width == 0 || info.Height == 0)
                    return;
                if (_videoBitmap is null || _videoBitmap.PixelWidth != info.Width || _videoBitmap.PixelHeight != info.Height)
                {
                    _videoBitmap = new WriteableBitmap((int)info.Width, (int)info.Height, 96, 96,
                        System.Windows.Media.PixelFormats.Bgra32, null);
                    VideoImage.Source = _videoBitmap;
                    Trace.TraceInformation($"WPF video surface resized to {info.Width}x{info.Height}.");
                }
                _videoBitmap.WritePixels(new Int32Rect(0, 0, (int)info.Width, (int)info.Height),
                    _renderBuffer, (int)info.Stride, 0);
                _renderedSequence = info.Sequence;
                VideoStateTextBlock.Visibility = Visibility.Collapsed;
                double frameRate = info.FrameRateDenominator == 0 ? 0 :
                    (double)info.FrameRateNumerator / info.FrameRateDenominator;
                VideoInfoTextBlock.Text = $"{info.Width} x {info.Height} at {frameRate:0.##} fps";
            }
        }
        finally
        {
            Interlocked.Exchange(ref _renderPending, 0);
            bool newerFrame;
            lock (_renderLock)
                newerFrame = _latestFrameInfo.Sequence != _renderedSequence;
            if (newerFrame)
                QueueFrameRender();
        }
    }

    private Task SetPlaybackStateAsync(PlaybackState state, string? detail = null) =>
        Dispatcher.InvokeAsync(() =>
        {
            if (_closing && state != PlaybackState.Stopped)
                return;
            _playbackState = state;
            VideoStateTextBlock.Text = state switch
            {
                PlaybackState.Disconnected => "Disconnected",
                PlaybackState.Connecting => "Connecting...",
                PlaybackState.Playing => "Playing",
                PlaybackState.Reconnecting => "Reconnecting...",
                PlaybackState.Stopped => "Stopped",
                PlaybackState.Error => detail ?? "Playback error",
                _ => "Disconnected"
            };
            VideoStateTextBlock.Visibility = state == PlaybackState.Playing ? Visibility.Collapsed : Visibility.Visible;
            if (state == PlaybackState.Error && detail is not null)
                ErrorTextBlock.Text = detail;
            Trace.TraceInformation($"Playback state: {state}{(detail is null ? "" : $" ({detail})")}");
            UpdateControls();
        }).Task;

    private uint ParseLatency()
    {
        if (!uint.TryParse(LatencyTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out uint latency) || latency > 5000)
            throw new ArgumentException("Enter an RTSP latency from 0 to 5000 ms.");
        return latency;
    }

    private async Task<CameraResponse?> RunCommandAsync(
        CameraSession session, string command, object? parameters = null,
        CancellationToken cancellationToken = default, long? revision = null, TimeSpan? timeout = null)
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
                CameraResponse response = timeout is { } duration
                    ? await _client.SendCommandWithTimeoutAsync(command, parameters, duration, linked.Token)
                    : await _client.SendCommandAsync(command, parameters, linked.Token);
                if (IsCurrent(session) && !linked.IsCancellationRequested)
                {
                    await Dispatcher.InvokeAsync(() =>
                    {
                        if (IsCurrent(session) && !linked.IsCancellationRequested)
                            ApplyResponse(session, response, revision);
                    }).Task.ConfigureAwait(false);
                }
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
            await Dispatcher.InvokeAsync(() =>
            {
                if (IsCurrent(session) && !_closing)
                    ErrorTextBlock.Text = ex.Message;
            }).Task.ConfigureAwait(false);
            return null;
        }
    }

    private void ApplyResponse(CameraSession session, CameraResponse response, long? revision)
    {
        if (revision.HasValue && revision.Value != session.Revision)
            return;

        CameraCapabilities? capabilities = response.Capabilities;
        if (capabilities?.Commands is { } commands)
        {
            if (commands.Any(command => command is null))
                throw new InvalidDataException("The camera reported invalid commands.");
            session.Commands.UnionWith(commands);
        }
        CameraDescriptor[]? cameras = response.Cameras ?? capabilities?.Cameras;
        CameraVideoMode[]? modes = response.VideoModes ?? capabilities?.VideoModes;
        if (cameras is not null)
        {
            if (cameras.Any(camera => camera is null || camera.Position is not ("front" or "back")))
                throw new InvalidDataException("The camera reported invalid camera positions.");
            session.Cameras = cameras;
        }
        if (modes is not null)
        {
            if (modes.Any(mode => mode is null || !IsValidVideoMode(mode)))
                throw new InvalidDataException("The camera reported invalid video modes.");
            session.VideoModes = modes;
        }

        CameraStreamStatus? streamStatus = response.Stream ?? response.StreamStatus;
        if (streamStatus is not null)
        {
            session.StreamStatus = streamStatus;
            if (!_playbackRequested)
                VideoStateTextBlock.Text = streamStatus.State;
        }

        if ((response.Status ?? capabilities?.Status) is not { } status)
        {
            if (cameras is not null || modes is not null)
                UpdateCameraSelections(session, resetCamera: cameras is not null, resetMode: modes is not null);
            UpdateControls();
            return;
        }
        if (!double.IsFinite(status.MinFactor) || !double.IsFinite(status.MaxFactor) ||
            !double.IsFinite(status.Factor) || status.MinFactor <= 0 ||
            status.MaxFactor < status.MinFactor || status.Factor < status.MinFactor ||
            status.Factor > status.MaxFactor || status.DeviceName is null ||
            status.SwitchOverFactors is null || status.SwitchOverFactors.Any(f => !double.IsFinite(f)))
            throw new InvalidDataException("The camera reported invalid status.");
        if (status.Camera is { } camera && camera.Position is not ("front" or "back") ||
            status.VideoMode is { } videoMode && (!IsValidVideoMode(videoMode) ||
                videoMode.FrameRate is not { } fps || !double.IsFinite(fps) || fps <= 0))
            throw new InvalidDataException("The camera reported invalid camera or video mode status.");
        CameraStatus? previous = session.Status;
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
        bool cameraChanged = previous?.Camera?.Position != status.Camera?.Position;
        bool modeChanged = previous?.VideoMode?.Width != status.VideoMode?.Width ||
            previous?.VideoMode?.Height != status.VideoMode?.Height ||
            previous?.VideoMode?.FrameRate != status.VideoMode?.FrameRate;
        UpdateCameraSelections(session, cameras is not null || cameraChanged, modes is not null || modeChanged);
        UpdateControls();
    }

    private static bool IsValidVideoMode(CameraVideoMode mode) =>
        mode.Width > 0 && mode.Height > 0 &&
        double.IsFinite(mode.MinFrameRate) && double.IsFinite(mode.MaxFrameRate) &&
        mode.MinFrameRate >= 0 && mode.MaxFrameRate >= mode.MinFrameRate &&
        mode.MaxFrameRate <= int.MaxValue;

    private static double MinimumWholeFrameRate(CameraVideoMode mode) => Math.Max(1, Math.Ceiling(mode.MinFrameRate));

    private void UpdateCameraSelections(CameraSession session, bool resetCamera, bool resetMode)
    {
        _updatingCameraControls = true;
        try
        {
            if (resetCamera)
            {
                string? previous = (CameraComboBox.SelectedItem as CameraPositionOption)?.Position;
                string? selected = session.Status?.Camera?.Position ?? previous;
                CameraComboBox.ItemsSource = session.Cameras.Select(camera => camera.Position)
                    .Distinct().OrderBy(position => position == "back" ? 0 : 1)
                    .Select(position => new CameraPositionOption(position)).ToArray();
                CameraComboBox.SelectedItem = CameraComboBox.Items.Cast<CameraPositionOption>()
                    .FirstOrDefault(option => option.Position == selected);
            }
            if (resetMode)
            {
                CameraVideoMode? active = session.Status?.VideoMode;
                ResolutionOption? previous = ResolutionComboBox.SelectedItem as ResolutionOption;
                int? width = active?.Width ?? previous?.Width;
                int? height = active?.Height ?? previous?.Height;
                ResolutionComboBox.ItemsSource = session.VideoModes
                    .Where(mode => MinimumWholeFrameRate(mode) <= Math.Floor(mode.MaxFrameRate))
                    .Select(mode => new ResolutionOption(mode.Width, mode.Height))
                    .Distinct().OrderBy(option => option.Width).ThenBy(option => option.Height).ToArray();
                ResolutionComboBox.SelectedItem = ResolutionComboBox.Items.Cast<ResolutionOption>()
                    .FirstOrDefault(option => option.Width == width && option.Height == height);
                if (ResolutionComboBox.SelectedItem is null && ResolutionComboBox.Items.Count > 0)
                    ResolutionComboBox.SelectedIndex = 0;
                UpdateFrameRateSelection(session, preferActive: true);
            }
            CameraVideoMode? current = session.Status?.VideoMode;
            ActiveVideoModeTextBlock.Text = current is null ? "" :
                $"Current: {current.Width} x {current.Height} at {current.FrameRate:0.##} fps";
        }
        finally
        {
            _updatingCameraControls = false;
        }
    }

    private void Resolution_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingCameraControls || _session is not { } session)
            return;
        UpdateFrameRateSelection(session, preferActive: true);
        UpdateControls();
    }

    private void Camera_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updatingCameraControls && _session is not null)
            UpdateControls();
    }

    private void UpdateFrameRateSelection(CameraSession session, bool preferActive)
    {
        if (ResolutionComboBox.SelectedItem is not ResolutionOption resolution)
        {
            FrameRateRangeTextBlock.Text = "";
            FrameRateTextBox.Text = "";
            return;
        }
        CameraVideoMode[] matching = session.VideoModes.Where(mode =>
            mode.Width == resolution.Width && mode.Height == resolution.Height &&
            MinimumWholeFrameRate(mode) <= Math.Floor(mode.MaxFrameRate)).ToArray();
        FrameRateRangeTextBlock.Text = "Supported fps: " + string.Join(", ", matching
            .Select(mode => $"{MinimumWholeFrameRate(mode):0}-{Math.Floor(mode.MaxFrameRate):0}")
            .Distinct());
        double? active = preferActive && session.Status?.VideoMode is { } mode &&
            mode.Width == resolution.Width && mode.Height == resolution.Height ? mode.FrameRate : null;
        double rounded = active is { } value ? Math.Round(value) : 0;
        int fps = active is { } current && Math.Abs(current - rounded) < 0.001 && rounded <= int.MaxValue &&
            matching.Any(candidate => candidate.MinFrameRate <= rounded && rounded <= candidate.MaxFrameRate)
            ? (int)rounded : (int)MinimumWholeFrameRate(matching[0]);
        FrameRateTextBox.Text = fps.ToString(CultureInfo.InvariantCulture);
    }

    private async void ApplyCamera_Click(object sender, RoutedEventArgs e)
    {
        if (_reconfiguring || _session is not { } session || !IsCurrent(session) ||
            !session.Commands.Contains("setCamera") ||
            CameraComboBox.SelectedItem is not CameraPositionOption selected)
            return;
        if (selected.Position == session.Status?.Camera?.Position)
            return;
        await ReconfigureAsync(session, "setCamera", new { position = selected.Position }, refreshModes: true);
    }

    private async void ApplyVideoMode_Click(object sender, RoutedEventArgs e)
    {
        if (_reconfiguring || _session is not { } session || !IsCurrent(session) ||
            !session.Commands.Contains("setVideoMode") ||
            ResolutionComboBox.SelectedItem is not ResolutionOption selected)
            return;
        if (!int.TryParse(FrameRateTextBox.Text, NumberStyles.None, CultureInfo.InvariantCulture, out int fps) ||
            fps <= 0 || !session.VideoModes.Any(mode => mode.Width == selected.Width &&
                mode.Height == selected.Height && mode.MinFrameRate <= fps && fps <= mode.MaxFrameRate))
        {
            ErrorTextBlock.Text = "Enter a whole-number frame rate within a supported range for the selected resolution.";
            return;
        }
        if (session.Status?.VideoMode is { } active && active.Width == selected.Width &&
            active.Height == selected.Height && active.FrameRate == fps)
            return;
        await ReconfigureAsync(session, "setVideoMode", new { width = selected.Width, height = selected.Height, fps },
            refreshModes: false);
    }

    private async Task ReconfigureAsync(CameraSession session, string command, object parameters, bool refreshModes)
    {
        _reconfiguring = true;
        ErrorTextBlock.Text = "";
        CancelSlider();
        ++session.Revision;
        UpdateControls();
        try
        {
            await StopContinuousZoomAsync();
            if (!IsCurrent(session))
                return;
            if (refreshModes)
            {
                session.VideoModes = [];
                UpdateCameraSelections(session, resetCamera: false, resetMode: true);
            }
            CameraResponse? response = await RunCommandAsync(session, command, parameters,
                revision: session.Revision, timeout: TimeSpan.FromSeconds(15));
            if (!IsCurrent(session))
                return;
            string error = ErrorTextBlock.Text;
            if (response?.Status is null)
            {
                if (response is not null)
                    error = "The camera did not report its updated status.";
                await RunCommandAsync(session, "status", revision: session.Revision);
                if (IsCurrent(session) && refreshModes)
                    UpdateCameraSelections(session, resetCamera: true, resetMode: false);
            }
            if (refreshModes)
            {
                bool getModes = session.Commands.Contains("getVideoModes");
                CameraResponse? refreshed = await RunCommandAsync(session, getModes ? "getVideoModes" : "capabilities");
                if (refreshed is not null &&
                    (getModes ? refreshed.VideoModes : refreshed.Capabilities?.VideoModes) is null)
                    ErrorTextBlock.Text = "The camera did not report video modes after the camera change.";
            }
            if (!string.IsNullOrEmpty(error))
                ErrorTextBlock.Text = error;
        }
        finally
        {
            _reconfiguring = false;
            if (IsCurrent(session))
                UpdateControls();
        }
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
        !_reconfiguring && IsCurrent(session) && session.Status is not null && session.Commands.Contains("setZoom");

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
            {
                _playbackRequested = false;
                _playbackCancellation?.Cancel();
                ClearSession();
                if (!_suppressAutoConnect && AutoConnectCheckBox.IsChecked == true)
                    StartAutoConnectLoop();
            }
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
        _playbackRequested = false;
        _playbackCancellation?.Cancel();
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
        _updatingCameraControls = true;
        CameraComboBox.ItemsSource = null;
        ResolutionComboBox.ItemsSource = null;
        _updatingCameraControls = false;
        FrameRateRangeTextBlock.Text = "";
        FrameRateTextBox.Text = "";
        ActiveVideoModeTextBlock.Text = "";
        CameraControlsInfoTextBlock.Text = "";
        if (!_client.IsConnected)
            _ = SetPlaybackStateAsync(PlaybackState.Disconnected);
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
        bool canSet = available && !_reconfiguring && CanSetZoom(_session!);
        bool canRamp = available && !_reconfiguring && CanRampZoom(_session!);
        ZoomSlider.IsEnabled = canSet;
        SpeedSlider.IsEnabled = canRamp;
        ZoomInButton.IsEnabled = canRamp;
        ZoomOutButton.IsEnabled = canRamp;
        bool canStream = available && _session!.Commands.Contains("startStream") && _session.Commands.Contains("stopStream");
        PlaybackButton.IsEnabled = canStream;
        PlaybackButton.Content = _playbackRequested ? "Stop video" : "Start video";
        CapturePhotoButton.IsEnabled = available && !_reconfiguring && !_capturingPhoto && _session!.Commands.Contains("capturePhoto");
        CapturePhotoButton.Content = _capturingPhoto ? "Capturing..." : "Capture photo";
        bool canChangeCamera = available && !_reconfiguring && _session!.Commands.Contains("setCamera") &&
            _session.Status?.Camera is not null && _session.Cameras.Length > 0;
        bool canChangeMode = available && !_reconfiguring && _session!.Commands.Contains("setVideoMode") &&
            _session.VideoModes.Length > 0 && _session.Status?.VideoMode is not null;
        CameraComboBox.IsEnabled = canChangeCamera;
        ApplyCameraButton.IsEnabled = canChangeCamera && CameraComboBox.SelectedItem is not null;
        ResolutionComboBox.IsEnabled = canChangeMode && ResolutionComboBox.Items.Count > 0;
        FrameRateTextBox.IsEnabled = ResolutionComboBox.IsEnabled;
        ApplyVideoModeButton.IsEnabled = ResolutionComboBox.IsEnabled && ResolutionComboBox.SelectedItem is not null;
        CameraControlsInfoTextBlock.Text = available && !canChangeCamera && !canChangeMode && !_reconfiguring
            ? "Camera and video mode controls are unavailable for this server." : "";
        ShowLiveButton.IsEnabled = _capturedPhoto is not null;
        SavePhotoButton.IsEnabled = _capturedPhoto is not null;
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
        CancelAutoConnectLoop();
        CancelSlider();
        UpdateControls();
        try
        {
            if (_autoConnectTask is { } autoConnectTask)
                await autoConnectTask;
            await StopContinuousZoomAsync();
            await StopPlaybackAsync(sendServerStop: false);
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

    private sealed class ConnectionSettings
    {
        public string Host { get; init; } = "";
        public int Port { get; init; } = 8555;
        public bool AutoConnect { get; init; }
        public bool AutoStream { get; init; }
        public uint LatencyMilliseconds { get; init; } = 20;
    }

    private enum PlaybackState
    {
        Disconnected,
        Connecting,
        Playing,
        Reconnecting,
        Stopped,
        Error
    }

    private sealed class CameraSession
    {
        public CancellationTokenSource Cancellation { get; } = new();
        public CancellationToken Token => Cancellation.Token;
        public SemaphoreSlim CommandLock { get; } = new(1, 1);
        public HashSet<string> Commands { get; set; } = new(StringComparer.Ordinal);
        public CameraStatus? Status { get; set; }
        public CameraStreamStatus? StreamStatus { get; set; }
        public CameraDescriptor[] Cameras { get; set; } = [];
        public CameraVideoMode[] VideoModes { get; set; } = [];
        public long Revision { get; set; }
    }

    private sealed record CameraPositionOption(string Position)
    {
        public override string ToString() => Position == "front" ? "Front camera" : "Rear camera";
    }

    private sealed record ResolutionOption(int Width, int Height)
    {
        public override string ToString() => $"{Width} x {Height}";
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

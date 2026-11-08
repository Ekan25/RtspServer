using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

internal sealed class FakeCamera : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _cancel = new();
    private readonly ConcurrentQueue<JsonElement> _requests = new();
    private readonly ConcurrentDictionary<string, ConcurrentQueue<Gate>> _gates = new();
    private readonly Task _loop;
    private double _factor = 2;
    private bool _ramping;
    private string _streamState = "running";
    private int _rejectStop;
    private string? _rejectCommand;
    private string _position = "back";
    private int _width = 1280;
    private int _height = 720;
    private int _fps = 30;

    public FakeCamera(params string[] commands)
    {
        Commands = commands;
        _listener.Start();
        _loop = RunAsync();
    }

    public string[] Commands { get; set; }
    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;
    public JsonElement[] Requests => _requests.ToArray();
    public int Count(string command) => Requests.Count(r => r.GetProperty("command").GetString() == command);
    public void RejectNextStop() => Interlocked.Exchange(ref _rejectStop, 1);
    public void RejectNext(string command) => Interlocked.Exchange(ref _rejectCommand, command);

    public Gate DelayNext(string command)
    {
        var gate = new Gate();
        _gates.GetOrAdd(command, _ => new()).Enqueue(gate);
        return gate;
    }

    private async Task RunAsync()
    {
        try
        {
            while (!_cancel.IsCancellationRequested)
            {
                using TcpClient client = await _listener.AcceptTcpClientAsync(_cancel.Token);
                try { await ServeAsync(client, _cancel.Token); }
                catch (IOException) { }
                catch (SocketException) { }
            }
        }
        catch (OperationCanceledException) when (_cancel.IsCancellationRequested) { }
        catch (ObjectDisposedException) when (_cancel.IsCancellationRequested) { }
    }

    private async Task ServeAsync(TcpClient client, CancellationToken token)
    {
        using NetworkStream stream = client.GetStream();
        using var reader = new StreamReader(stream, new UTF8Encoding(false, true), false, 1024, true);
        using var connectionCancel = CancellationTokenSource.CreateLinkedTokenSource(token);
        using var writeLock = new SemaphoreSlim(1, 1);
        var responses = new List<Task>();
        try
        {
            while (await reader.ReadLineAsync(token) is { } line)
            {
                using var document = JsonDocument.Parse(line);
                JsonElement request = document.RootElement.Clone();
                _requests.Enqueue(request);
                string command = request.GetProperty("command").GetString()!;
                bool rejected = command == "stopZoom" && Interlocked.Exchange(ref _rejectStop, 0) == 1;
                if (command == _rejectCommand)
                    rejected = Interlocked.CompareExchange(ref _rejectCommand, null, command) == command;
                if (command == "setZoom") _factor = request.GetProperty("factor").GetDouble();
                if (command == "rampZoom") _ramping = true;
                if (command == "stopZoom" && !rejected) _ramping = false;
                if (command == "startStream") _streamState = "running";
                if (command == "stopStream") _streamState = "stopped";
                if (!rejected && command == "setCamera")
                {
                    _position = request.GetProperty("position").GetString()!;
                    (_width, _height, _fps) = _position == "front" ? (1920, 1080, 30) : (1280, 720, 30);
                }
                if (!rejected && command == "setVideoMode")
                {
                    _width = request.GetProperty("width").GetInt32();
                    _height = request.GetProperty("height").GetInt32();
                    _fps = request.GetProperty("fps").GetInt32();
                }
                bool supportsCameraControls = Commands.Contains("setCamera") || Commands.Contains("setVideoMode");
                var cameras = new[] { new { position = "back", name = "Rear" }, new { position = "front", name = "Front" } };
                var modes = _position == "front"
                    ? new[] { new { width = 1920, height = 1080, minFrameRate = 24.0, maxFrameRate = 30.0 } }
                    : new[]
                    {
                        new { width = 640, height = 480, minFrameRate = 0.0, maxFrameRate = 30.0 },
                        new { width = 1280, height = 720, minFrameRate = 29.97, maxFrameRate = 60.0 }
                    };
                var status = new
                {
                    factor = _factor, minFactor = 1.0, maxFactor = 8.0,
                    isRamping = _ramping, deviceName = "Fake camera",
                    switchOverFactors = new[] { 2.0, 4.0 },
                    camera = supportsCameraControls ? new { position = _position, name = "Fake camera" } : null,
                    videoMode = supportsCameraControls
                        ? new { width = _width, height = _height, minFrameRate = (double)_fps, maxFrameRate = (double)_fps, frameRate = (double)_fps }
                        : null
                };
                var response = new
                {
                    id = request.GetProperty("id").GetString(),
                    ok = !rejected,
                    error = rejected ? new { code = "camera_error", message = command == "stopZoom" ? "Cannot stop zoom" : "Camera change failed" } : null,
                    commands = command == "capabilities" ? Commands : null,
                    capabilities = command == "capabilities" && supportsCameraControls
                        ? new { commands = Commands, status, cameras, videoModes = modes } : null,
                    videoModes = command == "getVideoModes" ? modes : null,
                    status = command is "capabilities" or "getStreamStatus" or "startStream" or "stopStream"
                        ? null
                        : status,
                    stream = command is "getStreamStatus" or "startStream" or "stopStream"
                        ? new { state = _streamState, message = (string?)null }
                        : null
                };
                _gates.TryGetValue(command, out var queue);
                Gate? gate = null;
                queue?.TryDequeue(out gate);
                string responseJson = JsonSerializer.Serialize(response);
                responses.Add(RespondAsync(stream, writeLock, responseJson, gate, connectionCancel.Token));
            }
        }
        finally
        {
            _ramping = false;
            connectionCancel.Cancel();
            try { await Task.WhenAll(responses); }
            catch (OperationCanceledException) when (connectionCancel.IsCancellationRequested) { }
            catch (IOException) { }
        }
    }

    private static async Task RespondAsync(NetworkStream stream, SemaphoreSlim writeLock, string response, Gate? gate, CancellationToken token)
    {
        if (gate is not null)
        {
            gate.Received.TrySetResult();
            await gate.Release.Task.WaitAsync(token);
        }
        await writeLock.WaitAsync(token);
        try { await stream.WriteAsync(Encoding.UTF8.GetBytes(response + "\n"), token); }
        finally { writeLock.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        _cancel.Cancel();
        _listener.Stop();
        try { await _loop.WaitAsync(TimeSpan.FromSeconds(3)); }
        finally { _cancel.Dispose(); }
    }

    public sealed class Gate
    {
        public TaskCompletionSource Received { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public void Open() => Release.TrySetResult();
    }
}

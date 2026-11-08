using System.Collections.Concurrent;
using System.IO;
using System.Net.Sockets;
using System.Text.Json;

namespace CameraController;

public sealed class CameraControlClient : IAsyncDisposable
{
    private const int MaxMessageBytes = 16 * 1024;
    private static readonly TimeSpan ConnectTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(5);

    private readonly object _stateLock = new();
    private readonly SemaphoreSlim _connectionGate = new(1, 1);
    private Session? _session;
    private bool _disposed;

    public event EventHandler? ConnectionChanged;
    public event EventHandler<string>? Error;
    public event EventHandler<CameraStreamStatus>? StreamStateChanged;

    public bool IsConnected
    {
        get
        {
            lock (_stateLock)
                return _session is not null;
        }
    }

    public async Task ConnectAsync(
        string host,
        int port,
        CancellationToken cancellationToken = default)
    {
        await _connectionGate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            lock (_stateLock)
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                if (_session is not null)
                    throw new InvalidOperationException("Already connected.");
            }

            using var timeout = new CancellationTokenSource(ConnectTimeout);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(
                cancellationToken, timeout.Token);

            var client = new TcpClient();
            try
            {
                await client.ConnectAsync(host, port, linked.Token)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
                when (!cancellationToken.IsCancellationRequested &&
                      timeout.IsCancellationRequested)
            {
                client.Dispose();
                throw new TimeoutException("Connection attempt timed out.");
            }
            catch
            {
                client.Dispose();
                throw;
            }

            var session = new Session(client);
            lock (_stateLock)
                _session = session;

            session.ReaderTask = ReceiveLoopAsync(session);
            ConnectionChanged?.Invoke(this, EventArgs.Empty);
        }
        finally
        {
            _connectionGate.Release();
        }
    }

    public async Task DisconnectAsync()
    {
        await _connectionGate.WaitAsync().ConfigureAwait(false);
        try
        {
            Session? session;
            lock (_stateLock)
                session = _session;

            if (session is null)
                return;

            CloseSession(session, new IOException("Disconnected."), false);
            if (session.ReaderTask is not null)
                await session.ReaderTask.ConfigureAwait(false);
        }
        finally
        {
            _connectionGate.Release();
        }
    }

    public Task<CameraResponse> SendCommandAsync(
        string command,
        object? parameters = null,
        CancellationToken cancellationToken = default)
        => SendCommandCoreAsync(command, parameters, null, cancellationToken);

    internal Task<CameraResponse> SendCommandWithWriteNotificationAsync(
        string command,
        object? parameters,
        TaskCompletionSource<bool> written,
        CancellationToken cancellationToken)
        => SendCommandCoreAsync(command, parameters, written, cancellationToken);

    internal Task<CameraResponse> SendCommandWithTimeoutAsync(
        string command, object? parameters, TimeSpan timeout, CancellationToken cancellationToken)
        => SendCommandCoreAsync(command, parameters, null, cancellationToken, timeout);

    private async Task<CameraResponse> SendCommandCoreAsync(
        string command,
        object? parameters,
        TaskCompletionSource<bool>? written,
        CancellationToken cancellationToken,
        TimeSpan? timeout = null)
    {
        try
        {
            return await SendCommandInternalAsync(command, parameters, written, cancellationToken, timeout)
                .ConfigureAwait(false);
        }
        finally
        {
            written?.TrySetResult(false);
        }
    }

    private async Task<CameraResponse> SendCommandInternalAsync(
        string command,
        object? parameters,
        TaskCompletionSource<bool>? written,
        CancellationToken cancellationToken,
        TimeSpan? commandTimeout)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command);

        Session session;
        lock (_stateLock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            session = _session
                ?? throw new InvalidOperationException("Not connected.");
        }

        var fields = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        if (parameters is not null)
        {
            JsonElement element = JsonSerializer.SerializeToElement(parameters);
            if (element.ValueKind != JsonValueKind.Object)
                throw new ArgumentException(
                    "Parameters must serialize to a JSON object.", nameof(parameters));

            foreach (JsonProperty property in element.EnumerateObject())
            {
                if (property.Name is "id" or "command")
                    throw new ArgumentException(
                        "Parameters cannot override id or command.", nameof(parameters));

                fields.Add(property.Name, property.Value.Clone());
            }
        }

        string id = Guid.NewGuid().ToString();

        var request = new CameraRequest
        {
            Id = id,
            Command = command,
            Parameters = fields
        };

        byte[] json = JsonSerializer.SerializeToUtf8Bytes(request);
        if (json.Length > MaxMessageBytes)
            throw new ArgumentException("Command exceeds the message size limit.");

        byte[] message = new byte[json.Length + 1];
        Buffer.BlockCopy(json, 0, message, 0, json.Length);
        message[^1] = (byte)'\n';

        var completion = new TaskCompletionSource<CameraResponse>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        // A disconnect can fault the response before the write has completed.
        _ = completion.Task.ContinueWith(
            task => _ = task.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);

        lock (session.Sync)
        {
            if (session.Closed)
                throw new IOException("The connection has closed.");

            if (!session.Pending.TryAdd(id, completion))
                throw new InvalidOperationException("Duplicate request ID.");
        }

        using var timeout = new CancellationTokenSource(commandTimeout ?? CommandTimeout);
        using var requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(
            cancellationToken, timeout.Token);
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(
            requestCancellation.Token, session.Cancellation.Token);

        bool sent = false;
        try
        {
            await session.WriteLock.WaitAsync(linked.Token).ConfigureAwait(false);
            try
            {
                try
                {
                    await session.Stream.WriteAsync(message, linked.Token)
                        .ConfigureAwait(false);
                    sent = true;
                    written?.TrySetResult(true);
                }
                catch
                {
                    // A failed write may have sent a partial JSON line.
                    CloseSession(session,
                        new IOException("The connection failed while sending."), true);
                    throw;
                }
            }
            finally
            {
                session.WriteLock.Release();
            }

            CameraResponse response = await completion.Task
                .WaitAsync(requestCancellation.Token).ConfigureAwait(false);

            if (!response.Ok)
                throw new CameraCommandException(response.Error);

            return response;
        }
        catch (OperationCanceledException)
            when (!cancellationToken.IsCancellationRequested &&
                  timeout.IsCancellationRequested)
        {
            throw new TimeoutException($"Command '{command}' timed out.");
        }
        catch (OperationCanceledException)
            when (!cancellationToken.IsCancellationRequested &&
                  session.Cancellation.IsCancellationRequested)
        {
            throw new IOException("The connection was lost.");
        }
        finally
        {
            lock (session.Sync)
            {
                if (session.Pending.TryRemove(id, out _) && sent && !session.Closed)
                {
                    session.Abandoned.Add(id);
                    session.AbandonedOrder.Enqueue(id);
                    if (session.AbandonedOrder.Count > 1024)
                        session.Abandoned.Remove(session.AbandonedOrder.Dequeue());
                }
            }
        }
    }

    private async Task ReceiveLoopAsync(Session session)
    {
        var readBuffer = new byte[4096];
        var messageBuffer = new byte[MaxMessageBytes];
        int messageLength = 0;

        try
        {
            while (true)
            {
                int count = await session.Stream.ReadAsync(
                    readBuffer, session.Cancellation.Token).ConfigureAwait(false);

                if (count == 0)
                    throw new IOException(messageLength == 0
                        ? "The camera closed the connection."
                        : "The camera closed the connection with an incomplete response.");

                for (int i = 0; i < count; i++)
                {
                    byte value = readBuffer[i];
                    if (value == (byte)'\n')
                    {
                        ProcessMessage(session, messageBuffer, messageLength);
                        messageLength = 0;
                    }
                    else
                    {
                        if (messageLength == MaxMessageBytes)
                            throw new IOException("Incoming message exceeds 16 KB.");

                        messageBuffer[messageLength++] = value;
                    }
                }
            }
        }
        catch (OperationCanceledException)
            when (session.Cancellation.IsCancellationRequested)
        {
        }
        catch (Exception ex)
        {
            CloseSession(session, ex, true);
        }
    }

    private void ProcessMessage(Session session, byte[] buffer, int length)
    {
        if (length > 0 && buffer[length - 1] == (byte)'\r')
            length--;

        string? id = null;
        try
        {
            using JsonDocument document = JsonDocument.Parse(buffer.AsMemory(0, length));
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                throw new JsonException("Expected a JSON object.");
            if (document.RootElement.TryGetProperty("id", out JsonElement idElement) &&
                idElement.ValueKind == JsonValueKind.String)
                id = idElement.GetString();

            CameraResponse response = document.RootElement.Deserialize<CameraResponse>()
                ?? throw new JsonException("Expected a response object.");
            if (response.Status is { } status &&
                (status.DeviceName is null || status.SwitchOverFactors is null))
                throw new JsonException("Status contains null required fields.");
            if (response.Commands is not null && response.Commands.Any(command => command is null))
                throw new JsonException("Commands contains a null entry.");
            if (response.Error is { } error && (error.Code is null || error.Message is null))
                throw new JsonException("Error contains null required fields.");

            if (string.IsNullOrEmpty(id))
            {
                if (response.Event == "streamStateChanged" && response.Stream is not null)
                {
                    StreamStateChanged?.Invoke(this, response.Stream);
                    return;
                }
                string detail = response.Error is null ? "" :
                    $" {response.Error.Code}: {response.Error.Message}";
                throw new IOException("Received a response without a request ID." + detail);
            }

            TaskCompletionSource<CameraResponse>? completion;
            bool abandoned;
            lock (session.Sync)
            {
                session.Pending.TryRemove(id, out completion);
                abandoned = completion is null && session.Abandoned.Remove(id);
            }
            if (completion is not null)
                completion.TrySetResult(response);
            else if (!abandoned)
            {
                string detail = response.Error is null ? "" :
                    $" {response.Error.Code}: {response.Error.Message}";
                Error?.Invoke(this, $"Received a response for an unknown request ID '{id}'." + detail);
            }
        }
        catch (JsonException ex)
        {
            var failure = new IOException("Received an invalid response from the camera.", ex);
            if (!string.IsNullOrEmpty(id) && session.Pending.TryRemove(id, out var completion))
            {
                completion.TrySetException(failure);
                Error?.Invoke(this, failure.Message);
                return;
            }
            throw failure;
        }
    }

    private void CloseSession(Session session, Exception reason, bool reportError)
    {
        lock (session.Sync)
        {
            if (session.Closed)
                return;

            session.Closed = true;
            foreach (var entry in session.Pending)
            {
                if (session.Pending.TryRemove(entry.Key, out var completion))
                    completion.TrySetException(reason);
            }
        }

        bool changed;
        lock (_stateLock)
        {
            changed = ReferenceEquals(_session, session);
            if (changed)
                _session = null;
        }

        session.Cancellation.Cancel();
        session.Client.Dispose();

        if (changed)
        {
            ConnectionChanged?.Invoke(this, EventArgs.Empty);
            if (reportError)
                Error?.Invoke(this, reason.Message);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await _connectionGate.WaitAsync().ConfigureAwait(false);
        try
        {
            Session? session;
            lock (_stateLock)
            {
                if (_disposed)
                    return;

                _disposed = true;
                session = _session;
            }

            if (session is not null)
            {
                CloseSession(session, new IOException("Client disposed."), false);
                if (session.ReaderTask is not null)
                    await session.ReaderTask.ConfigureAwait(false);
            }
        }
        finally
        {
            _connectionGate.Release();
        }
    }

    private sealed class Session
    {
        public Session(TcpClient client)
        {
            Client = client;
            Stream = client.GetStream();
        }

        public object Sync { get; } = new();
        public TcpClient Client { get; }
        public NetworkStream Stream { get; }
        public CancellationTokenSource Cancellation { get; } = new();
        public SemaphoreSlim WriteLock { get; } = new(1, 1);
        public ConcurrentDictionary<string, TaskCompletionSource<CameraResponse>>
            Pending { get; } = new();
        public HashSet<string> Abandoned { get; } = new(StringComparer.Ordinal);
        public Queue<string> AbandonedOrder { get; } = new();
        public bool Closed { get; set; }
        public Task? ReaderTask { get; set; }
    }
}

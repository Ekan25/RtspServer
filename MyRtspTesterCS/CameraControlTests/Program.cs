using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using CameraController;

internal static class Program
{
    private const string Status = """{"factor":2.5,"minFactor":1.0,"maxFactor":8.0,"isRamping":true,"deviceName":"Loopback camera","switchOverFactors":[2.0,4.0]}""";
    private static readonly string[] Commands = ["status", "capabilities", "setZoom", "rampZoom", "stopZoom", "startStream", "stopStream"];
    private static readonly TimeSpan TestTimeout = TimeSpan.FromSeconds(8);

    private static async Task<int> Main()
    {
        (string Name, Func<CancellationToken, Task> Run)[] tests =
        [
            ("commands and typed responses", CommandsAndResponses),
            ("current macOS response shapes", CurrentResponseShapes),
            ("authenticated JPEG and BGRA photo transfer", PhotoTransfer),
            ("fragmentation, CRLF and concurrent correlation", FramingAndCorrelation),
            ("server error", ServerError),
            ("invalid client inputs", InvalidInputs),
            ("malformed response", token => ProtocolFailure(_ => "{not-json}\n", token)),
            ("missing ok", token => ProtocolFailure(id => JsonSerializer.Serialize(new { id }) + "\n", token)),
            ("invalid ok", token => ProtocolFailure(id => JsonSerializer.Serialize(new { id, ok = "true" }) + "\n", token)),
            ("unknown ID", token => ProtocolFailure(_ => """{"id":"unknown","ok":true}""" + "\n", token)),
            ("uncorrelatable response", token => ProtocolFailure(_ => """{"ok":false,"error":{"code":"invalid_request","message":"bad request"}}""" + "\n", token)),
            ("oversized response", token => ProtocolFailure(_ => new string('x', 16 * 1024 + 1), token)),
            ("cancellation and connection reuse", CancellationAndReuse),
            ("disconnect and reconnect", DisconnectAndReconnect),
            ("remote close and reconnect", RemoteCloseAndReconnect),
            ("command timeout and reuse", CommandTimeoutAndReuse),
            ("disposal", Disposal)
        ];

        int failures = 0;
        foreach (var (name, run) in tests)
        {
            using var timeout = new CancellationTokenSource(TestTimeout);
            try
            {
                await run(timeout.Token).WaitAsync(TestTimeout);
                Console.WriteLine($"PASS {name}");
            }
            catch (Exception ex)
            {
                failures++;
                Console.WriteLine($"FAIL {name}: {ex.GetType().Name}: {ex.Message}");
            }
        }

        Console.WriteLine($"{tests.Length - failures}/{tests.Length} passed.");
        return failures == 0 ? 0 : 1;
    }

    private static async Task<(CameraControlClient Client, Peer Peer)> Connect(FakeCamera server, CancellationToken token)
    {
        var client = new CameraControlClient();
        try
        {
            await client.ConnectAsync("127.0.0.1", server.Port, token);
            return (client, await server.AcceptAsync(token));
        }
        catch
        {
            await client.DisposeAsync();
            throw;
        }
    }

    private static string CheckRequest(JsonElement request, string command, params (string Name, double Value)[] parameters)
    {
        Check(request.ValueKind == JsonValueKind.Object, "Request must be an object.");
        var names = request.EnumerateObject().Select(p => p.Name).Order().ToArray();
        var expected = new[] { "id", "command" }.Concat(parameters.Select(p => p.Name)).Order().ToArray();
        Check(names.SequenceEqual(expected), $"Unexpected fields for {command}: {string.Join(", ", names)}.");
        Check(request.GetProperty("command").GetString() == command, $"Wrong command for {command}.");
        var id = request.GetProperty("id");
        Check(id.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(id.GetString()), "ID must be a nonempty string.");
        foreach (var (name, value) in parameters)
            Check(request.GetProperty(name).GetDouble() == value, $"Wrong {name} for {command}.");
        return id.GetString()!;
    }

    private static string Success(string id, bool capabilities = false) =>
        JsonSerializer.Serialize(new
        {
            id,
            ok = true,
            status = JsonSerializer.Deserialize<JsonElement>(Status),
            streamStatus = new { state = "ready", isReady = true, isStreaming = true },
            commands = capabilities ? Commands : null
        });

    private static void CheckStatus(CameraResponse response)
    {
        var status = response.Status ?? throw new Exception("Typed status is missing.");
        Check(status.Factor == 2.5, "Incorrect factor.");
        Check(status.MinFactor == 1, "Incorrect minimum.");
        Check(status.MaxFactor == 8, "Incorrect maximum.");
        Check(status.IsRamping, "Incorrect ramp state.");
        Check(status.DeviceName == "Loopback camera", "Incorrect device.");
        Check(status.SwitchOverFactors.SequenceEqual([2.0, 4.0]), "Incorrect switch-over factors.");
        Check(response.StreamStatus is { State: "ready", IsReady: true, IsStreaming: true }, "Incorrect stream status.");
    }

    private static Task CurrentResponseShapes(CancellationToken token)
    {
        const string capabilitiesJson = """{"id":"caps","ok":true,"commands":["getStreamStatus","startStream","stopStream"],"capabilities":{"commands":["getStreamStatus","startStream","stopStream"]}}""";
        const string streamJson = """{"id":"stream","ok":true,"stream":{"state":"running"}}""";
        CameraResponse capabilities = JsonSerializer.Deserialize<CameraResponse>(capabilitiesJson)
            ?? throw new Exception("Capabilities response was empty.");
        CameraResponse stream = JsonSerializer.Deserialize<CameraResponse>(streamJson)
            ?? throw new Exception("Stream response was empty.");
        CameraStreamStatus streamStatus = stream.Stream
            ?? throw new Exception("Stream-only response did not contain stream status.");
        Check(capabilities.Status is null && capabilities.Commands?.Contains("startStream") == true,
            "Capabilities-only response should not require camera status.");
        Check(stream.Status is null && streamStatus is { State: "running", IsReady: true, IsStreaming: true },
            "Stream-only response should infer running readiness.");
        Check(streamStatus.Message is null, "Stream message is optional.");
        const string cameraJson = """
            {"id":"camera","ok":true,"capabilities":{"commands":["setCamera","setVideoMode"],
            "cameras":[{"position":"front","name":"Front"}],
            "videoModes":[{"width":1280,"height":720,"minFrameRate":29.97,"maxFrameRate":60}],
            "status":{"camera":{"position":"front","name":"Front"},
            "videoMode":{"width":1280,"height":720,"minFrameRate":30,"maxFrameRate":30,"frameRate":30},
            "factor":1,"minFactor":1,"maxFactor":8,"isRamping":false,"deviceName":"Front","switchOverFactors":[]}}}
            """;
        CameraCapabilities camera = JsonSerializer.Deserialize<CameraResponse>(cameraJson)?.Capabilities
            ?? throw new Exception("Nested camera capabilities missing.");
        Check(camera.Cameras?.Single().Position == "front" &&
              camera.VideoModes?.Single() is { Width: 1280, Height: 720, MinFrameRate: 29.97, MaxFrameRate: 60 } &&
              camera.Status?.VideoMode?.FrameRate == 30 && camera.Status.Camera?.Position == "front",
            "Nested camera and video mode fields must be parsed.");
        return Task.CompletedTask;
    }

    private static async Task PhotoTransfer(CancellationToken token)
    {
        byte[] jpeg = [0xff, 0xd8, 0xff, 0xd9];
        ReceivedPhoto jpegPhoto = await PhotoRoundTrip("jpeg", 2, 1, 0, jpeg, token);
        Check(jpegPhoto.Format == "jpeg" && jpegPhoto.Width == 2 && jpegPhoto.Height == 1 &&
              jpegPhoto.Data.SequenceEqual(jpeg), "JPEG transfer metadata or payload is incorrect.");

        byte[] bgra = [1, 2, 3, 4, 5, 6, 7, 8];
        ReceivedPhoto bgraPhoto = await PhotoRoundTrip("bgra", 2, 1, 8, bgra, token);
        Check(bgraPhoto.Format == "bgra" && bgraPhoto.RowStride == 8 &&
              bgraPhoto.Data.SequenceEqual(bgra), "BGRA transfer metadata or payload is incorrect.");
    }

    private static async Task<ReceivedPhoto> PhotoRoundTrip(
        string format, uint width, uint height, uint stride, byte[] payload, CancellationToken token)
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        ushort port = (ushort)((IPEndPoint)listener.LocalEndpoint).Port;
        var info = new PhotoTransferInfo
        {
            TransferId = "test-transfer",
            TransferHost = "127.0.0.1",
            TransferPort = port,
            TransferToken = "test-token",
            Format = format
        };

        Task<ReceivedPhoto> receive = PhotoTransferClient.ReceiveAsync(info, token);
        using TcpClient peer = await listener.AcceptTcpClientAsync(token);
        NetworkStream stream = peer.GetStream();
        byte[] request = new byte[12 + info.TransferId.Length + info.TransferToken.Length];
        await stream.ReadExactlyAsync(request, token);
        Check(request.AsSpan(0, 4).SequenceEqual("LVP1"u8) &&
              BinaryPrimitives.ReadUInt16BigEndian(request.AsSpan(4, 2)) == 1 &&
              BinaryPrimitives.ReadUInt16BigEndian(request.AsSpan(6, 2)) == info.TransferId.Length &&
              BinaryPrimitives.ReadUInt16BigEndian(request.AsSpan(8, 2)) == info.TransferToken.Length,
            "Photo authentication header is incorrect.");
        Check(Encoding.UTF8.GetString(request, 12, info.TransferId.Length) == info.TransferId &&
              Encoding.UTF8.GetString(request, 12 + info.TransferId.Length, info.TransferToken.Length) == info.TransferToken,
            "Photo transfer credentials are incorrect.");

        byte[] response = new byte[32];
        "LVP1"u8.CopyTo(response);
        BinaryPrimitives.WriteUInt16BigEndian(response.AsSpan(4, 2), 1);
        BinaryPrimitives.WriteUInt16BigEndian(response.AsSpan(8, 2), format == "jpeg" ? (ushort)1 : (ushort)2);
        BinaryPrimitives.WriteUInt32BigEndian(response.AsSpan(12, 4), width);
        BinaryPrimitives.WriteUInt32BigEndian(response.AsSpan(16, 4), height);
        BinaryPrimitives.WriteUInt32BigEndian(response.AsSpan(20, 4), stride);
        BinaryPrimitives.WriteUInt64BigEndian(response.AsSpan(24, 8), (ulong)payload.Length);
        await stream.WriteAsync(response, token);
        await stream.WriteAsync(payload, token);
        return await receive.WaitAsync(token);
    }

    private static async Task CommandsAndResponses(CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        await using (client)
        using (peer)
        {
            var ids = new HashSet<string>();
            foreach (string command in Commands)
            {
                object? args = command switch
                {
                    "setZoom" => new { factor = 2.5 },
                    "rampZoom" => new { factor = 8.0, speed = 2.0 },
                    _ => null
                };
                var call = client.SendCommandAsync(command, args, token);
                JsonElement request = await peer.ReadRequestAsync(token);
                string id = command switch
                {
                    "setZoom" => CheckRequest(request, command, ("factor", 2.5)),
                    "rampZoom" => CheckRequest(request, command, ("factor", 8.0), ("speed", 2.0)),
                    _ => CheckRequest(request, command)
                };
                Check(ids.Add(id), "Request ID was reused.");
                await peer.WriteAsync(Success(id, command == "capabilities") + "\n", token);
                CameraResponse response = await call.WaitAsync(token);
                Check(response.Id == id && response.Ok, "Response ID or ok is incorrect.");
                CheckStatus(response);
                if (command == "capabilities")
                {
                    Check(response.Commands is not null && response.Commands.SequenceEqual(Commands), "Incorrect commands.");
                }
            }
        }
    }

    private static async Task FramingAndCorrelation(CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        await using (client)
        using (peer)
        {
            var first = client.SendCommandAsync("status", null, token);
            var second = client.SendCommandAsync("capabilities", null, token);
            var ids = new Dictionary<string, string>();
            for (int i = 0; i < 2; i++)
            {
                var request = await peer.ReadRequestAsync(token);
                string command = request.GetProperty("command").GetString()!;
                ids.Add(command, CheckRequest(request, command));
            }
            Check(ids["status"] != ids["capabilities"], "Concurrent IDs must differ.");
            string combined = Success(ids["capabilities"], true) + "\r\n" + Success(ids["status"]) + "\n";
            await peer.WriteAsync(combined[..7], token);
            await peer.WriteAsync(combined[7..], token);
            var status = await first.WaitAsync(token);
            var capabilities = await second.WaitAsync(token);
            Check(status.Id == ids["status"] && capabilities.Id == ids["capabilities"], "Responses were not correlated by ID.");
            CheckStatus(status);
            Check(capabilities.Commands is not null, "Out-of-order response matched wrong request.");
            Check(status.Commands is null, "Out-of-order response matched wrong request.");
        }
    }

    private static async Task ServerError(CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        await using (client)
        using (peer)
        {
            var call = client.SendCommandAsync("setZoom", new { factor = -1.0 }, token);
            string id = CheckRequest(await peer.ReadRequestAsync(token), "setZoom", ("factor", -1.0));
            await peer.WriteAsync(JsonSerializer.Serialize(new { id, ok = false, error = new { code = "invalid_parameters", message = "Invalid zoom" } }) + "\n", token);
            var error = await Throws<CameraCommandException>(call, token);
            Check(error.Code == "invalid_parameters" && error.Message == "Invalid zoom", "Structured error was not preserved.");
            await RoundTrip(client, peer, token, id);
        }
    }

    private static async Task InvalidInputs(CancellationToken token)
    {
        await using var client = new CameraControlClient();
        await Throws<InvalidOperationException>(client.SendCommandAsync("status", null, token), token);
        using var server = new FakeCamera();
        await client.ConnectAsync("127.0.0.1", server.Port, token);
        using var peer = await server.AcceptAsync(token);
        await Throws<ArgumentException>(client.SendCommandAsync("", null, token), token);
        await Throws<ArgumentException>(client.SendCommandAsync("status", 42, token), token);
        await Throws<ArgumentException>(client.SendCommandAsync("status", new { id = "override" }, token), token);
        await Throws<ArgumentException>(client.SendCommandAsync("status", new { command = "override" }, token), token);
        await Throws<ArgumentException>(client.SendCommandAsync("status", new { payload = new string('x', 17 * 1024) }, token), token);
        await RoundTrip(client, peer, token);
    }

    private static async Task ProtocolFailure(Func<string, string> frame, CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        await using (client)
        using (peer)
        using (var callCancellation = CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            var reported = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
            client.Error += (_, message) => reported.TrySetResult(message);
            var call = client.SendCommandAsync("status", null, callCancellation.Token);
            string id = CheckRequest(await peer.ReadRequestAsync(token), "status");
            await peer.WriteAsync(frame(id), token);
            Task completed = await Task.WhenAny(reported.Task, call).WaitAsync(TimeSpan.FromSeconds(2), token);
            if (completed == call)
            {
                Check(call.IsFaulted, "Invalid response must not succeed or be silently cancelled.");
                _ = call.Exception;
            }
            else
                Check(!string.IsNullOrWhiteSpace(await reported.Task), "Protocol error must be reported.");
            callCancellation.Cancel();
            try { await call.WaitAsync(token); }
            catch (Exception) when (!token.IsCancellationRequested) { }
        }
    }

    private static async Task CancellationAndReuse(CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        await using (client)
        using (peer)
        using (var cancelled = CancellationTokenSource.CreateLinkedTokenSource(token))
        {
            var call = client.SendCommandAsync("status", null, cancelled.Token);
            string id = CheckRequest(await peer.ReadRequestAsync(token), "status");
            cancelled.Cancel();
            await Throws<OperationCanceledException>(call, token);
            var errors = new List<string>();
            client.Error += (_, message) => errors.Add(message);
            await peer.WriteAsync(Success(id) + "\n", token);
            await RoundTrip(client, peer, token, id);
            Check(errors.Count == 0, "A late response to a cancelled request must not be reported as an unknown ID.");
        }
    }

    private static async Task DisconnectAndReconnect(CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        await using (client)
        using (peer)
        {
            var call = client.SendCommandAsync("status", null, token);
            string oldId = CheckRequest(await peer.ReadRequestAsync(token), "status");
            await client.DisconnectAsync().WaitAsync(token);
            await ThrowsAny(call, token);
            await client.ConnectAsync("127.0.0.1", server.Port, token);
            using var reconnected = await server.AcceptAsync(token);
            await RoundTrip(client, reconnected, token, oldId);
        }
    }

    private static async Task RemoteCloseAndReconnect(CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        await using (client)
        {
            var call = client.SendCommandAsync("status", null, token);
            await peer.ReadRequestAsync(token);
            peer.Dispose();
            await ThrowsAny(call, token);
            await client.DisconnectAsync().WaitAsync(token);
            await client.ConnectAsync("127.0.0.1", server.Port, token);
            using var reconnected = await server.AcceptAsync(token);
            await RoundTrip(client, reconnected, token);
        }
    }

    private static async Task CommandTimeoutAndReuse(CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        await using (client)
        using (peer)
        {
            var call = client.SendCommandAsync("status", null, token);
            string id = CheckRequest(await peer.ReadRequestAsync(token), "status");
            await Throws<TimeoutException>(call, token);
            await RoundTrip(client, peer, token, id);
        }
    }

    private static async Task Disposal(CancellationToken token)
    {
        using var server = new FakeCamera();
        var (client, peer) = await Connect(server, token);
        using (peer)
        {
            var call = client.SendCommandAsync("status", null, token);
            await peer.ReadRequestAsync(token);
            await client.DisposeAsync().AsTask().WaitAsync(token);
            await ThrowsAny(call, token);
            await Throws<ObjectDisposedException>(client.SendCommandAsync("status", null, token), token);
            await client.DisposeAsync().AsTask().WaitAsync(token);
        }
    }

    private static async Task RoundTrip(CameraControlClient client, Peer peer, CancellationToken token, string? previousId = null)
    {
        var call = client.SendCommandAsync("status", null, token);
        string id = CheckRequest(await peer.ReadRequestAsync(token), "status");
        Check(id != previousId, "A request ID was reused.");
        await peer.WriteAsync(Success(id) + "\n", token);
        CheckStatus(await call.WaitAsync(token));
    }

    private static async Task<T> Throws<T>(Task task, CancellationToken token) where T : Exception
    {
        try { await task.WaitAsync(token); }
        catch (T ex) when (!token.IsCancellationRequested) { return ex; }
        throw new Exception($"Expected {typeof(T).Name}.");
    }

    private static async Task ThrowsAny(Task task, CancellationToken token)
    {
        try { await task.WaitAsync(token); }
        catch (Exception) when (!token.IsCancellationRequested) { return; }
        throw new Exception("Expected the pending request to fail.");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition)
            throw new Exception(message);
    }
}

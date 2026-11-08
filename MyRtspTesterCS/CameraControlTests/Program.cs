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

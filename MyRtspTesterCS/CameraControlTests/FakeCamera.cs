using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

internal sealed class FakeCamera : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);

    public FakeCamera() => _listener.Start();

    public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;

    public async Task<Peer> AcceptAsync(CancellationToken token) =>
        new(await _listener.AcceptTcpClientAsync(token));

    public void Dispose() => _listener.Stop();
}

internal sealed class Peer : IDisposable
{
    private readonly TcpClient _client;
    private readonly StreamReader _reader;
    private readonly NetworkStream _stream;

    public Peer(TcpClient client)
    {
        _client = client;
        _stream = client.GetStream();
        _reader = new StreamReader(_stream, new UTF8Encoding(false, true), false, 1024, true);
    }

    public async Task<JsonElement> ReadRequestAsync(CancellationToken token)
    {
        string line = await _reader.ReadLineAsync(token)
            ?? throw new Exception("Client closed before sending a request.");
        using JsonDocument document = JsonDocument.Parse(line);
        return document.RootElement.Clone();
    }

    public Task WriteAsync(string text, CancellationToken token) =>
        _stream.WriteAsync(Encoding.UTF8.GetBytes(text), token).AsTask();

    public void Dispose()
    {
        _reader.Dispose();
        _client.Dispose();
    }
}

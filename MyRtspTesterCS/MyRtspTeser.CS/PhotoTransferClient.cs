using System.Buffers.Binary;
using System.IO;
using System.Net.Sockets;
using System.Text;

namespace CameraController;

public sealed record ReceivedPhoto(string Format, int Width, int Height, int RowStride, byte[] Data);

public static class PhotoTransferClient
{
    private const int RequestHeaderBytes = 12;
    private const int ResponseHeaderBytes = 32;
    private const int MaxIdBytes = 64;
    private const int MaxTokenBytes = 128;
    private const int MaxPhotoBytes = 100 * 1024 * 1024;

    public static async Task<ReceivedPhoto> ReceiveAsync(
        PhotoTransferInfo info,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(info);
        byte[] id = Encoding.UTF8.GetBytes(info.TransferId);
        byte[] token = Encoding.UTF8.GetBytes(info.TransferToken);
        if (string.IsNullOrWhiteSpace(info.TransferHost) || info.TransferPort == 0 ||
            id.Length is 0 or > MaxIdBytes || token.Length is 0 or > MaxTokenBytes)
            throw new InvalidDataException("The camera returned invalid photo transfer information.");

        using var client = new TcpClient();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        await client.ConnectAsync(info.TransferHost, info.TransferPort, timeout.Token).ConfigureAwait(false);
        using NetworkStream stream = client.GetStream();

        byte[] request = new byte[RequestHeaderBytes + id.Length + token.Length];
        "LVP1"u8.CopyTo(request);
        BinaryPrimitives.WriteUInt16BigEndian(request.AsSpan(4, 2), 1);
        BinaryPrimitives.WriteUInt16BigEndian(request.AsSpan(6, 2), (ushort)id.Length);
        BinaryPrimitives.WriteUInt16BigEndian(request.AsSpan(8, 2), (ushort)token.Length);
        id.CopyTo(request, RequestHeaderBytes);
        token.CopyTo(request, RequestHeaderBytes + id.Length);
        await stream.WriteAsync(request, timeout.Token).ConfigureAwait(false);

        byte[] header = new byte[ResponseHeaderBytes];
        await stream.ReadExactlyAsync(header, timeout.Token).ConfigureAwait(false);
        if (!header.AsSpan(0, 4).SequenceEqual("LVP1"u8) ||
            BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(4, 2)) != 1)
            throw new InvalidDataException("The camera sent an invalid photo transfer header.");
        if (BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(6, 2)) != 0)
            throw new InvalidDataException("The camera rejected the photo transfer token.");

        ushort formatCode = BinaryPrimitives.ReadUInt16BigEndian(header.AsSpan(8, 2));
        string format = formatCode switch
        {
            1 => "jpeg",
            2 => "bgra",
            _ => throw new InvalidDataException("The camera sent an unsupported photo format.")
        };
        uint width = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(12, 4));
        uint height = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(16, 4));
        uint rowStride = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(20, 4));
        ulong payloadLength = BinaryPrimitives.ReadUInt64BigEndian(header.AsSpan(24, 8));
        if (width is 0 or > int.MaxValue || height is 0 or > int.MaxValue ||
            payloadLength is 0 or > MaxPhotoBytes || !string.Equals(info.Format, format, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("The camera returned invalid photo metadata.");

        if (format == "bgra" &&
            (rowStride < (ulong)width * 4 || (ulong)rowStride * height != payloadLength))
            throw new InvalidDataException("The camera returned inconsistent BGRA dimensions or stride.");

        byte[] data = new byte[(int)payloadLength];
        await stream.ReadExactlyAsync(data, timeout.Token).ConfigureAwait(false);
        return new ReceivedPhoto(format, (int)width, (int)height, (int)rowStride, data);
    }
}
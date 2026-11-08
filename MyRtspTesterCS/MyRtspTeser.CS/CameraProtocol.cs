using System.Text.Json;
using System.Text.Json.Serialization;

namespace CameraController;

public sealed class CameraRequest
{
    [JsonPropertyName("id")]
    public string Id { get; init; } = "";

    [JsonPropertyName("command")]
    public string Command { get; init; } = "";

    [JsonExtensionData]
    public Dictionary<string, JsonElement> Parameters { get; init; } = new();
}

public sealed class CameraResponse
{
    [JsonPropertyName("id")]
    public string? Id { get; init; }

    [JsonPropertyName("ok")]
    [JsonRequired]
    public bool Ok { get; init; }

    [JsonPropertyName("status")]
    public CameraStatus? Status { get; init; }

    [JsonPropertyName("streamStatus")]
    public CameraStreamStatus? StreamStatus { get; init; }

    [JsonPropertyName("commands")]
    public string[]? Commands { get; init; }

    [JsonPropertyName("stream")]
    public CameraStreamStatus? Stream { get; init; }

    [JsonPropertyName("event")]
    public string? Event { get; init; }

    [JsonPropertyName("photo")]
    public PhotoTransferInfo? Photo { get; init; }

    [JsonPropertyName("error")]
    public CameraError? Error { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> Properties { get; init; } = new();
}

public sealed class PhotoTransferInfo
{
    [JsonPropertyName("transferId")]
    [JsonRequired]
    public string TransferId { get; init; } = "";

    [JsonPropertyName("transferHost")]
    [JsonRequired]
    public string TransferHost { get; init; } = "";

    [JsonPropertyName("transferPort")]
    [JsonRequired]
    public ushort TransferPort { get; init; }

    [JsonPropertyName("transferToken")]
    [JsonRequired]
    public string TransferToken { get; init; } = "";

    [JsonPropertyName("format")]
    [JsonRequired]
    public string Format { get; init; } = "";
}

public sealed class CameraStreamStatus
{
    [JsonPropertyName("state")]
    public string State { get; init; } = "stopped";

    [JsonPropertyName("isReady")]
    public bool? ReportedIsReady { get; init; }

    [JsonPropertyName("isStreaming")]
    public bool? ReportedIsStreaming { get; init; }

    [JsonPropertyName("message")]
    public string? Message { get; init; }

    [JsonIgnore]
    public bool IsReady => ReportedIsReady ?? State is "running" or "ready";

    [JsonIgnore]
    public bool IsStreaming => ReportedIsStreaming ?? State is "running" or "starting" or "stopping" or "ready";
}

public sealed class CameraStatus
{
    [JsonPropertyName("factor")]
    [JsonRequired]
    public double Factor { get; init; }

    [JsonPropertyName("minFactor")]
    [JsonRequired]
    public double MinFactor { get; init; }

    [JsonPropertyName("maxFactor")]
    [JsonRequired]
    public double MaxFactor { get; init; }

    [JsonPropertyName("isRamping")]
    [JsonRequired]
    public bool IsRamping { get; init; }

    [JsonPropertyName("deviceName")]
    [JsonRequired]
    public string DeviceName { get; init; } = "";

    [JsonPropertyName("switchOverFactors")]
    [JsonRequired]
    public double[] SwitchOverFactors { get; init; } = Array.Empty<double>();
}

public sealed class CameraError
{
    [JsonPropertyName("code")]
    [JsonRequired]
    public string Code { get; init; } = "";

    [JsonPropertyName("message")]
    [JsonRequired]
    public string Message { get; init; } = "";
}

public sealed class CameraCommandException : Exception
{
    public string? Code { get; }

    public CameraCommandException(CameraError? error)
        : base(error?.Message ?? "The camera rejected the command.")
    {
        Code = error?.Code;
    }
}

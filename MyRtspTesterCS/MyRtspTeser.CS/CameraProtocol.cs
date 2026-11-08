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

    [JsonPropertyName("capabilities")]
    public CameraCapabilities? Capabilities { get; init; }

    [JsonPropertyName("videoModes")]
    public CameraVideoMode[]? VideoModes { get; init; }

    [JsonPropertyName("cameras")]
    public CameraDescriptor[]? Cameras { get; init; }

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
    [JsonPropertyName("camera")]
    public CameraDescriptor? Camera { get; init; }

    [JsonPropertyName("videoMode")]
    public CameraVideoMode? VideoMode { get; init; }

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

public sealed class CameraCapabilities
{
    [JsonPropertyName("commands")]
    public string[]? Commands { get; init; }

    [JsonPropertyName("status")]
    public CameraStatus? Status { get; init; }

    [JsonPropertyName("cameras")]
    public CameraDescriptor[]? Cameras { get; init; }

    [JsonPropertyName("videoModes")]
    public CameraVideoMode[]? VideoModes { get; init; }
}

public sealed class CameraDescriptor
{
    [JsonPropertyName("position")]
    [JsonRequired]
    public string Position { get; init; } = "";

    [JsonPropertyName("name")]
    public string? Name { get; init; }
}

public sealed class CameraVideoMode
{
    [JsonPropertyName("width")]
    [JsonRequired]
    public int Width { get; init; }

    [JsonPropertyName("height")]
    [JsonRequired]
    public int Height { get; init; }

    [JsonPropertyName("minFrameRate")]
    [JsonRequired]
    public double MinFrameRate { get; init; }

    [JsonPropertyName("maxFrameRate")]
    [JsonRequired]
    public double MaxFrameRate { get; init; }

    [JsonPropertyName("frameRate")]
    public double? FrameRate { get; init; }
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

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

    [JsonPropertyName("error")]
    public CameraError? Error { get; init; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> Properties { get; init; } = new();
}

public sealed class CameraStreamStatus
{
    [JsonPropertyName("state")]
<<<<<<< HEAD
    public string State { get; init; } = "stopped";

    [JsonPropertyName("isReady")]
    public bool IsReady { get; init; }

    [JsonPropertyName("isStreaming")]
    public bool IsStreaming { get; init; }
=======
    [JsonRequired]
    public string State { get; init; } = "";

    [JsonPropertyName("message")]
    public string? Message { get; init; }
>>>>>>> 8a85150c3ad6bccc935b1ed9d8350131bb627c28
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

using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

const int MaxMessageBytes = 64 * 1024;

try
{
    var request = await ReadMessageAsync(Console.OpenStandardInput());
    var response = await HandleAsync(request);
    await WriteMessageAsync(Console.OpenStandardOutput(), response);
}
catch (Exception exception)
{
    await WriteMessageAsync(
        Console.OpenStandardOutput(),
        new NativeResponse(false, FriendlyError(exception)));
}

static async Task<NativeRequest> ReadMessageAsync(Stream input)
{
    var lengthBytes = new byte[sizeof(int)];
    await input.ReadExactlyAsync(lengthBytes);
    var length = BitConverter.ToInt32(lengthBytes, 0);

    if (length is <= 0 or > MaxMessageBytes)
    {
        throw new InvalidDataException("Некорректный размер сообщения.");
    }

    var payload = new byte[length];
    await input.ReadExactlyAsync(payload);
    return JsonSerializer.Deserialize<NativeRequest>(payload)
        ?? throw new InvalidDataException("Пустой запрос.");
}

static async Task<NativeResponse> HandleAsync(NativeRequest request)
{
    var action = request.Action?.Trim().ToLowerInvariant();
    if (action is not ("add" or "remove"))
    {
        throw new InvalidDataException("Допустимы только действия add и remove.");
    }

    var target = NormalizeDnsName(request.Target);
    var scriptPath = Path.Combine(AppContext.BaseDirectory, "VPN-Bypass-Manager.ps1");
    if (!File.Exists(scriptPath))
    {
        throw new FileNotFoundException("Не найден скрипт управления маршрутами.", scriptPath);
    }

    var resultPath = Path.Combine(Path.GetTempPath(), $"vpn-bypass-{Guid.NewGuid():N}.json");
    try
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        startInfo.ArgumentList.Add("-NoLogo");
        startInfo.ArgumentList.Add("-NoProfile");
        startInfo.ArgumentList.Add("-NonInteractive");
        startInfo.ArgumentList.Add("-ExecutionPolicy");
        startInfo.ArgumentList.Add("Bypass");
        startInfo.ArgumentList.Add("-File");
        startInfo.ArgumentList.Add(scriptPath);
        startInfo.ArgumentList.Add("-Action");
        startInfo.ArgumentList.Add(action);
        startInfo.ArgumentList.Add("-Target");
        startInfo.ArgumentList.Add(target);
        startInfo.ArgumentList.Add("-ResultPath");
        startInfo.ArgumentList.Add(resultPath);

        using var process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("Не удалось запустить PowerShell.");

        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        await process.WaitForExitAsync(timeout.Token);

        if (!File.Exists(resultPath))
        {
            throw new InvalidOperationException($"PowerShell завершился с кодом {process.ExitCode} без результата.");
        }

        var resultJson = await File.ReadAllTextAsync(resultPath, Encoding.UTF8);
        var result = JsonSerializer.Deserialize<ScriptResult>(resultJson)
            ?? throw new InvalidDataException("PowerShell вернул пустой результат.");

        return result.Ok
            ? new NativeResponse(true, null, result.Changed, result.Addresses)
            : new NativeResponse(false, result.Error ?? "Не удалось изменить маршрут.");
    }
    finally
    {
        try
        {
            File.Delete(resultPath);
        }
        catch
        {
            // A stale temporary result is harmless and will be cleaned by Windows.
        }
    }
}

static string NormalizeDnsName(string? rawTarget)
{
    var target = (rawTarget ?? string.Empty).Trim().TrimEnd('.');
    if (target.Length is 0 or > 253)
    {
        throw new InvalidDataException("Некорректное имя сайта.");
    }

    string ascii;
    try
    {
        ascii = new IdnMapping().GetAscii(target).ToLowerInvariant();
    }
    catch (ArgumentException)
    {
        throw new InvalidDataException("Некорректное имя сайта.");
    }

    if (Uri.CheckHostName(ascii) != UriHostNameType.Dns || !ascii.Contains('.'))
    {
        throw new InvalidDataException("Ожидалось доменное имя сайта.");
    }

    return ascii;
}

static async Task WriteMessageAsync(Stream output, NativeResponse response)
{
    var payload = JsonSerializer.SerializeToUtf8Bytes(response);
    await output.WriteAsync(BitConverter.GetBytes(payload.Length));
    await output.WriteAsync(payload);
    await output.FlushAsync();
}

static string FriendlyError(Exception exception) => exception switch
{
    Win32Exception { NativeErrorCode: 1223 } => "User cancelled the administrator request.",
    OperationCanceledException => "Истекло время ожидания PowerShell.",
    _ => exception.Message
};

internal sealed record NativeRequest(
    [property: JsonPropertyName("action")] string? Action,
    [property: JsonPropertyName("target")] string? Target);

internal sealed record NativeResponse(
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("error")] string? Error = null,
    [property: JsonPropertyName("changed")] bool Changed = false,
    [property: JsonPropertyName("addresses")] string[]? Addresses = null);

internal sealed record ScriptResult(
    [property: JsonPropertyName("ok")] bool Ok,
    [property: JsonPropertyName("changed")] bool Changed,
    [property: JsonPropertyName("addresses")] string[]? Addresses,
    [property: JsonPropertyName("error")] string? Error);

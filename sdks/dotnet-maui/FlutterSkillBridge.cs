using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace FlutterSkill;

/// <summary>
/// Platform-agnostic WebSocket JSON-RPC 2.0 bridge server.
/// Subclass and override the Handle* methods to integrate with your UI framework (MAUI, WPF, etc).
/// </summary>
public class FlutterSkillBridge
{
    private readonly int _port;
    private HttpListener? _listener;
    private CancellationTokenSource? _cts;

    public FlutterSkillBridge(int port = 18118)
    {
        _port = port;
    }

    public void Start()
    {
        _cts = new CancellationTokenSource();
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://127.0.0.1:{_port}/");
        _listener.Start();
        Console.WriteLine($"[flutter-skill] WebSocket server on port {_port}");
        _ = AcceptLoop(_cts.Token);
    }

    public void Stop()
    {
        _cts?.Cancel();
        _listener?.Stop();
    }

    private async Task AcceptLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var ctx = await _listener!.GetContextAsync();
                if (ctx.Request.IsWebSocketRequest)
                {
                    var wsCtx = await ctx.AcceptWebSocketAsync(null);
                    _ = HandleClient(wsCtx.WebSocket, ct);
                }
                else if (ctx.Request.Url?.AbsolutePath == "/.flutter-skill")
                {
                    // Health check endpoint
                    var health = new JsonObject
                    {
                        ["framework"] = "dotnet",
                        ["app_name"] = "dotnet-app",
                        ["platform"] = "dotnet",
                        ["sdk_version"] = "1.0.0",
                        ["capabilities"] = new JsonArray(
                            "initialize", "inspect", "inspect_interactive", "tap", "enter_text", "get_text",
                            "find_element", "wait_for_element", "scroll", "swipe",
                            "screenshot", "go_back", "get_logs", "clear_logs"
                        )
                    };
                    var bytes = Encoding.UTF8.GetBytes(health.ToJsonString());
                    ctx.Response.ContentType = "application/json";
                    ctx.Response.ContentLength64 = bytes.Length;
                    await ctx.Response.OutputStream.WriteAsync(bytes, ct);
                    ctx.Response.Close();
                }
                else
                {
                    ctx.Response.StatusCode = 400;
                    ctx.Response.Close();
                }
            }
            catch (Exception) when (ct.IsCancellationRequested) { break; }
        }
    }

    private async Task HandleClient(WebSocket ws, CancellationToken ct)
    {
        var buffer = new byte[65536];
        var messageBuffer = new List<byte>();

        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            var result = await ws.ReceiveAsync(buffer, ct);
            if (result.MessageType == WebSocketMessageType.Close) break;

            messageBuffer.AddRange(buffer.AsSpan(0, result.Count).ToArray());

            if (!result.EndOfMessage) continue; // accumulate fragments

            var text = Encoding.UTF8.GetString(messageBuffer.ToArray());
            messageBuffer.Clear();

            var response = await HandleRequest(text);
            var bytes = Encoding.UTF8.GetBytes(response);
            await ws.SendAsync(bytes, WebSocketMessageType.Text, true, ct);
        }
    }

    private async Task<string> HandleRequest(string raw)
    {
        JsonNode? req;
        try { req = JsonNode.Parse(raw); }
        catch { return JsonResponse(null, error: "Parse error", code: -32700); }

        var id = req?["id"];
        var method = req?["method"]?.GetValue<string>() ?? "";
        var parms = req?["params"]?.AsObject() ?? new JsonObject();

        try
        {
            // Resolve key/selector/element to a single selector string
            var selector = parms["selector"]?.GetValue<string>()
                ?? parms["key"]?.GetValue<string>()
                ?? parms["element"]?.GetValue<string>()
                ?? "";

            var result = method switch
            {
                "initialize" => new JsonObject { ["success"] = true, ["framework"] = GetPlatformName(), ["sdk_version"] = "1.0.0", ["platform"] = GetPlatformName() },
                "health" => new JsonObject { ["status"] = "ok", ["platform"] = GetPlatformName() },
                "inspect" => await HandleInspect(parms),
                "tap" => await HandleTap(selector, parms),
                "enter_text" => await HandleEnterText(
                    selector, parms["text"]?.GetValue<string>() ?? "", parms),
                "screenshot" => await HandleScreenshot(parms),
                "scroll" => await HandleScroll(
                    parms["dx"]?.GetValue<int>() ?? 0,
                    parms["dy"]?.GetValue<int>() ?? 0, parms),
                "swipe" => await HandleScroll(
                    parms["dx"]?.GetValue<int>() ?? 0,
                    parms["dy"]?.GetValue<int>() ?? 0, parms),
                "get_text" => await HandleGetText(selector, parms),
                "find_element" => await HandleFindElement(
                    selector.Length > 0 ? selector : null,
                    parms["text"]?.GetValue<string>(), parms),
                "wait_for_element" => await HandleWaitForElement(
                    selector, parms["timeout"]?.GetValue<int>() ?? 5000, parms),
                "go_back" => await HandleGoBack(parms),
                "get_logs" => await HandleGetLogs(parms),
                "clear_logs" => await HandleClearLogs(parms),
                "inspect_interactive" => await HandleInspectInteractive(parms),
                _ => throw new JsonRpcException(-32601, "Method not found")
            };
            return JsonResponse(id, result: result);
        }
        catch (JsonRpcException jex)
        {
            return JsonResponse(id, error: jex.Message, code: jex.Code);
        }
        catch (Exception ex)
        {
            return JsonResponse(id, error: ex.Message);
        }
    }

    private static string JsonResponse(JsonNode? id, JsonNode? result = null, string? error = null, int code = -32000)
    {
        var obj = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id?.DeepClone() };
        if (error != null)
            obj["error"] = new JsonObject { ["code"] = code, ["message"] = error };
        else
            obj["result"] = result?.DeepClone();
        return obj.ToJsonString();
    }

    // --- Override these in your platform-specific subclass ---

    protected virtual string GetPlatformName() => "dotnet";

    protected virtual Task<JsonObject> HandleInspectInteractive(JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "inspect_interactive not implemented — subclass FlutterSkillBridge for your UI framework" });

    protected virtual Task<JsonObject> HandleInspect(JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "inspect not implemented — subclass FlutterSkillBridge for your UI framework" });

    protected virtual Task<JsonObject> HandleTap(string selector, JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "tap not implemented" });

    protected virtual Task<JsonObject> HandleEnterText(string selector, string text, JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "enter_text not implemented" });

    protected virtual Task<JsonObject> HandleScreenshot(JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "screenshot not implemented" });

    protected virtual Task<JsonObject> HandleScroll(int dx, int dy, JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "scroll not implemented" });

    protected virtual Task<JsonObject> HandleGetText(string selector, JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "get_text not implemented" });

    protected virtual Task<JsonObject> HandleFindElement(string? selector, string? text, JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "find_element not implemented" });

    protected virtual Task<JsonObject> HandleWaitForElement(string selector, int timeout, JsonObject parms)
        => Task.FromResult(new JsonObject { ["error"] = "wait_for_element not implemented" });

    protected virtual Task<JsonObject> HandleGoBack(JsonObject parms)
        => Task.FromResult(new JsonObject { ["success"] = false, ["message"] = "go_back not implemented" });

    protected virtual Task<JsonObject> HandleGetLogs(JsonObject parms)
        => Task.FromResult(new JsonObject { ["logs"] = new JsonArray() });

    protected virtual Task<JsonObject> HandleClearLogs(JsonObject parms)
        => Task.FromResult(new JsonObject { ["success"] = true });
}

public class JsonRpcException : Exception
{
    public int Code { get; }
    public JsonRpcException(int code, string message) : base(message) { Code = code; }
}

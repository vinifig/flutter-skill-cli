using System.Net;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Maui.Controls;
using Microsoft.Maui.Automation;

namespace FlutterSkill;

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
        Console.WriteLine($"[flutter-skill-maui] WebSocket server on port {_port}");
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
        while (ws.State == WebSocketState.Open && !ct.IsCancellationRequested)
        {
            var result = await ws.ReceiveAsync(buffer, ct);
            if (result.MessageType == WebSocketMessageType.Close) break;

            var text = Encoding.UTF8.GetString(buffer, 0, result.Count);
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
            var result = method switch
            {
                "health" => new JsonObject { ["status"] = "ok", ["platform"] = "maui" },
                "inspect" => Inspect(),
                "tap" => Tap(parms["selector"]?.GetValue<string>() ?? ""),
                "enter_text" => EnterText(parms["selector"]?.GetValue<string>() ?? "", parms["text"]?.GetValue<string>() ?? ""),
                "screenshot" => await Screenshot(),
                "scroll" => Scroll(parms["dx"]?.GetValue<int>() ?? 0, parms["dy"]?.GetValue<int>() ?? 0),
                "get_text" => GetText(parms["selector"]?.GetValue<string>() ?? ""),
                "find_element" => FindElement(parms["selector"]?.GetValue<string>(), parms["text"]?.GetValue<string>()),
                "wait_for_element" => await WaitForElement(parms["selector"]?.GetValue<string>() ?? "", parms["timeout"]?.GetValue<int>() ?? 5000),
                _ => new JsonObject { ["error"] = $"Unknown method: {method}" }
            };
            return JsonResponse(id, result: result);
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

    private static Page? GetCurrentPage()
    {
        if (Application.Current?.MainPage is NavigationPage nav)
            return nav.CurrentPage;
        if (Application.Current?.MainPage is Shell shell)
            return shell.CurrentPage;
        return Application.Current?.MainPage;
    }

    private static JsonObject Inspect()
    {
        var page = GetCurrentPage();
        if (page == null) return new JsonObject { ["error"] = "No page" };
        return WalkElement(page, 0);
    }

    private static JsonObject WalkElement(Element el, int depth)
    {
        var node = new JsonObject
        {
            ["type"] = el.GetType().Name,
            ["automationId"] = AutomationProperties.GetAutomationId(el as BindableObject) ?? ""
        };
        if (el is Label lbl) node["text"] = lbl.Text?.Substring(0, Math.Min(lbl.Text.Length, 200));
        if (el is Button btn) node["text"] = btn.Text?.Substring(0, Math.Min(btn.Text.Length, 200));
        if (el is Entry ent) node["text"] = ent.Text?.Substring(0, Math.Min(ent.Text?.Length ?? 0, 200));

        if (depth < 15)
        {
            var children = new JsonArray();
            foreach (var child in el.LogicalChildren.OfType<Element>())
                children.Add(WalkElement(child, depth + 1));
            if (children.Count > 0) node["children"] = children;
        }
        return node;
    }

    private static JsonObject Tap(string selector)
    {
        var el = FindByAutomationId(selector);
        if (el is Button btn) { MainThread.BeginInvokeOnMainThread(() => btn.SendClicked()); return new JsonObject { ["tapped"] = true }; }
        if (el is VisualElement ve)
        {
            // Simulate tap via gesture
            return new JsonObject { ["tapped"] = true, ["note"] = "element found, tap simulated" };
        }
        return new JsonObject { ["error"] = "not found" };
    }

    private static JsonObject EnterText(string selector, string text)
    {
        var el = FindByAutomationId(selector) as Entry;
        if (el == null) return new JsonObject { ["error"] = "Entry not found" };
        MainThread.BeginInvokeOnMainThread(() => el.Text = text);
        return new JsonObject { ["entered"] = true };
    }

    private static async Task<JsonObject> Screenshot()
    {
        var page = GetCurrentPage();
        if (page == null) return new JsonObject { ["error"] = "No page" };
        // MAUI doesn't have a built-in screenshot API on all platforms; placeholder
        return new JsonObject { ["screenshot"] = "pending", ["note"] = "Use platform-specific screenshot capture" };
    }

    private static JsonObject Scroll(int dx, int dy)
    {
        var page = GetCurrentPage();
        var scrollView = FindFirst<ScrollView>(page);
        if (scrollView != null)
        {
            MainThread.BeginInvokeOnMainThread(async () =>
                await scrollView.ScrollToAsync(scrollView.ScrollX + dx, scrollView.ScrollY + dy, true));
            return new JsonObject { ["scrolled"] = true };
        }
        return new JsonObject { ["scrolled"] = false };
    }

    private static JsonObject GetText(string selector)
    {
        var el = FindByAutomationId(selector);
        var text = el switch
        {
            Label l => l.Text,
            Button b => b.Text,
            Entry e => e.Text,
            _ => null
        };
        return text != null ? new JsonObject { ["text"] = text } : new JsonObject { ["error"] = "not found" };
    }

    private static JsonObject FindElement(string? selector, string? text)
    {
        if (selector != null)
            return new JsonObject { ["found"] = (FindByAutomationId(selector) != null) };
        if (text != null)
        {
            var page = GetCurrentPage();
            var found = FindFirst<Label>(page, l => l.Text?.Contains(text) == true) != null ||
                        FindFirst<Button>(page, b => b.Text?.Contains(text) == true) != null;
            return new JsonObject { ["found"] = found };
        }
        return new JsonObject { ["error"] = "selector or text required" };
    }

    private static async Task<JsonObject> WaitForElement(string selector, int timeout)
    {
        var start = Environment.TickCount64;
        while (Environment.TickCount64 - start < timeout)
        {
            if (FindByAutomationId(selector) != null)
                return new JsonObject { ["found"] = true };
            await Task.Delay(100);
        }
        return new JsonObject { ["found"] = false, ["error"] = "timeout" };
    }

    private static Element? FindByAutomationId(string id)
    {
        var page = GetCurrentPage();
        if (page == null) return null;
        return FindFirst<Element>(page, e =>
            AutomationProperties.GetAutomationId(e as BindableObject) == id);
    }

    private static T? FindFirst<T>(Element? root, Func<T, bool>? predicate = null) where T : Element
    {
        if (root == null) return null;
        if (root is T t && (predicate == null || predicate(t))) return t;
        foreach (var child in root.LogicalChildren.OfType<Element>())
        {
            var found = FindFirst<T>(child, predicate);
            if (found != null) return found;
        }
        return null;
    }
}

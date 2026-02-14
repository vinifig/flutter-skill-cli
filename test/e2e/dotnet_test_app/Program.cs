using System.Text.Json.Nodes;
using FlutterSkill;

/// <summary>
/// Simulated UI test app for the .NET FlutterSkillBridge.
/// Uses in-memory elements to test the bridge protocol without requiring MAUI.
/// </summary>
class TestElement
{
    public string Type { get; set; } = "";
    public string? Key { get; set; }
    public string? Text { get; set; }
    public bool Enabled { get; set; } = true;
    public bool Clickable { get; set; }
    public List<TestElement> Children { get; } = new();
}

class TestBridge : FlutterSkillBridge
{
    private readonly List<TestElement> _elements = new();
    private string _currentPage = "home";
    private int _counter = 0;
    private string _inputText = "";
    private readonly List<string> _logs = new();

    public TestBridge(int port = 18118) : base(port)
    {
        BuildHomePage();
    }

    private void BuildHomePage()
    {
        _elements.Clear();
        _elements.Add(new TestElement { Type = "text", Key = "counter", Text = $"Count: {_counter}" });
        _elements.Add(new TestElement { Type = "button", Key = "increment-btn", Text = "Increment", Clickable = true });
        _elements.Add(new TestElement { Type = "button", Key = "decrement-btn", Text = "Decrement", Clickable = true });
        _elements.Add(new TestElement { Type = "text_field", Key = "text-input", Text = _inputText });
        _elements.Add(new TestElement { Type = "button", Key = "submit-btn", Text = "Submit", Clickable = true });
        _elements.Add(new TestElement { Type = "checkbox", Key = "test-checkbox", Text = _counter % 2 == 0 ? "Checked" : "Unchecked" });
        _elements.Add(new TestElement { Type = "button", Key = "detail-btn", Text = "Go to Detail", Clickable = true });
        for (int i = 0; i < 20; i++)
            _elements.Add(new TestElement { Type = "text", Key = $"item-{i}", Text = $"Item {i + 1}" });
    }

    private void BuildDetailPage()
    {
        _elements.Clear();
        _elements.Add(new TestElement { Type = "text", Key = "detail-title", Text = "Detail Page" });
        _elements.Add(new TestElement { Type = "text", Key = "detail-counter", Text = $"Counter: {_counter}" });
        _elements.Add(new TestElement { Type = "button", Key = "back-btn", Text = "Go Back", Clickable = true });
    }

    protected override string GetPlatformName() => "dotnet";

    protected override Task<JsonObject> HandleInspect(JsonObject parms)
    {
        var elements = new JsonArray();
        foreach (var el in _elements)
        {
            elements.Add(new JsonObject
            {
                ["type"] = el.Type,
                ["key"] = el.Key,
                ["text"] = el.Text,
                ["enabled"] = el.Enabled,
                ["clickable"] = el.Clickable,
                ["visible"] = true,
                ["bounds"] = new JsonObject { ["x"] = 0, ["y"] = 0, ["width"] = 200, ["height"] = 40 }
            });
        }
        return Task.FromResult(new JsonObject { ["elements"] = elements });
    }

    protected override Task<JsonObject> HandleInspectInteractive(JsonObject parms)
    {
        var elements = new JsonArray();
        var refCounts = new Dictionary<string, int>();
        int yOffset = 0;

        foreach (var el in _elements)
        {
            if (!IsInteractive(el.Type)) { yOffset += 40; continue; }

            var role = MapRole(el.Type);
            var content = (el.Text ?? el.Key ?? "").Replace(" ", "_");
            if (content.Length > 30) content = content[..27] + "...";

            var baseRef = string.IsNullOrEmpty(content) ? role : $"{role}:{content}";
            refCounts.TryGetValue(baseRef, out var count);
            refCounts[baseRef] = count + 1;
            var refId = count == 0 ? baseRef : $"{baseRef}[{count}]";

            var actions = new JsonArray();
            if (el.Type is "button") actions.Add("tap");
            else if (el.Type is "text_field") { actions.Add("tap"); actions.Add("enter_text"); }
            else if (el.Type is "checkbox" or "switch") { actions.Add("tap"); actions.Add("toggle"); }
            else if (el.Type is "slider") { actions.Add("set_value"); }
            else actions.Add("tap");

            elements.Add(new JsonObject
            {
                ["ref"] = refId,
                ["type"] = el.Type,
                ["text"] = el.Text,
                ["enabled"] = el.Enabled,
                ["actions"] = actions,
                ["bounds"] = new JsonObject { ["x"] = 0, ["y"] = yOffset, ["width"] = 200, ["height"] = 40 }
            });
            yOffset += 40;
        }

        return Task.FromResult(new JsonObject
        {
            ["elements"] = elements,
            ["summary"] = $"{elements.Count} interactive elements"
        });
    }

    private static bool IsInteractive(string type) =>
        type is "button" or "text_field" or "checkbox" or "switch" or "slider" or "dropdown" or "link";

    private static string MapRole(string type) => type switch
    {
        "button" => "button",
        "text_field" => "input",
        "checkbox" or "switch" => "toggle",
        "slider" => "slider",
        "dropdown" => "select",
        "link" => "link",
        _ => "element"
    };

    private TestElement? FindByKey(string key)
    {
        return _elements.FirstOrDefault(e => e.Key == key);
    }

    private TestElement? FindByText(string text)
    {
        return _elements.FirstOrDefault(e => e.Text?.Contains(text) == true);
    }

    protected override Task<JsonObject> HandleTap(string selector, JsonObject parms)
    {
        var key = parms["key"]?.GetValue<string>() ?? selector;
        var textMatch = parms["text"]?.GetValue<string>();
        
        var el = !string.IsNullOrEmpty(key) ? FindByKey(key) : null;
        el ??= textMatch != null ? FindByText(textMatch) : null;
        
        if (el == null) return Task.FromResult(new JsonObject { ["success"] = false, ["message"] = "Element not found" });

        _logs.Add($"Tapped: {el.Key}");
        
        if (el.Key == "increment-btn") { _counter++; BuildHomePage(); }
        else if (el.Key == "decrement-btn") { _counter--; BuildHomePage(); }
        else if (el.Key == "detail-btn") { _currentPage = "detail"; BuildDetailPage(); }
        else if (el.Key == "back-btn") { _currentPage = "home"; BuildHomePage(); }
        else if (el.Key == "submit-btn") { _logs.Add($"Submitted: {_inputText}"); }

        return Task.FromResult(new JsonObject { ["success"] = true });
    }

    protected override Task<JsonObject> HandleEnterText(string selector, string text, JsonObject parms)
    {
        var key = parms["key"]?.GetValue<string>() ?? selector;
        var el = FindByKey(key);
        if (el == null) return Task.FromResult(new JsonObject { ["success"] = false, ["message"] = "Not found" });
        el.Text = text;
        _inputText = text;
        return Task.FromResult(new JsonObject { ["success"] = true });
    }

    protected override Task<JsonObject> HandleGetText(string selector, JsonObject parms)
    {
        var key = parms["key"]?.GetValue<string>() ?? selector;
        var el = FindByKey(key);
        return Task.FromResult(new JsonObject { ["text"] = el?.Text });
    }

    protected override Task<JsonObject> HandleFindElement(string? selector, string? text, JsonObject parms)
    {
        var key = parms["key"]?.GetValue<string>() ?? selector;
        TestElement? el = null;
        if (!string.IsNullOrEmpty(key)) el = FindByKey(key!);
        if (el == null && !string.IsNullOrEmpty(text)) el = FindByText(text!);
        
        if (el != null)
            return Task.FromResult(new JsonObject
            {
                ["found"] = true,
                ["element"] = new JsonObject { ["type"] = el.Type, ["key"] = el.Key, ["text"] = el.Text }
            });
        return Task.FromResult(new JsonObject { ["found"] = false });
    }

    protected override async Task<JsonObject> HandleWaitForElement(string selector, int timeout, JsonObject parms)
    {
        var key = parms["key"]?.GetValue<string>() ?? selector;
        var textMatch = parms["text"]?.GetValue<string>();
        var start = Environment.TickCount64;
        while (Environment.TickCount64 - start < timeout)
        {
            var el = !string.IsNullOrEmpty(key) ? FindByKey(key) : null;
            el ??= textMatch != null ? FindByText(textMatch) : null;
            if (el != null) return new JsonObject { ["found"] = true };
            await Task.Delay(100);
        }
        return new JsonObject { ["found"] = false };
    }

    protected override Task<JsonObject> HandleScroll(int dx, int dy, JsonObject parms)
    {
        var direction = parms["direction"]?.GetValue<string>() ?? "down";
        _logs.Add($"Scrolled: {direction}");
        return Task.FromResult(new JsonObject { ["success"] = true });
    }

    protected override Task<JsonObject> HandleScreenshot(JsonObject parms)
    {
        // Return a small fake screenshot (1x1 white PNG base64)
        var fakePng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==";
        return Task.FromResult(new JsonObject
        {
            ["success"] = true,
            ["image"] = fakePng,
            ["format"] = "png",
            ["encoding"] = "base64"
        });
    }

    protected override Task<JsonObject> HandleGoBack(JsonObject parms)
    {
        if (_currentPage == "detail") { _currentPage = "home"; BuildHomePage(); }
        return Task.FromResult(new JsonObject { ["success"] = true });
    }
}

// Override HandleRequest to add go_back, get_logs, clear_logs, initialize, swipe
class FullTestBridge : TestBridge
{
    private readonly List<string> _logBuffer = new();
    
    public FullTestBridge(int port = 18118) : base(port) { }
}

class Program
{
    static async Task Main(string[] args)
    {
        var port = args.Length > 0 ? int.Parse(args[0]) : 18118;
        var bridge = new TestBridge(port);
        bridge.Start();
        Console.WriteLine($"[flutter-skill-dotnet] Test bridge on port {port}. Press Enter to stop.");
        Console.ReadLine();
        bridge.Stop();
    }
}

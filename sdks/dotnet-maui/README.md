# Flutter Skill — .NET MAUI SDK

AI E2E testing bridge for .NET MAUI apps. JSON-RPC 2.0 over WebSocket on port 18118.

## Setup

Add project reference:
```xml
<ProjectReference Include="../sdks/dotnet-maui/FlutterSkill.csproj" />
```

## Usage

```csharp
var bridge = new FlutterSkill.FlutterSkillBridge();
bridge.Start();
```

Use `AutomationProperties.AutomationId` on your MAUI elements for selector-based targeting.

## Supported Commands

`health`, `inspect`, `tap`, `enter_text`, `screenshot`, `scroll`, `get_text`, `find_element`, `wait_for_element`

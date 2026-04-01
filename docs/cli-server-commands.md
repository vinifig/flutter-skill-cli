# Named Server Registry and CLI IPC Layer

## Overview

The named server registry and CLI IPC layer is a modern approach to managing connections to Flutter applications without requiring the MCP (Model Context Protocol) server. This feature enables you to:

- **Give running Flutter apps memorable names** using `flutter_skill connect --id=myapp`
- **Target multiple apps in parallel** with commands like `flutter_skill tap "Button" --server=app-a,app-b`
- **Work seamlessly across git worktrees** — each worktree targets its named server independently
- **Integrate easily into CI/CD pipelines** with JSON output and detached process modes
- **Escape MCP complexity** — use simple CLI commands instead of JSON-RPC protocol details

### The Core Concept: Named Server Instances

Instead of managing a single anonymous connection or relying on a shared MCP server process, each running `flutter_skill` server gets a memorable name (ID). A named server instance is a lightweight daemon that:

1. Holds a connection to a running Flutter application via its VM Service
2. Listens on a local TCP port (with a Unix socket fast path on macOS/Linux) for incoming commands
3. Registers itself in `~/.flutter_skill/servers/` so other CLI invocations can find it
4. Executes commands (tap, inspect, screenshot, etc.) on the app and returns results

This enables a **distribute-and-query** model where multiple tools, scripts, and environments can interact with the same app instance without blocking each other.

---

## Quick Start

### Single App (Backward Compatible)

If you're developing on one app, the workflow is unchanged:

```bash
# Terminal A: Run your app with Dart VM Service
flutter run --vm-service-port=50000

# Terminal B: Attach flutter-skill to it (just once)
flutter_skill connect --id=myapp --port=50000
# Output: Skill server "myapp" listening on port <random-port>
#         Press Ctrl+C to stop.

# Terminal C (or anywhere else): Use flutter-skill
flutter_skill inspect --server=myapp
flutter_skill tap "Login" --server=myapp
flutter_skill screenshot "app.png" --server=myapp

# When done
Ctrl+C in Terminal B
```

### Multiple Apps in Parallel

If you're testing multiple apps at once (e.g., two different features):

```bash
# Terminal A: Run feature-auth app
flutter run -d "iPhone 16" --vm-service-port=50000

# Terminal B: Connect it
flutter_skill connect --id=feature-auth --port=50000

# Terminal C: Run feature-payments app
flutter run -d "Pixel 8" --vm-service-port=50001

# Terminal D: Connect it
flutter_skill connect --id=feature-payments --port=50001

# Now use both apps from anywhere:
flutter_skill tap "Login" --server=feature-auth
flutter_skill tap "Pay Now" --server=feature-payments

# Run the same action on both in parallel:
flutter_skill tap "Logout" --server=feature-auth,feature-payments
```

### Git Worktrees

Each git worktree is an isolated environment. This feature lets each worktree target its own named server:

```bash
# Main worktree: run one app
git checkout main
flutter run --vm-service-port=50000 &
flutter_skill connect --id=main-app --port=50000 &

# Worktree A: run a different app
git worktree add ../wt-feature-a origin/feature-a
cd ../wt-feature-a
flutter run --vm-service-port=50001 &
flutter_skill connect --id=feature-a-app --port=50001 &

# From worktree A, target its own server
flutter_skill inspect --server=feature-a-app
flutter_skill tap "New Button" --server=feature-a-app

# Switch back to main and target main's server
cd ../flutter-skill-cli
flutter_skill inspect --server=main-app
```

### CI/CD Pipeline

In continuous integration, you typically can't use interactive terminals. Use `--detach` to start everything in the background:

```bash
# .github/workflows/e2e.yml

- name: Launch Flutter app in background
  run: flutter_skill launch . --id=ci-test --device=chrome --detach
  # Now flutter run + skill server are both running as background processes

- name: Run smoke tests
  run: |
    flutter_skill inspect --server=ci-test
    flutter_skill tap "Login" --server=ci-test
    flutter_skill enter_text "email" "test@example.com" --server=ci-test
    flutter_skill tap "Submit" --server=ci-test
    flutter_skill screenshot "dashboard.png" --server=ci-test
  # Output is automatically JSON when CI=true (GitHub Actions sets this)

- name: Cleanup
  if: always()
  run: flutter_skill server stop --id=ci-test
  # Kills both flutter run and skill server
```

---

## Commands Reference

### `flutter_skill connect`

**Attach flutter-skill to a running Flutter app and register it with a name.**

```bash
flutter_skill connect --id=<name> [--port=<port>|--uri=<uri>] \
  [--project=<path>] [--device=<device-id>]
```

#### Options

| Option | Required | Default | Description |
|--------|----------|---------|-------------|
| `--id=<name>` | Yes | — | Server name (alphanumeric, hyphens, underscores only). |
| `--port=<port>` | No | — | VM Service port (e.g., 50000). Either this or `--uri` must be provided. |
| `--uri=<uri>` | No | — | Full VM Service URI (e.g., `ws://127.0.0.1:50000/ws` or `http://127.0.0.1:50000`). |
| `--project=<path>` | No | `.` | Project directory (stored in registry for reference). |
| `--device=<id>` | No | — | Device ID (stored in registry for reference). |

#### Behavior

- Connects to the running Flutter app via VM Service
- Starts a JSON-RPC server on a random free local TCP port
- Registers the server in `~/.flutter_skill/servers/<name>.json`
- **Stays in foreground** — prints logs and waits for `Ctrl+C` to disconnect cleanly
- On `Ctrl+C`: closes the server, unregisters from the registry, and exits

#### Examples

```bash
# Connect to app on port 50000, name it "myapp"
flutter_skill connect --id=myapp --port=50000

# Connect using a full URI (useful for discovery output)
flutter_skill connect --id=myapp \
  --uri=ws://127.0.0.1:50000/ws \
  --project=/Users/you/projects/myapp \
  --device="iPhone 16 Pro"

# Connect with auto-discovery (looks up URI automatically)
flutter_skill connect --id=myapp
```

#### Exit Codes

- `0` — Connected and cleanly shut down
- `1` — Failed to connect or invalid arguments

---

### `flutter_skill launch`

**Start a Flutter app and optionally register a named server for it.**

```bash
flutter_skill launch [<project-path>] [--id=<name>] [--detach] [<flutter-args>...]
```

#### Options

| Option | Description |
|--------|-------------|
| `--id=<name>` | Optional. If provided, automatically starts a skill server with this name once the app is running. |
| `--detach` | Optional. Spawns the skill server in a detached background process. Useful for CI/CD. Without this flag, the skill server runs in the same process. |
| `<flutter-args>` | Any flags you'd normally pass to `flutter run` (e.g., `-d "iPhone 16"`, `-r` for release mode). |

#### Behavior

- Runs `flutter run` with your project
- Auto-adds `--vm-service-port=50000` if no other port is specified (recommended for faster discovery)
- If `--id` is provided:
  - Once the VM Service is ready, starts a skill server with that ID
  - Registers it in the server registry
  - Writes `.flutter_skill_server` file in the project directory (for auto-discovery by other commands)
- If `--detach` is provided:
  - Spawns the skill server as a separate background process
  - Parent `flutter run` continues in foreground (you see app output normally)
  - Useful when you want to keep the `flutter run` window open for interactive debugging
- Without `--detach`:
  - Skill server runs in the same process (non-blocking background task)

#### Examples

```bash
# Launch app and attach a skill server (in-process)
flutter_skill launch . --id=myapp

# Launch app, attach skill server, and run flutter in background
flutter_skill launch . --id=myapp --detach

# Launch on a specific device
flutter_skill launch . --id=myapp -d "iPhone 16" --detach

# Launch in release mode
flutter_skill launch . --id=myapp -r --detach

# Custom VM Service port
flutter_skill launch . --id=myapp --vm-service-port=8888
```

#### Exit Codes

- `0` — App exited cleanly
- `1` — Setup failed or app crashed

---

### `flutter_skill server list`

**Show all registered skill servers and their status.**

```bash
flutter_skill server list [--output=json|human]
```

#### Output (Human)

```
Running skill servers:

ID                  PORT     PID      PROJECT
myapp               52341    84921    /Users/you/projects/myapp
feature-auth        52342    84922    /Users/you/projects/feature-auth
feature-payments    52343    84923    /Users/you/projects/feature-payments
```

#### Output (JSON)

```json
[
  {
    "id": "myapp",
    "port": 52341,
    "pid": 84921,
    "projectPath": "/Users/you/projects/myapp",
    "deviceId": "iPhone 16 Pro",
    "vmServiceUri": "ws://127.0.0.1:50000/ws",
    "startedAt": "2026-04-01T10:30:00.000Z"
  }
]
```

#### Notes

- Automatically filters out stale entries (processes that are no longer running)
- Shows "unreachable" status next to servers whose TCP port is not responding
- In CI environments (when `CI=true` or `GITHUB_ACTIONS=true`), JSON output is default

---

### `flutter_skill server stop`

**Stop a named skill server and clean up its registry entry.**

```bash
flutter_skill server stop --id=<name> [--output=json|human]
```

#### Behavior

- Sends a shutdown signal to the skill server
- Server unregisters itself from the registry
- If the server process is unreachable, manually cleans up the registry entry
- Exits with code 0 if stopped successfully, 1 if the ID does not exist

#### Examples

```bash
flutter_skill server stop --id=myapp

# In CI, capture the result as JSON
flutter_skill server stop --id=ci-test --output=json
```

#### Output

```
Server "myapp" stopped.
```

---

### `flutter_skill server status`

**Show detailed status of a named skill server.**

```bash
flutter_skill server status --id=<name> [--output=json|human]
```

#### Output (Human)

```
Server: myapp
  Status  : running
  Port    : 52341
  PID     : 84921
  Project : /Users/you/projects/myapp
  Device  : iPhone 16 Pro
  URI     : ws://127.0.0.1:50000/ws
  Started : 2026-04-01 10:30:00.000
```

#### Output (JSON)

```json
{
  "id": "myapp",
  "port": 52341,
  "pid": 84921,
  "projectPath": "/Users/you/projects/myapp",
  "deviceId": "iPhone 16 Pro",
  "vmServiceUri": "ws://127.0.0.1:50000/ws",
  "startedAt": "2026-04-01T10:30:00.000Z",
  "alive": true
}
```

---

### `flutter_skill servers`

**Shorthand for `flutter_skill server list`.**

```bash
flutter_skill servers [--output=json|human]
```

Identical to `flutter_skill server list`. Useful for quick checks.

---

### `flutter_skill ping`

**Quick health check for one or more named server instances.**

```bash
flutter_skill ping --server=<id>[,<id2>,...] [--output=json|human]
```

Sends a `ping` request to each named server and reports whether it responded.
Exits with code 0 if all servers are reachable, or 1 if any are unreachable.

#### Examples

```bash
# Check a single server
flutter_skill ping --server=myapp

# Check multiple servers
flutter_skill ping --server=feature-auth,feature-payments

# JSON output (useful for scripting and CI)
flutter_skill ping --server=ci-test --output=json
```

#### Output (Human)

```
[myapp] pong (12ms)
```

#### Output (Human, Unreachable)

```
[myapp] unreachable: Could not connect to server "myapp": Connection refused
```

#### Output (JSON)

```json
[
  {"server": "myapp", "success": true, "action": "ping", "duration_ms": 12}
]
```

---

### `flutter_skill inspect`

**Inspect the interactive elements of a Flutter app.**

```bash
flutter_skill inspect [--server=<id>[,<id2>,...]] [--output=json|human]
```

#### Without `--server` (Auto-Discovery)

- Uses `.flutter_skill_server` file if present (written by `launch`)
- Falls back to `.flutter_skill_uri` file if present (backward compatibility)
- If multiple servers are running, prompts you to specify one
- Otherwise, uses direct VM Service connection via discovery

#### With `--server`

- Connects to the named server(s) via the registry

#### Examples

```bash
# Auto-discover (works after flutter_skill launch . --id=myapp)
flutter_skill inspect

# Target a specific server
flutter_skill inspect --server=myapp

# Target multiple servers (concurrent)
flutter_skill inspect --server=feature-auth,feature-payments

# JSON output for parsing
flutter_skill inspect --server=myapp --output=json
```

#### Output (Human)

```
Interactive Elements:
- **ElevatedButton** [Key: "loginBtn"] [Text: "Login"]
  - **Text** [Text: "Login"]
- **TextField** [Key: "emailField"]
- **Row** [Key: "header"]
  - **Text** [Text: "Welcome"]
```

#### Output (JSON)

```json
{
  "elements": [
    {
      "type": "ElevatedButton",
      "key": "loginBtn",
      "text": "Login"
    },
    {
      "type": "TextField",
      "key": "emailField"
    }
  ]
}
```

---

### `flutter_skill act` (and related commands)

**Perform actions on a Flutter app (tap, enter text, scroll, screenshot, etc.).**

```bash
flutter_skill act <action> [<params>...] [--server=<id>[,<id2>,...]]
flutter_skill tap <key-or-text> [--server=<id>[,<id2>,...]]
flutter_skill enter_text <key> <text> [--server=<id>[,<id2>,...]]
flutter_skill swipe [<direction>] [<distance>] [--server=<id>[,<id2>,...]]
flutter_skill scroll_to <key-or-text> [--server=<id>[,<id2>,...]]
flutter_skill screenshot [<output-path>] [--server=<id>[,<id2>,...]]
```

#### Available Actions

| Action | Parameters | Description |
|--------|-----------|-------------|
| `tap` | `<key-or-text>` | Tap a button or widget by key or visible text. |
| `enter_text` | `<key> <text>` | Enter text into a text field. |
| `swipe` | `[<direction>] [<distance>]` | Swipe the screen (up, down, left, right). Default: 300px up. |
| `scroll_to` | `<key-or-text>` | Scroll until a widget is visible. |
| `screenshot` | `[<path>]` | Capture the screen. Saves to file or prints base64 if no path given. |
| `get_text` | `<key>` | Get the text value of a widget. |
| `wait_for_element` | `<key-or-text> [<timeout-ms>]` | Wait for a widget to appear (default timeout 5000ms). |
| `assert_visible` | `<key-or-text>` | Verify a widget is visible; fail if not. |
| `assert_gone` | `<key-or-text>` | Verify a widget is NOT visible; fail if it is. |
| `go_back` | — | Trigger Android back button or iOS back gesture. |
| `hot_reload` | — | Hot reload the app. |
| `hot_restart` | — | Hot restart the app. |

#### Examples

```bash
# Single app (auto-discovery)
flutter_skill tap "Login"

# Specific server
flutter_skill tap "Login" --server=myapp

# Multiple servers (runs in parallel)
flutter_skill tap "Login" --server=app-a,app-b

# Enter text
flutter_skill enter_text "email" "user@example.com" --server=myapp

# Scroll and assert
flutter_skill scroll_to "Submit Button" --server=myapp
flutter_skill assert_visible "Submit Button" --server=myapp

# Capture screenshot
flutter_skill screenshot "screenshots/login.png" --server=myapp

# Wait for element to appear (up to 10 seconds)
flutter_skill wait_for_element "Dashboard" 10000 --server=myapp

# Hot reload
flutter_skill hot_reload --server=myapp

# Get text value
flutter_skill get_text "emailLabel" --server=myapp
```

#### Output (Human, Single Server)

```
Tapped "Login"
```

or

```
Entered text "user@example.com" into "email"
```

#### Output (Human, Multiple Servers)

```
[app-a] tap completed (123ms)
[app-b] tap completed (145ms)
```

#### Output (JSON)

```json
[
  {
    "server": "app-a",
    "action": "tap",
    "success": true,
    "duration_ms": 123
  },
  {
    "server": "app-b",
    "action": "tap",
    "success": true,
    "duration_ms": 145
  }
]
```

---

## Use Cases

### Single Developer Workflow

You're developing a single app and want simple commands without MCP complexity.

```bash
# Start your app (one terminal)
flutter run --vm-service-port=50000

# In another terminal, attach flutter-skill
flutter_skill connect --id=myapp --port=50000

# From anywhere, use flutter-skill
flutter_skill inspect --server=myapp
flutter_skill tap "Login"
flutter_skill enter_text "email" "test@example.com"
flutter_skill tap "Submit"
flutter_skill screenshot "result.png"
```

**Benefit**: No MCP server to manage. Just two CLI commands and you're done.

---

### Multiple Apps in Parallel

You're testing two features simultaneously on different devices or emulators.

```bash
# Terminal 1: Feature A on iPhone
flutter run -d "iPhone 16 Pro" --vm-service-port=50000
# Terminal 2
flutter_skill connect --id=feature-a --port=50000

# Terminal 3: Feature B on Pixel 8
flutter run -d "Pixel 8" --vm-service-port=50001
# Terminal 4
flutter_skill connect --id=feature-b --port=50001

# Now, from anywhere, test both:
flutter_skill tap "Login" --server=feature-a
flutter_skill tap "Login" --server=feature-b

# Or run the same action on both in parallel:
flutter_skill tap "Logout" --server=feature-a,feature-b
```

**Benefit**: No context switching. Both apps are always available via named servers. Script or automate across multiple apps seamlessly.

---

### Git Worktrees Without MCP

Each git worktree is an isolated environment. Normally, if two worktrees want to use flutter-skill, they'd have to share a single MCP server (which doesn't work well) or duplicate the MCP setup.

With named servers, each worktree independently targets its own server:

```bash
# Main branch worktree
git checkout main
cd /path/to/flutter-skill-cli
flutter run --vm-service-port=50000 &
flutter_skill connect --id=main --port=50000 &

# Feature A worktree
git worktree add ../wt-a origin/feature-a
cd ../wt-a
flutter run --vm-service-port=50001 &
flutter_skill connect --id=feature-a --port=50001 &

# Feature B worktree
git worktree add ../wt-b origin/feature-b
cd ../wt-b
flutter run --vm-service-port=50002 &
flutter_skill connect --id=feature-b --port=50002 &

# Now each worktree can independently test:
# In wt-a:
flutter_skill tap "New Button" --server=feature-a

# In wt-b:
flutter_skill tap "Updated Flow" --server=feature-b

# Back in main:
flutter_skill tap "Original Button" --server=main
```

**Benefit**: Zero coordination between worktrees. Each one runs its own flutter app and skill server independently. Perfect for parallel feature development.

---

### CI/CD Pipeline

In a CI pipeline, there's no interactive terminal. Use `--detach` to start everything in the background and `--output=json` for machine-readable results.

```yaml
# .github/workflows/e2e.yml
name: E2E Tests

on: [push, pull_request]

jobs:
  e2e:
    runs-on: macos-latest
    
    steps:
      - uses: actions/checkout@v4
      
      - uses: subosito/flutter-action@v2
      
      - name: Install flutter-skill CLI
        run: dart pub global activate --source path .
      
      - name: Launch app in background
        run: |
          flutter_skill launch . \
            --id=ci-test \
            --device=chrome \
            --detach
      
      - name: Wait for app readiness
        run: |
          for i in {1..30}; do
            if flutter_skill ping --server=ci-test --output=json 2>/dev/null; then
              echo "App is ready"
              exit 0
            fi
            sleep 1
          done
          echo "App failed to start"
          exit 1
      
      - name: Run smoke tests
        run: |
          # All these run with JSON output (CI=true from GitHub Actions)
          flutter_skill tap "Login" --server=ci-test
          flutter_skill enter_text "email" "test@ci.com" --server=ci-test
          flutter_skill enter_text "password" "secret123" --server=ci-test
          flutter_skill tap "Sign In" --server=ci-test
          flutter_skill assert_visible "Dashboard" --server=ci-test
          flutter_skill screenshot "dashboard.png" --server=ci-test
      
      - name: Upload screenshots
        if: always()
        uses: actions/upload-artifact@v3
        with:
          name: screenshots
          path: "*.png"
      
      - name: Cleanup
        if: always()
        run: flutter_skill server stop --id=ci-test
```

**Benefits**:
- No interactive prompts; everything runs unattended
- `--detach` starts the app and server as background processes
- `CI=true` (set automatically by GitHub Actions) triggers JSON output
- Easily parse results for pass/fail decisions
- Clean shutdown with `server stop` ensures resources are freed

---

### Testing Against Remote VM Service

If your Flutter app is running on a remote machine, you can still use flutter-skill by connecting to the remote VM Service URI.

```bash
# On the app's machine (or wherever flutter run is)
flutter run --vm-service-port=50000

# On your local machine, connect to the remote
flutter_skill connect --id=remote-app \
  --uri=ws://192.168.1.100:50000/ws \
  --project="/path/to/project" \
  --device="remote-emulator"

# Now use flutter-skill locally
flutter_skill inspect --server=remote-app
flutter_skill tap "Login" --server=remote-app
```

**Benefit**: Great for testing shared CI machines or testing with apps running on team infrastructure without needing to duplicate the development environment locally.

---

## Server Registry

### Location

All server registration data is stored in `~/.flutter_skill/servers/` (cross-platform):

```
~/.flutter_skill/
  servers/
    myapp.json          ← Server registration file (human-readable JSON)
    myapp.sock          ← Unix socket (optional, macOS/Linux only, for lower latency)
    feature-auth.json
    feature-auth.sock
```

### Server Entry Format

Each `.json` file contains:

```json
{
  "id": "myapp",
  "port": 52341,
  "pid": 84921,
  "projectPath": "/Users/you/projects/myapp",
  "deviceId": "iPhone 16 Pro",
  "vmServiceUri": "ws://127.0.0.1:50000/ws",
  "startedAt": "2026-04-01T10:30:00.000Z"
}
```

| Field | Purpose |
|-------|---------|
| `id` | The server name (must match the filename without `.json`) |
| `port` | Local TCP port the server listens on |
| `pid` | Process ID of the server (used to detect stale entries) |
| `projectPath` | Project directory (for reference and organizing server lists) |
| `deviceId` | Device identifier (for reference, e.g., "iPhone 16 Pro") |
| `vmServiceUri` | Full VM Service URI of the connected Flutter app |
| `startedAt` | ISO 8601 timestamp when the server started |

### Cleanup

- **Stale entries are automatically cleaned up** when you list servers. If a registered server's PID is no longer running, it's silently removed.
- **Manual cleanup**: Delete `~/.flutter_skill/servers/<id>.json` and `~/.flutter_skill/servers/<id>.sock` (if present) to unregister a server.
- **Broken connections**: If a server crashes, its registry entry is cleaned up the next time you run `flutter_skill server list`.

---

## Output Formats

### Human-Readable Output (Default)

Optimized for developers reading output in a terminal:

```bash
$ flutter_skill tap "Login"
Tapped "Login"

$ flutter_skill inspect
Interactive Elements:
- **ElevatedButton** [Key: "loginBtn"] [Text: "Login"]
  - **Text** [Text: "Login"]
- **TextField** [Key: "emailField"]

$ flutter_skill server list
Running skill servers:

ID                  PORT     PID      PROJECT
myapp               52341    84921    /Users/you/projects/myapp
feature-auth        52342    84922    /Users/you/projects/feature-auth
```

### JSON Output

Machine-readable format for CI, scripting, and automation:

```bash
$ flutter_skill tap "Login" --output=json
{"server":"myapp","action":"tap","success":true,"duration_ms":123}

$ flutter_skill server list --output=json
[{"id":"myapp","port":52341,"pid":84921,...}]
```

### Automatic CI Detection

When running in a CI environment, output is automatically JSON:

- GitHub Actions: `GITHUB_ACTIONS=true`
- CircleCI: `CIRCLECI=true`
- Travis CI: `TRAVIS=true`
- Buildkite: `BUILDKITE=true`
- Generic CI: `CI=true`

Override with `--output=human` if needed:

```bash
# CI environment defaults to JSON
flutter_skill tap "Login" --server=myapp
# Output: {"server":"myapp",...}

# Force human output even in CI
flutter_skill tap "Login" --server=myapp --output=human
# Output: Tapped "Login"
```

---

## Architecture

### Communication Model

The named server registry uses a **distributed client-server model** over local IPC:

```
┌─ Developer Machine ────────────────────────────────┐
│                                                    │
│  flutter_skill launch      ← starts flutter run   │
│  flutter_skill connect     ← attaches skill server│
│                                                    │
│  ┌──────────────────────────────────────────────┐ │
│  │         SkillServer Instance (myapp)         │ │
│  │  - Listens on TCP 127.0.0.1:52341            │ │
│  │  - (Optional Unix socket: ~/.flutter_skill/  │ │
│  │    servers/myapp.sock)                       │ │
│  │  - Registered in ~/.flutter_skill/servers/   │ │
│  │    myapp.json                                │ │
│  └──────────────────────────────────────────────┘ │
│           ▲                                        │
│           │ JSON-RPC 2.0                          │
│           │ (TCP or Unix socket)                  │
│           │                                        │
│  ┌────────┴────────────────────────────────────┐ │
│  │     CLI Client (flutter_skill tap ...)      │ │
│  │  1. Read ~/.flutter_skill/servers/myapp.json│ │
│  │  2. Connect to 127.0.0.1:52341              │ │
│  │  3. Send JSON-RPC request                   │ │
│  │  4. Receive response, print to user         │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
└────────────────────────────────────────────────────┘
```

### SkillServer: The Daemon

`SkillServer` is the long-lived process that runs during `flutter_skill connect` or `flutter_skill launch`. It:

1. **Owns the AppDriver connection**: Maintains a WebSocket connection to the Flutter app's VM Service
2. **Runs a JSON-RPC server**: Listens on a local TCP port and optionally a Unix socket
3. **Dispatches commands**: Receives requests (tap, screenshot, etc.), delegates to AppDriver, and returns results
4. **Self-manages lifecycle**: Unregisters from the registry when shut down

### SkillClient: The CLI Tool

`SkillClient` is what the CLI uses to communicate with a `SkillServer`. It:

1. **Resolves the server**: Reads `~/.flutter_skill/servers/<id>.json` to find the port
2. **Connects**: Establishes a TCP socket (or prefers Unix socket on macOS/Linux)
3. **Sends one request**: A single JSON-RPC call with the command and parameters
4. **Reads the response**: Waits for the result and returns it
5. **Closes the socket**: Cleans up immediately

### ServerRegistry: The Catalog

`ServerRegistry` manages the `~/.flutter_skill/servers/` directory:

- **Register**: Write `<id>.json` with server metadata when a server starts
- **List**: Read all `.json` files, filter out stale PIDs, return active servers
- **Get**: Retrieve a single server's metadata by ID
- **Unregister**: Delete `<id>.json` and `<id>.sock` when a server stops
- **Check alive**: Try to connect to the server's TCP port to verify it's responsive

### JSON-RPC 2.0 Protocol

Commands are sent as newline-delimited JSON-RPC 2.0 requests:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tap",
  "params": {
    "text": "Login"
  }
}
```

Success response:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "success": true
  }
}
```

Error response:

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32000,
    "message": "Element not found: 'Login'"
  }
}
```

---

## Troubleshooting

### "No server registered with id 'myapp'"

**Problem**: You tried to use `--server=myapp` but that server hasn't been started yet.

**Solution**:
1. Verify the server is running: `flutter_skill server list`
2. If not listed, start it: `flutter_skill connect --id=myapp --port=50000`
3. The registry is in `~/.flutter_skill/servers/` — check for `myapp.json`

### "Could not connect to server: Connection refused"

**Problem**: The server is registered but not responding on its TCP port.

**Solution**:
1. Check if the server process is still running: `flutter_skill server status --id=myapp`
2. If the PID is no longer alive, unregister it: `flutter_skill server stop --id=myapp`
3. Check if the Flutter app itself crashed
4. Restart the server: `flutter_skill connect --id=myapp --port=50000`

### Server appears in list but shows "unreachable"

**Problem**: A server entry is in the registry but the TCP port is not responding.

**Solution**:
- This often means the server process crashed but didn't clean up its registry file
- Clean it up: `flutter_skill server stop --id=myapp`
- Or manually delete: `rm ~/.flutter_skill/servers/myapp.json`
- Restart: `flutter_skill connect --id=myapp --port=50000`

### "Found DTD URI but no VM Service URI"

**Problem**: Flutter couldn't establish the VM Service (despite DTD being available). This is rare with modern Flutter versions.

**Solution**:
1. Ensure you're on Flutter 3.x or later: `flutter --version`
2. Try explicitly setting a VM Service port: `--vm-service-port=8888`
3. Try a different port if 50000 is already in use
4. Check that the device/emulator is responding normally (try `flutter doctor`)

### Multiple servers running but `flutter_skill inspect` asks me to specify one

**Problem**: You used `flutter_skill inspect` without `--server=<id>` and there are multiple servers running.

**Solution**:
- Explicitly name the server: `flutter_skill inspect --server=myapp`
- Or set the default: `export FLUTTER_SKILL_SERVER=myapp` then `flutter_skill inspect`
- Or use the `.flutter_skill_server` file by running from the project directory

### Command hangs or times out

**Problem**: A `flutter_skill` command is waiting too long or hanging indefinitely.

**Solution**:
1. Press `Ctrl+C` to interrupt
2. Check if the Flutter app is responsive (look at the app window)
3. Check if the skill server process is running: `flutter_skill server list`
4. Try a simpler command first (e.g., `flutter_skill server list`) to verify connectivity
5. Check system resource usage (disk, memory, CPU) — the app might be thrashing

### Unix socket not being used (always TCP on macOS/Linux)

**Problem**: You expected lower latency via Unix socket but the CLI is using TCP.

**Solution**:
- This is fine; TCP is the default and reliable
- Unix socket is an optional optimization
- Verify socket was created: `ls -la ~/.flutter_skill/servers/<id>.sock`
- If it exists, the CLI will prefer it automatically; if not, TCP is used as fallback

### Permission denied when accessing `~/.flutter_skill/servers/`

**Problem**: Registry directory or files have restrictive permissions.

**Solution**:
1. Check permissions: `ls -la ~/.flutter_skill/servers/`
2. Ensure your user owns the directory: `chown -R $(whoami) ~/.flutter_skill`
3. Ensure readability: `chmod 700 ~/.flutter_skill` and `chmod 600 ~/.flutter_skill/servers/*`

### Stale servers accumulate over time

**Problem**: Registrations are building up even though the servers aren't running.

**Solution**:
- This shouldn't happen (stale entries are auto-cleaned when you list)
- But if it does, manually clean up:
  ```bash
  rm ~/.flutter_skill/servers/*.json ~/.flutter_skill/servers/*.sock 2>/dev/null
  flutter_skill server list  # Verify they're gone
  ```

---

## Best Practices

1. **Always give servers meaningful names**: Use `--id=feature-auth` instead of `--id=app1`. Makes logs and debugging much easier.

2. **Use `--detach` in CI/CD**: Non-interactive environments should detach the server so tests can run unattended.

3. **Prefer explicit `--server=<id>`**: While auto-discovery works, explicitly naming the server makes scripts more maintainable and less ambiguous.

4. **Monitor servers during development**: Use `flutter_skill server list` periodically to see what's running and clean up old servers if needed.

5. **Combine with logging**: Redirect logs to files for debugging:
   ```bash
   flutter_skill connect --id=myapp --port=50000 > server.log 2>&1 &
   ```

6. **Use `--output=json` in scripts**: When parsing output programmatically, always use `--output=json` to get structured results.

7. **Handle parallel failures gracefully**: When using `--server=a,b,c`, individual failures don't stop the entire command. Check the exit code (1 if any failed) and parse JSON results to identify which ones failed.

8. **Clean up on exit**: In CI pipelines, always use `flutter_skill server stop` in a cleanup step (or `if: always()` block) to prevent resource leaks.

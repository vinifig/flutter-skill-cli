# Flutter Skill — Tauri SDK

AI E2E testing bridge for Tauri v2 apps. JSON-RPC 2.0 over WebSocket on port 18118.

## Install

Add to `Cargo.toml`:
```toml
[dependencies]
tauri-plugin-flutter-skill = { path = "../sdks/tauri" }
```

## Usage (Rust)

```rust
fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_flutter_skill::init())
        .run(tauri::generate_context!())
        .expect("error");
}
```

## Frontend (TypeScript)

```ts
import { connect } from 'tauri-plugin-flutter-skill/guest-js';
const client = await connect();
await client.tap('#my-button');
```

## Supported Commands

`health`, `inspect`, `tap`, `enter_text`, `screenshot`, `scroll`, `get_text`, `find_element`, `wait_for_element`

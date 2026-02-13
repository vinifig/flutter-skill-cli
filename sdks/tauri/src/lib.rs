use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::net::SocketAddr;
use std::sync::Arc;
use tauri::{
    plugin::{Builder, TauriPlugin},
    Manager, Runtime, WebviewWindow,
};
use tokio::net::TcpListener;
use tokio::sync::Mutex;

const DEFAULT_PORT: u16 = 18118;
const WS_PORT: u16 = 18119;
const RESULT_PORT: u16 = 18120;
const SDK_VERSION: &str = "1.0.0";

#[derive(Deserialize)]
struct JsonRpcRequest {
    method: String,
    params: Option<Value>,
    id: Value,
}

#[derive(Serialize)]
struct JsonRpcResponse {
    jsonrpc: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<Value>,
    id: Value,
}

impl JsonRpcResponse {
    fn ok(id: Value, result: Value) -> Self {
        Self { jsonrpc: "2.0".into(), result: Some(result), error: None, id }
    }
    fn err(id: Value, msg: &str) -> Self {
        Self { jsonrpc: "2.0".into(), result: None, error: Some(json!({"code": -32000, "message": msg})), id }
    }
}

type ResultChannel = Arc<Mutex<Option<tokio::sync::oneshot::Sender<String>>>>;

fn resolve_selector(params: &Value) -> Option<String> {
    if let Some(s) = params.get("selector").and_then(|v| v.as_str()) {
        return Some(s.to_string());
    }
    if let Some(k) = params.get("key").and_then(|v| v.as_str()) {
        return Some(format!("#{k}"));
    }
    if let Some(e) = params.get("element").and_then(|v| v.as_str()) {
        return Some(e.to_string());
    }
    None
}

/// Execute JS and get result back via HTTP POST from JS to a local result endpoint.
/// 1. Eval JS that computes result
/// 2. JS does fetch('http://127.0.0.1:RESULT_PORT', {method:'POST', body: JSON})
/// 3. Rust HTTP handler on RESULT_PORT forwards result through oneshot channel
async fn eval_js_with_result<R: Runtime>(
    window: &WebviewWindow<R>,
    js: &str,
    timeout_ms: u64,
    result_tx: &ResultChannel,
) -> Result<Value, String> {
    let (tx, rx) = tokio::sync::oneshot::channel::<String>();
    {
        let mut guard = result_tx.lock().await;
        *guard = Some(tx);
    }

    let wrapped = format!(
        r#"(async function() {{
            try {{
                const __r = {js};
                const __v = (__r instanceof Promise) ? await __r : __r;
                const __d = JSON.stringify(__v);
                var ws = new WebSocket('ws://127.0.0.1:{RESULT_PORT}');
                ws.onopen = function() {{ ws.send(__d); ws.close(); }};
            }} catch(e) {{
                var ws = new WebSocket('ws://127.0.0.1:{RESULT_PORT}');
                ws.onopen = function() {{ ws.send(JSON.stringify({{error: e.message}})); ws.close(); }};
            }}
        }})()"#
    );

    window.eval(&wrapped).map_err(|e| e.to_string())?;

    match tokio::time::timeout(std::time::Duration::from_millis(timeout_ms), rx).await {
        Ok(Ok(data)) => serde_json::from_str(&data).map_err(|e| format!("JSON parse: {e}")),
        Ok(Err(_)) => Err("Channel dropped".into()),
        Err(_) => Err("JS eval timeout".into()),
    }
}

fn eval_fire<R: Runtime>(window: &WebviewWindow<R>, js: &str) -> Result<(), String> {
    window.eval(js).map_err(|e| e.to_string())
}

async fn handle_method<R: Runtime>(
    window: &WebviewWindow<R>,
    method: &str,
    params: Value,
    result_tx: &ResultChannel,
) -> Result<Value, String> {
    match method {
        "initialize" => Ok(json!({
            "success": true, "framework": "tauri",
            "sdk_version": SDK_VERSION, "platform": "tauri",
        })),

        "inspect" => {
            let js = r#"
                (function() {
                    var results = [];
                    function walk(el) {
                        if (!el || el.nodeType !== 1) return;
                        var style = window.getComputedStyle(el);
                        if (style.display === 'none' || style.visibility === 'hidden') return;
                        var tag = el.tagName.toLowerCase();
                        var isInteractive = el.matches('button, input, select, textarea, a, [role="button"], [onclick], label');
                        var hasId = !!el.id;
                        var hasText = !el.children.length && (el.textContent || '').trim().length > 0;
                        if (isInteractive || hasId || hasText) {
                            var rect = el.getBoundingClientRect();
                            var type = tag === 'button' || el.matches('[role="button"]') ? 'button'
                                : tag === 'input' && el.type === 'checkbox' ? 'checkbox'
                                : tag === 'input' ? 'text_field'
                                : tag === 'textarea' ? 'text_field'
                                : tag === 'select' ? 'dropdown'
                                : tag === 'a' ? 'link' : 'text';
                            results.push({
                                type: type, key: el.id || null, tag: tag,
                                text: (el.value || el.textContent || '').trim().slice(0, 200) || null,
                                bounds: { x: Math.round(rect.x), y: Math.round(rect.y), width: Math.round(rect.width), height: Math.round(rect.height) },
                                visible: rect.width > 0 && rect.height > 0,
                                enabled: !el.disabled,
                                clickable: el.matches('button, a, [role="button"], [onclick]'),
                            });
                        }
                        for (var i = 0; i < el.children.length; i++) walk(el.children[i]);
                    }
                    walk(document.body);
                    return { elements: results };
                })()
            "#;
            eval_js_with_result(window, js, 5000, result_tx).await
        }

        "tap" => {
            let sel = resolve_selector(&params);
            let text_match = params.get("text").and_then(|v| v.as_str());
            let js = if let Some(s) = sel {
                format!(
                    "(function() {{ var el = document.querySelector({s}); if(!el) return {{success:false,message:'Not found'}}; el.click(); return {{success:true}}; }})()",
                    s = serde_json::to_string(&s).unwrap()
                )
            } else if let Some(t) = text_match {
                format!(
                    "(function() {{ var tw=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT); while(tw.nextNode()) {{ if(tw.currentNode.textContent.includes({t})) {{ tw.currentNode.parentElement.click(); return {{success:true}}; }} }} return {{success:false,message:'Text not found'}}; }})()",
                    t = serde_json::to_string(t).unwrap()
                )
            } else {
                return Err("Missing key/selector/text".into());
            };
            eval_js_with_result(window, &js, 5000, result_tx).await
        }

        "enter_text" => {
            let sel = resolve_selector(&params).ok_or("Missing key/selector")?;
            let text = params.get("text").and_then(|v| v.as_str()).unwrap_or("");
            let js = format!(
                "(function() {{ var e=document.querySelector({s}); if(!e) return {{success:false,message:'Not found'}}; e.focus(); e.value={t}; e.dispatchEvent(new Event('input',{{bubbles:true}})); e.dispatchEvent(new Event('change',{{bubbles:true}})); return {{success:true}}; }})()",
                s = serde_json::to_string(&sel).unwrap(),
                t = serde_json::to_string(text).unwrap()
            );
            eval_js_with_result(window, &js, 5000, result_tx).await
        }

        "get_text" => {
            let sel = resolve_selector(&params).ok_or("Missing key/selector")?;
            let js = format!(
                "(function() {{ var e=document.querySelector({s}); return e ? {{text:(e.value||e.textContent||'').trim()}} : {{text:null}}; }})()",
                s = serde_json::to_string(&sel).unwrap()
            );
            eval_js_with_result(window, &js, 5000, result_tx).await
        }

        "find_element" => {
            let sel = resolve_selector(&params);
            let text_match = params.get("text").and_then(|v| v.as_str());
            let js = if let Some(s) = sel {
                format!(
                    "(function() {{ var e=document.querySelector({s}); return e ? {{found:true,element:{{tag:e.tagName.toLowerCase(),key:e.id||null,text:(e.value||e.textContent||'').trim().slice(0,200)}}}} : {{found:false}}; }})()",
                    s = serde_json::to_string(&s).unwrap()
                )
            } else if let Some(t) = text_match {
                format!(
                    "(function() {{ var tw=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT); while(tw.nextNode()) {{ if(tw.currentNode.textContent.includes({t})) {{ var p=tw.currentNode.parentElement; return {{found:true,element:{{tag:p.tagName.toLowerCase(),key:p.id||null,text:tw.currentNode.textContent.trim().slice(0,200)}}}}; }} }} return {{found:false}}; }})()",
                    t = serde_json::to_string(t).unwrap()
                )
            } else {
                return Err("Missing key/selector/text".into());
            };
            eval_js_with_result(window, &js, 5000, result_tx).await
        }

        "wait_for_element" => {
            let sel = resolve_selector(&params);
            let text_match = params.get("text").and_then(|v| v.as_str());
            let timeout = params.get("timeout").and_then(|v| v.as_u64()).unwrap_or(5000);
            let js = if let Some(s) = sel {
                format!(
                    "new Promise(function(r) {{ var t=Date.now(); function c() {{ if(document.querySelector({s})) return r({{found:true}}); if(Date.now()-t>{timeout}) return r({{found:false}}); requestAnimationFrame(c); }} c(); }})",
                    s = serde_json::to_string(&s).unwrap()
                )
            } else if let Some(t) = text_match {
                format!(
                    "new Promise(function(r) {{ var t=Date.now(); function c() {{ var tw=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT); while(tw.nextNode()) {{ if(tw.currentNode.textContent.includes({text})) return r({{found:true}}); }} if(Date.now()-t>{timeout}) return r({{found:false}}); requestAnimationFrame(c); }} c(); }})",
                    text = serde_json::to_string(t).unwrap()
                )
            } else {
                return Err("Missing key/selector/text".into());
            };
            eval_js_with_result(window, &js, timeout + 1000, result_tx).await
        }

        "scroll" | "swipe" => {
            let direction = params.get("direction").and_then(|v| v.as_str()).unwrap_or("down");
            let distance = params.get("distance").and_then(|v| v.as_i64()).unwrap_or(300);
            let (dx, dy) = match direction {
                "up" => (0, -distance), "down" => (0, distance),
                "left" => (-distance, 0), "right" => (distance, 0),
                _ => (0, distance),
            };
            eval_fire(window, &format!("(document.scrollingElement||document.body).scrollBy({dx},{dy})"))?;
            Ok(json!({"success": true}))
        }

        "screenshot" => {
            Ok(json!({"success": false, "message": "Screenshot requires html2canvas or native capture"}))
        }

        "go_back" => {
            let js = r#"
                (function() {
                    if (typeof window.__flutterSkillGoBack === 'function') { window.__flutterSkillGoBack(); return {success:true}; }
                    var btns = document.querySelectorAll('[id*="back"], [class*="back"], [aria-label*="back"], [aria-label*="Back"]');
                    for (var i = 0; i < btns.length; i++) { if (btns[i].offsetParent !== null) { btns[i].click(); return {success:true}; } }
                    window.history.back();
                    return {success:true};
                })()
            "#;
            eval_js_with_result(window, js, 3000, result_tx).await
        }

        "get_logs" => Ok(json!({"logs": []})),
        "clear_logs" => Ok(json!({"success": true})),

        _ => Err(format!("Unknown method: {method}")),
    }
}

/// WebSocket result server on RESULT_PORT.
/// JS connects here and sends a single message with the result JSON.
async fn start_result_server(result_channel: ResultChannel) {
    let addr: SocketAddr = ([127, 0, 0, 1], RESULT_PORT).into();
    let listener = match TcpListener::bind(addr).await {
        Ok(l) => l,
        Err(e) => { eprintln!("[flutter-skill] Failed to bind result port {RESULT_PORT}: {e}"); return; }
    };
    
    eprintln!("[flutter-skill] Result WS server listening on port {RESULT_PORT}");
    loop {
        if let Ok((stream, _)) = listener.accept().await {
            eprintln!("[flutter-skill] Result connection received!");
            let rc = result_channel.clone();
            tokio::spawn(async move {
                if let Ok(ws) = tokio_tungstenite::accept_async(stream).await {
                    eprintln!("[flutter-skill] Result WS handshake OK");
                    let (_, mut rx) = ws.split();
                    if let Some(Ok(msg)) = rx.next().await {
                        if msg.is_text() {
                            let data = msg.to_text().unwrap_or("").to_string();
                            eprintln!("[flutter-skill] Result data: {}...", &data[..data.len().min(100)]);
                            if !data.is_empty() {
                                let mut guard = rc.lock().await;
                                if let Some(tx) = guard.take() {
                                    let _ = tx.send(data);
                                }
                            }
                        }
                    }
                }
            });
        }
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("flutter-skill")
        .setup(|app, _| {
            let result_channel: ResultChannel = Arc::new(Mutex::new(None));
            let app_handle = app.clone();

            let rc = result_channel.clone();
            tokio::spawn(async move {
                // HTTP health check server
                let http_addr: SocketAddr = ([127, 0, 0, 1], DEFAULT_PORT).into();
                let http_listener = TcpListener::bind(http_addr).await.expect("Failed to bind health port");
                
                // WebSocket server
                let ws_addr: SocketAddr = ([127, 0, 0, 1], WS_PORT).into();
                let ws_listener = TcpListener::bind(ws_addr).await.expect("Failed to bind WS port");

                // Result HTTP server (JS posts results here)
                let rc2 = rc.clone();
                tokio::spawn(start_result_server(rc2));

                // HTTP health server
                tokio::spawn(async move {
                    loop {
                        if let Ok((mut stream, _)) = http_listener.accept().await {
                            let mut buf = vec![0u8; 4096];
                            let _ = tokio::io::AsyncReadExt::read(&mut stream, &mut buf).await;
                            let health = json!({
                                "framework": "tauri", "app_name": "tauri-app",
                                "platform": "tauri", "sdk_version": SDK_VERSION,
                                "capabilities": ["initialize","inspect","tap","enter_text","get_text",
                                    "find_element","wait_for_element","scroll","swipe","go_back","get_logs","clear_logs"]
                            });
                            let body = health.to_string();
                            let resp = format!(
                                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n{}",
                                body.len(), body
                            );
                            let _ = tokio::io::AsyncWriteExt::write_all(&mut stream, resp.as_bytes()).await;
                        }
                    }
                });

                // WebSocket server
                while let Ok((stream, _)) = ws_listener.accept().await {
                    let handle = app_handle.clone();
                    let rc3 = rc.clone();
                    tokio::spawn(async move {
                        if let Ok(ws) = tokio_tungstenite::accept_async(stream).await {
                            handle_ws(handle, ws, rc3).await;
                        }
                    });
                }
            });
            Ok(())
        })
        .build()
}

async fn handle_ws<R: Runtime>(
    handle: tauri::AppHandle<R>,
    ws: tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>,
    result_channel: ResultChannel,
) {
    let (mut tx, mut rx) = ws.split();
    while let Some(Ok(msg)) = rx.next().await {
        if !msg.is_text() { continue; }
        let text = msg.to_text().unwrap_or("");
        let req: JsonRpcRequest = match serde_json::from_str(text) {
            Ok(r) => r,
            Err(_) => continue,
        };

        let resp = if let Some(win) = handle.get_webview_window("main") {
            let params = req.params.unwrap_or(json!({}));
            match handle_method(&win, &req.method, params, &result_channel).await {
                Ok(v) => JsonRpcResponse::ok(req.id, v),
                Err(e) => JsonRpcResponse::err(req.id, &e),
            }
        } else {
            JsonRpcResponse::err(req.id, "No window")
        };

        let _ = tx.send(tungstenite::Message::Text(
            serde_json::to_string(&resp).unwrap().into()
        )).await;
    }
}

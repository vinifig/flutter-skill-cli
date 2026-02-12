use base64::Engine;
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
use tokio_tungstenite::accept_async;

const DEFAULT_PORT: u16 = 18118;

#[derive(Deserialize)]
struct JsonRpcRequest {
    jsonrpc: Option<String>,
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

async fn handle_method<R: Runtime>(
    window: &WebviewWindow<R>,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    match method {
        "health" => Ok(json!({"status": "ok", "platform": "tauri"})),

        "inspect" => {
            let js = r#"
                (function walk(el, d) {
                    if (!el || d > 15) return null;
                    const t = el.tagName ? el.tagName.toLowerCase() : '#text';
                    const ch = [];
                    for (const c of (el.children || [])) ch.push(walk(c, d+1));
                    return {tag: t, id: el.id||undefined, text: el.children.length===0?(el.textContent||'').trim().slice(0,200):undefined, children: ch};
                })(document.body, 0);
            "#;
            window.eval_js(js).await.map_err(|e| e.to_string())?;
            Ok(json!({"inspected": true}))
        }

        "tap" => {
            let sel = params.get("selector").and_then(|v| v.as_str()).ok_or("selector required")?;
            let js = format!("document.querySelector({}).click()", serde_json::to_string(sel).unwrap());
            window.eval(&js).map_err(|e| e.to_string())?;
            Ok(json!({"tapped": true}))
        }

        "enter_text" => {
            let sel = params.get("selector").and_then(|v| v.as_str()).ok_or("selector required")?;
            let text = params.get("text").and_then(|v| v.as_str()).unwrap_or("");
            let js = format!(
                "(() => {{ const e=document.querySelector({s}); e.focus(); e.value={t}; e.dispatchEvent(new Event('input',{{bubbles:true}})); }})()",
                s = serde_json::to_string(sel).unwrap(),
                t = serde_json::to_string(text).unwrap()
            );
            window.eval(&js).map_err(|e| e.to_string())?;
            Ok(json!({"entered": true}))
        }

        "screenshot" => {
            // Tauri 2 doesn't have a direct capturePage; delegate to JS canvas capture
            let js = r#"
                (async () => {
                    const c = document.createElement('canvas');
                    c.width = window.innerWidth; c.height = window.innerHeight;
                    // Use html2canvas if available, otherwise return placeholder
                    return { screenshot: 'use_html2canvas_or_native', format: 'png' };
                })()
            "#;
            window.eval(js).map_err(|e| e.to_string())?;
            Ok(json!({"screenshot": "pending", "note": "Implement via frontend html2canvas or Tauri screenshot plugin"}))
        }

        "scroll" => {
            let dx = params.get("dx").and_then(|v| v.as_i64()).unwrap_or(0);
            let dy = params.get("dy").and_then(|v| v.as_i64()).unwrap_or(0);
            window.eval(&format!("window.scrollBy({dx},{dy})")).map_err(|e| e.to_string())?;
            Ok(json!({"scrolled": true}))
        }

        "get_text" | "find_element" | "wait_for_element" => {
            let sel = params.get("selector").and_then(|v| v.as_str()).ok_or("selector required")?;
            let js = format!(
                "(() => {{ const e=document.querySelector({s}); return e ? {{found:true,text:e.textContent.trim().slice(0,200)}} : {{found:false}}; }})()",
                s = serde_json::to_string(sel).unwrap()
            );
            window.eval(&js).map_err(|e| e.to_string())?;
            Ok(json!({"delegated": true}))
        }

        _ => Err(format!("Unknown method: {method}")),
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    Builder::new("flutter-skill")
        .setup(|app, _| {
            let app_handle = app.clone();
            tokio::spawn(async move {
                let addr: SocketAddr = ([127, 0, 0, 1], DEFAULT_PORT).into();
                let listener = TcpListener::bind(addr).await.expect("Failed to bind flutter-skill port");
                log::info!("[flutter-skill] WebSocket server on port {DEFAULT_PORT}");

                while let Ok((stream, _)) = listener.accept().await {
                    let handle = app_handle.clone();
                    tokio::spawn(async move {
                        let ws = match accept_async(stream).await {
                            Ok(ws) => ws,
                            Err(_) => return,
                        };
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
                                match handle_method(&win, &req.method, params).await {
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
                    });
                }
            });
            Ok(())
        })
        .build()
}

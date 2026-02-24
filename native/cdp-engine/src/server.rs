//! HTTP + Unix Socket server for fs-cdp.

use crate::ops;
use crate::pool::ConnectionPool;
use crate::workflow::{self, Workflow};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Start the HTTP API server.
pub async fn start_http(pool: Arc<ConnectionPool>, port: u16) -> Result<(), String> {
    let listener = tokio::net::TcpListener::bind(format!("127.0.0.1:{port}"))
        .await
        .map_err(|e| format!("Bind failed: {e}"))?;

    eprintln!("🚀 fs-cdp server on http://127.0.0.1:{port}");
    eprintln!("   Endpoints:");
    eprintln!("     POST /call          — Single tool call");
    eprintln!("     POST /workflow      — Multi-step workflow");
    eprintln!("     POST /parallel      — Parallel multi-tab workflow");
    eprintln!("     GET  /tabs          — List tabs");
    eprintln!("     GET  /health        — Health check");

    loop {
        let (stream, _) = listener
            .accept()
            .await
            .map_err(|e| format!("Accept: {e}"))?;
        let pool = pool.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_http(stream, &pool).await {
                eprintln!("HTTP error: {e}");
            }
        });
    }
}

async fn handle_http(
    mut stream: tokio::net::TcpStream,
    pool: &Arc<ConnectionPool>,
) -> Result<(), String> {
    let mut buf = vec![0u8; 65536];
    let n = stream
        .read(&mut buf)
        .await
        .map_err(|e| format!("Read: {e}"))?;
    let request = String::from_utf8_lossy(&buf[..n]);

    // Parse HTTP request (minimal parser)
    let first_line = request.lines().next().unwrap_or("");
    let parts: Vec<&str> = first_line.split_whitespace().collect();
    let method = parts.first().copied().unwrap_or("GET");
    let path = parts.get(1).copied().unwrap_or("/");

    // Extract body (after \r\n\r\n)
    let body = request
        .find("\r\n\r\n")
        .map(|pos| &request[pos + 4..])
        .unwrap_or("");

    let (status, response) = match (method, path) {
        ("GET", "/health") => ("200 OK", json!({"status": "ok"}).to_string()),
        ("GET", "/tabs") => {
            let tabs = pool.discover_tabs().await.unwrap_or_default();
            ("200 OK", serde_json::to_string(&tabs).unwrap())
        }
        ("POST", "/call") => {
            let result = handle_call(pool, body).await;
            ("200 OK", result.to_string())
        }
        ("POST", "/workflow") => {
            let result = handle_workflow(pool, body).await;
            ("200 OK", serde_json::to_string(&result).unwrap())
        }
        ("POST", "/parallel") => {
            let result = handle_parallel(pool, body).await;
            ("200 OK", serde_json::to_string(&result).unwrap())
        }
        _ => ("404 Not Found", json!({"error": "Not found"}).to_string()),
    };

    let http_response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        response.len(),
        response
    );

    stream
        .write_all(http_response.as_bytes())
        .await
        .map_err(|e| format!("Write: {e}"))?;
    Ok(())
}

async fn handle_call(pool: &Arc<ConnectionPool>, body: &str) -> Value {
    let req: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return json!({"error": format!("Bad JSON: {e}")}),
    };

    let name = req["name"].as_str().unwrap_or("");
    let args = req.get("arguments").cloned().unwrap_or(json!({}));
    let tab_id = req["tab"].as_str().unwrap_or("");

    // Resolve tab connection
    let conn = if tab_id.is_empty() {
        // Use first connected tab or first available
        match get_default_tab(pool).await {
            Ok(c) => c,
            Err(e) => return json!({"error": e}),
        }
    } else {
        match pool.get_or_connect(tab_id).await {
            Ok(c) => c,
            Err(e) => return json!({"error": e}),
        }
    };

    let start = std::time::Instant::now();

    let result = match name {
        "navigate" => {
            let url = args["url"].as_str().unwrap_or("");
            ops::navigate(&conn, url).await
        }
        "evaluate" => {
            let expr = args["expression"].as_str().unwrap_or("");
            ops::evaluate(&conn, expr).await.map(|v| json!({"result": v}))
        }
        "screenshot" => {
            let q = args["quality"].as_u64().unwrap_or(80) as u8;
            let clip = if args.get("clip").is_some() {
                Some((
                    args["clip"]["x"].as_f64().unwrap_or(0.0),
                    args["clip"]["y"].as_f64().unwrap_or(0.0),
                    args["clip"]["width"].as_f64().unwrap_or(800.0),
                    args["clip"]["height"].as_f64().unwrap_or(600.0),
                ))
            } else {
                None
            };
            ops::screenshot(&conn, q, clip).await.map(|b| json!({"base64": b}))
        }
        "snapshot" => ops::snapshot(&conn)
            .await
            .map(|s| json!({"snapshot": s})),
        "tap" => {
            if let Some(text) = args["text"].as_str() {
                ops::tap_text(&conn, text).await
            } else {
                let x = args["x"].as_f64().unwrap_or(0.0);
                let y = args["y"].as_f64().unwrap_or(0.0);
                ops::tap(&conn, x, y).await
            }
        }
        "upload_file" => {
            let sel = args["selector"].as_str().unwrap_or("auto");
            let file = args["file"]
                .as_str()
                .or_else(|| args["files"].as_array().and_then(|a| a[0].as_str()))
                .unwrap_or("");
            let trigger = args["trigger"].as_str();
            ops::upload_file_ext(&conn, sel, &PathBuf::from(file), trigger).await
        }
        "get_title" => ops::get_title(&conn)
            .await
            .map(|t| json!({"title": t})),
        "press_key" => {
            let key = args["key"].as_str().unwrap_or("");
            ops::press_key(&conn, key).await
        }
        "scroll_to" => {
            let text = args["text"].as_str().unwrap_or("");
            ops::scroll_to(&conn, text).await
        }
        "cdp" => {
            // Raw CDP call: {"name":"cdp","arguments":{"method":"DOM.getDocument","params":{}}}
            let method = args["method"].as_str().unwrap_or("");
            let params = args.get("params").cloned().unwrap_or(json!({}));
            conn.call(method, params).await
        }
        _ => Err(format!("Unknown tool: {name}")),
    };

    let duration_ms = start.elapsed().as_millis();

    match result {
        Ok(mut v) => {
            if let Value::Object(ref mut map) = v {
                map.insert("duration_ms".into(), json!(duration_ms));
            }
            v
        }
        Err(e) => json!({"error": e, "duration_ms": duration_ms}),
    }
}

async fn handle_workflow(pool: &Arc<ConnectionPool>, body: &str) -> Value {
    #[derive(serde::Deserialize)]
    struct Req {
        tab: Option<String>,
        #[serde(default)]
        url: Option<String>,
        #[serde(flatten)]
        workflow: Workflow,
    }

    let req: Req = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return json!({"error": format!("Bad JSON: {e}")}),
    };

    // Resolve tab
    let tab_id = if let Some(ref id) = req.tab {
        id.clone()
    } else if let Some(ref url) = req.url {
        match pool.get_by_url(url).await {
            Ok((id, _)) => id,
            Err(e) => return json!({"error": e}),
        }
    } else {
        match get_default_tab_id(pool).await {
            Ok(id) => id,
            Err(e) => return json!({"error": e}),
        }
    };

    let result = workflow::execute(pool, &tab_id, req.workflow).await;
    serde_json::to_value(result).unwrap_or(json!({"error": "serialize failed"}))
}

async fn handle_parallel(pool: &Arc<ConnectionPool>, body: &str) -> Value {
    #[derive(serde::Deserialize)]
    struct Task {
        tab: Option<String>,
        url: Option<String>,
        #[serde(flatten)]
        workflow: Workflow,
    }

    #[derive(serde::Deserialize)]
    struct Req {
        tasks: Vec<Task>,
    }

    let req: Req = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return json!({"error": format!("Bad JSON: {e}")}),
    };

    let mut resolved_tasks = Vec::new();
    for task in req.tasks {
        let tab_id = if let Some(id) = task.tab {
            id
        } else if let Some(ref url) = task.url {
            match pool.get_by_url(url).await {
                Ok((id, _)) => id,
                Err(_) => continue,
            }
        } else {
            continue;
        };
        resolved_tasks.push((tab_id, task.workflow));
    }

    let results = workflow::execute_parallel(pool, resolved_tasks).await;
    let out: Vec<Value> = results
        .into_iter()
        .map(|(tab, r)| {
            json!({
                "tab": tab,
                "result": serde_json::to_value(r).unwrap_or(json!(null)),
            })
        })
        .collect();

    json!({"results": out})
}

async fn get_default_tab(
    pool: &Arc<ConnectionPool>,
) -> Result<Arc<crate::cdp::CdpConnection>, String> {
    let tabs = pool.discover_tabs().await?;
    let tab = tabs.first().ok_or("No tabs available")?;
    pool.get_or_connect(&tab.id).await
}

async fn get_default_tab_id(pool: &Arc<ConnectionPool>) -> Result<String, String> {
    let tabs = pool.discover_tabs().await?;
    tabs.first()
        .map(|t| t.id.clone())
        .ok_or_else(|| "No tabs available".into())
}

//! High-level browser operations built on CDP.
//! Each operation minimizes CDP round-trips by pushing logic into the browser.

use crate::cdp::CdpConnection;
use base64::Engine;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

/// Navigate to a URL. Returns the final URL.
pub async fn navigate(conn: &Arc<CdpConnection>, url: &str) -> Result<Value, String> {
    // Check current URL — skip if already there. Use timeout to detect dead connections.
    let check = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        conn.call("Runtime.evaluate", json!({"expression": "location.href", "returnByValue": true})),
    ).await;
    
    if let Ok(Ok(current)) = check {
        let current_url = current["value"].as_str().unwrap_or("");
        if current_url == url {
            return Ok(json!({"navigated": false, "url": url, "reason": "already_there"}));
        }
    }
    // If check timed out, connection may be dead — proceed anyway, server will reconnect

    let nav = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        conn.call("Page.navigate", json!({"url": url})),
    ).await;

    if let Err(_) = nav {
        // Navigate call itself timed out — connection is dead
        return Ok(json!({"navigated": true, "url": url, "reconnect_needed": true}));
    }
    nav.unwrap()?;

    // Brief wait for navigation to start
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    Ok(json!({"navigated": true, "url": url}))
}

/// Evaluate JS expression. Returns the result value.
pub async fn evaluate(conn: &Arc<CdpConnection>, expression: &str) -> Result<Value, String> {
    let result = conn
        .call(
            "Runtime.evaluate",
            json!({
                "expression": expression,
                "returnByValue": true,
                "awaitPromise": true,
            }),
        )
        .await?;

    if let Some(exc) = result.get("exceptionDetails") {
        return Err(format!("JS exception: {exc}"));
    }

    Ok(result
        .get("result")
        .and_then(|r| r.get("value"))
        .cloned()
        .unwrap_or(Value::Null))
}

/// Take a screenshot. Returns base64 JPEG data.
pub async fn screenshot(
    conn: &Arc<CdpConnection>,
    quality: u8,
    clip: Option<(f64, f64, f64, f64)>,
) -> Result<String, String> {
    let mut params = json!({
        "format": "jpeg",
        "quality": quality,
        "optimizeForSpeed": true,
        "captureBeyondViewport": false,
        "fromSurface": true,
    });
    // Use caller-specified clip, or default 800x600 (best speed/info balance)
    let (x, y, w, h) = clip.unwrap_or((0.0, 0.0, 800.0, 600.0));
    params["clip"] = json!({"x": x, "y": y, "width": w, "height": h, "scale": 1});

    let result = conn.call("Page.captureScreenshot", params).await?;

    result["data"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "No screenshot data".into())
}

/// Get page text snapshot — optimized JS DOM walk with depth limit.
pub async fn snapshot(conn: &Arc<CdpConnection>) -> Result<String, String> {
    // Single optimized evaluate — walks visible DOM with depth limit for speed.
    // Skips hidden elements, extracts interactive elements with type annotations.
    let js = r#"(() => {
        const l = [], MAX = 500;
        let c = 0;
        const w = (n, d) => {
            if (c >= MAX || d > 30) return;
            if (n.nodeType === 3) { const t = n.textContent.trim(); if (t && t.length < 500) { l.push(t); c++; } return; }
            if (n.nodeType !== 1) return;
            const el = n, t = el.tagName;
            if (t === 'SCRIPT' || t === 'STYLE' || t === 'NOSCRIPT' || t === 'SVG') return;
            if (el.offsetWidth === 0 && el.offsetHeight === 0 && t !== 'INPUT') return;
            if (t === 'INPUT' || t === 'SELECT' || t === 'TEXTAREA') { l.push(`[${el.type||t.toLowerCase()}] ${el.value||el.placeholder||''}`); c++; return; }
            if (t === 'A' && el.textContent.trim()) { l.push(`[link] ${el.textContent.trim().substring(0,80)}`); c++; return; }
            if (t === 'BUTTON') { l.push(`[button] ${el.textContent.trim().substring(0,60)}`); c++; return; }
            if (t === 'IMG') { l.push(`[img] ${el.alt||''}`); c++; return; }
            if (t === 'H1'||t === 'H2'||t === 'H3'||t === 'H4') { l.push(`[heading] ${el.textContent.trim().substring(0,100)}`); c++; return; }
            for (const ch of el.childNodes) w(ch, d+1);
        };
        w(document.body, 0);
        return l.join('\n');
    })()"#;
    evaluate(conn, js).await.map(|v| v.as_str().unwrap_or("").to_string())
}

/// Tap/click at coordinates.
pub async fn tap(conn: &Arc<CdpConnection>, x: f64, y: f64) -> Result<Value, String> {
    // Pipeline: mousePressed + mouseReleased (skip mouseMoved for speed)
    let results = conn
        .pipeline(vec![
            (
                "Input.dispatchMouseEvent",
                json!({"type": "mousePressed", "x": x, "y": y, "button": "left", "clickCount": 1}),
            ),
            (
                "Input.dispatchMouseEvent",
                json!({"type": "mouseReleased", "x": x, "y": y, "button": "left", "clickCount": 1}),
            ),
        ])
        .await;

    for r in &results {
        if let Err(e) = r {
            return Err(e.clone());
        }
    }

    Ok(json!({"success": true, "x": x, "y": y}))
}

/// Tap an element by text content. Finds element, gets coordinates, clicks.
/// Prioritizes: buttons/links > shortest match > visible elements.
/// Done in 2 CDP calls: 1 evaluate (find + coords) + 1 pipeline (mouse events).
pub async fn tap_text(conn: &Arc<CdpConnection>, text: &str) -> Result<Value, String> {
    let escaped = text.replace('\\', "\\\\").replace('\'', "\\'");
    let js = format!(
        r#"
        (() => {{
            const text = '{escaped}';
            // Strategy 1: Find button/link/submit with matching text (most reliable)
            const clickables = document.querySelectorAll('button, a, [role=button], input[type=submit]');
            for (const el of clickables) {{
                const t = el.textContent.trim();
                if (t === text || t.includes(text)) {{
                    const r = el.getBoundingClientRect();
                    if (r.width > 0 && r.height > 0 && r.y >= 0 && r.y < window.innerHeight) {{
                        return {{x: r.x + r.width/2, y: r.y + r.height/2, tag: el.tagName, matched: 'clickable'}};
                    }}
                }}
            }}
            // Strategy 2: TreeWalker — find shortest text match
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            let best = null;
            let bestLen = Infinity;
            while (walker.nextNode()) {{
                const n = walker.currentNode;
                const t = n.textContent.trim();
                if (t.includes(text) && t.length < bestLen) {{
                    const el = n.parentElement;
                    const r = el.getBoundingClientRect();
                    if (r.width > 0 && r.height > 0) {{
                        best = el;
                        bestLen = t.length;
                    }}
                }}
            }}
            if (!best) return null;
            const r = best.getBoundingClientRect();
            return {{x: r.x + r.width/2, y: r.y + r.height/2, tag: best.tagName, matched: 'text'}};
        }})()
    "#
    );

    let coords = evaluate(conn, &js).await?;
    if coords.is_null() {
        return Err(format!("Element with text '{text}' not found or not visible"));
    }

    let x = coords["x"].as_f64().ok_or("No x coordinate")?;
    let y = coords["y"].as_f64().ok_or("No y coordinate")?;
    tap(conn, x, y).await
}

/// Upload a file — extreme performance edition.
///
/// Fast path (1-2 CDP calls, <10ms): Direct setFileInputFiles + events in single evaluate.
/// Trigger path: Click trigger element → file chooser interception → setFileInputFiles.
///
/// `selector`: CSS selector for `<input type=file>` (or "auto" to discover)
/// `trigger`: optional element to click to open file dialog (for sites without file inputs)
pub async fn upload_file(
    conn: &Arc<CdpConnection>,
    selector: &str,
    file_path: &Path,
) -> Result<Value, String> {
    upload_file_ext(conn, selector, file_path, None).await
}

pub async fn upload_file_ext(
    conn: &Arc<CdpConnection>,
    selector: &str,
    file_path: &Path,
    trigger: Option<&str>,
) -> Result<Value, String> {
    let path_str = file_path.to_str().ok_or("Invalid file path")?;
    let start = std::time::Instant::now();

    // If trigger specified, go straight to file chooser interception path
    if let Some(trig) = trigger {
        return upload_via_trigger(conn, trig, selector, path_str, start).await;
    }

    // ── Fast path: resolve element → setFileInputFiles → verify+events (2-3 CDP calls) ──
    let sel = if selector.is_empty() || selector == "auto" { "input[type=file]" } else { selector };
    let escaped = sel.replace('\\', "\\\\").replace('\'', "\\'");

    // Step 1: Find element and get objectId (single call)
    let obj = conn.call("Runtime.evaluate", json!({
        "expression": format!(
            "(() => {{ \
                function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; \
                    for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }} \
                return dq('{escaped}', document); \
            }})()"
        ),
        "returnByValue": false,
    })).await;

    // Auto-discover fallback if selector didn't match
    let obj = if obj.as_ref().map(|o| o["result"]["objectId"].is_null()).unwrap_or(true)
        && (selector.is_empty() || selector == "auto")
    {
        // Try shadow DOM scan
        conn.call("Runtime.evaluate", json!({
            "expression": "(() => { \
                function scan(root) { for(const n of root.querySelectorAll('*')) { \
                    if(n.shadowRoot) { const f=n.shadowRoot.querySelector('input[type=file]'); if(f) return f; const r=scan(n.shadowRoot); if(r) return r; } \
                } return null; } return scan(document); })()",
            "returnByValue": false,
        })).await
    } else {
        obj
    };

    let obj = obj.map_err(|e| format!("find element: {e}"))?;
    let object_id = obj["result"]["objectId"].as_str()
        .ok_or("No file input found")?;

    // Step 2: describeNode → setFileInputFiles (pipeline both)
    let node = conn.call("DOM.describeNode", json!({"objectId": object_id})).await
        .map_err(|e| format!("describeNode: {e}"))?;
    let bid = node["node"]["backendNodeId"].as_u64().ok_or("No backendNodeId")?;

    conn.call("DOM.setFileInputFiles", json!({"backendNodeId": bid, "files": [path_str]})).await
        .map_err(|e| format!("setFileInputFiles: {e}"))?;

    // Step 3: Verify + dispatch events (single evaluate combining both)
    let result = evaluate(conn, &format!(
        r#"(() => {{
            function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }}
            const el = dq('{escaped}', document);
            if (!el) return {{error:'not_found'}};
            const count = el.files ? el.files.length : 0;
            if (count > 0) {{
                el.dispatchEvent(new Event('input', {{bubbles:true}}));
                el.dispatchEvent(new Event('change', {{bubbles:true}}));
                const rp = Object.keys(el).find(k => k.startsWith('__reactProps'));
                if (rp && el[rp] && typeof el[rp].onChange === 'function')
                    try {{ el[rp].onChange({{target:el, currentTarget:el, type:'change'}}); }} catch(e) {{}}
                if (el.__vue_) try {{ el.__vue__.$emit('change', el.files); }} catch(e) {{}}
            }}
            return {{files:count, name:el.files && el.files[0] ? el.files[0].name : null}};
        }})()"#
    )).await.unwrap_or(json!({"files":0}));

    let count = result["files"].as_u64().unwrap_or(0);
    if count == 0 {
        // setFileInputFiles didn't stick — try file chooser interception as fallback
        return upload_via_chooser(conn, &escaped, path_str, start).await;
    }

    Ok(json!({
        "success": true, "method": "direct", "files": count,
        "path": path_str, "duration_ms": start.elapsed().as_millis() as u64,
    }))
}

/// Upload via clicking a trigger element → file chooser interception.
async fn upload_via_trigger(
    conn: &Arc<CdpConnection>,
    trigger: &str,
    selector: &str,
    path_str: &str,
    start: std::time::Instant,
) -> Result<Value, String> {
    let escaped_trig = trigger.replace('\\', "\\\\").replace('\'', "\\'");

    let _ = conn.call("Page.setInterceptFileChooserDialog", json!({"enabled": true})).await;
    let mut rx = conn.on_event("Page.fileChooserOpened");

    let _ = evaluate(conn, &format!(
        "(() => {{ const el = document.querySelector('{escaped_trig}'); if(el) {{ el.click(); return 'ok'; }} return 'miss'; }})()"
    )).await;

    let event = tokio::select! {
        Some(e) = rx.recv() => Some(e),
        _ = tokio::time::sleep(std::time::Duration::from_millis(500)) => None,
    };
    conn.remove_listeners("Page.fileChooserOpened");
    let _ = conn.call("Page.setInterceptFileChooserDialog", json!({"enabled": false})).await;

    if let Some(evt) = event {
        if let Some(bid) = evt.get("backendNodeId").and_then(|v| v.as_u64()) {
            let _ = conn.call("DOM.setFileInputFiles", json!({"backendNodeId": bid, "files": [path_str]})).await;
        }
        return Ok(json!({
            "success": true, "method": "trigger",
            "path": path_str, "duration_ms": start.elapsed().as_millis() as u64,
        }));
    }
    Err("Trigger click did not open file chooser".into())
}

/// Upload via file chooser interception (unhide input → JS click → intercept).
async fn upload_via_chooser(
    conn: &Arc<CdpConnection>,
    escaped_sel: &str,
    path_str: &str,
    start: std::time::Instant,
) -> Result<Value, String> {
    let _ = conn.call("Page.setInterceptFileChooserDialog", json!({"enabled": true})).await;
    let mut rx = conn.on_event("Page.fileChooserOpened");

    // Unhide + click
    let _ = evaluate(conn, &format!(
        r#"(() => {{
            function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }}
            const el = dq('{escaped_sel}', document);
            if (!el) return 'miss';
            const cs = getComputedStyle(el);
            if (cs.display === 'none' || cs.visibility === 'hidden' || el.offsetWidth === 0) {{
                el.dataset.fsOrig = el.getAttribute('style') || '';
                el.style.cssText = 'display:block !important;visibility:visible !important;position:fixed !important;top:-9999px !important;left:-9999px !important;width:1px !important;height:1px !important;opacity:0.01 !important;';
            }}
            el.click();
            return 'ok';
        }})()"#
    )).await;

    let event = tokio::select! {
        Some(e) = rx.recv() => Some(e),
        _ = tokio::time::sleep(std::time::Duration::from_millis(200)) => None,
    };
    conn.remove_listeners("Page.fileChooserOpened");

    // Restore style
    let _ = evaluate(conn, &format!(
        r#"(() => {{
            function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }}
            const el = dq('{escaped_sel}', document);
            if (el && el.dataset.fsOrig !== undefined) {{ el.setAttribute('style', el.dataset.fsOrig); delete el.dataset.fsOrig; }}
        }})()"#
    )).await;

    let _ = conn.call("Page.setInterceptFileChooserDialog", json!({"enabled": false})).await;

    if let Some(evt) = event {
        if let Some(bid) = evt.get("backendNodeId").and_then(|v| v.as_u64()) {
            let _ = conn.call("DOM.setFileInputFiles", json!({"backendNodeId": bid, "files": [path_str]})).await;
        }
        return Ok(json!({
            "success": true, "method": "fileChooser",
            "path": path_str, "duration_ms": start.elapsed().as_millis() as u64,
        }));
    }

    Err("File chooser interception failed".into())
}

/// Get the page title.
pub async fn get_title(conn: &Arc<CdpConnection>) -> Result<String, String> {
    evaluate(conn, "document.title")
        .await
        .map(|v| v.as_str().unwrap_or("").to_string())
}

/// Press a key.
pub async fn press_key(conn: &Arc<CdpConnection>, key: &str) -> Result<Value, String> {
    let results = conn
        .pipeline(vec![
            (
                "Input.dispatchKeyEvent",
                json!({"type": "keyDown", "key": key}),
            ),
            (
                "Input.dispatchKeyEvent",
                json!({"type": "keyUp", "key": key}),
            ),
        ])
        .await;

    for r in &results {
        if let Err(e) = r {
            return Err(e.clone());
        }
    }
    Ok(json!({"success": true, "key": key}))
}

/// Scroll to an element by text.
pub async fn scroll_to(conn: &Arc<CdpConnection>, text: &str) -> Result<Value, String> {
    let escaped = text.replace('\\', "\\\\").replace('\'', "\\'");
    evaluate(
        conn,
        &format!(
            r#"
        (() => {{
            const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
            while (walker.nextNode()) {{
                if (walker.currentNode.textContent.includes('{escaped}')) {{
                    walker.currentNode.parentElement.scrollIntoView({{behavior:'smooth',block:'center'}});
                    return true;
                }}
            }}
            return false;
        }})()
    "#
        ),
    )
    .await
    .map(|v| json!({"scrolled": v}))
}

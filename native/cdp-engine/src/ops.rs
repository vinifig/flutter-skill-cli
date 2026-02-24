//! High-level browser operations built on CDP.
//! Each operation minimizes CDP round-trips by pushing logic into the browser.

use crate::cdp::CdpConnection;
use base64::Engine;
use serde_json::{json, Value};
use std::path::Path;
use std::sync::Arc;

/// Navigate to a URL. Returns the final URL.
pub async fn navigate(conn: &Arc<CdpConnection>, url: &str) -> Result<Value, String> {
    // Check current URL first — skip if already there
    let current = conn
        .call(
            "Runtime.evaluate",
            json!({"expression": "location.href", "returnByValue": true}),
        )
        .await?;
    let current_url = current["value"].as_str().unwrap_or("");
    if current_url == url {
        return Ok(json!({"navigated": false, "url": url, "reason": "already_there"}));
    }

    conn.call("Page.navigate", json!({"url": url})).await?;

    // Wait for load
    let mut rx = conn.on_event("Page.loadEventFired");
    tokio::select! {
        _ = rx.recv() => {},
        _ = tokio::time::sleep(std::time::Duration::from_secs(10)) => {},
    }
    conn.remove_listeners("Page.loadEventFired");

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
pub async fn screenshot(conn: &Arc<CdpConnection>, quality: u8) -> Result<String, String> {
    let result = conn
        .call(
            "Page.captureScreenshot",
            json!({
                "format": "jpeg",
                "quality": quality,
                "optimizeForSpeed": true,
            }),
        )
        .await?;

    result["data"]
        .as_str()
        .map(|s| s.to_string())
        .ok_or_else(|| "No screenshot data".into())
}

/// Get page text snapshot (accessibility-like).
pub async fn snapshot(conn: &Arc<CdpConnection>) -> Result<String, String> {
    let js = r#"
        (() => {
            const lines = [];
            const walk = (node, depth) => {
                if (node.nodeType === 3) {
                    const t = node.textContent.trim();
                    if (t) lines.push(t);
                    return;
                }
                if (node.nodeType !== 1) return;
                const el = node;
                const tag = el.tagName.toLowerCase();
                const style = getComputedStyle(el);
                if (style.display === 'none' || style.visibility === 'hidden') return;
                
                if (tag === 'input' || tag === 'select' || tag === 'textarea') {
                    const type = el.type || tag;
                    const val = el.value || el.placeholder || '';
                    lines.push(`[${type}] ${val}`);
                    return;
                }
                if (tag === 'a') lines.push('[link] ');
                if (tag === 'button') lines.push('[button] ');
                if (tag === 'img') { lines.push(`[img] ${el.alt || ''}`); return; }
                
                for (const child of el.childNodes) walk(child, depth + 1);
            };
            walk(document.body, 0);
            return lines.join('\n');
        })()
    "#;
    evaluate(conn, js).await.map(|v| v.as_str().unwrap_or("").to_string())
}

/// Tap/click at coordinates.
pub async fn tap(conn: &Arc<CdpConnection>, x: f64, y: f64) -> Result<Value, String> {
    // Pipeline: mouseMoved + mousePressed + mouseReleased
    let results = conn
        .pipeline(vec![
            (
                "Input.dispatchMouseEvent",
                json!({"type": "mouseMoved", "x": x, "y": y}),
            ),
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

/// Upload a file to a file input — universal, optimized for <500ms.
///
/// `selector`: CSS selector for `<input type=file>` (auto-discovers if empty/`auto`)
/// `file_path`: local file path
/// `trigger`: optional CSS selector for button/element that opens file dialog
///            (for sites without standard file inputs, e.g. Medium, Reddit)
///
/// Flow:
///   1. Enable Page.setInterceptFileChooserDialog
///   2. Find and click the file input (unhide if hidden) or trigger element
///   3. Intercept the file chooser → DOM.setFileInputFiles
///   4. Dispatch framework events (React/Vue/Angular/native)
///   5. Restore original styles, disable interception
///
/// If file chooser fails (300ms timeout), falls back to direct setFileInputFiles + events.
pub async fn upload_file(
    conn: &Arc<CdpConnection>,
    selector: &str,
    file_path: &Path,
) -> Result<Value, String> {
    upload_file_ext(conn, selector, file_path, None).await
}

/// Extended upload with optional trigger element.
pub async fn upload_file_ext(
    conn: &Arc<CdpConnection>,
    selector: &str,
    file_path: &Path,
    trigger: Option<&str>,
) -> Result<Value, String> {
    let path_str = file_path.to_str().ok_or("Invalid file path")?;
    let start = std::time::Instant::now();

    // Auto-discover file input if selector is empty or "auto"
    let sel = if selector.is_empty() || selector == "auto" {
        let found = evaluate(conn,
            "(() => { \
                const el = document.querySelector('input[type=file]'); \
                if (el) { return el.id ? '#' + el.id : (el.name ? 'input[name=\"' + el.name + '\"]' : 'input[type=file]'); } \
                function scan(root) { \
                    for (const n of root.querySelectorAll('*')) { \
                        if (n.shadowRoot) { \
                            const f = n.shadowRoot.querySelector('input[type=file]'); \
                            if (f) return 'input[type=file]'; \
                            const r = scan(n.shadowRoot); if (r) return r; \
                        } \
                    } return null; \
                } \
                return scan(document) || ''; \
            })()"
        ).await.unwrap_or(json!(""));
        sel_from_value(&found)
    } else {
        selector.to_string()
    };

    if sel.is_empty() && trigger.is_none() {
        return Err("No file input found and no trigger specified".into());
    }

    let escaped_sel = sel.replace('\\', "\\\\").replace('\'', "\\'");

    // ── Enable file chooser interception ──
    let _ = conn.call("Page.setInterceptFileChooserDialog", json!({"enabled": true})).await;
    let mut rx = conn.on_event("Page.fileChooserOpened");

    // ── Click to trigger file dialog ──
    if let Some(trig) = trigger {
        // Use trigger element (button, link, avatar area, etc.)
        let escaped_trig = trig.replace('\\', "\\\\").replace('\'', "\\'");
        let _ = evaluate(conn, &format!(
            r#"(() => {{
                const el = document.querySelector('{escaped_trig}');
                if (el) {{ el.click(); return 'clicked'; }}
                return 'not_found';
            }})()"#
        )).await;
    } else {
        // Unhide file input and JS click it
        let _ = evaluate(conn, &format!(
            r#"(() => {{
                function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }}
                const el = dq('{escaped_sel}', document);
                if (!el) return 'not_found';
                const cs = getComputedStyle(el);
                if (cs.display === 'none' || cs.visibility === 'hidden' || el.offsetWidth === 0) {{
                    el.dataset.fsOrig = el.getAttribute('style') || '';
                    el.style.cssText = 'display:block !important; visibility:visible !important; position:fixed !important; top:-9999px !important; left:-9999px !important; width:1px !important; height:1px !important; opacity:0.01 !important;';
                }}
                el.click();
                return 'clicked';
            }})()"#
        )).await;
    }

    // ── Wait for file chooser (100ms fast timeout — chooser fires instantly if it works) ──
    let event = tokio::select! {
        Some(e) = rx.recv() => Some(e),
        _ = tokio::time::sleep(std::time::Duration::from_millis(100)) => None,
    };

    conn.remove_listeners("Page.fileChooserOpened");

    // ── Restore original styles ──
    if !sel.is_empty() {
        let _ = evaluate(conn, &format!(
            r#"(() => {{
                function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }}
                const el = dq('{escaped_sel}', document);
                if (el && el.dataset.fsOrig !== undefined) {{
                    el.setAttribute('style', el.dataset.fsOrig);
                    delete el.dataset.fsOrig;
                }}
            }})()"#
        )).await;
    }

    if let Some(evt) = event {
        // ── File chooser triggered — set files via backendNodeId ──
        if let Some(bid) = evt.get("backendNodeId").and_then(|v| v.as_u64()) {
            let _ = conn.call("DOM.setFileInputFiles", json!({"backendNodeId": bid, "files": [path_str]})).await;
        } else if !sel.is_empty() {
            let _ = set_files_by_selector(conn, &escaped_sel, path_str).await;
        }
        let _ = conn.call("Page.setInterceptFileChooserDialog", json!({"enabled": false})).await;
        dispatch_file_events(conn, &escaped_sel).await;
        return Ok(json!({
            "success": true, "method": "fileChooser",
            "path": path_str, "duration_ms": start.elapsed().as_millis() as u64,
        }));
    }

    // ── File chooser not triggered — fallback to direct setFileInputFiles ──
    let _ = conn.call("Page.setInterceptFileChooserDialog", json!({"enabled": false})).await;

    if sel.is_empty() {
        return Err("No file input selector for direct fallback".into());
    }

    // Set files via CDP
    set_files_by_selector(conn, &escaped_sel, path_str).await?;

    // Verify
    let verify = evaluate(conn, &format!(
        r#"(() => {{
            function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }}
            const el = dq('{escaped_sel}', document);
            return el && el.files ? el.files.length : 0;
        }})()"#
    )).await.unwrap_or(json!(0));

    let count = verify.as_u64().unwrap_or(0);
    if count == 0 {
        return Err("setFileInputFiles failed: files.length = 0".into());
    }

    dispatch_file_events(conn, &escaped_sel).await;

    Ok(json!({
        "success": true, "method": "direct", "files": count,
        "path": path_str, "duration_ms": start.elapsed().as_millis() as u64,
    }))
}

fn sel_from_value(v: &Value) -> String {
    v.as_str().unwrap_or("").to_string()
}

/// Set files on a file input by selector (tries Runtime.evaluate → DOM.describeNode → setFileInputFiles).
async fn set_files_by_selector(conn: &Arc<CdpConnection>, escaped_sel: &str, path_str: &str) -> Result<(), String> {
    let obj = conn.call("Runtime.evaluate", json!({
        "expression": format!(
            "(() => {{ function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }} return dq('{escaped_sel}', document); }})()"
        ),
        "returnByValue": false,
    })).await.map_err(|e| format!("evaluate: {e}"))?;

    let object_id = obj["result"]["objectId"].as_str().ok_or("No objectId")?;
    let node = conn.call("DOM.describeNode", json!({"objectId": object_id})).await
        .map_err(|e| format!("describeNode: {e}"))?;
    let bid = node["node"]["backendNodeId"].as_u64().ok_or("No backendNodeId")?;
    conn.call("DOM.setFileInputFiles", json!({"backendNodeId": bid, "files": [path_str]})).await
        .map_err(|e| format!("setFileInputFiles: {e}"))?;
    Ok(())
}

/// Dispatch framework-aware events after file upload.
async fn dispatch_file_events(conn: &Arc<CdpConnection>, escaped_sel: &str) {
    let _ = evaluate(conn, &format!(
        r#"(() => {{
            function dq(s,r) {{ let e=r.querySelector(s); if(e) return e; for(const n of r.querySelectorAll('*')) {{ if(n.shadowRoot) {{ e=dq(s,n.shadowRoot); if(e) return e; }} }} return null; }}
            const el = dq('{escaped_sel}', document);
            if (!el) return;
            el.dispatchEvent(new Event('input', {{bubbles:true}}));
            el.dispatchEvent(new Event('change', {{bubbles:true}}));
            const rp = Object.keys(el).find(k => k.startsWith('__reactProps'));
            if (rp && el[rp] && typeof el[rp].onChange === 'function')
                try {{ el[rp].onChange({{target:el, currentTarget:el, type:'change'}}); }} catch(e) {{}}
            if (el.__vue_) try {{ el.__vue__.$emit('change', el.files); }} catch(e) {{}}
        }})()"#
    )).await;
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

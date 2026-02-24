//! CDP WebSocket connection with command pipelining.

use dashmap::DashMap;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::sync::{oneshot, Mutex};
use tokio_tungstenite::{connect_async, tungstenite::Message};

/// A single CDP WebSocket connection (one per tab).
pub struct CdpConnection {
    tx: Mutex<futures_util::stream::SplitSink<
        tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>,
        Message,
    >>,
    pending: DashMap<u64, oneshot::Sender<Value>>,
    next_id: AtomicU64,
    /// Event listeners: method -> list of senders
    event_listeners: DashMap<String, Vec<tokio::sync::mpsc::UnboundedSender<Value>>>,
}

impl CdpConnection {
    /// Connect to a CDP WebSocket URL.
    pub async fn connect(ws_url: &str) -> Result<Arc<Self>, String> {
        // Build request with Origin header to pass Chrome's CORS check
        let request = tokio_tungstenite::tungstenite::http::Request::builder()
            .uri(ws_url)
            .header("Origin", "http://127.0.0.1")
            .header("Host", "127.0.0.1")
            .header("Connection", "Upgrade")
            .header("Upgrade", "websocket")
            .header("Sec-WebSocket-Version", "13")
            .header("Sec-WebSocket-Key", tokio_tungstenite::tungstenite::handshake::client::generate_key())
            .body(())
            .map_err(|e| format!("Request build failed: {e}"))?;

        let (ws, _) = connect_async(request)
            .await
            .map_err(|e| format!("WebSocket connect failed: {e}"))?;

        let (sink, stream) = ws.split();

        let conn = Arc::new(Self {
            tx: Mutex::new(sink),
            pending: DashMap::new(),
            next_id: AtomicU64::new(1),
            event_listeners: DashMap::new(),
        });

        // Spawn message reader
        let conn2 = conn.clone();
        tokio::spawn(async move {
            conn2.read_loop(stream).await;
        });

        Ok(conn)
    }

    async fn read_loop(
        &self,
        mut stream: futures_util::stream::SplitStream<
            tokio_tungstenite::WebSocketStream<
                tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
            >,
        >,
    ) {
        while let Some(Ok(msg)) = stream.next().await {
            if let Message::Text(text) = msg {
                if let Ok(val) = serde_json::from_str::<Value>(&text) {
                    if let Some(id) = val.get("id").and_then(|v| v.as_u64()) {
                        // Response to a command
                        if let Some((_, tx)) = self.pending.remove(&id) {
                            let _ = tx.send(val);
                        }
                    } else if let Some(method) = val.get("method").and_then(|v| v.as_str()) {
                        // Event
                        let params = val.get("params").cloned().unwrap_or(json!({}));
                        if let Some(listeners) = self.event_listeners.get(method) {
                            for tx in listeners.value().iter() {
                                let _ = tx.send(params.clone());
                            }
                        }
                    }
                }
            }
        }
    }

    /// Send a CDP command and wait for response.
    pub async fn call(&self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let msg = json!({
            "id": id,
            "method": method,
            "params": params,
        });

        let (tx, rx) = oneshot::channel();
        self.pending.insert(id, tx);

        {
            let mut sink = self.tx.lock().await;
            sink.send(Message::Text(msg.to_string()))
                .await
                .map_err(|e| format!("WS send failed: {e}"))?;
        }

        let resp = rx.await.map_err(|_| "Response channel closed".to_string())?;

        if let Some(err) = resp.get("error") {
            return Err(format!("CDP error: {err}"));
        }

        Ok(resp.get("result").cloned().unwrap_or(json!({})))
    }

    /// Send multiple CDP commands in pipeline (all sent before waiting for any response).
    pub async fn pipeline(&self, commands: Vec<(&str, Value)>) -> Vec<Result<Value, String>> {
        let mut receivers = Vec::with_capacity(commands.len());

        // Send all commands without waiting
        {
            let mut sink = self.tx.lock().await;
            for (method, params) in &commands {
                let id = self.next_id.fetch_add(1, Ordering::SeqCst);
                let msg = json!({
                    "id": id,
                    "method": method,
                    "params": params,
                });
                let (tx, rx) = oneshot::channel();
                self.pending.insert(id, tx);
                receivers.push(rx);
                let _ = sink.send(Message::Text(msg.to_string())).await;
            }
        }

        // Wait for all responses
        let mut results = Vec::with_capacity(receivers.len());
        for rx in receivers {
            match rx.await {
                Ok(resp) => {
                    if let Some(err) = resp.get("error") {
                        results.push(Err(format!("CDP error: {err}")));
                    } else {
                        results.push(Ok(resp.get("result").cloned().unwrap_or(json!({}))));
                    }
                }
                Err(_) => results.push(Err("Channel closed".into())),
            }
        }
        results
    }

    /// Subscribe to a CDP event. Returns a receiver for event params.
    pub fn on_event(&self, method: &str) -> tokio::sync::mpsc::UnboundedReceiver<Value> {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        self.event_listeners
            .entry(method.to_string())
            .or_default()
            .push(tx);
        rx
    }

    /// Remove all event listeners for a method.
    pub fn remove_listeners(&self, method: &str) {
        self.event_listeners.remove(method);
    }
}

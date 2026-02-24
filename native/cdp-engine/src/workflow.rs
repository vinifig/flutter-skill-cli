//! Workflow engine — execute multi-step browser operations in a single call.

use crate::ops;
use crate::pool::ConnectionPool;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Instant;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Workflow {
    pub steps: Vec<Step>,
    /// Optional: verify expression (JS) to run after all steps.
    #[serde(default)]
    pub verify: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum Step {
    Navigate {
        url: String,
    },
    Tap {
        #[serde(default)]
        text: Option<String>,
        #[serde(default)]
        x: Option<f64>,
        #[serde(default)]
        y: Option<f64>,
    },
    UploadFile {
        selector: String,
        file: String,
    },
    Evaluate {
        expression: String,
    },
    Snapshot,
    Screenshot {
        #[serde(default = "default_quality")]
        quality: u8,
    },
    Wait {
        #[serde(default = "default_wait_ms")]
        ms: u64,
    },
    WaitSelector {
        selector: String,
        #[serde(default = "default_timeout_ms")]
        timeout_ms: u64,
    },
    PressKey {
        key: String,
    },
    ScrollTo {
        text: String,
    },
}

fn default_quality() -> u8 {
    80
}
fn default_wait_ms() -> u64 {
    500
}
fn default_timeout_ms() -> u64 {
    5000
}

#[derive(Debug, Serialize)]
pub struct WorkflowResult {
    pub success: bool,
    pub steps: Vec<StepResult>,
    pub duration_ms: u64,
    pub verify_result: Option<Value>,
}

#[derive(Debug, Serialize)]
pub struct StepResult {
    pub step: usize,
    pub action: String,
    pub success: bool,
    pub result: Value,
    pub duration_ms: u64,
}

/// Execute a workflow on a single tab.
pub async fn execute(
    pool: &Arc<ConnectionPool>,
    tab_id: &str,
    workflow: Workflow,
) -> WorkflowResult {
    let start = Instant::now();
    let mut step_results = Vec::new();

    let conn = match pool.get_or_connect(tab_id).await {
        Ok(c) => c,
        Err(e) => {
            return WorkflowResult {
                success: false,
                steps: vec![StepResult {
                    step: 0,
                    action: "connect".into(),
                    success: false,
                    result: json!({"error": e}),
                    duration_ms: 0,
                }],
                duration_ms: start.elapsed().as_millis() as u64,
                verify_result: None,
            };
        }
    };

    for (i, step) in workflow.steps.iter().enumerate() {
        let step_start = Instant::now();
        let (action, result) = execute_step(&conn, step).await;
        let success = !result.get("error").is_some();
        step_results.push(StepResult {
            step: i,
            action,
            success,
            result: result.clone(),
            duration_ms: step_start.elapsed().as_millis() as u64,
        });

        if !success {
            return WorkflowResult {
                success: false,
                steps: step_results,
                duration_ms: start.elapsed().as_millis() as u64,
                verify_result: None,
            };
        }
    }

    // Run verify expression
    let verify_result = if let Some(ref expr) = workflow.verify {
        match ops::evaluate(&conn, expr).await {
            Ok(v) => Some(v),
            Err(e) => Some(json!({"error": e})),
        }
    } else {
        None
    };

    WorkflowResult {
        success: true,
        steps: step_results,
        duration_ms: start.elapsed().as_millis() as u64,
        verify_result,
    }
}

/// Execute a workflow across multiple tabs in parallel.
pub async fn execute_parallel(
    pool: &Arc<ConnectionPool>,
    tasks: Vec<(String, Workflow)>, // (tab_id, workflow)
) -> Vec<(String, WorkflowResult)> {
    let mut handles = Vec::new();

    for (tab_id, workflow) in tasks {
        let pool = pool.clone();
        let tab_id2 = tab_id.clone();
        handles.push(tokio::spawn(async move {
            let result = execute(&pool, &tab_id2, workflow).await;
            (tab_id, result)
        }));
    }

    let mut results = Vec::new();
    for handle in handles {
        if let Ok(r) = handle.await {
            results.push(r);
        }
    }
    results
}

async fn execute_step(
    conn: &Arc<crate::cdp::CdpConnection>,
    step: &Step,
) -> (String, Value) {
    match step {
        Step::Navigate { url } => (
            "navigate".into(),
            ops::navigate(conn, url).await.unwrap_or_else(|e| json!({"error": e})),
        ),
        Step::Tap { text, x, y } => {
            let result = if let Some(t) = text {
                ops::tap_text(conn, t).await
            } else if let (Some(x), Some(y)) = (x, y) {
                ops::tap(conn, *x, *y).await
            } else {
                Err("tap requires 'text' or 'x'+'y'".into())
            };
            ("tap".into(), result.unwrap_or_else(|e| json!({"error": e})))
        }
        Step::UploadFile { selector, file } => (
            "upload_file".into(),
            ops::upload_file(conn, selector, &PathBuf::from(file))
                .await
                .unwrap_or_else(|e| json!({"error": e})),
        ),
        Step::Evaluate { expression } => (
            "evaluate".into(),
            ops::evaluate(conn, expression)
                .await
                .unwrap_or_else(|e| json!({"error": e})),
        ),
        Step::Snapshot => (
            "snapshot".into(),
            match ops::snapshot(conn).await {
                Ok(s) => json!({"snapshot": s}),
                Err(e) => json!({"error": e}),
            },
        ),
        Step::Screenshot { quality } => (
            "screenshot".into(),
            match ops::screenshot(conn, *quality, None).await {
                Ok(b64) => json!({"base64": b64}),
                Err(e) => json!({"error": e}),
            },
        ),
        Step::Wait { ms } => {
            tokio::time::sleep(std::time::Duration::from_millis(*ms)).await;
            ("wait".into(), json!({"waited_ms": ms}))
        }
        Step::WaitSelector {
            selector,
            timeout_ms,
        } => {
            let escaped = selector.replace('\\', "\\\\").replace('\'', "\\'");
            let start = Instant::now();
            let timeout = std::time::Duration::from_millis(*timeout_ms);
            loop {
                if start.elapsed() > timeout {
                    return (
                        "wait_selector".into(),
                        json!({"error": format!("Timeout waiting for {selector}")}),
                    );
                }
                let found = ops::evaluate(
                    conn,
                    &format!("!!document.querySelector('{escaped}')"),
                )
                .await;
                if let Ok(Value::Bool(true)) = found {
                    return (
                        "wait_selector".into(),
                        json!({"found": true, "elapsed_ms": start.elapsed().as_millis()}),
                    );
                }
                tokio::time::sleep(std::time::Duration::from_millis(100)).await;
            }
        }
        Step::PressKey { key } => (
            "press_key".into(),
            ops::press_key(conn, key)
                .await
                .unwrap_or_else(|e| json!({"error": e})),
        ),
        Step::ScrollTo { text } => (
            "scroll_to".into(),
            ops::scroll_to(conn, text)
                .await
                .unwrap_or_else(|e| json!({"error": e})),
        ),
    }
}

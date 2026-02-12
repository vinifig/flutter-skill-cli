// Flutter Skill guest-js bridge for Tauri frontend
// This runs in the Tauri webview and communicates with the Rust plugin

interface JsonRpcRequest {
  jsonrpc: '2.0';
  method: string;
  params?: Record<string, unknown>;
  id: number;
}

interface JsonRpcResponse {
  jsonrpc: '2.0';
  result?: unknown;
  error?: { code: number; message: string };
  id: number;
}

let requestId = 0;

function buildRequest(method: string, params?: Record<string, unknown>): JsonRpcRequest {
  return { jsonrpc: '2.0', method, params, id: ++requestId };
}

/**
 * Connect to the flutter-skill WebSocket server running in the Tauri backend.
 */
export function connect(port = 18118): Promise<FlutterSkillClient> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${port}`);
    const pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();

    ws.onopen = () => resolve(new FlutterSkillClient(ws, pending));
    ws.onerror = (e) => reject(e);

    ws.onmessage = (ev) => {
      const resp: JsonRpcResponse = JSON.parse(ev.data);
      const p = pending.get(resp.id);
      if (p) {
        pending.delete(resp.id);
        if (resp.error) p.reject(new Error(resp.error.message));
        else p.resolve(resp.result);
      }
    };
  });
}

export class FlutterSkillClient {
  constructor(
    private ws: WebSocket,
    private pending: Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>
  ) {}

  private call(method: string, params?: Record<string, unknown>): Promise<unknown> {
    const req = buildRequest(method, params);
    return new Promise((resolve, reject) => {
      this.pending.set(req.id, { resolve, reject });
      this.ws.send(JSON.stringify(req));
    });
  }

  health() { return this.call('health'); }
  inspect() { return this.call('inspect'); }
  tap(selector: string) { return this.call('tap', { selector }); }
  enterText(selector: string, text: string) { return this.call('enter_text', { selector, text }); }
  screenshot() { return this.call('screenshot'); }
  scroll(dx = 0, dy = 0) { return this.call('scroll', { dx, dy }); }
  getText(selector: string) { return this.call('get_text', { selector }); }
  findElement(params: { selector?: string; text?: string }) { return this.call('find_element', params); }
  waitForElement(selector: string, timeout = 5000) { return this.call('wait_for_element', { selector, timeout }); }

  close() { this.ws.close(); }
}

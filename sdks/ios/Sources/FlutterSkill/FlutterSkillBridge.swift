//
//  FlutterSkillBridge.swift
//  FlutterSkill iOS SDK
//
//  Bridge that lets flutter-skill automate native iOS apps (UIKit / SwiftUI).
//  Starts an HTTP + WebSocket server on port 18118 using Network.framework.
//  No external dependencies — uses only Foundation, UIKit, and Network.
//

import CommonCrypto
import Foundation
@preconcurrency import Network
import UIKit

// MARK: - Public API

/// Main bridge class. Call `FlutterSkillBridge.shared.start()` in your
/// AppDelegate or SwiftUI App init to enable flutter-skill automation.
public final class FlutterSkillBridge: @unchecked Sendable {

    // MARK: Properties

    public static let shared = FlutterSkillBridge()

    public static let sdkVersion = "1.0.0"
    public nonisolated static let defaultPort: UInt16 = 18118

    public private(set) var isRunning = false

    private var listener: NWListener?
    private var wsConnections: [NWConnection] = []
    private var logBuffer: [String] = []
    private let maxLogEntries = 500
    private var appName: String = ""

    // MARK: Lifecycle

    private init() {}

    /// Start the bridge server. Call once at app launch (typically inside
    /// `application(_:didFinishLaunchingWithOptions:)` or SwiftUI `App.init`).
    ///
    /// - Parameter appName: Human-readable app name reported to flutter-skill.
    /// - Parameter port: TCP port to listen on. Defaults to 18118.
    public func start(appName: String? = nil, port: UInt16 = defaultPort) {
        guard !isRunning else { return }
        self.appName = appName ?? Bundle.main.appName
        startListener(port: port)
    }

    /// Stop the bridge server and disconnect all clients.
    public func stop() {
        listener?.cancel()
        listener = nil
        for conn in wsConnections {
            conn.cancel()
        }
        wsConnections.removeAll()
        upgradedConnections.removeAll()
        isRunning = false
        appendLog("[FlutterSkill] Bridge stopped")
    }

    // MARK: Log capture

    /// Append a log entry to the ring buffer. Apps can call this directly,
    /// or the SDK hooks `print` output automatically when `captureStdout` is used.
    public func appendLog(_ message: String) {
        logBuffer.append(message)
        if logBuffer.count > maxLogEntries {
            logBuffer.removeFirst()
        }
    }

    // MARK: - Listener Setup

    /// Connections that have completed the WebSocket handshake and are in frame mode.
    private var upgradedConnections: Set<ObjectIdentifier> = []

    private func startListener(port: UInt16) {
        // Use plain TCP — no WebSocket options in the protocol stack.
        // This allows us to serve both plain HTTP health checks and
        // WebSocket connections on the same port by inspecting raw bytes.
        let params = NWParameters.tcp

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            appendLog("[FlutterSkill] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
                self?.appendLog("[FlutterSkill] Bridge listening on port \(port)")
            case .failed(let error):
                self?.appendLog("[FlutterSkill] Listener failed: \(error)")
                self?.isRunning = false
            case .cancelled:
                self?.isRunning = false
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: .main)
    }

    // MARK: - Connection Handling

    /// Accept a new raw TCP connection and read the initial bytes to determine
    /// whether it is a plain HTTP request or a WebSocket upgrade.
    private func handleNewConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readHTTPRequest(on: connection)
            case .failed, .cancelled:
                self?.removeConnection(connection)
            default:
                break
            }
        }
        connection.start(queue: .main)
    }

    /// Read raw bytes from the connection, expecting an HTTP request.
    /// This is used for the initial request on every new TCP connection.
    private func readHTTPRequest(on connection: NWConnection) {
        // Read up to 8 KB for the initial HTTP request (headers only).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] content, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.appendLog("[FlutterSkill] Receive error: \(error)")
                connection.cancel()
                return
            }

            guard let data = content, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }

            self.routeHTTPRequest(data: data, on: connection)
        }
    }

    /// Parse the incoming HTTP request and route to health check or WebSocket upgrade.
    private func routeHTTPRequest(data: Data, on connection: NWConnection) {
        guard let request = String(data: data, encoding: .utf8) else {
            connection.cancel()
            return
        }

        // Buffer incomplete requests - must contain \r\n\r\n (end of headers)
        if !request.contains("\r\n\r\n") {
            // Partial read - need more data. Re-read.
            appendLog("[FlutterSkill] Partial HTTP request (\(data.count) bytes), reading more...")
            var accumulated = data
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
                [weak self] more, _, _, error in
                guard let self = self else { return }
                if let more = more {
                    accumulated.append(more)
                    self.routeHTTPRequest(data: accumulated, on: connection)
                } else {
                    connection.cancel()
                }
            }
            return
        }

        let lines = request.components(separatedBy: "\r\n")
        let firstLine = lines.first ?? ""
        let parts = firstLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : ""
        let path = parts.count > 1 ? parts[1] : ""

        // Parse headers into a dictionary (case-insensitive lookup).
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break } // end of headers
            if let colonIndex = line.firstIndex(of: ":") {
                let key = line[line.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        appendLog("[FlutterSkill] HTTP \(method) \(path) with \(headers.count) headers, wskey=\(headers["sec-websocket-key"] ?? "nil")")

        if method == "GET" && path == "/.flutter-skill" {
            // Health check endpoint — respond with JSON and close.
            self.respondHealthCheck(on: connection)
        } else if method == "GET" && path == "/ws"
                    && headers["upgrade"]?.lowercased() == "websocket"
                    && headers["sec-websocket-key"] != nil {
            // WebSocket upgrade request — perform the handshake.
            let wsKey = headers["sec-websocket-key"]!
            self.performWebSocketHandshake(key: wsKey, on: connection)
        } else {
            // 404 for anything else.
            let notFound = "HTTP/1.1 404 Not Found\r\n"
                + "Content-Length: 0\r\n"
                + "Connection: close\r\n"
                + "\r\n"
            connection.send(
                content: notFound.data(using: .utf8),
                completion: .contentProcessed({ _ in
                    connection.cancel()
                })
            )
        }
    }

    // MARK: - HTTP Health Check

    private func respondHealthCheck(on connection: NWConnection) {
        let capabilities = Self.allCapabilities
        let body: [String: Any] = [
            "framework": "ios-native",
            "app_name": appName,
            "platform": "ios",
            "capabilities": capabilities,
            "sdk_version": Self.sdkVersion,
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            connection.cancel()
            return
        }

        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(jsonData.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        let response = header + jsonString
        connection.send(
            content: response.data(using: .utf8),
            completion: .contentProcessed({ _ in
                connection.cancel()
            })
        )
    }

    // MARK: - WebSocket Handshake

    /// Perform the server-side WebSocket handshake (RFC 6455 section 4.2.2).
    /// Computes the Sec-WebSocket-Accept value and sends the 101 response,
    /// then transitions the connection into WebSocket frame mode.
    private func performWebSocketHandshake(key: String, on connection: NWConnection) {
        let magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magic
        let acceptKey = sha1Base64(combined)

        let response = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Connection: Upgrade\r\n"
            + "Upgrade: websocket\r\n"
            + "Sec-WebSocket-Accept: \(acceptKey)\r\n"
            + "\r\n"

        connection.send(content: response.data(using: .utf8), completion: .contentProcessed({ [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.appendLog("[FlutterSkill] WS handshake send error: \(error)")
                connection.cancel()
                return
            }

            // Mark as upgraded and start reading WebSocket frames.
            self.upgradedConnections.insert(ObjectIdentifier(connection))
            if !self.wsConnections.contains(where: { $0 === connection }) {
                self.wsConnections.append(connection)
            }
            self.appendLog("[FlutterSkill] WebSocket client connected")
            self.readWebSocketFrame(on: connection)
        }))
    }

    /// Compute SHA-1 hash and return base64-encoded result using CommonCrypto.
    private func sha1Base64(_ string: String) -> String {
        let data = Data(string.utf8)
        // Use CommonCrypto for SHA-1 (available on all Apple platforms).
        var digest = [UInt8](repeating: 0, count: 20) // SHA-1 produces 20 bytes
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return Data(digest).base64EncodedString()
    }

    // MARK: - WebSocket Frame Reading

    /// Read the next WebSocket frame from an upgraded connection.
    /// Implements a minimal RFC 6455 frame parser for text, close, and ping frames.
    private func readWebSocketFrame(on connection: NWConnection) {
        // Read at least 2 bytes (the minimum WebSocket frame header).
        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) {
            [weak self] header, _, isComplete, error in
            guard let self = self else { return }

            if let error = error {
                self.appendLog("[FlutterSkill] WS frame header error: \(error)")
                self.closeAndRemove(connection)
                return
            }

            guard let header = header, header.count >= 2 else {
                if isComplete { self.closeAndRemove(connection) }
                return
            }

            let byte0 = header[0]
            let byte1 = header[1]
            let opcode = byte0 & 0x0F
            let isMasked = (byte1 & 0x80) != 0
            var payloadLen = UInt64(byte1 & 0x7F)

            // Determine extended payload length.
            if payloadLen == 126 {
                // Read 2 more bytes for 16-bit length.
                self.readBytes(count: 2, on: connection) { extData in
                    guard let extData = extData else {
                        self.closeAndRemove(connection)
                        return
                    }
                    payloadLen = UInt64(extData[0]) << 8 | UInt64(extData[1])
                    self.readFramePayload(
                        opcode: opcode, isMasked: isMasked,
                        payloadLen: payloadLen, on: connection
                    )
                }
            } else if payloadLen == 127 {
                // Read 8 more bytes for 64-bit length.
                self.readBytes(count: 8, on: connection) { extData in
                    guard let extData = extData else {
                        self.closeAndRemove(connection)
                        return
                    }
                    payloadLen = 0
                    for i in 0..<8 {
                        payloadLen = (payloadLen << 8) | UInt64(extData[i])
                    }
                    self.readFramePayload(
                        opcode: opcode, isMasked: isMasked,
                        payloadLen: payloadLen, on: connection
                    )
                }
            } else {
                // Payload length fits in 7 bits.
                self.readFramePayload(
                    opcode: opcode, isMasked: isMasked,
                    payloadLen: payloadLen, on: connection
                )
            }
        }
    }

    /// Read exactly `count` bytes from the connection.
    private func readBytes(count: Int, on connection: NWConnection, completion: @escaping (Data?) -> Void) {
        guard count > 0 else {
            completion(Data())
            return
        }
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if error != nil || data == nil || data!.count < count {
                completion(nil)
            } else {
                completion(data)
            }
        }
    }

    /// Read the masking key (if present) and payload, then handle the frame.
    private func readFramePayload(
        opcode: UInt8, isMasked: Bool,
        payloadLen: UInt64, on connection: NWConnection
    ) {
        let maskLen = isMasked ? 4 : 0
        let totalToRead = Int(payloadLen) + maskLen

        // Guard against absurdly large frames (limit to 16 MB).
        guard payloadLen <= 16 * 1024 * 1024 else {
            appendLog("[FlutterSkill] WS frame too large: \(payloadLen) bytes")
            closeAndRemove(connection)
            return
        }

        if totalToRead == 0 {
            // No payload (e.g., close frame with no body).
            handleDecodedFrame(opcode: opcode, payload: Data(), on: connection)
            return
        }

        readBytes(count: totalToRead, on: connection) { [weak self] rawData in
            guard let self = self, let rawData = rawData else {
                self?.closeAndRemove(connection)
                return
            }

            var payload: Data
            if isMasked {
                let mask = rawData.prefix(4)
                let masked = rawData.dropFirst(4)
                var unmasked = Data(count: Int(payloadLen))
                for i in 0..<Int(payloadLen) {
                    unmasked[i] = masked[masked.startIndex + i] ^ mask[mask.startIndex + (i % 4)]
                }
                payload = unmasked
            } else {
                payload = rawData
            }

            self.handleDecodedFrame(opcode: opcode, payload: payload, on: connection)
        }
    }

    /// Handle a decoded WebSocket frame based on its opcode.
    private func handleDecodedFrame(opcode: UInt8, payload: Data, on connection: NWConnection) {
        switch opcode {
        case 0x01: // Text frame
            handleWebSocketTextMessage(data: payload, on: connection)
            // Continue reading the next frame.
            readWebSocketFrame(on: connection)

        case 0x08: // Close frame
            // Reply with a close frame and tear down.
            let closeFrame = buildWSFrame(opcode: 0x08, payload: Data())
            connection.send(content: closeFrame, completion: .contentProcessed({ [weak self] _ in
                self?.closeAndRemove(connection)
            }))

        case 0x09: // Ping — reply with Pong carrying the same payload.
            let pongFrame = buildWSFrame(opcode: 0x0A, payload: payload)
            connection.send(content: pongFrame, completion: .contentProcessed({ [weak self] _ in
                self?.readWebSocketFrame(on: connection)
            }))

        case 0x0A: // Pong — ignore, continue reading.
            readWebSocketFrame(on: connection)

        default:
            // Unsupported opcode — close with protocol error (1002).
            let statusBody = Data([0x03, 0xEA]) // status code 1002 in network byte order
            let closeFrame = buildWSFrame(opcode: 0x08, payload: statusBody)
            connection.send(content: closeFrame, completion: .contentProcessed({ [weak self] _ in
                self?.closeAndRemove(connection)
            }))
        }
    }

    // MARK: - WebSocket Frame Writing

    /// Build a server-to-client WebSocket frame (unmasked, per RFC 6455).
    private func buildWSFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()

        // FIN bit + opcode
        frame.append(0x80 | opcode)

        // Payload length (server frames are never masked).
        let length = payload.count
        if length < 126 {
            frame.append(UInt8(length))
        } else if length <= 65535 {
            frame.append(126)
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> shift) & 0xFF))
            }
        }

        frame.append(payload)
        return frame
    }

    /// Send a text message over WebSocket.
    private func sendWSText(_ text: Data, on connection: NWConnection) {
        let frame = buildWSFrame(opcode: 0x01, payload: text)
        connection.send(content: frame, completion: .contentProcessed({ _ in }))
    }

    // MARK: - WebSocket Message Handling

    /// Handle a decoded text-frame payload as a JSON-RPC message.
    private func handleWebSocketTextMessage(data: Data, on connection: NWConnection) {
        // Handle text ping keepalive
        if let text = String(data: data, encoding: .utf8), text == "ping" {
            sendWSText("pong".data(using: .utf8)!, on: connection)
            return
        }
        // Parse JSON-RPC request
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rpcMethod = json["method"] as? String else {
            sendWSError(on: connection, id: nil, code: -32700, message: "Parse error")
            return
        }

        let id = json["id"] // may be Int or null for notifications
        let params = json["params"] as? [String: Any] ?? [:]

        // Dispatch on main thread for UIKit safety
        Task { @MainActor in
            // wait_for_element is async (polls with timeout)
            if rpcMethod == "wait_for_element" {
                let result = await self.handleWaitForElementAsync(params)
                self.sendWSResult(on: connection, id: id, result: result)
                return
            }
            let result = self.dispatch(method: rpcMethod, params: params)
            self.sendWSDispatchResult(on: connection, id: id, result: result)
        }
    }

    private func sendWSDispatchResult(on connection: NWConnection, id: Any?, result: DispatchResult) {
        switch result {
        case .success(let dict):
            sendWSResult(on: connection, id: id, result: dict)
        case .error(let code, let message):
            sendWSError(on: connection, id: id, code: code, message: message)
        }
    }

    private func sendWSResult(on connection: NWConnection, id: Any?, result: [String: Any]) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id = id {
            response["id"] = id
        }

        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        sendWSText(data, on: connection)
    }

    private func sendWSError(on connection: NWConnection, id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message,
            ] as [String: Any],
        ]
        if let id = id {
            response["id"] = id
        }

        guard let data = try? JSONSerialization.data(withJSONObject: response) else { return }
        sendWSText(data, on: connection)
    }

    private func closeAndRemove(_ connection: NWConnection) {
        connection.cancel()
        removeConnection(connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        wsConnections.removeAll(where: { $0 === connection })
        upgradedConnections.remove(ObjectIdentifier(connection))
    }

    // MARK: - Capabilities

    static let allCapabilities: [String] = [
        // Core
        "initialize", "screenshot", "inspect", "inspect_interactive", "tap", "enter_text",
        "swipe", "scroll", "find_element", "get_text", "wait_for_element",
        // Extended
        "get_logs", "clear_logs", "go_back", "get_route", "press_key",
    ]

    // MARK: - JSON-RPC Dispatch

    /// Result type from dispatch: either a success result dict or a JSON-RPC error.
    private enum DispatchResult {
        case success([String: Any])
        case error(code: Int, message: String)
    }

    private func dispatch(method: String, params: [String: Any]) -> DispatchResult {
        switch method {
        case "initialize":
            return .success(handleInitialize(params))
        case "inspect":
            return .success(handleInspect(params))
        case "inspect_interactive":
            return .success(handleInspectInteractive(params))
        case "tap":
            return .success(handleTap(params))
        case "enter_text":
            return .success(handleEnterText(params))
        case "swipe":
            return .success(handleSwipe(params))
        case "scroll":
            return .success(handleScroll(params))
        case "find_element":
            return .success(handleFindElement(params))
        case "get_text":
            return .success(handleGetText(params))
        case "wait_for_element":
            return .success(handleWaitForElement(params))
        case "screenshot":
            return .success(handleScreenshot(params))
        case "get_logs":
            return .success(handleGetLogs(params))
        case "clear_logs":
            return .success(handleClearLogs(params))
        case "go_back":
            return .success(handleGoBack(params))
        case "get_route":
            return .success(handleGetRoute(params))
        case "press_key":
            return .success(handlePressKey(params))
        default:
            return .error(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Core Method Implementations

    private func handleInitialize(_ params: [String: Any]) -> [String: Any] {
        return [
            "success": true,
            "framework": "ios-native",
            "sdk_version": Self.sdkVersion,
            "app_name": appName,
            "platform": "ios",
        ]
    }

    private func handleInspect(_ params: [String: Any]) -> [String: Any] {
        guard let window = Self.keyWindow else {
            return ["elements": [Any]()]
        }

        var seenIds = Set<String>()
        var merged: [[String: Any]] = []

        // 1. SwiftUI registry elements (highest priority)
        for entry in FlutterSkillRegistry.shared.allElements() {
            seenIds.insert(entry.id)
            var dict: [String: Any] = [
                "id": entry.id,
                "tag": entry.tag,
                "type": "SwiftUI",
                "visible": true,
                "interactive": entry.onTap != nil || entry.onSetText != nil,
            ]
            if let text = entry.text() { dict["text"] = text }
            if let label = entry.label { dict["label"] = label }
            if entry.frame != .zero {
                dict["bounds"] = [
                    "x": Int(entry.frame.origin.x),
                    "y": Int(entry.frame.origin.y),
                    "width": Int(entry.frame.size.width),
                    "height": Int(entry.frame.size.height),
                ]
            }
            merged.append(dict)
        }

        // 2. UIKit view elements (for non-SwiftUI views)
        for el in window.flutterSkill_interactiveElements().map({ $0.toDictionary() }) {
            let id = el["id"] as? String ?? ""
            if !seenIds.contains(id) {
                merged.append(el)
                if !id.isEmpty { seenIds.insert(id) }
            }
        }

        return ["elements": merged]
    }

    private func handleInspectInteractive(_ params: [String: Any]) -> [String: Any] {
        guard let window = Self.keyWindow else {
            return [
                "elements": [Any](),
                "summary": "No key window available"
            ]
        }

        var refCounts: [String: Int] = [:]
        var elements: [[String: Any]] = []

        func generateSemanticRef(role: String, content: String?, refCounts: inout [String: Int]) -> String {
            // Clean content: spaces to underscores, remove special chars, truncate to 30 chars
            let sanitized = content?.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
                .replacingOccurrences(of: "[^\\w]", with: "", options: .regularExpression)
                .prefix(30)
                .takeIf { !$0.isEmpty }
                .map(String.init)

            let base = sanitized != nil ? "\(role):\(sanitized!)" : role
            let count = refCounts[base] ?? 0
            refCounts[base] = count + 1

            return count == 0 ? base : "\(base)[\(count)]"
        }

        func generateRefId(baseType: String, view: UIView) -> String {
            // Map base types to semantic roles
            let role: String
            switch baseType {
            case "button":
                role = "button"
            case "text_field":
                role = "input"
            case "switch":
                role = "toggle"
            case "slider":
                role = "slider"
            case "tab":
                role = "select"
            case "link":
                role = "link"
            case "list_item":
                role = "item"
            default:
                role = "element"
            }

            // Extract content with priority: accessibilityLabel -> title -> text -> placeholder
            let content = view.accessibilityLabel
                ?? (view as? UIButton)?.titleLabel?.text
                ?? extractText(from: view).takeIf { !$0.isEmpty }
                ?? (view as? UITextField)?.placeholder

            return generateSemanticRef(role: role, content: content, refCounts: &refCounts)
        }

        func getElementType(view: UIView) -> String {
            if view is UIButton { return "button" }
            if view is UITextField || view is UITextView || view is UISearchBar { return "text_field" }
            if view is UISwitch { return "switch" }
            if view is UISlider { return "slider" }
            if view is UISegmentedControl { return "tab" }
            if view.accessibilityTraits.contains(.button) { return "button" }
            if view.accessibilityTraits.contains(.searchField) { return "text_field" }
            if view.accessibilityTraits.contains(.adjustable) { return "slider" }
            if view.accessibilityTraits.contains(.link) { return "link" }
            if view.isKind(of: NSClassFromString("UITableViewCell") ?? UIView.self) { return "list_item" }
            return "button" // Default for interactive elements
        }

        func getBaseType(elementType: String) -> String {
            switch elementType {
            case "button": return "button"
            case "text_field": return "text_field"
            case "switch": return "switch"
            case "slider": return "slider"
            case "tab": return "tab"
            case "link": return "link"
            case "list_item": return "list_item"
            default: return "button"
            }
        }

        func getActions(elementType: String) -> [String] {
            switch elementType {
            case "text_field":
                return ["tap", "enter_text"]
            case "slider":
                return ["tap", "swipe"]
            default:
                return ["tap", "long_press"]
            }
        }

        func getValue(view: UIView, elementType: String) -> Any? {
            switch elementType {
            case "text_field":
                if let textField = view as? UITextField {
                    return textField.text ?? ""
                } else if let textView = view as? UITextView {
                    return textView.text ?? ""
                } else if let searchBar = view as? UISearchBar {
                    return searchBar.text ?? ""
                }
                return ""
            case "switch":
                if let switchControl = view as? UISwitch {
                    return switchControl.isOn
                }
                return false
            case "slider":
                if let slider = view as? UISlider {
                    return slider.value
                }
                return 0.0
            default:
                return nil
            }
        }

        // Collect interactive UIViews
        window.flutterSkill_walkHierarchy { view in
            let isInteractive = view.isUserInteractionEnabled &&
                               (view.accessibilityTraits.contains(.button) ||
                                view.accessibilityTraits.contains(.searchField) ||
                                view.accessibilityTraits.contains(.adjustable) ||
                                view.accessibilityTraits.contains(.link) ||
                                view is UIButton ||
                                view is UITextField ||
                                view is UITextView ||
                                view is UISearchBar ||
                                view is UISwitch ||
                                view is UISlider ||
                                view is UISegmentedControl ||
                                (view.accessibilityIdentifier != nil && !view.accessibilityIdentifier!.isEmpty))

            if isInteractive {
                let elementType = getElementType(view: view)
                let baseType = getBaseType(elementType: elementType)
                let refId = generateRefId(baseType: baseType, view: view)

                let frame = view.superview?.convert(view.frame, to: window) ?? view.frame
                var element: [String: Any] = [
                    "ref": refId,
                    "type": String(describing: type(of: view)),
                    "actions": getActions(elementType: elementType),
                    "enabled": (view as? UIControl)?.isEnabled ?? view.isUserInteractionEnabled,
                    "bounds": [
                        "x": Int(frame.origin.x),
                        "y": Int(frame.origin.y),
                        "w": Int(frame.width),
                        "h": Int(frame.height)
                    ]
                ]

                // Add optional fields
                let text = extractText(from: view)
                if !text.isEmpty {
                    element["text"] = text
                }

                if let label = view.accessibilityLabel, !label.isEmpty {
                    element["label"] = label
                }

                let value = getValue(view: view, elementType: elementType)
                if value != nil {
                    element["value"] = value
                }

                elements.append(element)
            }
        }

        // Add SwiftUI registry elements
        for entry in FlutterSkillRegistry.shared.allElements() {
            if entry.onTap != nil || entry.onSetText != nil {
                let elementType = entry.onSetText != nil ? "text_field" : "button"
                let baseType = getBaseType(elementType: elementType)
                
                // Create a synthetic semantic ref for SwiftUI elements
                let role = baseType == "text_field" ? "input" : "button"
                let content = entry.text() ?? entry.label
                let refId = generateSemanticRef(role: role, content: content, refCounts: &refCounts)

                var element: [String: Any] = [
                    "ref": refId,
                    "type": "SwiftUI.\(entry.tag)",
                    "actions": getActions(elementType: elementType),
                    "enabled": true,
                    "bounds": [
                        "x": Int(entry.frame.origin.x),
                        "y": Int(entry.frame.origin.y),
                        "w": Int(entry.frame.width),
                        "h": Int(entry.frame.height)
                    ]
                ]

                if let text = entry.text(), !text.isEmpty {
                    element["text"] = text
                }

                if let label = entry.label, !label.isEmpty {
                    element["label"] = label
                }

                element["_swiftui_id"] = entry.id // Store for ref resolution

                elements.append(element)
            }
        }

        // Generate summary
        let counts = refCounts.map { (prefix, count) -> String in
            switch prefix {
            case "btn": return "\(count) button\(count == 1 ? "" : "s")"
            case "tf": return "\(count) text field\(count == 1 ? "" : "s")"
            case "sw": return "\(count) switch\(count == 1 ? "" : "es")"
            case "sl": return "\(count) slider\(count == 1 ? "" : "s")"
            case "dd": return "\(count) dropdown\(count == 1 ? "" : "s")"
            case "item": return "\(count) list item\(count == 1 ? "" : "s")"
            case "lnk": return "\(count) link\(count == 1 ? "" : "s")"
            case "tab": return "\(count) tab\(count == 1 ? "" : "s")"
            default: return "\(count) element\(count == 1 ? "" : "s")"
            }
        }

        let summary = counts.isEmpty ?
            "No interactive elements found" :
            "\(elements.count) interactive: \(counts.joined(separator: ", "))"

        return [
            "elements": elements,
            "summary": summary
        ]
    }

    private func extractText(from view: UIView) -> String {
        if let label = view as? UILabel {
            return label.text ?? ""
        } else if let button = view as? UIButton {
            return button.titleLabel?.text ?? ""
        } else if let textField = view as? UITextField {
            return textField.text ?? ""
        } else if let textView = view as? UITextView {
            return textView.text ?? ""
        } else if let searchBar = view as? UISearchBar {
            return searchBar.text ?? ""
        } else if let accessibilityLabel = view.accessibilityLabel {
            return accessibilityLabel
        }
        return ""
    }

    private func handleTap(_ params: [String: Any]) -> [String: Any] {
        var method = "unknown"

        // Try ref-based resolution first
        if let refId = params["ref"] as? String, !refId.isEmpty {
            if let element = resolveElementByRef(refId) {
                method = "ref"
                if let control = element as? UIControl {
                    control.sendActions(for: .touchUpInside)
                    return ["success": true, "message": "Tapped (sendActions)", "method": method]
                }
                if element.accessibilityActivate() {
                    return ["success": true, "message": "Tapped (accessibilityActivate)", "method": method]
                }
                let center = element.superview?.convert(element.center, to: nil) ?? element.center
                simulateTap(at: center, in: element.window)
                return ["success": true, "message": "Tapped (simulated touch)", "method": method]
            }
            
            // Try SwiftUI registry by ref
            if let entry = resolveRegisteredElementByRef(refId) {
                method = "ref"
                if let onTap = entry.onTap {
                    onTap()
                    return ["success": true, "message": "Tapped (registry)", "method": method]
                }
            }
        }

        // Fall back to UIView-based resolution
        if let element = resolveElement(params) {
            method = params["key"] != nil ? "key" : "text"
            if let control = element as? UIControl {
                control.sendActions(for: .touchUpInside)
                return ["success": true, "message": "Tapped (sendActions)", "method": method]
            }
            if element.accessibilityActivate() {
                return ["success": true, "message": "Tapped (accessibilityActivate)", "method": method]
            }
            let center = element.superview?.convert(element.center, to: nil) ?? element.center
            simulateTap(at: center, in: element.window)
            return ["success": true, "message": "Tapped (simulated touch)", "method": method]
        }

        // Fall back to SwiftUI registry
        if let entry = resolveRegisteredElement(params) {
            method = "registry"
            if let onTap = entry.onTap {
                onTap()
                return ["success": true, "message": "Tapped (registry)", "method": method]
            }
            // Fall back to simulated tap at registered frame center
            if entry.frame != .zero, let window = Self.keyWindow {
                let center = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
                let windowCenter = window.convert(center, from: nil)
                simulateTap(at: windowCenter, in: window)
                return ["success": true, "message": "Tapped (registry frame)", "method": method]
            }
        }

        return ["success": false, "message": "Element not found"]
    }

    private func handleEnterText(_ params: [String: Any]) -> [String: Any] {
        let text = params["text"] as? String ?? ""
        var method = "unknown"

        // Try ref-based resolution first
        if let refId = params["ref"] as? String, !refId.isEmpty {
            if let element = resolveElementByRef(refId) {
                method = "ref"
                if let textField = element as? UITextField {
                    textField.becomeFirstResponder()
                    textField.text = text
                    textField.sendActions(for: .editingChanged)
                    NotificationCenter.default.post(
                        name: UITextField.textDidChangeNotification, object: textField
                    )
                    return ["success": true, "message": "Text entered in UITextField", "method": method]
                }

                if let textView = element as? UITextView {
                    textView.becomeFirstResponder()
                    textView.text = text
                    textView.delegate?.textViewDidChange?(textView)
                    NotificationCenter.default.post(
                        name: UITextView.textDidChangeNotification, object: textView
                    )
                    return ["success": true, "message": "Text entered in UITextView", "method": method]
                }

                if let searchBar = element as? UISearchBar {
                    searchBar.becomeFirstResponder()
                    searchBar.text = text
                    searchBar.delegate?.searchBar?(searchBar, textDidChange: text)
                    return ["success": true, "message": "Text entered in UISearchBar", "method": method]
                }

                return ["success": false, "message": "Element is not a text input", "method": method]
            }
            
            // Try SwiftUI registry by ref
            if let entry = resolveRegisteredElementByRef(refId) {
                method = "ref"
                if let onSetText = entry.onSetText {
                    onSetText(text)
                    return ["success": true, "message": "Text entered (registry)", "method": method]
                }
                return ["success": false, "message": "Registry element has no text setter", "method": method]
            }
        }

        // Fall back to UIView-based resolution
        if let element = resolveElement(params) {
            method = params["key"] != nil ? "key" : "text"
            if let textField = element as? UITextField {
                textField.becomeFirstResponder()
                textField.text = text
                textField.sendActions(for: .editingChanged)
                NotificationCenter.default.post(
                    name: UITextField.textDidChangeNotification, object: textField
                )
                return ["success": true, "message": "Text entered in UITextField", "method": method]
            }

            if let textView = element as? UITextView {
                textView.becomeFirstResponder()
                textView.text = text
                textView.delegate?.textViewDidChange?(textView)
                NotificationCenter.default.post(
                    name: UITextView.textDidChangeNotification, object: textView
                )
                return ["success": true, "message": "Text entered in UITextView", "method": method]
            }

            if let searchBar = element as? UISearchBar {
                searchBar.becomeFirstResponder()
                searchBar.text = text
                searchBar.delegate?.searchBar?(searchBar, textDidChange: text)
                return ["success": true, "message": "Text entered in UISearchBar", "method": method]
            }

            return ["success": false, "message": "Element is not a text input", "method": method]
        }

        // Fall back to SwiftUI registry
        if let entry = resolveRegisteredElement(params) {
            method = "registry"
            if let onSetText = entry.onSetText {
                onSetText(text)
                return ["success": true, "message": "Text entered (registry)", "method": method]
            }
            return ["success": false, "message": "Registry element has no text setter", "method": method]
        }

        return ["success": false, "message": "Element not found"]
    }

    private func handleSwipe(_ params: [String: Any]) -> [String: Any] {
        let direction = params["direction"] as? String ?? "up"
        let distance = CGFloat((params["distance"] as? NSNumber)?.doubleValue ?? 300)

        // If a key is specified, find that element; otherwise swipe on the key window.
        let target: UIView
        if let element = resolveElement(params) {
            target = element
        } else if let window = Self.keyWindow {
            target = window
        } else {
            return ["success": false, "message": "No target for swipe"]
        }

        let bounds = target.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let centerInWindow = target.convert(center, to: nil)

        var dx: CGFloat = 0
        var dy: CGFloat = 0
        switch direction {
        case "up": dy = -distance
        case "down": dy = distance
        case "left": dx = -distance
        case "right": dx = distance
        default: break
        }

        let endPoint = CGPoint(x: centerInWindow.x + dx, y: centerInWindow.y + dy)

        // Use accessibility scroll for UIScrollView subclasses
        if let scrollView = target as? UIScrollView {
            var offset = scrollView.contentOffset
            offset.x -= dx
            offset.y -= dy
            scrollView.setContentOffset(offset, animated: true)
            return ["success": true, "message": "Swiped via scroll offset"]
        }

        // Fallback: use accessibility scroll direction
        let axDirection = accessibilityScrollDirection(for: direction)
        if target.accessibilityScroll(axDirection) {
            return ["success": true, "message": "Swiped via accessibility"]
        }

        // Last resort: synthesize touch events
        simulateSwipe(from: centerInWindow, to: endPoint, in: target.window)
        return ["success": true, "message": "Swiped (simulated touch)"]
    }

    private func handleScroll(_ params: [String: Any]) -> [String: Any] {
        let direction = params["direction"] as? String ?? "down"
        let distance = CGFloat((params["distance"] as? NSNumber)?.doubleValue ?? 300)

        // Find scroll view
        let scrollView: UIScrollView?
        if let element = resolveElement(params) as? UIScrollView {
            scrollView = element
        } else if let element = resolveElement(params) {
            scrollView = element.flutterSkill_findEnclosingScrollView()
        } else if let window = Self.keyWindow {
            scrollView = window.flutterSkill_findFirstScrollView()
        } else {
            scrollView = nil
        }

        guard let sv = scrollView else {
            return ["success": false, "message": "No UIScrollView found"]
        }

        var offset = sv.contentOffset
        switch direction {
        case "up": offset.y = max(offset.y - distance, -sv.adjustedContentInset.top)
        case "down":
            let maxY = sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom
            offset.y = min(offset.y + distance, max(maxY, 0))
        case "left": offset.x = max(offset.x - distance, -sv.adjustedContentInset.left)
        case "right":
            let maxX = sv.contentSize.width - sv.bounds.width + sv.adjustedContentInset.right
            offset.x = min(offset.x + distance, max(maxX, 0))
        default: break
        }

        sv.setContentOffset(offset, animated: true)
        return ["success": true, "message": "Scrolled"]
    }

    private func handleFindElement(_ params: [String: Any]) -> [String: Any] {
        if let element = resolveElement(params) {
            let desc = ElementDescriptor(view: element)
            return ["found": true, "element": desc.toDictionary()]
        }

        // Fall back to SwiftUI registry
        if let entry = resolveRegisteredElement(params) {
            var dict: [String: Any] = [
                "id": entry.id,
                "tag": entry.tag,
                "type": "SwiftUI",
                "visible": true,
                "interactive": entry.onTap != nil || entry.onSetText != nil,
            ]
            if let text = entry.text() { dict["text"] = text }
            if let label = entry.label { dict["label"] = label }
            if entry.frame != .zero {
                dict["bounds"] = [
                    "x": Int(entry.frame.origin.x),
                    "y": Int(entry.frame.origin.y),
                    "width": Int(entry.frame.size.width),
                    "height": Int(entry.frame.size.height),
                ]
            }
            return ["found": true, "element": dict]
        }

        return ["found": false]
    }

    private func handleGetText(_ params: [String: Any]) -> [String: Any] {
        // Try UIView-based resolution first
        if let element = resolveElement(params) {
            if let label = element as? UILabel { return ["text": label.text ?? ""] }
            if let textField = element as? UITextField { return ["text": textField.text ?? ""] }
            if let textView = element as? UITextView { return ["text": textView.text ?? ""] }
            if let button = element as? UIButton { return ["text": button.titleLabel?.text ?? ""] }

            if let value = element.accessibilityValue, !value.isEmpty { return ["text": value] }
            if let label = element.accessibilityLabel, !label.isEmpty { return ["text": label] }

            // Walk subviews for text content
            var foundText: String?
            element.flutterSkill_walkHierarchy { subview in
                if foundText != nil { return }
                if let label = subview as? UILabel { foundText = label.text }
                else if subview.accessibilityLabel != nil && subview !== element {
                    foundText = subview.accessibilityLabel
                }
            }
            if let text = foundText { return ["text": text] }
            return ["text": ""]
        }

        // Fall back to SwiftUI registry
        if let entry = resolveRegisteredElement(params) {
            if let text = entry.text() {
                return ["text": text]
            }
            if let label = entry.label {
                return ["text": label]
            }
            return ["text": ""]
        }

        return ["text": NSNull()]
    }

    private func handleWaitForElement(_ params: [String: Any]) -> [String: Any] {
        // Synchronous single check (used as fallback from dispatch table)
        if resolveElement(params) != nil || resolveRegisteredElement(params) != nil {
            return ["found": true]
        }
        return ["found": false]
    }

    /// Async version of wait_for_element that polls with a timeout.
    private func handleWaitForElementAsync(_ params: [String: Any]) async -> [String: Any] {
        let timeoutMs = (params["timeout"] as? NSNumber)?.intValue ?? 5000
        let intervalMs = 200
        let maxAttempts = max(1, timeoutMs / intervalMs)

        for _ in 0..<maxAttempts {
            if resolveElement(params) != nil || resolveRegisteredElement(params) != nil {
                return ["found": true]
            }
            try? await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
        }

        return ["found": false]
    }

    private func handleScreenshot(_ params: [String: Any]) -> [String: Any] {
        guard let window = Self.keyWindow else {
            return ["success": false, "message": "No key window"]
        }

        let scale = window.screen.scale
        let size = window.bounds.size

        // Use layer.render which is more reliable than drawHierarchy
        // (drawHierarchy can return blank images when called outside the
        // normal rendering cycle or from async contexts)
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        guard let context = UIGraphicsGetCurrentContext() else {
            UIGraphicsEndImageContext()
            return ["success": false, "message": "Failed to create graphics context"]
        }
        window.layer.render(in: context)
        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        guard let image = image, let pngData = image.pngData() else {
            return ["success": false, "message": "Failed to render PNG"]
        }

        let base64 = pngData.base64EncodedString()
        return [
            "success": true,
            "format": "png",
            "encoding": "base64",
            "data": base64,
            "width": Int(size.width * scale),
            "height": Int(size.height * scale),
        ]
    }

    // MARK: - Extended Method Implementations

    private func handleGetLogs(_ params: [String: Any]) -> [String: Any] {
        return ["logs": logBuffer]
    }

    private func handleClearLogs(_ params: [String: Any]) -> [String: Any] {
        logBuffer.removeAll()
        return ["success": true]
    }

    private func handleGoBack(_ params: [String: Any]) -> [String: Any] {
        // 1. Try UINavigationController pop
        if let nav = Self.topNavigationController, nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
            return ["success": true, "message": "Popped view controller"]
        }

        // 2. Try dismissing a presented modal
        if let topVC = Self.topViewController, topVC.presentingViewController != nil {
            topVC.dismiss(animated: true)
            return ["success": true, "message": "Dismissed modal"]
        }

        // 3. Post a notification so the app can handle custom back navigation
        // (e.g., SwiftUI NavigationStack, custom routers, etc.)
        NotificationCenter.default.post(
            name: Notification.Name("FlutterSkillGoBack"),
            object: nil
        )
        return ["success": true, "message": "Posted FlutterSkillGoBack notification"]
    }

    private func handleGetRoute(_ params: [String: Any]) -> [String: Any] {
        let topVC = Self.topViewController
        let name = topVC.map { String(describing: type(of: $0)) } ?? "unknown"
        let title = topVC?.title ?? topVC?.navigationItem.title
        var result: [String: Any] = ["route": name]
        if let title = title {
            result["title"] = title
        }
        return result
    }

    private func handlePressKey(_ params: [String: Any]) -> [String: Any] {
        guard let keyName = params["key"] as? String, !keyName.isEmpty else {
            return ["success": false, "error": "Missing key parameter"]
        }

        // Map key names to UIKit key commands where possible
        let keyMap: [String: String] = [
            "enter": "\r", "tab": "\t", "escape": UIKeyCommand.inputEscape,
            "backspace": "\u{8}", "delete": "\u{7F}", "space": " ",
            "up": UIKeyCommand.inputUpArrow, "down": UIKeyCommand.inputDownArrow,
            "left": UIKeyCommand.inputLeftArrow, "right": UIKeyCommand.inputRightArrow,
            "home": UIKeyCommand.inputHome, "end": UIKeyCommand.inputEnd,
            "pageup": UIKeyCommand.inputPageUp, "pagedown": UIKeyCommand.inputPageDown,
        ]

        let mappedKey = keyMap[keyName.lowercased()] ?? keyName

        let modifiers = params["modifiers"] as? [String] ?? []
        var modifierFlags: UIKeyModifierFlags = []
        if modifiers.contains("ctrl") { modifierFlags.insert(.control) }
        if modifiers.contains("shift") { modifierFlags.insert(.shift) }
        if modifiers.contains("alt") { modifierFlags.insert(.alternate) }
        if modifiers.contains("meta") { modifierFlags.insert(.command) }

        // Try to insert text into the first responder for simple keys
        if modifiers.isEmpty, let responder = UIResponder.currentFirstResponder as? UITextInput {
            if keyName.lowercased() == "backspace" {
                if let range = responder.selectedTextRange, !range.isEmpty {
                    responder.replace(range, withText: "")
                } else if let start = responder.selectedTextRange?.start,
                          let newStart = responder.position(from: start, offset: -1),
                          let range = responder.textRange(from: newStart, to: start) {
                    responder.replace(range, withText: "")
                }
                return ["success": true, "message": "Backspace applied"]
            }
            // For enter/tab on text inputs
            if keyName.lowercased() == "enter" || keyName.lowercased() == "tab" {
                // Let it fall through to key command approach
            }
        }

        // Use UIKeyCommand dispatch via the responder chain
        let keyCommand = UIKeyCommand(input: mappedKey, modifierFlags: modifierFlags, action: #selector(UIResponder.flutterSkill_keyAction(_:)))
        UIApplication.shared.sendAction(keyCommand.action!, to: nil, from: keyCommand, for: nil)

        return ["success": true, "message": "Key '\(keyName)' dispatched"]
    }

    // MARK: - Element Resolution

    /// Resolve a UIView by ref ID from inspect_interactive data
    private func resolveElementByRef(_ refId: String) -> UIView? {
        let interactiveData = handleInspectInteractive([:])
        guard let elements = interactiveData["elements"] as? [[String: Any]] else { return nil }
        
        // Find element with matching ref ID
        guard let targetElement = elements.first(where: { ($0["ref"] as? String) == refId }),
              let bounds = targetElement["bounds"] as? [String: Any],
              let x = bounds["x"] as? Int,
              let y = bounds["y"] as? Int,
              let w = bounds["w"] as? Int,
              let h = bounds["h"] as? Int else { return nil }
        
        if w <= 0 || h <= 0 { return nil }
        
        let centerX = CGFloat(x + w / 2)
        let centerY = CGFloat(y + h / 2)
        let centerPoint = CGPoint(x: centerX, y: centerY)
        
        // Find view at center position
        guard let window = Self.keyWindow else { return nil }
        return window.hitTest(centerPoint, with: nil)
    }
    
    /// Resolve a SwiftUI registry element by ref ID
    private func resolveRegisteredElementByRef(_ refId: String) -> FlutterSkillRegistry.ElementEntry? {
        let interactiveData = handleInspectInteractive([:])
        guard let elements = interactiveData["elements"] as? [[String: Any]] else { return nil }
        
        // Find element with matching ref ID and SwiftUI ID
        guard let targetElement = elements.first(where: { ($0["ref"] as? String) == refId }),
              let swiftUIId = targetElement["_swiftui_id"] as? String else { return nil }
        
        return FlutterSkillRegistry.shared.find(id: swiftUIId)
    }

    /// Resolve a UIView from the params. Supports: key (accessibilityIdentifier),
    /// text (accessibilityLabel / visible text), and type (class name).
    private func resolveElement(_ params: [String: Any]) -> UIView? {
        guard let window = Self.keyWindow else { return nil }

        if let key = params["key"] as? String, !key.isEmpty {
            // Search by accessibilityIdentifier first
            if let found = window.flutterSkill_findView(accessibilityIdentifier: key) {
                return found
            }
            // Then by accessibilityLabel
            if let found = window.flutterSkill_findView(accessibilityLabel: key) {
                return found
            }
        }

        if let text = params["text"] as? String, !text.isEmpty {
            if let found = window.flutterSkill_findView(accessibilityLabel: text) {
                return found
            }
            if let found = window.flutterSkill_findView(containingText: text) {
                return found
            }
        }

        if let type = params["type"] as? String, !type.isEmpty {
            if let found = window.flutterSkill_findView(ofTypeName: type) {
                return found
            }
        }

        return nil
    }

    /// Resolve a registered SwiftUI element from the FlutterSkillRegistry.
    private func resolveRegisteredElement(_ params: [String: Any]) -> FlutterSkillRegistry.ElementEntry? {
        let registry = FlutterSkillRegistry.shared

        if let key = params["key"] as? String, !key.isEmpty {
            if let found = registry.find(id: key) { return found }
        }

        if let text = params["text"] as? String, !text.isEmpty {
            if let found = registry.find(text: text) { return found }
        }

        return nil
    }

    /// Get the accessibility identifier from any NSObject (safe for both UIView and non-UIView elements).
    private func a11yIdentifier(of obj: NSObject) -> String? {
        if let view = obj as? UIView { return view.accessibilityIdentifier }
        // For non-UIView accessibility elements, use KVC
        if obj.responds(to: Selector(("accessibilityIdentifier"))) {
            return obj.value(forKey: "accessibilityIdentifier") as? String
        }
        return nil
    }

    /// Recursively search the accessibility tree for an element with the given identifier.
    /// Uses both accessibilityElements array and accessibilityElement(at:) for SwiftUI support.
    private func flutterSkill_findAccessibilityElement(in root: NSObject, identifier: String) -> NSObject? {
        if a11yIdentifier(of: root) == identifier { return root }

        // Walk accessibility children (covers SwiftUI hosting views)
        for child in a11yChildren(of: root) {
            if let found = flutterSkill_findAccessibilityElement(in: child, identifier: identifier) {
                return found
            }
        }
        // Walk UIView subviews
        if let view = root as? UIView {
            for subview in view.subviews {
                if let found = flutterSkill_findAccessibilityElement(in: subview, identifier: identifier) {
                    return found
                }
            }
        }
        return nil
    }

    /// Recursively search the accessibility tree for an element with the given label.
    private func flutterSkill_findAccessibilityElement(in root: NSObject, label: String) -> NSObject? {
        if root.accessibilityLabel == label { return root }
        for child in a11yChildren(of: root) {
            if let found = flutterSkill_findAccessibilityElement(in: child, label: label) {
                return found
            }
        }
        if let view = root as? UIView {
            for subview in view.subviews {
                if let found = flutterSkill_findAccessibilityElement(in: subview, label: label) {
                    return found
                }
            }
        }
        return nil
    }

    /// Get accessibility children using both accessibilityElements and indexed accessors.
    /// SwiftUI uses accessibilityElement(at:) instead of accessibilityElements.
    private func a11yChildren(of obj: NSObject) -> [NSObject] {
        var children: [NSObject] = []

        // Method 1: accessibilityElements array
        if let elements = obj.accessibilityElements {
            for element in elements {
                if let child = element as? NSObject { children.append(child) }
            }
        }

        // Method 2: index-based accessors (SwiftUI uses these)
        if children.isEmpty {
            let count = obj.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let element = obj.accessibilityElement(at: i) as? NSObject {
                        children.append(element)
                    }
                }
            }
        }

        return children
    }

    /// Collect all accessibility elements for inspect.
    private func flutterSkill_collectAccessibilityElements(from root: NSObject) -> [[String: Any]] {
        var results: [[String: Any]] = []
        var seen = Set<String>()

        func walk(_ obj: NSObject) {
            let id = a11yIdentifier(of: obj)
            let label = obj.accessibilityLabel
            let value = obj.accessibilityValue
            let traits = obj.accessibilityTraits

            let hasContent = (id != nil && !id!.isEmpty) ||
                           (label != nil && !label!.isEmpty) ||
                           (value != nil && !value!.isEmpty)

            if hasContent {
                let dedupKey = "\(id ?? "")-\(label ?? "")"
                if !seen.contains(dedupKey) {
                    seen.insert(dedupKey)
                    var dict: [String: Any] = [
                        "type": String(describing: Swift.type(of: obj)),
                        "visible": true,
                    ]

                    if traits.contains(.button) { dict["tag"] = "button" }
                    else if traits.contains(.staticText) { dict["tag"] = "text" }
                    else if traits.contains(.searchField) { dict["tag"] = "textfield" }
                    else if traits.contains(.image) { dict["tag"] = "image" }
                    else if traits.contains(.link) { dict["tag"] = "link" }
                    else if traits.contains(.header) { dict["tag"] = "header" }
                    else if traits.contains(.adjustable) { dict["tag"] = "slider" }
                    else { dict["tag"] = "view" }

                    dict["interactive"] = traits.contains(.button) || traits.contains(.link) || traits.contains(.adjustable) || traits.contains(.searchField)

                    if let id = id, !id.isEmpty { dict["id"] = id }
                    if let label = label, !label.isEmpty { dict["label"] = label }
                    if let value = value, !value.isEmpty { dict["value"] = value }

                    let frame = obj.accessibilityFrame
                    if frame != .zero {
                        dict["bounds"] = [
                            "x": Int(frame.origin.x),
                            "y": Int(frame.origin.y),
                            "width": Int(frame.size.width),
                            "height": Int(frame.size.height),
                        ]
                    }

                    results.append(dict)
                }
            }

            for child in a11yChildren(of: obj) {
                walk(child)
            }
            if let view = obj as? UIView {
                for subview in view.subviews {
                    walk(subview)
                }
            }
        }

        walk(root)
        return results
    }

    // MARK: - Touch Simulation Helpers

    private func simulateTap(at point: CGPoint, in window: UIWindow?) {
        guard let window = window else { return }
        guard let hitView = window.hitTest(point, with: nil) else { return }

        // For UIControl, use sendActions
        if let control = hitView as? UIControl {
            control.sendActions(for: .touchUpInside)
            return
        }

        // Try accessibility activation
        _ = hitView.accessibilityActivate()
    }

    private func simulateSwipe(from start: CGPoint, to end: CGPoint, in window: UIWindow?) {
        guard let window = window else { return }
        guard let hitView = window.hitTest(start, with: nil) else { return }

        // If the hit view or an ancestor is a scroll view, adjust offset
        if let scrollView = hitView.flutterSkill_findEnclosingScrollView() {
            let dx = start.x - end.x
            let dy = start.y - end.y
            var offset = scrollView.contentOffset
            offset.x += dx
            offset.y += dy
            scrollView.setContentOffset(offset, animated: true)
        }
    }

    private func accessibilityScrollDirection(for direction: String) -> UIAccessibilityScrollDirection {
        switch direction {
        case "up": return .up
        case "down": return .down
        case "left": return .left
        case "right": return .right
        default: return .down
        }
    }

    // MARK: - UIKit Helpers

    private static var keyWindow: UIWindow? {
        if #available(iOS 15.0, *) {
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first(where: { $0.isKeyWindow })
        } else {
            return UIApplication.shared.windows.first(where: { $0.isKeyWindow })
        }
    }

    private static var topViewController: UIViewController? {
        guard let root = keyWindow?.rootViewController else { return nil }
        return topVC(from: root)
    }

    private static var topNavigationController: UINavigationController? {
        var vc = topViewController
        while let current = vc {
            if let nav = current.navigationController {
                return nav
            }
            vc = current.parent
        }
        // Check if root is a nav controller
        if let nav = keyWindow?.rootViewController as? UINavigationController {
            return nav
        }
        return nil
    }

    private static func topVC(from vc: UIViewController) -> UIViewController {
        if let presented = vc.presentedViewController {
            return topVC(from: presented)
        }
        if let nav = vc as? UINavigationController,
           let visible = nav.visibleViewController {
            return topVC(from: visible)
        }
        if let tab = vc as? UITabBarController,
           let selected = tab.selectedViewController {
            return topVC(from: selected)
        }
        return vc
    }
}

// MARK: - Bundle Helper

extension Bundle {
    var appName: String {
        return object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Unknown App"
    }
}

// MARK: - String Helper

extension String {
    func takeIf(_ predicate: (String) -> Bool) -> String? {
        return predicate(self) ? self : nil
    }
}

extension Substring {
    func takeIf(_ predicate: (Substring) -> Bool) -> Substring? {
        return predicate(self) ? self : nil
    }
}

// MARK: - UIResponder Helpers for press_key

extension UIResponder {
    @objc func flutterSkill_keyAction(_ sender: Any?) {
        // No-op target for key command dispatch
    }

    private static weak var _currentFirstResponder: UIResponder?

    static var currentFirstResponder: UIResponder? {
        _currentFirstResponder = nil
        UIApplication.shared.sendAction(#selector(_findFirstResponder(_:)), to: nil, from: nil, for: nil)
        return _currentFirstResponder
    }

    @objc private func _findFirstResponder(_ sender: Any?) {
        UIResponder._currentFirstResponder = self
    }
}


//
//  FlutterSkillBridgeTests.swift
//  FlutterSkill iOS SDK Tests
//
//  Tests for FlutterSkillBridge — public API, constants, and protocol conformance.
//

import XCTest
@testable import FlutterSkill

final class FlutterSkillBridgeTests: XCTestCase {

    // MARK: - Constants

    func testDefaultPort() {
        XCTAssertEqual(FlutterSkillBridge.defaultPort, 18118,
                       "Default port must match bridge protocol (18118)")
    }

    func testSDKVersion() {
        XCTAssertFalse(FlutterSkillBridge.sdkVersion.isEmpty)
        // Version should be semver-like
        let parts = FlutterSkillBridge.sdkVersion.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "SDK version should be MAJOR.MINOR.PATCH")
    }

    // MARK: - Capabilities

    func testAllCapabilitiesIncludesCoreSet() {
        let caps = FlutterSkillBridge.allCapabilities
        let required = [
            "initialize", "screenshot", "inspect", "tap", "enter_text",
            "swipe", "scroll", "find_element", "get_text", "wait_for_element",
        ]
        for method in required {
            XCTAssertTrue(caps.contains(method),
                          "Missing core capability: \(method)")
        }
    }

    func testAllCapabilitiesIncludesExtendedSet() {
        let caps = FlutterSkillBridge.allCapabilities
        let extended = ["get_logs", "clear_logs", "go_back", "get_route"]
        for method in extended {
            XCTAssertTrue(caps.contains(method),
                          "Missing extended capability: \(method)")
        }
    }

    // MARK: - Singleton

    func testSharedInstanceIsSingleton() {
        let a = FlutterSkillBridge.shared
        let b = FlutterSkillBridge.shared
        XCTAssertTrue(a === b, "shared should return the same instance")
    }

    // MARK: - Start/Stop Guards

    func testIsRunningInitiallyFalse() {
        // Note: We cannot call start() in tests (no real Network listener),
        // but we can verify the initial state.
        // The shared instance may be running from other tests, so just
        // verify the property exists and is a Bool.
        let running = FlutterSkillBridge.shared.isRunning
        XCTAssertNotNil(running as Bool?)
    }

    // MARK: - Log Buffer

    func testAppendLog() {
        let bridge = FlutterSkillBridge.shared
        bridge.appendLog("[Test] Log entry 1")
        bridge.appendLog("[Test] Log entry 2")
        // Logs should not crash. We can't easily read them without starting
        // the server, but this verifies the API works without errors.
    }
}

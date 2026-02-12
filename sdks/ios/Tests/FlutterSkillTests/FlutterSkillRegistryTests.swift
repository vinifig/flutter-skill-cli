//
//  FlutterSkillRegistryTests.swift
//  FlutterSkill iOS SDK Tests
//
//  Tests for FlutterSkillRegistry — the SwiftUI element registration system.
//

import XCTest
@testable import FlutterSkill

final class FlutterSkillRegistryTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Clear the registry before each test
        for entry in FlutterSkillRegistry.shared.allElements() {
            FlutterSkillRegistry.shared.unregister(id: entry.id)
        }
    }

    // MARK: - Registration

    func testRegisterAndFind() {
        let entry = FlutterSkillRegistry.ElementEntry(
            id: "test-btn",
            text: { "Hello" },
            onTap: nil,
            onSetText: nil,
            label: "Test Button",
            tag: "button",
            frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry)

        let found = FlutterSkillRegistry.shared.find(id: "test-btn")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "test-btn")
        XCTAssertEqual(found?.tag, "button")
        XCTAssertEqual(found?.label, "Test Button")
        XCTAssertEqual(found?.text(), "Hello")
    }

    func testUnregister() {
        let entry = FlutterSkillRegistry.ElementEntry(
            id: "remove-me",
            text: { nil },
            onTap: nil,
            onSetText: nil,
            label: nil,
            tag: "view",
            frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry)
        XCTAssertNotNil(FlutterSkillRegistry.shared.find(id: "remove-me"))

        FlutterSkillRegistry.shared.unregister(id: "remove-me")
        XCTAssertNil(FlutterSkillRegistry.shared.find(id: "remove-me"))
    }

    func testFindByText() {
        let entry = FlutterSkillRegistry.ElementEntry(
            id: "text-el",
            text: { "Submit Order" },
            onTap: nil,
            onSetText: nil,
            label: nil,
            tag: "button",
            frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry)

        let found = FlutterSkillRegistry.shared.find(text: "Submit Order")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "text-el")
    }

    func testFindByLabel() {
        let entry = FlutterSkillRegistry.ElementEntry(
            id: "label-el",
            text: { nil },
            onTap: nil,
            onSetText: nil,
            label: "My Label",
            tag: "text",
            frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry)

        let found = FlutterSkillRegistry.shared.find(text: "My Label")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, "label-el")
    }

    func testFindNotFound() {
        XCTAssertNil(FlutterSkillRegistry.shared.find(id: "nonexistent"))
        XCTAssertNil(FlutterSkillRegistry.shared.find(text: "nonexistent"))
    }

    // MARK: - Frame Updates

    func testUpdateFrame() {
        let entry = FlutterSkillRegistry.ElementEntry(
            id: "frame-el",
            text: { nil },
            onTap: nil,
            onSetText: nil,
            label: nil,
            tag: "view",
            frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry)
        XCTAssertEqual(FlutterSkillRegistry.shared.find(id: "frame-el")?.frame, .zero)

        let newFrame = CGRect(x: 10, y: 20, width: 100, height: 50)
        FlutterSkillRegistry.shared.updateFrame(id: "frame-el", frame: newFrame)
        XCTAssertEqual(FlutterSkillRegistry.shared.find(id: "frame-el")?.frame, newFrame)
    }

    // MARK: - Text Updates

    func testUpdateText() {
        var currentText = "initial"
        let entry = FlutterSkillRegistry.ElementEntry(
            id: "dynamic-text",
            text: { currentText },
            onTap: nil,
            onSetText: nil,
            label: nil,
            tag: "text",
            frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry)
        XCTAssertEqual(FlutterSkillRegistry.shared.find(id: "dynamic-text")?.text(), "initial")

        currentText = "updated"
        XCTAssertEqual(FlutterSkillRegistry.shared.find(id: "dynamic-text")?.text(), "updated")
    }

    // MARK: - All Elements

    func testAllElements() {
        let entry1 = FlutterSkillRegistry.ElementEntry(
            id: "el-1", text: { nil }, onTap: nil, onSetText: nil,
            label: nil, tag: "view", frame: .zero
        )
        let entry2 = FlutterSkillRegistry.ElementEntry(
            id: "el-2", text: { nil }, onTap: nil, onSetText: nil,
            label: nil, tag: "button", frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry1)
        FlutterSkillRegistry.shared.register(entry2)

        let all = FlutterSkillRegistry.shared.allElements()
        XCTAssertEqual(all.count, 2)

        let ids = Set(all.map(\.id))
        XCTAssertTrue(ids.contains("el-1"))
        XCTAssertTrue(ids.contains("el-2"))
    }

    // MARK: - Overwrite

    func testRegisterOverwrites() {
        let entry1 = FlutterSkillRegistry.ElementEntry(
            id: "same-id", text: { "first" }, onTap: nil, onSetText: nil,
            label: nil, tag: "text", frame: .zero
        )
        let entry2 = FlutterSkillRegistry.ElementEntry(
            id: "same-id", text: { "second" }, onTap: nil, onSetText: nil,
            label: nil, tag: "button", frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry1)
        FlutterSkillRegistry.shared.register(entry2)

        let found = FlutterSkillRegistry.shared.find(id: "same-id")
        XCTAssertEqual(found?.text(), "second")
        XCTAssertEqual(found?.tag, "button")
        XCTAssertEqual(FlutterSkillRegistry.shared.allElements().count, 1)
    }

    // MARK: - Callbacks

    func testOnTapCallback() {
        var tapped = false
        let entry = FlutterSkillRegistry.ElementEntry(
            id: "tap-btn", text: { nil },
            onTap: { tapped = true },
            onSetText: nil,
            label: nil, tag: "button", frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry)

        let found = FlutterSkillRegistry.shared.find(id: "tap-btn")
        found?.onTap?()
        XCTAssertTrue(tapped)
    }

    func testOnSetTextCallback() {
        var receivedText = ""
        let entry = FlutterSkillRegistry.ElementEntry(
            id: "text-input", text: { receivedText },
            onTap: nil,
            onSetText: { newText in receivedText = newText },
            label: nil, tag: "textfield", frame: .zero
        )

        FlutterSkillRegistry.shared.register(entry)

        let found = FlutterSkillRegistry.shared.find(id: "text-input")
        found?.onSetText?("Hello World")
        XCTAssertEqual(receivedText, "Hello World")
        XCTAssertEqual(found?.text(), "Hello World")
    }

    // MARK: - Thread Safety

    func testConcurrentAccess() {
        let expectation = XCTestExpectation(description: "Concurrent registry access")
        expectation.expectedFulfillmentCount = 100

        for i in 0..<100 {
            DispatchQueue.global().async {
                let entry = FlutterSkillRegistry.ElementEntry(
                    id: "concurrent-\(i)", text: { nil }, onTap: nil, onSetText: nil,
                    label: nil, tag: "view", frame: .zero
                )
                FlutterSkillRegistry.shared.register(entry)
                _ = FlutterSkillRegistry.shared.find(id: "concurrent-\(i)")
                _ = FlutterSkillRegistry.shared.allElements()
                FlutterSkillRegistry.shared.unregister(id: "concurrent-\(i)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
    }
}

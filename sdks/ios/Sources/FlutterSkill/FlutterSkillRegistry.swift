//
//  FlutterSkillRegistry.swift
//  FlutterSkill iOS SDK
//
//  Element registry for SwiftUI. SwiftUI views register themselves
//  using .flutterSkillId() modifier, enabling the bridge to find and
//  interact with them at runtime.
//

import Foundation
import SwiftUI

// MARK: - Element Registry

/// Stores registered SwiftUI element metadata for bridge interaction.
public final class FlutterSkillRegistry: @unchecked Sendable {

    public static let shared = FlutterSkillRegistry()

    /// Registered element entries.
    private var elements: [String: ElementEntry] = [:]
    private let lock = NSLock()

    /// Describes a registered element.
    struct ElementEntry {
        let id: String
        var text: () -> String?
        var onTap: (() -> Void)?
        var onSetText: ((String) -> Void)?
        var label: String?
        var tag: String
        var frame: CGRect
    }

    func register(_ entry: ElementEntry) {
        lock.lock()
        elements[entry.id] = entry
        lock.unlock()
    }

    func unregister(id: String) {
        lock.lock()
        elements.removeValue(forKey: id)
        lock.unlock()
    }

    func updateFrame(id: String, frame: CGRect) {
        lock.lock()
        elements[id]?.frame = frame
        lock.unlock()
    }

    func updateText(id: String, text: @escaping () -> String?) {
        lock.lock()
        elements[id]?.text = text
        lock.unlock()
    }

    func find(id: String) -> ElementEntry? {
        lock.lock()
        defer { lock.unlock() }
        return elements[id]
    }

    func find(text: String) -> ElementEntry? {
        lock.lock()
        defer { lock.unlock() }
        return elements.values.first { entry in
            entry.text() == text || entry.label == text
        }
    }

    func allElements() -> [ElementEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(elements.values)
    }
}

// MARK: - SwiftUI View Modifiers

public extension View {
    /// Register this view with the Flutter Skill bridge for testing.
    /// Use like: Button("Tap me") { ... }.flutterSkillId("my-button")
    func flutterSkillId(_ id: String, tag: String = "view") -> some View {
        self.modifier(FlutterSkillIdModifier(id: id, tag: tag))
    }

    /// Register a button with the Flutter Skill bridge.
    func flutterSkillButton(_ id: String, action: @escaping () -> Void) -> some View {
        self.modifier(FlutterSkillButtonModifier(id: id, action: action))
    }

    /// Register a text element with the Flutter Skill bridge.
    func flutterSkillText(_ id: String, text: @escaping () -> String?) -> some View {
        self.modifier(FlutterSkillTextModifier(id: id, getText: text))
    }

    /// Register a text field with the Flutter Skill bridge for text entry automation.
    /// Use like: TextField("Name", text: $name).flutterSkillTextField("name-field", text: $name)
    func flutterSkillTextField(_ id: String, text: Binding<String>) -> some View {
        self.modifier(FlutterSkillTextFieldModifier(id: id, text: text))
    }
}

// MARK: - Modifiers

struct FlutterSkillIdModifier: ViewModifier {
    let id: String
    let tag: String

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id)
            .background(GeometryReader { geo in
                Color.clear.onAppear {
                    let frame = geo.frame(in: .global)
                    FlutterSkillRegistry.shared.register(.init(
                        id: id, text: { nil }, onTap: nil, onSetText: nil,
                        label: nil, tag: tag, frame: frame
                    ))
                }.onChange(of: geo.frame(in: .global)) { newFrame in
                    FlutterSkillRegistry.shared.updateFrame(id: id, frame: newFrame)
                }
            })
            .onDisappear {
                FlutterSkillRegistry.shared.unregister(id: id)
            }
    }
}

struct FlutterSkillButtonModifier: ViewModifier {
    let id: String
    let action: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id)
            .background(GeometryReader { geo in
                Color.clear.onAppear {
                    let frame = geo.frame(in: .global)
                    FlutterSkillRegistry.shared.register(.init(
                        id: id, text: { nil }, onTap: action, onSetText: nil,
                        label: nil, tag: "button", frame: frame
                    ))
                }.onChange(of: geo.frame(in: .global)) { newFrame in
                    FlutterSkillRegistry.shared.updateFrame(id: id, frame: newFrame)
                }
            })
            .onDisappear {
                FlutterSkillRegistry.shared.unregister(id: id)
            }
    }
}

struct FlutterSkillTextModifier: ViewModifier {
    let id: String
    let getText: () -> String?

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id)
            .background(GeometryReader { geo in
                Color.clear.onAppear {
                    let frame = geo.frame(in: .global)
                    FlutterSkillRegistry.shared.register(.init(
                        id: id, text: getText, onTap: nil, onSetText: nil,
                        label: nil, tag: "text", frame: frame
                    ))
                }.onChange(of: geo.frame(in: .global)) { newFrame in
                    FlutterSkillRegistry.shared.updateFrame(id: id, frame: newFrame)
                }
            })
            .onDisappear {
                FlutterSkillRegistry.shared.unregister(id: id)
            }
    }
}

struct FlutterSkillTextFieldModifier: ViewModifier {
    let id: String
    @Binding var text: String

    func body(content: Content) -> some View {
        content
            .accessibilityIdentifier(id)
            .background(GeometryReader { geo in
                Color.clear.onAppear {
                    let frame = geo.frame(in: .global)
                    FlutterSkillRegistry.shared.register(.init(
                        id: id, text: { text }, onTap: nil,
                        onSetText: { newText in text = newText },
                        label: nil, tag: "textfield", frame: frame
                    ))
                }.onChange(of: geo.frame(in: .global)) { newFrame in
                    FlutterSkillRegistry.shared.updateFrame(id: id, frame: newFrame)
                }
            })
            .onDisappear {
                FlutterSkillRegistry.shared.unregister(id: id)
            }
    }
}

//
//  FlutterSkillBridge+ViewTraversal.swift
//  FlutterSkill iOS SDK
//
//  UIView hierarchy traversal helpers for element inspection and lookup.
//

import Foundation
import UIKit

// MARK: - Element Descriptor

/// Describes a UI element in a format matching the bridge protocol.
struct ElementDescriptor {
    let tag: String
    let identifier: String?
    let label: String?
    let text: String?
    let type: String
    let bounds: CGRect
    let visible: Bool
    let interactive: Bool

    init(view: UIView) {
        self.type = String(describing: Swift.type(of: view))
        self.tag = Self.semanticTag(for: view)
        self.identifier = view.accessibilityIdentifier
        self.label = view.accessibilityLabel
        self.text = Self.extractText(from: view)
        self.visible = !view.isHidden && view.alpha > 0.01 && view.frame.size != .zero
        self.interactive = Self.isInteractive(view)

        // Convert bounds to window coordinates
        if let window = view.window {
            self.bounds = view.convert(view.bounds, to: window)
        } else {
            self.bounds = view.frame
        }
    }

    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "tag": tag,
            "type": type,
            "bounds": [
                "x": Int(bounds.origin.x),
                "y": Int(bounds.origin.y),
                "width": Int(bounds.size.width),
                "height": Int(bounds.size.height),
            ],
            "visible": visible,
            "interactive": interactive,
        ]
        if let identifier = identifier {
            dict["id"] = identifier
        }
        if let label = label {
            dict["label"] = label
        }
        if let text = text, !text.isEmpty {
            // Truncate long text
            dict["text"] = String(text.prefix(200))
        }
        return dict
    }

    // MARK: Helpers

    private static func semanticTag(for view: UIView) -> String {
        switch view {
        case is UIButton: return "button"
        case is UILabel: return "text"
        case is UITextField: return "textfield"
        case is UITextView: return "textview"
        case is UISwitch: return "switch"
        case is UISlider: return "slider"
        case is UIStepper: return "stepper"
        case is UISegmentedControl: return "segmented"
        case is UIImageView: return "image"
        case is UITableView: return "table"
        case is UICollectionView: return "collection"
        case is UIScrollView: return "scrollview"
        case is UIStackView: return "stack"
        case is UIPickerView: return "picker"
        case is UIDatePicker: return "datepicker"
        case is UIProgressView: return "progress"
        case is UIActivityIndicatorView: return "activity"
        case is UITabBar: return "tabbar"
        case is UINavigationBar: return "navbar"
        case is UIToolbar: return "toolbar"
        case is UISearchBar: return "searchbar"
        default: return "view"
        }
    }

    private static func extractText(from view: UIView) -> String? {
        if let label = view as? UILabel { return label.text }
        if let textField = view as? UITextField { return textField.text }
        if let textView = view as? UITextView { return textView.text }
        if let button = view as? UIButton { return button.titleLabel?.text }
        if let searchBar = view as? UISearchBar { return searchBar.text }
        // Fall back to accessibility label
        return view.accessibilityLabel
    }

    private static func isInteractive(_ view: UIView) -> Bool {
        if !view.isUserInteractionEnabled { return false }
        if view is UIControl { return true }
        if view is UITextField { return true }
        if view is UITextView { return (view as! UITextView).isEditable }
        if view is UISearchBar { return true }
        // SwiftUI buttons expose .button trait on the underlying UIKit view
        if view.accessibilityTraits.contains(.button) { return true }
        // Check for tap gesture recognizers
        if let gestures = view.gestureRecognizers {
            for gesture in gestures {
                if gesture is UITapGestureRecognizer { return true }
                if gesture is UILongPressGestureRecognizer { return true }
            }
        }
        return false
    }
}

// MARK: - UIView Traversal Extensions

extension UIView {

    /// Collect all interactive elements in the hierarchy.
    func flutterSkill_interactiveElements() -> [ElementDescriptor] {
        var results: [ElementDescriptor] = []
        var seenIdentifiers = Set<String>()
        flutterSkill_walkHierarchy { view in
            let desc = ElementDescriptor(view: view)
            guard desc.visible else { return }

            // Dedup by accessibility identifier to avoid SwiftUI wrapper duplicates
            if let id = view.accessibilityIdentifier, !id.isEmpty {
                if seenIdentifiers.contains(id) { return }
                seenIdentifiers.insert(id)
            }

            if desc.interactive {
                results.append(desc)
            }
            // Include views with accessibility identifiers (SwiftUI uses these)
            else if view.accessibilityIdentifier != nil {
                results.append(desc)
            }
            // Include SwiftUI accessibility elements (Text, Image, etc.)
            else if view.isAccessibilityElement && (view.accessibilityLabel != nil || view.accessibilityValue != nil) {
                results.append(desc)
            }
            // Include UIKit labels and text views
            else if desc.text != nil && !desc.text!.isEmpty {
                switch view {
                case is UILabel, is UITextField, is UITextView:
                    results.append(desc)
                default:
                    break
                }
            }
        }
        return results
    }

    /// Recursively walk the view hierarchy, calling the visitor for each view.
    func flutterSkill_walkHierarchy(_ visitor: (UIView) -> Void) {
        visitor(self)
        for subview in subviews {
            subview.flutterSkill_walkHierarchy(visitor)
        }
    }

    /// Walk the accessibility element tree (for SwiftUI views that don't use UIKit subviews).
    /// Returns accessibility elements as (identifier, label, value, traits, view) tuples.
    func flutterSkill_walkAccessibilityElements(_ visitor: (NSObject) -> Void) {
        // Check if this view exposes custom accessibility elements
        if let elements = self.accessibilityElements {
            for element in elements {
                if let obj = element as? NSObject {
                    visitor(obj)
                    // If it's also a UIView, recurse into it
                    if let view = obj as? UIView {
                        view.flutterSkill_walkAccessibilityElements(visitor)
                    }
                }
            }
        }
        // Also recurse into subviews
        for subview in subviews {
            subview.flutterSkill_walkAccessibilityElements(visitor)
        }
    }

    /// Find a view by its accessibilityIdentifier (exact match).
    /// Also searches SwiftUI accessibility elements that are UIViews.
    func flutterSkill_findView(accessibilityIdentifier id: String) -> UIView? {
        if self.accessibilityIdentifier == id { return self }
        // Check accessibility elements that are UIViews (for SwiftUI)
        if let elements = self.accessibilityElements {
            for element in elements {
                if let view = element as? UIView {
                    if let found = view.flutterSkill_findView(accessibilityIdentifier: id) {
                        return found
                    }
                }
            }
        }
        for subview in subviews {
            if let found = subview.flutterSkill_findView(accessibilityIdentifier: id) {
                return found
            }
        }
        return nil
    }

    /// Find a view by its accessibilityLabel (exact match).
    func flutterSkill_findView(accessibilityLabel label: String) -> UIView? {
        if self.accessibilityLabel == label { return self }
        for subview in subviews {
            if let found = subview.flutterSkill_findView(accessibilityLabel: label) {
                return found
            }
        }
        return nil
    }

    /// Find a view containing the given text (in UILabel, UITextField, UIButton, etc.).
    func flutterSkill_findView(containingText text: String) -> UIView? {
        if let label = self as? UILabel, label.text?.contains(text) == true { return self }
        if let tf = self as? UITextField, tf.text?.contains(text) == true { return self }
        if let tv = self as? UITextView, tv.text?.contains(text) == true { return self }
        if let btn = self as? UIButton, btn.titleLabel?.text?.contains(text) == true { return self }

        for subview in subviews {
            if let found = subview.flutterSkill_findView(containingText: text) {
                return found
            }
        }
        return nil
    }

    /// Find a view by its class name (e.g., "UIButton", "CustomView").
    func flutterSkill_findView(ofTypeName name: String) -> UIView? {
        let myType = String(describing: Swift.type(of: self))
        if myType == name || myType.hasSuffix(".\(name)") { return self }
        for subview in subviews {
            if let found = subview.flutterSkill_findView(ofTypeName: name) {
                return found
            }
        }
        return nil
    }

    /// Walk up the hierarchy to find the nearest enclosing UIScrollView.
    func flutterSkill_findEnclosingScrollView() -> UIScrollView? {
        var current: UIView? = self
        while let view = current {
            if let sv = view as? UIScrollView { return sv }
            current = view.superview
        }
        return nil
    }

    /// Find the first UIScrollView in the hierarchy (breadth-first).
    func flutterSkill_findFirstScrollView() -> UIScrollView? {
        var queue: [UIView] = [self]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let sv = view as? UIScrollView { return sv }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

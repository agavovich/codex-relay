import AppKit
import ApplicationServices
import Foundation

enum CodexActivityState: Equatable {
    case active
    case idle
    case unknown
}

final class CodexActivityDetector {
    private static let activeButtonTerms = [
        "stop", "interrupt",
        "останов", "прервать"
    ]

    func detect(enabled: Bool) -> CodexActivityState {
        guard enabled, AXIsProcessTrusted() else { return .unknown }
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: CodexDesktopController.bundleIdentifier
        ).first else {
            return .idle
        }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        var inspectedElements = 0
        return containsActiveButton(root, depth: 0, inspectedElements: &inspectedElements)
            ? .active
            : .idle
    }

    private func containsActiveButton(
        _ element: AXUIElement,
        depth: Int,
        inspectedElements: inout Int
    ) -> Bool {
        guard depth <= 18, inspectedElements < 3_000 else { return false }
        inspectedElements += 1

        let role = stringAttribute(kAXRoleAttribute, from: element)
        if role == kAXButtonRole as String {
            let searchableText = [
                stringAttribute(kAXTitleAttribute, from: element),
                stringAttribute(kAXDescriptionAttribute, from: element),
                stringAttribute(kAXHelpAttribute, from: element)
            ]
                .compactMap { $0 }
                .joined(separator: " ")
                .lowercased()

            if Self.activeButtonTerms.contains(where: searchableText.contains) {
                return true
            }
        }

        guard let children = arrayAttribute(kAXChildrenAttribute, from: element) else {
            return false
        }
        for child in children {
            if containsActiveButton(child, depth: depth + 1, inspectedElements: &inspectedElements) {
                return true
            }
        }
        return false
    }

    private func stringAttribute(_ name: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func arrayAttribute(_ name: String, from element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? [AXUIElement]
    }
}

import AppKit
import ApplicationServices

enum TeamsCallUIEvidenceProvider {
    struct Evidence: Equatable {
        var callControlEvidence: Bool
        var callWindowTitleEvidence: Bool

        static let none = Evidence(
            callControlEvidence: false,
            callWindowTitleEvidence: false
        )

        var hasCallEvidence: Bool {
            callControlEvidence || callWindowTitleEvidence
        }
    }

    static func evidence(for processID: pid_t) -> Evidence {
        Evidence(
            callControlEvidence: hasAccessibilityCallEvidence(for: processID),
            callWindowTitleEvidence: hasWindowTitleCallEvidence(for: processID)
        )
    }

    static func hasCallEvidence(for processID: pid_t) -> Bool {
        evidence(for: processID).hasCallEvidence
    }

    private static func hasAccessibilityCallEvidence(for processID: pid_t) -> Bool {
        guard AXIsProcessTrusted() else { return false }

        let app = AXUIElementCreateApplication(processID)
        var windowsValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)
        guard result == .success, let windows = windowsValue as? [AXUIElement] else { return false }

        return windows.contains { window in
            containsCallControl(in: window, maxDepth: 4)
        }
    }

    private static func containsCallControl(in element: AXUIElement, maxDepth: Int) -> Bool {
        if maxDepth < 0 { return false }
        if let title = stringAttribute(element, kAXTitleAttribute), isCallControlText(title) {
            return true
        }
        if let description = stringAttribute(element, kAXDescriptionAttribute), isCallControlText(description) {
            return true
        }
        if let value = stringAttribute(element, kAXValueAttribute), isCallControlText(value) {
            return true
        }

        var childrenValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue)
        guard result == .success, let children = childrenValue as? [AXUIElement] else { return false }

        return children.contains { child in
            containsCallControl(in: child, maxDepth: maxDepth - 1)
        }
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private static func isCallControlText(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let strongControls = [
            "leave call",
            "leave meeting",
            "hang up",
            "turn camera on",
            "turn camera off",
            "mute microphone",
            "unmute microphone",
            "share screen",
            "stop sharing",
        ]
        return strongControls.contains { normalized.contains($0) }
    }

    private static func hasWindowTitleCallEvidence(for processID: pid_t) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        return windows.contains { window in
            guard let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == processID,
                  let title = window[kCGWindowName as String] as? String else {
                return false
            }
            return isCallWindowTitle(title)
        }
    }

    private static func isCallWindowTitle(_ title: String) -> Bool {
        let normalized = title.lowercased()
        guard normalized != "microsoft teams" else { return false }
        let hints = [
            "meeting",
            "call",
            "teams meeting",
            "microsoft teams meeting",
        ]
        return hints.contains { normalized.contains($0) }
    }
}

import AppKit
import ApplicationServices

/// Window tiling via the macOS Accessibility API, ported from RustCast's
/// AX implementation. Requires the user to grant Accessibility permission.
enum TilingService {
    /// Applies a tiling position to the given app's focused window.
    /// Returns false (and triggers the caller's failure path) when permission
    /// is missing or the app exposes no window.
    @discardableResult
    static func tile(application: NSRunningApplication, position: TilingPosition) -> Bool {
        guard AXIsProcessTrusted() else {
            promptForAccessibility()
            return false
        }
        let axApp = AXUIElementCreateApplication(application.processIdentifier)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let windowRef = window else {
            return false
        }
        let axWindow = unsafeBitCast(windowRef, to: AXUIElement.self)

        guard let currentFrame = readFrame(axWindow) else { return false }

        // Convert AX (top-left origin, y down) center point to Cocoa coords
        // using the primary screen height, then pick the screen whose frame
        // contains that point (same logic as RustCast).
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let axCenterY = currentFrame.origin.y + currentFrame.height / 2
        let cocoaCenterY = primaryHeight - axCenterY
        let targetScreen = NSScreen.screens.first { screen in
            NSPointInRect(NSPoint(x: currentFrame.midX, y: cocoaCenterY), screen.frame)
        } ?? NSScreen.main

        guard let screen = targetScreen else { return false }
        let rect = rectFor(position: position, visibleFrame: screen.visibleFrame)

        // AX coords: y measured from the top of the global space.
        let targetSize = CGSize(width: rect.width, height: rect.height)
        let targetPos = CGPoint(x: rect.origin.x, y: primaryHeight - (rect.origin.y + rect.height))

        // Size -> Position -> Size: the double size-set defeats per-app
        // minimum-size clamping (same trick as RustCast).
        _ = setSize(axWindow, targetSize)
        _ = setPoint(axWindow, targetPos)
        _ = setSize(axWindow, targetSize)
        return true
    }

    private static func rectFor(position: TilingPosition, visibleFrame vf: CGRect) -> CGRect {
        let hw = vf.width / 2, hh = vf.height / 2, tw = vf.width / 3
        let x = vf.origin.x, y = vf.origin.y, w = vf.width, h = vf.height
        switch position {
        case .leftHalf: return CGRect(x: x, y: y, width: hw, height: h)
        case .rightHalf: return CGRect(x: x + hw, y: y, width: hw, height: h)
        case .topHalf: return CGRect(x: x, y: y + hh, width: w, height: hh)
        case .bottomHalf: return CGRect(x: x, y: y, width: w, height: hh)
        case .topLeftQuarter: return CGRect(x: x, y: y + hh, width: hw, height: hh)
        case .topRightQuarter: return CGRect(x: x + hw, y: y + hh, width: hw, height: hh)
        case .bottomLeftQuarter: return CGRect(x: x, y: y, width: hw, height: hh)
        case .bottomRightQuarter: return CGRect(x: x + hw, y: y, width: hw, height: hh)
        case .leftThird: return CGRect(x: x, y: y, width: tw, height: h)
        case .centerThird: return CGRect(x: x + tw, y: y, width: tw, height: h)
        case .rightThird: return CGRect(x: x + 2 * tw, y: y, width: tw, height: h)
        case .maximize: return vf
        }
    }

    private static func readFrame(_ axWindow: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let pos = positionValue, let size = sizeValue else { return nil }

        var point = CGPoint.zero
        var cgSize = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &cgSize) else { return nil }
        return CGRect(origin: point, size: cgSize)
    }

    private static func setPoint(_ axWindow: AXUIElement, _ point: CGPoint) -> Bool {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, value) == .success
    }

    private static func setSize(_ axWindow: AXUIElement, _ size: CGSize) -> Bool {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return false }
        return AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, value) == .success
    }

    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

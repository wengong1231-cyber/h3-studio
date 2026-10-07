import AppKit
import SwiftUI

/// All geometry is in AppKit screen points, independent of a display's backing scale.
enum OrbGeometry {
    static let windowSize = NSSize(width: 268, height: 94)
    static let orbRect = NSRect(x: 186, y: 12, width: 70, height: 70)
    static let edgeMargin: CGFloat = 8

    static func hitTest(_ point: NSPoint) -> Bool {
        hypot(point.x - orbRect.midX, point.y - orbRect.midY) <= orbRect.width / 2 + 4
    }

    /// Checks the union, so an orb may straddle two adjoining displays without snapping.
    static func covered(_ rectangle: NSRect, by frames: [NSRect]) -> Bool {
        let intersections = frames.map { $0.intersection(rectangle) }.filter { !$0.isNull && !$0.isEmpty }
        let edges = Array(Set([rectangle.minX, rectangle.maxX] + intersections.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard edges.count > 1 else { return false }
        for index in 1..<edges.count {
            let x = (edges[index - 1] + edges[index]) / 2
            let intervals = intersections.filter { $0.minX <= x && $0.maxX >= x }.sorted { $0.minY < $1.minY }
            var coveredY = rectangle.minY
            for interval in intervals {
                if interval.minY > coveredY + 0.001 { return false }
                coveredY = max(coveredY, interval.maxY)
            }
            if coveredY < rectangle.maxY - 0.001 { return false }
        }
        return !intersections.isEmpty
    }

    static func constrained(_ origin: NSPoint, visibleFrames: [NSRect]) -> NSPoint {
        guard origin.x.isFinite && origin.y.isFinite else { return .zero }
        let frames = visibleFrames.filter { !$0.isEmpty && !$0.isNull }
        guard !frames.isEmpty else { return origin }
        let visibleOrb = orbRect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -edgeMargin, dy: -edgeMargin)
        if covered(visibleOrb, by: frames) { return origin }
        let candidates = frames.map { frame -> NSPoint in
            let minX = frame.minX + edgeMargin - orbRect.minX
            let maxX = max(minX, frame.maxX - edgeMargin - orbRect.maxX)
            let minY = frame.minY + edgeMargin - orbRect.minY
            let maxY = max(minY, frame.maxY - edgeMargin - orbRect.maxY)
            return NSPoint(x: min(maxX, max(minX, origin.x)), y: min(maxY, max(minY, origin.y)))
        }
        return candidates.min {
            hypot($0.x - origin.x, $0.y - origin.y) < hypot($1.x - origin.x, $1.y - origin.y)
        } ?? origin
    }
}

enum OrbRelease {
    case click
    case moved(NSPoint)
    case cancelled
}

struct OrbDragSession {
    let pointerAtPress: NSPoint
    let originAtPress: NSPoint
    let threshold: CGFloat = 5
    private(set) var didDrag = false

    mutating func update(pointer: NSPoint) -> NSPoint? {
        guard pointer.x.isFinite && pointer.y.isFinite else { return nil }
        let delta = NSPoint(x: pointer.x - pointerAtPress.x, y: pointer.y - pointerAtPress.y)
        if hypot(delta.x, delta.y) >= threshold { didDrag = true }
        guard didDrag else { return nil }
        return NSPoint(x: originAtPress.x + delta.x, y: originAtPress.y + delta.y)
    }

    mutating func release(pointer: NSPoint, visibleFrames: [NSRect]) -> OrbRelease {
        guard pointer.x.isFinite && pointer.y.isFinite else { return .cancelled }
        let origin = update(pointer: pointer)
        guard didDrag, let origin else { return .click }
        return .moved(OrbGeometry.constrained(origin, visibleFrames: visibleFrames))
    }
}

@MainActor final class OrbHoverState: ObservableObject {
    @Published var visible = false
}

/// The moving NSWindow never becomes the gesture coordinate space.
final class OrbHostingView: NSHostingView<OrbView> {
    var onActivate: () -> Void = {}
    var onCommit: (NSPoint) -> Void = { _ in }
    var hoverState: OrbHoverState?
    private var session: OrbDragSession?
    private var tracking: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var needsPanelToBecomeKey: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        OrbGeometry.hitTest(convert(point, from: superview)) ? self : nil
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: OrbGeometry.orbRect.insetBy(dx: -4, dy: -4),
                                 options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(OrbGeometry.orbRect, cursor: .openHand) }
    override func cursorUpdate(with event: NSEvent) { (session == nil ? NSCursor.openHand : NSCursor.closedHand).set() }
    override func mouseEntered(with event: NSEvent) { if session == nil { hoverState?.visible = true } }
    override func mouseExited(with event: NSEvent) { if session == nil { hoverState?.visible = false } }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        // Capture the actual press event before moving, then follow the live global pointer.
        // Both conversions use logical screen points, without a Retina scale multiplier.
        session = OrbDragSession(pointerAtPress: window.convertPoint(toScreen: event.locationInWindow), originAtPress: window.frame.origin)
        hoverState?.visible = true
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard var active = session, let window else { return }
        let origin = active.update(pointer: NSEvent.mouseLocation)
        session = active
        // No state persistence, screen lookup, SwiftUI animation or telemetry in this hot path.
        if let origin { window.setFrameOrigin(origin) }
    }
    override func mouseUp(with event: NSEvent) {
        guard var active = session, let window else { return }
        let pointer = NSEvent.mouseLocation
        let release = active.release(pointer: pointer, visibleFrames: NSScreen.screens.map(\.visibleFrame))
        session = nil
        NSCursor.openHand.set()
        switch release {
        case .moved(let settled):
            window.setFrameOrigin(settled)
            // Exactly one write, only after release. A drag that returns to its start remains a drag.
            onCommit(window.frame.origin)
        case .click:
            onActivate()
        case .cancelled:
            break
        }
        let location = convert(window.convertPoint(fromScreen: pointer), from: nil)
        hoverState?.visible = OrbGeometry.hitTest(location)
    }
    func activateFromAccessibility() { if session == nil { onActivate() } }
}

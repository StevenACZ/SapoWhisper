import AppKit
import XCTest

@testable import SapoWhisper

final class RecordingOverlayAnchorTests: XCTestCase {
    private let surface = NSSize(width: 640, height: 440)

    @MainActor
    func testBottomAnchorCentresOnTheVisibleFrame() {
        let visible = NSRect(x: 0, y: 70, width: 1440, height: 805)
        let origin = RecordingOverlayWindow.anchoredOrigin(in: visible, windowSize: surface, position: .bottom)
        XCTAssertEqual(origin.x + surface.width / 2, visible.midX)
        XCTAssertEqual(origin.y, visible.minY + 6)
    }

    @MainActor
    func testAnchorFollowsTheNewGeometryAfterAResolutionChange() {
        let wide = NSRect(x: 0, y: 0, width: 1920, height: 1200)
        let narrow = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let before = RecordingOverlayWindow.anchoredOrigin(in: wide, windowSize: surface, position: .bottom)
        let after = RecordingOverlayWindow.anchoredOrigin(in: narrow, windowSize: surface, position: .bottom)
        XCTAssertEqual(before.x, 640)
        XCTAssertEqual(after.x, 400)
    }

    @MainActor
    func testTopAndCenterStayInsideNegativeDisplayCoordinates() {
        let visible = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
        for position in OverlayPosition.allCases {
            let origin = RecordingOverlayWindow.anchoredOrigin(in: visible, windowSize: surface, position: position)
            let frame = NSRect(origin: origin, size: surface)
            XCTAssertTrue(visible.contains(frame), "\(position)")
            XCTAssertEqual(frame.midX, visible.midX)
        }
    }

    @MainActor
    func testScreenParameterChangeReanchorsAStaleWindow() throws {
        let window = RecordingOverlayWindow(contentView: NSView())
        defer { window.close() }
        let screen = try XCTUnwrap(window.screen)
        let expected = RecordingOverlayWindow.anchoredOrigin(
            in: screen.visibleFrame, windowSize: window.frame.size, position: OverlayPosition.configured
        )

        window.setFrameOrigin(NSPoint(x: expected.x + 120, y: expected.y))
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)

        XCTAssertEqual(window.frame.origin.x, expected.x, accuracy: 0.5)
        XCTAssertEqual(window.frame.origin.y, expected.y, accuracy: 0.5)
    }
}

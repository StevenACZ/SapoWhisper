import AppKit
import XCTest

@testable import SapoWhisper

final class PermissionOverlayGeometryTests: XCTestCase {
    @MainActor
    func testPlacementFillsSettingsColumnWithoutLeavingVisibleArea() throws {
        let settings = CGRect(x: 100, y: 100, width: 724, height: 1000)
        let visible = CGRect(x: 0, y: 0, width: 1440, height: 1200)
        let frame = try XCTUnwrap(PermissionOverlayPlacement.frame(settings: settings, visible: visible, height: 210))
        XCTAssertTrue(settings.contains(frame))
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.minY, 120)
        XCTAssertEqual(frame.maxX, 804)
        XCTAssertGreaterThan(frame.minX, settings.minX + 220)
        XCTAssertEqual(frame, frame.integral)
    }

    @MainActor
    func testPlacementHidesAndRecoversWithInsufficientRoom() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 900)
        XCTAssertNil(
            PermissionOverlayPlacement.frame(
                settings: CGRect(x: 700, y: 100, width: 724, height: 800), visible: visible, height: 210
            ))
        XCTAssertNil(
            PermissionOverlayPlacement.frame(
                settings: CGRect(x: 100, y: 800, width: 724, height: 800), visible: visible, height: 210
            ))
        XCTAssertNotNil(
            PermissionOverlayPlacement.frame(
                settings: CGRect(x: 100, y: 100, width: 724, height: 800), visible: visible, height: 210
            ))
    }

    @MainActor
    func testPlacementSupportsNegativeDisplayCoordinatesAndTallerText() throws {
        let settings = CGRect(x: -1500, y: -500, width: 800, height: 900)
        let visible = CGRect(x: -1600, y: -600, width: 1600, height: 1000)
        let frame = try XCTUnwrap(PermissionOverlayPlacement.frame(settings: settings, visible: visible, height: 260))
        XCTAssertTrue(settings.contains(frame))
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.height, 260)
    }

    @MainActor
    func testEntranceClampsTimeAndFinishesAtLatestTarget() {
        let entrance = PermissionOverlayEntrance(origin: CGPoint(x: 20, y: 30), startedAt: 10)
        XCTAssertEqual(entrance.progress(at: 9), 0)
        XCTAssertEqual(entrance.progress(at: 11), 1)
        let target = CGPoint(x: 700, y: -200)
        XCTAssertEqual(entrance.origin(toward: target, progress: entrance.progress(at: 11)), target)
        XCTAssertGreaterThan(entrance.progress(at: 10.14), 0.5)
    }
    @MainActor
    func testNativeContentFitsAtSupportedWidths() throws {
        let language = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = language }
        for locale in ["en", "es"] {
            LocalizationManager.shared.language = locale
            for permission in AppPermission.allCases {
                let controller = PermissionOverlayWindowController(
                    hostApp: PermissionHostApp.current(), permission: permission, onClose: {})
                defer { controller.close() }
                let window = try XCTUnwrap(controller.window)
                let content = try XCTUnwrap(window.contentView as? PermissionOverlayContentView)
                for width: CGFloat in [400, 548] {
                    window.setContentSize(CGSize(width: width, height: content.preferredHeight(for: width)))
                    content.layoutSubtreeIfNeeded()
                    for label in textFields(in: content) where !label.stringValue.isEmpty {
                        XCTAssertGreaterThan(label.bounds.width, 0)
                        XCTAssertGreaterThan(label.bounds.height, 0)
                        let frame = label.convert(label.bounds, to: content)
                        XCTAssertTrue(content.bounds.insetBy(dx: -1, dy: -1).contains(frame))
                        if let parent = label.superview {
                            XCTAssertTrue(
                                parent.bounds.insetBy(dx: -0.5, dy: -0.5).contains(label.frame),
                                "\(locale) \(permission) width=\(width) parent=\(type(of: parent))")
                        }
                        let fitting = label.cell?.cellSize(
                            forBounds: CGRect(
                                x: 0, y: 0, width: label.bounds.width, height: .greatestFiniteMagnitude))
                        XCTAssertLessThanOrEqual(fitting?.height ?? 0, label.bounds.height + 1)
                    }
                    if let directory = ProcessInfo.processInfo.environment["SAPO_PERMISSION_RENDER_DIR"] {
                        let image = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
                        content.cacheDisplay(in: content.bounds, to: image)
                        let data = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                        let name = "\(locale)-\(permission)-\(Int(width)).png"
                        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
                    }
                }
                controller.hide()
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    @MainActor
    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }

}

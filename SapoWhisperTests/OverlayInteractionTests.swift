//
//  OverlayInteractionTests.swift
//  SapoWhisperTests
//

import XCTest

@testable import SapoWhisper

final class OverlayOutsideClickTests: XCTestCase {

    /// The fixed 640×440 surface is mostly transparent margin; the collapse
    /// decision must compare against the measured content frame, with a small
    /// forgiveness margin so near-misses on the pill edge do not dismiss.
    func testClickOutsideMeasuredContentCollapses() {
        let pillFrame = CGRect(x: 100, y: 200, width: 440, height: 236)

        XCTAssertTrue(
            OverlayWindowManager.clickLandsOutsideContent(
                contentFrame: pillFrame, clickPoint: CGPoint(x: 320, y: 40)),
            "click on the transparent margin above the pill must collapse"
        )
        XCTAssertTrue(
            OverlayWindowManager.clickLandsOutsideContent(
                contentFrame: pillFrame, clickPoint: CGPoint(x: 20, y: 300)),
            "click beside the pill must collapse"
        )
        XCTAssertFalse(
            OverlayWindowManager.clickLandsOutsideContent(
                contentFrame: pillFrame, clickPoint: CGPoint(x: 320, y: 300)),
            "click on the pill keeps it open"
        )
        XCTAssertFalse(
            OverlayWindowManager.clickLandsOutsideContent(
                contentFrame: pillFrame, clickPoint: CGPoint(x: 96, y: 196)),
            "click just off the pill edge stays within the forgiveness margin"
        )
    }

    /// Before the first layout pass there is no measured frame; collapsing on
    /// that gap would dismiss the pill from an unrelated click.
    func testEmptyContentFrameNeverCollapses() {
        XCTAssertFalse(
            OverlayWindowManager.clickLandsOutsideContent(
                contentFrame: .zero, clickPoint: CGPoint(x: 5, y: 5))
        )
    }
}

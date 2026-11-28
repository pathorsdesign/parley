import XCTest

@testable import ParleyKit

final class CaptureFormatCheckTests: XCTestCase {
    private func shape(_ rate: Double, _ channels: UInt32) -> CaptureFormatCheck.Shape {
        .init(sampleRate: rate, channels: channels)
    }

    func testMatchingFormatsAreReady() {
        XCTAssertEqual(
            CaptureFormatCheck.verdict(tap: shape(48_000, 1), hardware: shape(48_000, 1), sessionSampleRate: 48_000),
            .ready)
    }

    func testZeroHertzOrNoChannelsIsNotReady() {
        XCTAssertEqual(CaptureFormatCheck.verdict(tap: shape(0, 1), hardware: shape(48_000, 1)), .notReady)
        XCTAssertEqual(CaptureFormatCheck.verdict(tap: shape(48_000, 0), hardware: shape(48_000, 1)), .notReady)
        XCTAssertEqual(CaptureFormatCheck.verdict(tap: shape(48_000, 1), hardware: shape(0, 0)), .notReady)
        XCTAssertEqual(CaptureFormatCheck.verdict(tap: shape(.nan, 1), hardware: shape(48_000, 1)), .notReady)
    }

    func testNodeFormatsThatDisagreeAreStale() {
        // The exception `installTap` raises: tap format vs. hardware format.
        XCTAssertEqual(CaptureFormatCheck.verdict(tap: shape(48_000, 1), hardware: shape(24_000, 1)), .stale)
        XCTAssertEqual(CaptureFormatCheck.verdict(tap: shape(48_000, 2), hardware: shape(48_000, 1)), .stale)
    }

    func testASessionThatMovedOnMakesTheEngineStale() {
        XCTAssertEqual(
            CaptureFormatCheck.verdict(tap: shape(48_000, 1), hardware: shape(48_000, 1), sessionSampleRate: 16_000),
            .stale)
    }

    func testAnUnknownSessionRateIsIgnored() {
        XCTAssertEqual(
            CaptureFormatCheck.verdict(tap: shape(48_000, 1), hardware: shape(48_000, 1), sessionSampleRate: 0),
            .ready)
        XCTAssertEqual(
            CaptureFormatCheck.verdict(tap: shape(48_000, 1), hardware: shape(48_000, 1), sessionSampleRate: nil),
            .ready)
    }
}

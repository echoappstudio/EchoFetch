import Foundation
import XCTest
@testable import EchoFetchCore

final class ClipTests: XCTestCase {
    func testReadsTypedTimes() {
        XCTAssertEqual(ClipTime.parse("95"), 95)
        XCTAssertEqual(ClipTime.parse("95.5"), 95.5)
        XCTAssertEqual(ClipTime.parse("1:35"), 95)
        XCTAssertEqual(ClipTime.parse("1:35.5"), 95.5)
        XCTAssertEqual(ClipTime.parse("1:02:03.5"), 3723.5)
        XCTAssertEqual(ClipTime.parse(" 2:00 "), 120)
        XCTAssertEqual(ClipTime.parse("0:00"), 0)
    }

    func testRejectsTimesThatDontMakeSense() {
        for text in ["", "  ", "a", "1:60", "1:2:3:4", "-5", "1.5:30", "1::2", ":30", "1:30:", "1:3a"] {
            XCTAssertNil(ClipTime.parse(text), text)
        }
    }

    func testWritesTimes() {
        XCTAssertEqual(ClipTime.text(0), "0:00")
        XCTAssertEqual(ClipTime.text(5), "0:05")
        XCTAssertEqual(ClipTime.text(90), "1:30")
        XCTAssertEqual(ClipTime.text(90.5), "1:30.5")
        XCTAssertEqual(ClipTime.text(90.04), "1:30")
        XCTAssertEqual(ClipTime.text(90.06), "1:30.1")
        XCTAssertEqual(ClipTime.text(59.96), "1:00")
        XCTAssertEqual(ClipTime.text(3723.5), "1:02:03.5")
        XCTAssertEqual(ClipTime.text(-3), "0:00")
        XCTAssertEqual(ClipTime.fileText(90), "1.30")
        XCTAssertEqual(ClipTime.fileText(3723.5), "1.02.03.5")
    }

    func testWritesPlainSecondsForYtDlp() {
        XCTAssertEqual(ClipTime.plainSeconds(90), "90")
        XCTAssertEqual(ClipTime.plainSeconds(165.5), "165.5")
        XCTAssertEqual(ClipTime.plainSeconds(0.25), "0.25")
        XCTAssertEqual(ClipTime.plainSeconds(12.3456), "12.346")
        XCTAssertEqual(ClipTime.plainSeconds(0), "0")
    }

    func testTextRoundTripsThroughParse() {
        for seconds in [0.0, 5, 59.5, 90.5, 600, 3723.5] {
            XCTAssertEqual(ClipTime.parse(ClipTime.text(seconds)), seconds)
        }
    }

    func testDescribesARange() {
        let clip = ClipRange(start: 90, end: 165.5)
        XCTAssertEqual(clip.length, 75.5)
        XCTAssertEqual(clip.sectionArgument, "*90-165.5")
        XCTAssertEqual(clip.fileLabel, "part 1.30-2.45.5")
        XCTAssertEqual(clip.displayText, "1:30 – 2:45.5")
        XCTAssertEqual(ClipRange(start: 5, end: 2).length, 0)
    }

    func testChecksARangeFitsTheVideo() {
        XCTAssertTrue(ClipRange(start: 10, end: 20).isValid(videoLength: nil))
        XCTAssertTrue(ClipRange(start: 10, end: 15.04).isValid(videoLength: 15))
        XCTAssertTrue(ClipRange(start: 0, end: 0.5).isValid(videoLength: 15))
        XCTAssertFalse(ClipRange(start: 0, end: 0.4).isValid(videoLength: 15))
        XCTAssertFalse(ClipRange(start: 10, end: 5).isValid(videoLength: nil))
        XCTAssertFalse(ClipRange(start: -1, end: 5).isValid(videoLength: nil))
        XCTAssertFalse(ClipRange(start: 10, end: 20).isValid(videoLength: 15))
        XCTAssertFalse(ClipRange(start: 15, end: 16).isValid(videoLength: 15))
        XCTAssertFalse(ClipRange(start: 1, end: .infinity).isValid(videoLength: nil))
    }

    func testKnowsWhenTheRangeIsTheWholeVideo() {
        XCTAssertTrue(ClipRange(start: 0, end: 15).coversWholeVideo(videoLength: 15))
        XCTAssertTrue(ClipRange(start: 0.04, end: 14.96).coversWholeVideo(videoLength: 15))
        XCTAssertFalse(ClipRange(start: 1, end: 15).coversWholeVideo(videoLength: 15))
        XCTAssertFalse(ClipRange(start: 0, end: 14).coversWholeVideo(videoLength: 15))
        XCTAssertFalse(ClipRange(start: 0, end: 15).coversWholeVideo(videoLength: nil))
    }

    func testRangeIsSavedAsStartAndEnd() throws {
        let data = try JSONEncoder().encode(ClipRange(start: 1.5, end: 4))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
        XCTAssertEqual(object, ["start": 1.5, "end": 4])
        XCTAssertEqual(try JSONDecoder().decode(ClipRange.self, from: data), ClipRange(start: 1.5, end: 4))
    }
}

import XCTest

@testable import ParleyKit

final class SpeakerNamesTests: XCTestCase {
    private func meta(_ raw: [String: Any] = [:]) -> RecordingMeta {
        RecordingMeta(raw: raw.merging(["id": "r"]) { a, _ in a })
    }

    func testNamingASpeakerLabelsEveryOneOfItsLines() {
        var m = meta(["segments": [
            ["id": "a", "source": "mix", "speaker": 2, "text": "hi", "isFinal": true, "startMs": 0.0, "endMs": 1.0],
        ]])
        XCTAssertTrue(m.setSpeakerName("mix-2", to: "  Jack "))
        XCTAssertEqual(m.speakerNames["mix-2"], "Jack")
        XCTAssertEqual(m.speakerLabel(for: m.segments[0]), "Jack")
    }

    func testAnEmptyNameGoesBackToTheDefaultAndKeepsTheOldOneAsAnAlias() {
        var m = meta(["speakerNames": ["mix-1": "Bob"]])
        XCTAssertTrue(m.setSpeakerName("mix-1", to: " "))
        XCTAssertNil(m.speakerNames["mix-1"])
        XCTAssertEqual(m.speakerAliases["mix-1"], ["Bob"])
    }

    func testTheSameNameChangesNothing() {
        var m = meta(["speakerNames": ["mix-1": "Bob"]])
        XCTAssertFalse(m.setSpeakerName("mix-1", to: "Bob "))
        XCTAssertNil(m.raw["speakerAliases"])
    }

    func testRenamingKeepsTheReplacedName() {
        var m = meta(["speakerNames": ["mix-1": "Bob"]])
        m.setSpeakerName("mix-1", to: "Robert")
        XCTAssertEqual(m.speakerAliases["mix-1"], ["Bob"])
        m.setSpeakerName("mix-1", to: "Rob")
        // "Rob" is a prefix of nothing kept; "Robert" is kept, "Bob" stays.
        XCTAssertEqual(m.speakerAliases["mix-1"], ["Bob", "Robert"])
    }

    func testAliasesMatchTheDesktopRules() {
        // The desktop's relabel.test cases: typing residue is dropped.
        XCTAssertEqual(RecordingMeta.nextSpeakerAliases(["J", "Ja"], previous: "Jac", next: "Jack"), [])
        XCTAssertEqual(RecordingMeta.nextSpeakerAliases(nil, previous: "Speaker 2", next: "Jack"), ["Speaker 2"])
        XCTAssertEqual(RecordingMeta.nextSpeakerAliases(["Jack"], previous: nil, next: "Jack"), [])
    }
}

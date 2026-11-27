import XCTest

@testable import ParleyKit

final class ActionOwnersTests: XCTestCase {
    private func seg(_ speaker: Int, _ ms: Double, source: String = "mix") -> [String: Any] {
        ["id": "\(source)-\(speaker)-\(ms)", "source": source, "speaker": speaker, "text": "words",
         "isFinal": true, "startMs": ms, "endMs": ms + 1000]
    }

    private func meta(items: [[String: Any]], names: [String: String] = [:], selfKey: String? = nil)
        -> RecordingMeta
    {
        var raw: [String: Any] = [
            "id": "r", "segments": [seg(1, 0), seg(2, 2000), seg(3, 4000)],
            "speakerNames": names, "actionItems": items,
        ]
        if let selfKey { raw["selfSpeaker"] = selfKey }
        return RecordingMeta(raw: raw)
    }

    func testTheUserFirstThenSpeakersThenNamesThenNobody() {
        let m = meta(
            items: [
                ["id": "a", "text": "nobody's", "done": false],
                ["id": "b", "text": "dana's", "done": false, "owner": "Dana"],
                ["id": "c", "text": "first speaker's", "done": false, "owner": "Speaker 1"],
                ["id": "d", "text": "mine", "done": false, "owner": "Jack"],
                ["id": "e", "text": "third's", "done": false, "ownerKey": "mix-3", "owner": "Speaker 3"],
            ],
            names: ["mix-2": "Jack"], selfKey: "mix-2")
        let groups = m.actionItemsByOwner
        XCTAssertEqual(groups.map(\.kind), [
            .speaker(key: "mix-2", isSelf: true), .speaker(key: "mix-1", isSelf: false),
            .speaker(key: "mix-3", isSelf: false), .named, .unassigned,
        ])
        XCTAssertEqual(groups.map { $0.items.map(\.id) }, [["d"], ["c"], ["e"], ["b"], ["a"]])
        XCTAssertEqual(groups[0].name, "Jack")
        XCTAssertEqual(groups[3].name, "Dana")
    }

    func testARenamedSpeakerKeepsTheirItems() {
        var m = meta(
            items: [["id": "a", "text": "x", "done": false, "owner": "Bob", "ownerKey": "mix-1"]],
            names: ["mix-1": "Bob"])
        m.setSpeakerName("mix-1", to: "Robert")
        XCTAssertEqual(m.actionItemsByOwner.first?.name, "Robert")
        XCTAssertEqual(m.actionItemsByOwner.first?.kind, .speaker(key: "mix-1", isSelf: false))
    }

    func testAnOwnerTwoSpeakersCouldBeIsNotGuessed() {
        let m = meta(
            items: [["id": "a", "text": "x", "done": false, "owner": "Sam"]],
            names: ["mix-1": "Sam", "mix-2": "Sam"])
        XCTAssertEqual(m.actionItemsByOwner.map(\.kind), [.named])
    }
}

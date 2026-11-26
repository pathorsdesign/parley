import XCTest

@testable import ParleyKit

final class BriefSectionsTests: XCTestCase {

    func testCutsAtHeadingsAndMovesTheNextSectionsAside() {
        let brief = """
            ## Where this landed
            Moved forward [1:34].

            ## Their pain and objections
            - nights [0:08]

            ## Next steps
            - send the quote [2:04]
            """
        let split = BriefSections.split(brief)
        XCTAssertEqual(split.lead, "")
        XCTAssertEqual(split.sections.map(\.key), [.whereLanded, .painObjections])
        XCTAssertEqual(split.sections[0].body, "Moved forward [1:34].")
        XCTAssertEqual(split.next.map(\.key), [.nextSteps])
        XCTAssertEqual(split.next[0].body, "- send the quote [2:04]")
    }

    func testABriefWithoutHeadingsIsOneLead() {
        let split = BriefSections.split("**Held at forty.** More [0:12].")
        XCTAssertEqual(split.lead, "**Held at forty.** More [0:12].")
        XCTAssertTrue(split.sections.isEmpty)
        XCTAssertTrue(split.next.isEmpty)
    }

    func testUnknownHeadingsKeepTheirTextAndBoldedHeadingsAreUnwrapped() {
        let split = BriefSections.split("intro\n**## Decisions**\n- one\n## Risks：\n- two\n### Sub\n- three")
        XCTAssertEqual(split.lead, "intro")
        XCTAssertEqual(split.sections.map(\.key), [.decisions, nil])
        XCTAssertEqual(split.sections[1].title, "Risks：")
        XCTAssertEqual(split.sections[1].body, "- two\n### Sub\n- three")
    }

    func testEmptySectionsAreDropped() {
        let split = BriefSections.split("## Highlights\n\n## Suggested next agenda\n- ask about budget")
        XCTAssertTrue(split.sections.isEmpty)
        XCTAssertEqual(split.next.map(\.key), [.nextAgenda])
    }

    func testCurlyApostropheHeadingIsKnown() {
        XCTAssertEqual(BriefSections.key(of: "What we still don’t know"), .unknowns)
    }

    // MARK: meeting context

    func testNotesAndBackgroundSplitAtTheHeading() {
        let context = "Prepared background.\n\n會議中的筆記：\n- ask about Okta"
        XCTAssertEqual(MeetingContextParts.background(context), "Prepared background.")
        XCTAssertEqual(MeetingContextParts.notes(context), "- ask about Okta")
    }

    func testNotesOnlyAndBackgroundOnly() {
        XCTAssertEqual(MeetingContextParts.notes("Notes taken during the meeting:\n- one"), "- one")
        XCTAssertEqual(MeetingContextParts.background("Notes taken during the meeting:\n- one"), "")
        XCTAssertEqual(MeetingContextParts.notes("Just a background."), "")
        XCTAssertEqual(MeetingContextParts.background("Just a background."), "Just a background.")
    }

    func testTheLastHeadingWins() {
        let context = "bg\n\nNotes taken during the meeting:\nold\n\n會議中的筆記：\nnew"
        XCTAssertEqual(MeetingContextParts.notes(context), "new")
    }

    // MARK: action item sides

    func testActionItemsCarryTheirSideAndOwner() {
        let meta = RecordingMeta(raw: [
            "actionItems": [
                ["id": "a", "text": "Send quote", "done": false, "side": "us", "owner": " Amy "],
                ["id": "b", "text": "Check budget", "done": false, "side": "them"],
                ["id": "c", "text": "Old item", "done": false, "side": "weird", "owner": ""],
            ]
        ])
        XCTAssertEqual(meta.actionItems.map(\.side), [.us, .them, nil])
        XCTAssertEqual(meta.actionItems.map(\.owner), ["Amy", nil, nil])
    }
}

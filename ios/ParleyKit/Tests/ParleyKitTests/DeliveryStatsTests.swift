import XCTest

@testable import ParleyKit

/// The 評分 report's transcript facts, ported from the desktop's
/// `speechStats.test.ts` and `fillerWords.test.ts` — the same inputs must give
/// the same numbers on both, or a meeting scores differently per device.
final class DeliveryStatsTests: XCTestCase {
    private var n = 0

    private func seg(
        _ source: String, _ startS: Double, _ endS: Double, _ text: String, speaker: Int = 0
    ) -> TranscriptSegment {
        n += 1
        return TranscriptSegment(
            id: "s\(n)", source: source, speaker: speaker, text: text, isFinal: true,
            startMs: UInt64(startS * 1000), endMs: UInt64(endS * 1000))
    }

    private let micIsMe: SpeechStats.IsSelf = { $0.source == "me" }

    // MARK: speechUnits

    func testSpeechUnitsCountsCJKCharactersAndLatinWords() {
        XCTAssertEqual(SpeechStats.speechUnits("我們下週 launch 新版本"), 8)
        XCTAssertEqual(SpeechStats.speechUnits("Hello, world!"), 2)
        XCTAssertEqual(SpeechStats.speechUnits("，。"), 0)
    }

    // MARK: computeSpeechStats

    func testReadsPaceFromTheUsersOwnTalk() {
        // 30 characters over 15 s, twice → 120 字/分.
        let text = "一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十"
        let stats = SpeechStats.compute([seg("me", 0, 15, text), seg("me", 20, 35, text)], isSelf: micIsMe)
        XCTAssertEqual(stats.textPace, 120)
        XCTAssertEqual(stats.paceTimeline, [.init(atMs: 0, perMin: 120)])
    }

    func testPauseIsASilenceNobodyElseFilled() {
        let stats = SpeechStats.compute(
            [
                seg("me", 0, 5, "我先講"),
                seg("me", 7, 10, "然後"),
                seg("them", 11, 14, "好的我了解"),
                seg("me", 15, 20, "接著"),
                seg("me", 80, 85, "很久以後"),
            ], isSelf: micIsMe)
        XCTAssertEqual(stats.pauses, [.init(atMs: 5000, ms: 2000)])
    }

    func testTalliesFillersAndFindsImmediateRepetitions() {
        let stats = SpeechStats.compute([seg("me", 0, 10, "嗯我覺得我覺得然後就是這樣 the the plan")], isSelf: micIsMe)
        XCTAssertGreaterThan(stats.fillerTotal, 0)
        XCTAssertTrue(stats.fillers.contains { $0.word == "然後" })
        XCTAssertEqual(stats.repetitions.map(\.text), ["我覺得我覺得", "the the"])
    }

    func testLeavesReduplicatedWordsAlone() {
        XCTAssertEqual(SpeechStats.compute([seg("me", 0, 5, "謝謝大家看看")], isSelf: micIsMe).repetitions, [])
    }

    func testDiarizedMeetingReadsOnlyTheChosenSpeaker() {
        let isTwo: SpeechStats.IsSelf = { $0.speaker == 2 }
        let stats = SpeechStats.compute(
            [
                seg("mix", 0, 10, "嗯嗯嗯然後然後", speaker: 1),
                seg("mix", 10, 25, "一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十", speaker: 2),
            ], isSelf: isTwo)
        XCTAssertEqual(stats.myTalkMs, 15_000)
        XCTAssertFalse(stats.fillers.contains { $0.word == "然後" })
    }

    func testAGapSomeoneElseSpokeInIsNotAPause() {
        let isTwo: SpeechStats.IsSelf = { $0.speaker == 2 }
        let stats = SpeechStats.compute(
            [
                seg("mix", 0, 5, "我先講", speaker: 2), seg("mix", 5.5, 7, "好", speaker: 1),
                seg("mix", 8, 10, "接著", speaker: 2),
            ], isSelf: isTwo)
        XCTAssertEqual(stats.pauses, [])
    }

    func testBucketWidthWidensPastTwentyMinutes() {
        XCTAssertEqual(SpeechStats.bucketWidth(20 * 60_000), 60_000)
        XCTAssertEqual(SpeechStats.bucketWidth(21 * 60_000), 120_000)
        // Three hours: 180 min / 40 = 4.5 → 5-minute columns.
        XCTAssertEqual(SpeechStats.bucketWidth(180 * 60_000), 300_000)
    }

    // MARK: talkShare / clock

    func testTalkShareSplitsTalkTime() throws {
        let share = try XCTUnwrap(
            SpeechStats.talkShare([seg("mix", 0, 30, "嗨"), seg("me", 30, 40, "你好")], isSelf: micIsMe))
        XCTAssertEqual(share.me, 0.25, accuracy: 0.0001)
    }

    func testTalkShareIsNilForAMonologue() {
        XCTAssertNil(SpeechStats.talkShare([seg("me", 0, 30, "嗨")], isSelf: micIsMe))
    }

    func testClock() {
        XCTAssertEqual(SpeechStats.clock(65_000), "1:05")
        XCTAssertEqual(SpeechStats.clock(3_725_000), "1:02:05")
    }

    // MARK: fillers

    func testCountsLexicalCrutchWordsPerWord() {
        XCTAssertEqual(FillerWords.countByWord("然後我們然後再看，然後就好"), ["然後": 3])
    }

    func testPrefersTheLongestEntry() {
        XCTAssertEqual(FillerWords.countByWord("就是說這樣就是"), ["就是說": 1, "就是": 1])
    }

    func testFoldsHesitationSoundVariants() {
        XCTAssertEqual(FillerWords.countByWord("ummm so um, 嗯嗯 嗯 啊啊"), ["um": 2, "嗯": 2, "啊啊": 1])
    }

    /// JavaScript's `\b` is ASCII-only: "um" straight after 嗯 is still a word.
    func testLatinHesitationRightAfterCJK() {
        XCTAssertEqual(FillerWords.countByWord("嗯um"), ["嗯": 1, "um": 1])
    }

    func testCountsAgreementRunsOfThreeOrMore() {
        XCTAssertEqual(FillerWords.countByWord("對對對，好"), ["對對對": 1])
        XCTAssertEqual(FillerWords.countByWord("對，對，對，對"), ["對對對": 1])
        XCTAssertEqual(FillerWords.countByWord("對對"), [:])
    }

    func testAnchorsEnglishEntriesToWholeWordsCaseInsensitively() {
        XCTAssertEqual(
            FillerWords.countByWord("Like, it was likely, you know, LIKE that"), ["like": 2, "you know": 1])
    }

    func testAccumulatesIntoASharedMap() {
        var m: [String: Int] = [:]
        FillerWords.countByWord("然後", into: &m)
        FillerWords.countByWord("然後 um", into: &m)
        XCTAssertEqual(m, ["然後": 2, "um": 1])
    }

    func testTopOrdersByCountAndCaps() {
        let m = ["um": 2, "然後": 6, "對對對": 3, "其實": 1, "那個": 1, "就是": 1]
        XCTAssertEqual(
            FillerWords.top(m, limit: 3),
            [.init(word: "然後", count: 6), .init(word: "對對對", count: 3), .init(word: "um", count: 2)])
    }

    /// The Swift copy of the vocabulary is the shared one, word for word.
    func testLexiconMatchesSharedStudyPrompt() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("shared/prompts/study.json")
        guard let data = try? Data(contentsOf: url) else {
            throw XCTSkip("shared/prompts is not next to this checkout")
        }
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let shared = try XCTUnwrap(json["fillerWords"] as? [String: [String]])
        XCTAssertEqual(shared, FillerWords.lexicon)
    }

    // MARK: self speaker

    func testMarkWinsOverTheMicTrack() {
        let segments = [seg("me", 0, 5, "我"), seg("mix", 5, 9, "你", speaker: 2)]
        let me = DeliverySpeakers.resolveSelf(segments, marked: "mix-2")
        XCTAssertEqual(me?.origin, .marked)
        XCTAssertEqual(me?.key, "mix-2")
    }

    func testAMarkOnAVanishedSpeakerFallsBack() {
        let segments = [seg("me", 0, 5, "我"), seg("them", 5, 9, "你")]
        let me = DeliverySpeakers.resolveSelf(segments, marked: "mix-7")
        XCTAssertEqual(me?.origin, .micTrack)
        XCTAssertNil(DeliverySpeakers.resolveSelf([seg("mix", 0, 5, "我", speaker: 1)], marked: nil))
    }

    func testRosterPutsTheUserFirstThenByTalk() {
        let segments = [
            seg("mix", 0, 5, "一", speaker: 1), seg("mix", 5, 30, "二", speaker: 3),
            seg("mix", 30, 32, "三", speaker: 2),
        ]
        let me = DeliverySpeakers.resolveSelf(segments, marked: "mix-2")
        XCTAssertEqual(DeliverySpeakers.roster(segments, user: me).map(\.key), ["mix-2", "mix-3", "mix-1"])
        XCTAssertEqual(DeliverySpeakers.roster(segments, user: nil).map(\.key), ["mix-3", "mix-1", "mix-2"])
    }

    // MARK: meta

    func testAssessmentDecodesPermissively() {
        XCTAssertNil(DeliveryAssessment(raw: NSNull()))
        XCTAssertNil(DeliveryAssessment(raw: nil))
        let a = DeliveryAssessment(raw: ["tone": "warm", "summary": "ok"])
        XCTAssertEqual(a?.tone, .warm)
        XCTAssertEqual(a?.toneEvidence, "")
        XCTAssertNil(a?.fillerLevel)
        let b = DeliveryAssessment(raw: [
            "tone": "loud", "fillers": ["level": "frequent", "examples": ["然後"], "note": "n"],
        ])
        XCTAssertNil(b?.tone)
        XCTAssertEqual(b?.fillersFrequent, true)
        XCTAssertEqual(b?.fillerExamples, ["然後"])
    }

    func testMarkingSelfDropsTheToneReadOnlyWhenTheMarkChanges() {
        var meta = RecordingMeta(raw: ["selfSpeaker": "mix-2", "deliveryAssessment": ["tone": "warm"]])
        XCTAssertFalse(meta.markSelf("mix-2"))
        XCTAssertNotNil(meta.deliveryAssessment)
        XCTAssertTrue(meta.markSelf("mix-1"))
        XCTAssertEqual(meta.selfSpeaker, "mix-1")
        XCTAssertNil(meta.deliveryAssessment)
        XCTAssertTrue(meta.raw["deliveryAssessment"] is NSNull)
        XCTAssertTrue(meta.markSelf(nil))
        XCTAssertTrue(meta.raw["selfSpeaker"] is NSNull)
    }
}

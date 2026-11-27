import Foundation

/// Speech facts for the post-meeting 評分 report, computed from the saved
/// transcript alone: segment text and timing, no audio and no model. A port of
/// the desktop's `src/lib/analysis/speechStats.ts` — same thresholds, same
/// buckets, same regexes — so a meeting scores the same on the phone and the Mac.
///
/// Every fact is about one speaker's lines, which ones the caller's `isSelf`
/// says. Segment-level timing only: a pause inside one segment is invisible, so
/// pause counts are a floor, not an exact tally.
public struct SpeechStats: Equatable, Sendable {
    public struct PacePoint: Equatable, Sendable {
        /// Bucket start, ms into the recording.
        public let atMs: Int
        /// 字/分 over the speaker's own talk in this bucket.
        public let perMin: Int
    }

    public struct Pause: Equatable, Sendable {
        public let atMs: Int
        public let ms: Int
    }

    public struct Repetition: Equatable, Sendable {
        public let atMs: Int
        public let text: String
    }

    public let durationMs: Int
    /// The speaker's own talk time and how much they said.
    public let myTalkMs: Int
    public let myUnits: Int
    /// 字/分 over the talk time; nil with under 20 s of talk.
    public let textPace: Int?
    /// Pace across the meeting, one point per bucket with enough talk.
    public let paceTimeline: [PacePoint]
    public let bucketMs: Int
    public let pauses: [Pause]
    /// The eight most frequent fillers.
    public let fillers: [FillerCount]
    public let fillerTotal: Int
    public let repetitions: [Repetition]

    /// A silence between two of the speaker's own segments at least this long,
    /// with nobody else talking, counts as a pause.
    public static let pauseMinMs = 1_000
    /// Longer than this and the speaker had simply stopped talking for a while.
    public static let pauseMaxMs = 30_000

    public typealias IsSelf = (TranscriptSegment) -> Bool

    // MARK: units

    private static let cjk = FillerWords.regex("[\\x{3400}-\\x{9FFF}\\x{F900}-\\x{FAFF}]")
    private static let latinWord = FillerWords.regex("[a-z0-9']+", caseInsensitive: true)

    /// How much was said: CJK characters plus Latin words — the 字 of 字/分.
    public static func speechUnits(_ text: String) -> Int {
        let range = NSRange(location: 0, length: (text as NSString).length)
        let cjkCount = cjk.numberOfMatches(in: text, range: range)
        let rest = cjk.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        let latin = latinWord.numberOfMatches(
            in: rest, range: NSRange(location: 0, length: (rest as NSString).length))
        return cjkCount + latin
    }

    /// Bucket width: 1 min for meetings up to 20 min, else 2 min, else wider so
    /// the charts never get more than 40 columns.
    static func bucketWidth(_ durationMs: Int) -> Int {
        let min = 60_000
        if durationMs <= 20 * min { return min }
        let perColumn = (Double(durationMs) / 40 / Double(min)).rounded(.up)
        return max(2 * min, Int(perColumn) * min)
    }

    // MARK: repetitions

    /// Immediately repeated words: 我覺得我覺得, "the the". Single CJK characters
    /// are left out — 謝謝, 看看 and 常常 are words, not stumbles.
    private static let cjkRepeat = FillerWords.regex("([\\x{3400}-\\x{9FFF}]{2,4})[\\s,，、]*\\1")
    private static let latinRepeat = FillerWords.regex(
        "\(FillerWords.wordBoundary)([a-z']+)\\s+\\1\(FillerWords.wordBoundary)", caseInsensitive: true)

    private static func findRepetitions(_ seg: TranscriptSegment, into: inout [Repetition]) {
        let ns = seg.text as NSString
        for re in [cjkRepeat, latinRepeat] {
            for m in re.matches(in: seg.text, range: NSRange(location: 0, length: ns.length)) {
                into.append(Repetition(atMs: Int(seg.startMs), text: ns.substring(with: m.range)))
            }
        }
    }

    /// Final segments with words and a positive length, in time order.
    static func spoken(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated()
            .filter { _, s in
                s.isFinal && !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && s.endMs > s.startMs
            }
            .sorted { a, b in
                if a.element.startMs != b.element.startMs { return a.element.startMs < b.element.startMs }
                if a.element.endMs != b.element.endMs { return a.element.endMs < b.element.endMs }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// JavaScript's `Math.round` for the non-negative values used here.
    private static func round(_ x: Double) -> Int { Int((x + 0.5).rounded(.down)) }

    // MARK: compute

    /// Every fact the 評分 report shows that the transcript alone can answer,
    /// over the lines `isSelf` says are the speaker's.
    public static func compute(_ segments: [TranscriptSegment], isSelf: IsSelf) -> SpeechStats {
        let spoken = spoken(segments)
        let durationMs = spoken.reduce(0) { max($0, Int($1.endMs)) }
        let bucketMs = bucketWidth(durationMs)
        let buckets = max(1, Int((Double(durationMs) / Double(bucketMs)).rounded(.up)))
        let own = spoken.filter(isSelf)

        var paceUnits = [Int](repeating: 0, count: buckets)
        var paceMs = [Int](repeating: 0, count: buckets)
        var myTalkMs = 0
        var myUnits = 0
        var fillerCounts: [String: Int] = [:]
        var repetitions: [Repetition] = []

        for s in own {
            let i = min(buckets - 1, Int(s.startMs) / bucketMs)
            let ms = Int(s.endMs) - Int(s.startMs)
            let units = speechUnits(s.text)
            myTalkMs += ms
            myUnits += units
            paceUnits[i] += units
            paceMs[i] += ms
            FillerWords.countByWord(s.text, into: &fillerCounts)
            findRepetitions(s, into: &repetitions)
        }

        var paceTimeline: [PacePoint] = []
        for i in 0..<buckets where paceMs[i] >= 10_000 {
            // Under 10 s of talk in a bucket is too little to call a pace.
            paceTimeline.append(
                PacePoint(
                    atMs: i * bucketMs,
                    perMin: round(Double(paceUnits[i]) / (Double(paceMs[i]) / 60_000))))
        }

        // Pauses: the gap between two consecutive own segments that nobody
        // else spoke in.
        var pauses: [Pause] = []
        if own.count > 1 {
            for k in 1..<own.count {
                let a = own[k - 1]
                let b = own[k]
                let gap = Int(b.startMs) - Int(a.endMs)
                if gap < pauseMinMs || gap > pauseMaxMs { continue }
                let filled = spoken.contains { o in
                    !isSelf(o) && o.startMs < b.startMs && o.endMs > a.endMs
                }
                if !filled { pauses.append(Pause(atMs: Int(a.endMs), ms: gap)) }
            }
        }

        return SpeechStats(
            durationMs: durationMs,
            myTalkMs: myTalkMs,
            myUnits: myUnits,
            textPace: myTalkMs >= 20_000
                ? round(Double(myUnits) / (Double(myTalkMs) / 60_000)) : nil,
            paceTimeline: paceTimeline,
            bucketMs: bucketMs,
            pauses: pauses,
            fillers: FillerWords.top(fillerCounts, limit: 8),
            fillerTotal: fillerCounts.values.reduce(0, +),
            repetitions: repetitions)
    }

    /// The speaker's share of everyone's talk time, or nil when only one side
    /// spoke (a share of a monologue says nothing).
    public static func talkShare(
        _ segments: [TranscriptSegment], isSelf: IsSelf
    ) -> (me: Double, them: Double)? {
        var me = 0
        var them = 0
        for s in spoken(segments) {
            if isSelf(s) {
                me += Int(s.endMs - s.startMs)
            } else {
                them += Int(s.endMs - s.startMs)
            }
        }
        guard me > 0, them > 0 else { return nil }
        let total = Double(me + them)
        return (Double(me) / total, Double(them) / total)
    }

    /// m:ss (or h:mm:ss) for a position in the recording.
    public static func clock(_ ms: Int) -> String {
        let total = max(0, round(Double(ms) / 1000))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        let mm = h > 0 ? String(format: "%02d", m) : String(m)
        return (h > 0 ? "\(h):" : "") + mm + ":" + String(format: "%02d", s)
    }
}

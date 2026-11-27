import Foundation

/// Which speaker in a recording is the user — the person the 評分 report scores
/// — and the speakers its switch lists. The phone's half of the desktop's
/// `src/lib/speakers/self.ts`.
///
/// Two ways to know, tried in order:
///  1. `marked`: someone picked 標記為我 on one speaker (on either device; the
///     mark rides in the meta as `selfSpeaker`).
///  2. `micTrack`: the meeting was transcribed as two streams on the desktop,
///     so every "me" line came from that computer's own mic.
/// The desktop's other two (the voiceprint and the live mic timeline) need data
/// the phone never has. Neither → unknown, and the report asks.
public enum DeliverySpeakers {
    public enum Origin: String, Sendable {
        case marked
        case micTrack = "mic-track"
    }

    public struct SelfSpeaker: Sendable {
        public let origin: Origin
        /// The speaker key when one speaker is the user; nil for `micTrack`,
        /// where every "me" line is.
        public let key: String?

        public func isSelf(_ s: TranscriptSegment) -> Bool {
            switch origin {
            case .marked: speakerKey(s) == key
            case .micTrack: s.source == "me"
            }
        }
    }

    /// One speaker of the recording, as the switch lists them.
    public struct RosterEntry: Equatable, Sendable, Identifiable {
        public let key: String
        public let source: String
        public let speaker: Int
        /// Ms of final, spoken lines.
        public var talkMs: Int
        public let isSelf: Bool
        public var id: String { key }
    }

    /// The desktop's `speakerKey`: `"mix-2"`, `"me-0"`.
    public static func speakerKey(_ s: TranscriptSegment) -> String { "\(s.source)-\(s.speaker)" }

    /// Lines by one speaker key.
    public static func matching(_ key: String) -> (TranscriptSegment) -> Bool {
        { speakerKey($0) == key }
    }

    private static func hasLine(
        _ segments: [TranscriptSegment], _ match: (TranscriptSegment) -> Bool
    ) -> Bool {
        segments.contains { s in
            s.isFinal && !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && match(s)
        }
    }

    /// Who the user is in this recording, or nil when nothing says.
    public static func resolveSelf(_ segments: [TranscriptSegment], marked: String?) -> SelfSpeaker? {
        // A mark on a speaker the transcript no longer has (re-diarized since)
        // says nothing.
        if let marked, !marked.isEmpty, hasLine(segments, matching(marked)) {
            return SelfSpeaker(origin: .marked, key: marked)
        }
        if hasLine(segments, { $0.source == "me" }) {
            return SelfSpeaker(origin: .micTrack, key: nil)
        }
        return nil
    }

    /// Every speaker with a spoken line, the user first, then by how much each
    /// talked (first heard first on a tie).
    public static func roster(_ segments: [TranscriptSegment], user me: SelfSpeaker?) -> [RosterEntry] {
        var entries: [RosterEntry] = []
        var index: [String: Int] = [:]
        for s in segments {
            guard s.isFinal, !s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let key = speakerKey(s)
            let ms = s.endMs > s.startMs ? Int(s.endMs - s.startMs) : 0
            if let i = index[key] {
                entries[i].talkMs += ms
            } else {
                index[key] = entries.count
                entries.append(
                    RosterEntry(
                        key: key, source: s.source, speaker: s.speaker, talkMs: ms,
                        isSelf: me?.isSelf(s) ?? false))
            }
        }
        return entries.enumerated()
            .sorted { a, b in
                if a.element.isSelf != b.element.isSelf { return a.element.isSelf }
                if a.element.talkMs != b.element.talkMs { return a.element.talkMs > b.element.talkMs }
                return a.offset < b.offset
            }
            .map(\.element)
    }
}

/// The desktop's post-meeting tone read of the user (`DeliveryAssessment`,
/// `src/lib/types.ts`), lifted out of the synced meta. Permissive: a field the
/// entry lacks reads as empty rather than failing the whole read.
public struct DeliveryAssessment: Equatable, Sendable {
    public enum Tone: String, Sendable, CaseIterable {
        case neutral, warm, firm, sharp, aggressive, rude
    }

    public let tone: Tone?
    /// A short verbatim quote backing the tone read; empty if none.
    public let toneEvidence: String
    /// `ok` or `frequent`; nil when the entry does not say.
    public let fillerLevel: String?
    public let fillerExamples: [String]
    /// Short note about the dense stretch; empty when the level is ok.
    public let fillerNote: String
    /// `slow`, `comfortable` or `fast`, when given.
    public let pace: String?
    /// One-line plain-language summary.
    public let summary: String

    public init(
        tone: Tone?, toneEvidence: String = "", fillerLevel: String? = nil,
        fillerExamples: [String] = [], fillerNote: String = "", pace: String? = nil,
        summary: String = ""
    ) {
        self.tone = tone
        self.toneEvidence = toneEvidence
        self.fillerLevel = fillerLevel
        self.fillerExamples = fillerExamples
        self.fillerNote = fillerNote
        self.pace = pace
        self.summary = summary
    }

    /// From the meta's `deliveryAssessment`; nil for null, a missing field or
    /// anything that is not an object.
    public init?(raw: Any?) {
        guard let dict = raw as? [String: Any] else { return nil }
        let fillers = dict["fillers"] as? [String: Any] ?? [:]
        self.init(
            tone: (dict["tone"] as? String).flatMap(Tone.init(rawValue:)),
            toneEvidence: dict["toneEvidence"] as? String ?? "",
            fillerLevel: fillers["level"] as? String,
            fillerExamples: fillers["examples"] as? [String] ?? [],
            fillerNote: fillers["note"] as? String ?? "",
            pace: dict["pace"] as? String,
            summary: dict["summary"] as? String ?? "")
    }

    /// The filler read says the speaker leaned on them.
    public var fillersFrequent: Bool { fillerLevel == "frequent" }
    /// Nothing worth a row: no tone, no summary, no filler read.
    public var isEmpty: Bool { tone == nil && summary.isEmpty && fillerLevel == nil }
}

extension RecordingMeta {
    /// The speaker the user marked as themselves (`HistoryEntry.selfSpeaker`).
    public var selfSpeaker: String? {
        get {
            let key = raw["selfSpeaker"] as? String
            return key?.isEmpty == false ? key : nil
        }
        set { raw["selfSpeaker"] = newValue ?? NSNull() }
    }

    /// The desktop's tone read of the user, when one has been made.
    public var deliveryAssessment: DeliveryAssessment? {
        DeliveryAssessment(raw: raw["deliveryAssessment"])
    }

    /// Mark `key` as the user (nil clears it), the way the desktop's
    /// `markSelfSpeaker` does: when the mark changes, the tone read goes too —
    /// it judged whoever was the user before, and the desktop reads it again.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func markSelf(_ key: String?) -> Bool {
        guard selfSpeaker != key else { return false }
        selfSpeaker = key
        raw["deliveryAssessment"] = NSNull()
        return true
    }
}

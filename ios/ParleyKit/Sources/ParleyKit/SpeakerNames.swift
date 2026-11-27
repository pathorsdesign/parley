import Foundation

/// Renaming a speaker, the desktop's `setSpeakerName` (`store/speakers.ts`):
/// a name is trimmed, an empty one goes back to the default label, and the
/// name it replaces is kept as an alias so text the models wrote under the old
/// name (findings, action items, the tone read) can still be relabelled —
/// `nextSpeakerAliases` in `speakers/relabel.ts`.
extension RecordingMeta {
    /// The speaker key a segment's lines are filed under: `"{source}-{speaker}"`.
    public static func speakerKey(_ seg: TranscriptSegment) -> String {
        "\(seg.source)-\(seg.speaker)"
    }

    /// Stale names per speaker, most recent last (`speakerAliases`).
    public var speakerAliases: [String: [String]] {
        raw["speakerAliases"] as? [String: [String]] ?? [:]
    }

    /// Name the speaker `key`, or clear its name with an empty string.
    /// Returns whether anything changed.
    @discardableResult
    public mutating func setSpeakerName(_ key: String, to name: String) -> Bool {
        let now = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var names = speakerNames
        let previous = names[key]
        guard (previous ?? "") != now else { return false }
        if now.isEmpty { names[key] = nil } else { names[key] = now }
        raw["speakerNames"] = names

        var aliases = speakerAliases
        let next = Self.nextSpeakerAliases(aliases[key], previous: previous, next: now)
        aliases[key] = next.isEmpty ? nil : next
        raw["speakerAliases"] = aliases
        return true
    }

    /// Most recent stale names kept per speaker.
    static let maxAliases = 20

    /// The desktop's `nextSpeakerAliases`, line for line: add the old name,
    /// then keep only names that are not the new one, not a prefix of it, and
    /// not a prefix of another kept alias (typing residue on the desktop, where
    /// names save on every keystroke).
    static func nextSpeakerAliases(_ aliases: [String]?, previous: String?, next: String) -> [String] {
        let now = next.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = aliases ?? []
        let old = previous?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !old.isEmpty, old != now, !list.contains(old) { list.append(old) }
        let kept = list.filter { a in
            !a.isEmpty && a != now && !now.hasPrefix(a)
                && !list.contains { b in b != a && b.hasPrefix(a) }
        }
        return Array(kept.suffix(maxAliases))
    }
}

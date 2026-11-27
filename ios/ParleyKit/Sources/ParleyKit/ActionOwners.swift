import Foundation

/// 後續行動 by whose they are: one group per owner, kept in step with the
/// speaker names — the desktop's `speakers/owners.ts`.
///
/// The model names an owner by the label the transcript showed it ("Speaker 2",
/// or a name the user had already typed). An owner that is a speaker is tied
/// to the speaker's key (`ownerKey`, or matched by name), so renaming the
/// speaker on 回放 renames the group too.
extension RecordingMeta {
    public struct ActionOwnerGroup: Identifiable, Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// A speaker in the transcript; `isSelf` when it is the user.
            case speaker(key: String, isSelf: Bool)
            /// A name the meeting used for someone who did not speak.
            case named
            /// No owner the transcript made clear.
            case unassigned
        }

        public let kind: Kind
        /// The heading: the speaker's current label, the owner as written, or
        /// nil for `unassigned` (the screen says 未指定).
        public let name: String?
        public let items: [ActionItem]

        public var id: String {
            switch kind {
            case .speaker(let key, _): "speaker:\(key)"
            case .named: "named:\(name ?? "")"
            case .unassigned: "unassigned"
            }
        }
    }

    /// The action items grouped by owner: the user first, then the other
    /// speakers in the order they first spoke, then owners who never spoke in
    /// the order their items come, then the items nobody owns. Items keep the
    /// analysis's order (importance) inside each group.
    public var actionItemsByOwner: [ActionOwnerGroup] {
        let items = actionItems
        guard !items.isEmpty else { return [] }
        let segs = segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let me = DeliverySpeakers.resolveSelf(segs, marked: selfSpeaker)

        // One line per speaker, in order of first appearance.
        var speakerOrder: [String] = []
        var lineOf: [String: TranscriptSegment] = [:]
        for seg in segs.sorted(by: { $0.startMs < $1.startMs }) {
            let key = Self.speakerKey(seg)
            if lineOf[key] == nil {
                lineOf[key] = seg
                speakerOrder.append(key)
            }
        }

        var bySpeaker: [String: [ActionItem]] = [:]
        var named: [(name: String, items: [ActionItem])] = []
        var unassigned: [ActionItem] = []
        for item in items {
            if let key = ownerSpeakerKey(item, lines: lineOf) {
                bySpeaker[key, default: []].append(item)
            } else if let owner = item.owner {
                if let i = named.firstIndex(where: { Self.norm($0.name) == Self.norm(owner) }) {
                    named[i].items.append(item)
                } else {
                    named.append((owner, [item]))
                }
            } else {
                unassigned.append(item)
            }
        }

        let isSelf: (String) -> Bool = { key in
            guard let me, let line = lineOf[key] else { return false }
            return me.isSelf(line)
        }
        let speakers = speakerOrder.filter { bySpeaker[$0] != nil }
        let ordered = speakers.filter(isSelf) + speakers.filter { !isSelf($0) }
        var groups = ordered.map { key in
            ActionOwnerGroup(
                kind: .speaker(key: key, isSelf: isSelf(key)),
                name: speakerLabel(for: lineOf[key]!), items: bySpeaker[key] ?? [])
        }
        groups += named.map { ActionOwnerGroup(kind: .named, name: $0.name, items: $0.items) }
        if !unassigned.isEmpty {
            groups.append(ActionOwnerGroup(kind: .unassigned, name: nil, items: unassigned))
        }
        return groups
    }

    /// The speaker an item's owner is: its `ownerKey` when that speaker is in
    /// the transcript, else the one speaker whose current name or one of whose
    /// default labels the owner is (`ownerSpeakerKey`). nil when it names no
    /// speaker, or more than one could be meant.
    func ownerSpeakerKey(_ item: ActionItem, lines: [String: TranscriptSegment]) -> String? {
        if let key = item.ownerKey, lines[key] != nil { return key }
        guard let owner = item.owner else { return nil }
        let want = Self.norm(owner)
        guard !want.isEmpty else { return nil }
        let micSpeakers = Set(lines.values.filter { $0.source == "me" && $0.speaker > 0 }.map(\.speaker)).count
        let names = speakerNames
        let hits = lines.filter { key, line in
            if let custom = names[key], Self.norm(custom) == want { return true }
            // The label on screen now, in this language — a name the user saw
            // and the model may have been given.
            if Self.norm(speakerLabel(for: line)) == want { return true }
            return Self.knownDefaultLabels(line, micSpeakers: micSpeakers).contains { Self.norm($0) == want }
        }
        return hits.count == 1 ? hits.first?.key : nil
    }

    /// Every English label the desktop may have given this speaker in a prompt
    /// (`knownDefaultLabels`, speakers/labels.ts).
    static func knownDefaultLabels(_ s: TranscriptSegment, micSpeakers: Int) -> [String] {
        let n = s.speaker > 0 ? s.speaker : 1
        var out: [String]
        switch s.source {
        case "mix":
            out = ["Speaker \(n)"]
        case "me":
            let several = micSpeakers > 1 || s.speaker > 1
            out = [several ? "Me \(n)" : "Me", s.speaker > 1 ? "Me \(n)" : "Me"]
            out.append(s.speaker > 1 ? "Speaker \(s.speaker)" : "You")
        default:
            out = [s.speaker > 0 ? "Remote \(s.speaker)" : "Them"]
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

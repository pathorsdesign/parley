import Foundation

/// The saved brief, cut at its `## ` headings — the port of the desktop's
/// `splitBrief` (`src/lib/analysis/briefSections.ts`), so the phone's result
/// page lays the brief out the way the desktop's report does: the 總結 tab gets
/// the sections, and the forward-looking one (what to open with next time, how
/// to move the deal on) moves to 後續行動, beside the action items it belongs
/// with.
///
/// Cutting the saved text rather than asking for separate pieces costs nothing
/// and works on every recording already synced.
///
/// The model keeps the prompt's English headings even when it writes the body
/// in Chinese, so the known headings are matched by name and carry a `Key` the
/// app translates; an unknown heading keeps its own text.
public enum BriefSections {
    /// Every heading the brief prompt asks for, across the lenses.
    public enum Key: String, Sendable, CaseIterable {
        case highlights, decisions, openQuestions, nextAgenda, whereLanded, painObjections
        case unknowns, nextSteps, outcome, fellShort, improve, keyMoments

        /// The sections that say what happens next — shown under 後續行動.
        public var isNext: Bool { self == .nextAgenda || self == .nextSteps }
    }

    public struct Section: Equatable, Sendable {
        /// nil for a heading the prompt does not name.
        public let key: Key?
        /// The heading as written.
        public let title: String
        public let body: String

        public init(key: Key?, title: String, body: String) {
            self.key = key
            self.title = title
            self.body = body
        }
    }

    public struct Split: Equatable, Sendable {
        /// Text before the first heading (usually none).
        public let lead: String
        /// The sections 總結 shows, in order.
        public let sections: [Section]
        /// The forward-looking sections, for 後續行動.
        public let next: [Section]
    }

    private static let keyByHeading: [String: Key] = [
        "highlights": .highlights,
        "decisions": .decisions,
        "open questions": .openQuestions,
        "suggested next agenda": .nextAgenda,
        "where this landed": .whereLanded,
        "their pain and objections": .painObjections,
        "what we still don't know": .unknowns,
        "next steps": .nextSteps,
        "outcome": .outcome,
        "what fell short": .fellShort,
        "how to improve": .improve,
        "key moments": .keyMoments,
    ]

    static func key(of title: String) -> Key? {
        var normalized = title.trimmingCharacters(in: .whitespaces)
        if normalized.hasSuffix(":") || normalized.hasSuffix("：") { normalized.removeLast() }
        normalized = normalized.lowercased().replacingOccurrences(of: "’", with: "'")
        return keyByHeading[normalized]
    }

    /// Undo a model's habit of bolding its headings: `**## Highlights**` is no
    /// heading to the cutter, so it would come out uncut.
    static func normalizeHeadings(_ markdown: String) -> String {
        markdown.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for marker in ["**", "__"] where trimmed.hasPrefix(marker) && trimmed.hasSuffix(marker) {
                let inner = trimmed.dropFirst(marker.count).dropLast(marker.count)
                if inner.count >= 2, inner.hasPrefix("#") { return String(inner) }
            }
            return line
        }.joined(separator: "\n")
    }

    /// Cut a brief at its level-two headings. A brief without any comes back as
    /// one lead, to be shown whole.
    public static func split(_ markdown: String) -> Split {
        var sections: [Section] = []
        var lead: [String] = []
        var current: (title: String, lines: [String])?
        func close() {
            guard let open = current else { return }
            let title = open.title.trimmingCharacters(in: .whitespaces)
            sections.append(
                Section(
                    key: key(of: title), title: title,
                    body: open.lines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        let normalized = normalizeHeadings(markdown.replacingOccurrences(of: "\r\n", with: "\n"))
        for line in normalized.components(separatedBy: "\n") {
            if line.hasPrefix("##"), !line.hasPrefix("###") {
                let title = line.dropFirst(2)
                if title.first?.isWhitespace == true,
                    !title.trimmingCharacters(in: .whitespaces).isEmpty
                {
                    close()
                    current = (String(title), [])
                    continue
                }
            }
            if current != nil { current?.lines.append(line) } else { lead.append(line) }
        }
        close()
        let kept = sections.filter { !$0.body.isEmpty }
        return Split(
            lead: lead.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
            sections: kept.filter { !($0.key?.isNext ?? false) },
            next: kept.filter { $0.key?.isNext ?? false })
    }
}

/// The meeting context as the desktop saves it: the background prepared
/// before the meeting, then the notes typed during it under a heading — the
/// port of `src/lib/history/meetingNotes.ts`, so the phone's 筆記 and 會議背景
/// tabs show the same two halves the desktop's do.
public enum MeetingContextParts {
    /// The notes heading in every app language (`floating.notesHeading`),
    /// whichever language wrote the entry.
    public static let notesHeadings = ["會議中的筆記：", "Notes taken during the meeting:"]

    /// Where the notes begin: the heading's start and the body's start. The
    /// LAST heading of any language wins.
    private static func notesAt(_ context: String) -> (heading: String.Index, body: String.Index)? {
        var found: (heading: String.Index, body: String.Index)?
        for heading in notesHeadings {
            var at: (heading: String.Index, body: String.Index)?
            if let mid = context.range(of: "\n\n\(heading)\n", options: .backwards) {
                at = (mid.lowerBound, mid.upperBound)
            } else if context.hasPrefix("\(heading)\n") {
                at = (context.startIndex, context.index(context.startIndex, offsetBy: heading.count + 1))
            }
            if let candidate = at, found.map({ candidate.body > $0.body }) ?? true { found = candidate }
        }
        return found
    }

    /// The in-meeting notes ("" when none were taken).
    public static func notes(_ context: String) -> String {
        guard let at = notesAt(context) else { return "" }
        return String(context[at.body...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The prepared background, the notes left out ("" when there was none).
    public static func background(_ context: String) -> String {
        let cut = notesAt(context).map { String(context[..<$0.heading]) } ?? context
        return cut.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

import ParleyKit
import SwiftUI

/// The result page's reading tabs — 總結, 後續行動, 筆記 and 會議背景 — and the
/// compact 重點 list the 回放 tab shows above the transcript. The desktop's
/// `TabPage` (`src/components/study/StudyScreen.tsx`), on a phone.
///
/// The same page as the transcript: page-coloured, no cards, sections set apart
/// by whitespace and a small label. Blue appears only on what can be tapped —
/// and every timestamp can: it hands its moment to `seek`, which switches to
/// 回放, sends the audio there and lights the turn (the desktop's
/// `useSeekToReplay`).

// MARK: - 總結

/// The brief, as the desktop's report lays it out: whatever comes before the
/// first heading, then every section under a numbered heading — the prompt's
/// known headings in the reader's language, any other as the model wrote it.
/// The forward-looking section is not here: it reads under 後續行動
/// (`BriefSections`).
struct SummaryPage: View {
    let meta: RecordingMeta
    /// Whether there is a transcript to hand to an AI, for the empty state.
    let canGenerate: Bool
    let seek: (UInt64) -> Void
    let generate: () -> Void

    var body: some View {
        ResultScroll(seek: seek) {
            if meta.brief.isEmpty {
                noSummary
            } else {
                brief(BriefSections.split(meta.brief))
            }
        }
    }

    @ViewBuilder
    private func brief(_ split: BriefSections.Split) -> some View {
        if split.sections.count < 2 {
            // A brief that cannot be cut is shown whole, as the desktop does.
            let whole = ([split.lead] + split.sections.map(\.body)).filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            BriefProse(markdown: whole.isEmpty ? meta.brief : whole)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                if !split.lead.isEmpty { BriefProse(markdown: split.lead) }
                ForEach(Array(split.sections.enumerated()), id: \.offset) { index, section in
                    let ruled = index > 0 || !split.lead.isEmpty
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: String(format: "%02d", index + 1))
                                .font(.parley.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(Theme.primary)
                            BriefHeading(section: section)
                                .font(.parley.headline)
                                .foregroundStyle(Color(.label))
                                .accessibilityAddTraits(.isHeader)
                        }
                        BriefProse(markdown: section.body)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, ruled ? 20 : 0)
                    .overlay(alignment: .top) {
                        if ruled { Rectangle().fill(Color(.separator)).frame(height: 0.5) }
                    }
                }
            }
        }
    }

    /// Never a blank tab: a recording with no brief says so, and offers the
    /// way to get one — the same hand-off to the user's own AI as the header's
    /// button, with the prompt and the transcript.
    private var noSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No summary yet.")
                .font(.parley.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
            Button(action: generate) {
                Label("Generate a summary with AI", systemImage: "square.and.arrow.up")
                    .font(.parley.subheadlineEmphasized)
            }
            .disabled(!canGenerate)
        }
    }
}

// MARK: - 後續行動

/// The action items, then the brief's forward-looking section — the desktop's
/// 後續行動 tab: the same question, what happens after this meeting.
///
/// Grouped by whose they are: the user first, then each speaker who owns
/// something, then people only named, then 未指定 — the speaker names
/// follow a rename on 回放 (`RecordingMeta.actionItemsByOwner`).
struct ActionsPage: View {
    let meta: RecordingMeta
    /// The folder's name, for 對方's heading. nil = unfiled.
    let folderName: String?
    /// Whether a tick is kept. True for the sample, which keeps its ticks on
    /// the phone; a cloud recording shows the ticks it has and takes none,
    /// because the phone has no write path for them.
    let canTick: Bool
    let seek: (UInt64) -> Void
    let tick: (String, Bool) -> Void

    var body: some View {
        ResultScroll(seek: seek) {
            VStack(alignment: .leading, spacing: 32) {
                items
                let next = BriefSections.split(meta.brief).next
                ForEach(Array(next.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 8) {
                        BriefHeading(section: section)
                            .font(.parley.footnote.weight(.semibold))
                            .foregroundStyle(Color(.secondaryLabel))
                            .accessibilityAddTraits(.isHeader)
                        BriefProse(markdown: section.body)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var items: some View {
        let groups = meta.actionItemsByOwner
        if groups.isEmpty {
            Text("No action items.")
                .font(.parley.subheadline)
                .foregroundStyle(Color(.secondaryLabel))
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(groups) { group($0) }
            }
        }
    }

    /// One owner's items under a header: a person mark (filled and tinted for
    /// the user), the owner's name, the count.
    private func group(_ group: RecordingMeta.ActionOwnerGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: icon(group.kind))
                    .font(.parley.caption)
                    .foregroundStyle(isSelf(group.kind) ? Theme.primary : Color(.secondaryLabel))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Group {
                    if let name = group.name {
                        Text(verbatim: name)
                    } else {
                        Text("Unassigned")
                    }
                }
                .font(.parley.footnote.weight(.semibold))
                .foregroundStyle(Color(.label))
                .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(group.items.count) items")
                    .font(.parley.caption.monospacedDigit())
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(group.items) { row($0) }
        }
    }

    private func isSelf(_ kind: RecordingMeta.ActionOwnerGroup.Kind) -> Bool {
        if case .speaker(_, true) = kind { return true }
        return false
    }

    private func icon(_ kind: RecordingMeta.ActionOwnerGroup.Kind) -> String {
        switch kind {
        case .speaker(_, let isSelf): isSelf ? "person.fill" : "person"
        case .named: "person"
        case .unassigned: "questionmark.circle"
        }
    }

    private func row(_ item: RecordingMeta.ActionItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            check(item)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: item.text)
                        .font(.parley.subheadline)
                        .foregroundStyle(item.done ? Color(.secondaryLabel) : Color(.label))
                        .strikethrough(item.done, color: Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let atMs = item.atMs {
                    MomentLink(ms: atMs, seek: seek)
                }
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator).opacity(0.6)).frame(height: 0.5)
        }
    }

    /// The system green on a done item: "this is done" in the platform's words.
    /// A button only where the tick is kept.
    @ViewBuilder
    private func check(_ item: RecordingMeta.ActionItem) -> some View {
        let mark = Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
            .font(.parley.body)
            .foregroundStyle(item.done ? Theme.success : Color(.tertiaryLabel))
        if canTick {
            Button {
                tick(item.id, !item.done)
            } label: {
                mark.frame(minWidth: 28, minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: item.text))
            .accessibilityValue(item.done ? Text("Done") : Text(verbatim: ""))
        } else {
            mark
                .accessibilityLabel(item.done ? Text("Done") : Text(verbatim: ""))
        }
    }
}

// MARK: - 筆記 / 會議背景

/// The notes typed during the meeting, or the background prepared before it —
/// read-only text out of the meeting context the desktop synced, under the
/// desktop's one-line caption. Timestamps in it seek, as everywhere.
struct ContextPage: View {
    let caption: LocalizedStringKey
    let text: String
    let seek: (UInt64) -> Void

    var body: some View {
        ResultScroll(seek: seek) {
            VStack(alignment: .leading, spacing: 10) {
                Text(caption)
                    .font(.parley.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
                BriefProse(markdown: text)
            }
        }
    }
}

// MARK: - 重點, on 回放

/// The analysis's findings, compact, above the transcript on 回放 — the
/// desktop's replay workbench keeps them beside the player and the transcript
/// for the same reason: they are moments to go and hear. One line each, with
/// its clock; a tap seeks there.
struct HighlightsStrip: View {
    let findings: [RecordingMeta.Finding]
    let seek: (UInt64) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Highlights")
                .font(.parley.footnote.weight(.semibold))
                .foregroundStyle(Color(.secondaryLabel))
                .accessibilityAddTraits(.isHeader)
            ForEach(findings) { finding in
                Button {
                    seek(finding.atMs)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "lightbulb")
                            .font(.parley.caption)
                            .foregroundStyle(
                                finding.severity == "info" ? Color(.secondaryLabel) : Theme.warning)
                            .accessibilityHidden(true)
                        Text(verbatim: finding.title)
                            .font(.parley.subheadline)
                            .foregroundStyle(Color(.label))
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(verbatim: TranscriptClipboard.clock(finding.atMs))
                            .font(.parley.caption.monospacedDigit())
                            .foregroundStyle(Theme.primary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Highlight: \(finding.title)"))
                .accessibilityValue(Text(verbatim: TranscriptClipboard.clock(finding.atMs)))
            }
        }
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }
}

// MARK: - pieces

/// A reading tab's scroll: the page's gutters, and the hook that turns a
/// timestamp link in running text into a seek.
struct ResultScroll<Content: View>: View {
    let seek: (UInt64) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
        }
        // A timestamp in prose is a link inside running text; this is where its
        // tap lands. Anything that is not ours goes on to the system.
        .environment(
            \.openURL,
            OpenURLAction { url in
                guard let ms = BriefProse.moment(from: url) else { return .systemAction }
                seek(ms)
                return .handled
            })
    }
}

/// A section's heading: the prompt's known headings in the reader's language
/// (the desktop's `study.brief.section.*`), any other as the model wrote it.
struct BriefHeading: View {
    let section: BriefSections.Section

    var body: some View {
        if let key = section.key {
            Text(Self.label(key))
        } else {
            Text(verbatim: section.title.trimmingCharacters(in: CharacterSet(charactersIn: ":：")))
        }
    }

    static func label(_ key: BriefSections.Key) -> LocalizedStringKey {
        switch key {
        case .highlights: "Highlights"
        case .decisions: "Decisions"
        case .openQuestions: "Open questions"
        case .nextAgenda: "For the next meeting"
        case .whereLanded: "Where it landed"
        case .painObjections: "Pain & objections"
        case .unknowns: "Still unknown"
        case .nextSteps: "Moving it forward"
        case .outcome: "Outcome"
        case .fellShort: "Fell short"
        case .improve: "Do better"
        case .keyMoments: "Key moments"
        }
    }
}

/// Markdown-lite prose (`BriefMarkup`): paragraphs, bold, bullets, and
/// `[m:ss]` timestamps as links whose URL carries the moment.
struct BriefProse: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(BriefMarkup.paragraphs(markdown).enumerated()), id: \.offset) { _, runs in
                Text(Self.attributed(runs))
                    .font(.parley.body)
                    .foregroundStyle(Color(.label))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    /// One paragraph as one `Text`, so it wraps as prose. Bold runs take the
    /// semibold face; a timestamp is a link whose URL carries the moment.
    static func attributed(_ runs: [BriefMarkup.Run]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            switch run {
            case .text(let text, let bold):
                var piece = AttributedString(text)
                if bold { piece.font = .parley.headline }
                out += piece
            case .timestamp(let ms, let label):
                var piece = AttributedString(label)
                piece.link = URL(string: "\(scheme):\(ms)")
                piece.font = .parley.subheadline.monospacedDigit()
                out += piece
            }
        }
        return out
    }

    private static let scheme = "parley-moment"

    static func moment(from url: URL) -> UInt64? {
        guard url.scheme == scheme else { return nil }
        return UInt64(url.absoluteString.dropFirst(scheme.count + 1))
    }
}

/// A moment, as a way into 回放: a play glyph and the clock, in the tint
/// because it can be tapped.
struct MomentLink: View {
    let ms: UInt64
    let seek: (UInt64) -> Void

    var body: some View {
        Button {
            seek(ms)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "play.fill")
                    .font(.parley.caption2)
                Text(verbatim: TranscriptClipboard.clock(ms))
                    .monospacedDigit()
            }
            .font(.parley.caption)
            .fixedSize()
            .frame(minHeight: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.primary)
        .accessibilityLabel(Text("Play from \(TranscriptClipboard.clock(ms))"))
    }
}

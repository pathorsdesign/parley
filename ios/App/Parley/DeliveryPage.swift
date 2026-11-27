import Charts
import ParleyKit
import SwiftUI

/// 評分, the desktop's post-meeting delivery report (`DeliveryReport` and the
/// `DeliveryScorecard` around it, `src/components/delivery/`), on a phone.
///
/// A switch over the recording's speakers, then the facts the transcript alone
/// can answer for the one picked — headline numbers, 01 語速與停頓, 02 語言習慣
/// — and last, 03 語氣與整體表達: the desktop's AI tone read, which only exists
/// for the user and only once the desktop has analysed the meeting. The phone
/// computes nothing with a model; every number here is `SpeechStats`.
///
/// Opens on the user when Parley knows who that is (`DeliverySpeakers`), else on
/// whoever talked most — and then asks which speaker is the user.
struct DeliveryPage: View {
    let meta: RecordingMeta
    /// Mark a speaker key as the user; nil clears the mark.
    let markSelf: (String?) -> Void
    let seek: (UInt64) -> Void

    @State private var picked: String?
    @State private var report: Report?

    /// Everything the page shows, computed once per input rather than on every
    /// render: the detail screen re-renders with the player's clock, and the
    /// regexes over a long meeting are not free.
    struct Report {
        let roster: [DeliverySpeakers.RosterEntry]
        let user: DeliverySpeakers.SelfSpeaker?
        let viewed: DeliverySpeakers.RosterEntry
        let stats: SpeechStats
        let ratio: (me: Double, them: Double)?
    }

    private var cacheKey: String {
        let segments = meta.raw["segments"] as? [Any]
        return [
            meta.id, String(segments?.count ?? 0), meta.selfSpeaker ?? "-", picked ?? "-",
        ].joined(separator: "|")
    }

    var body: some View {
        ResultScroll(seek: seek) {
            if let report {
                content(report)
            }
        }
        .task(id: cacheKey) { report = Self.build(meta: meta, picked: picked) }
    }

    static func build(meta: RecordingMeta, picked: String?) -> Report? {
        let segments = meta.segments
        let user = DeliverySpeakers.resolveSelf(segments, marked: meta.selfSpeaker)
        let roster = DeliverySpeakers.roster(segments, user: user)
        // A pick on a speaker that is gone falls back to the default.
        guard let viewed = roster.first(where: { $0.key == picked }) ?? roster.first else {
            return nil
        }
        let match = DeliverySpeakers.matching(viewed.key)
        return Report(
            roster: roster, user: user, viewed: viewed,
            stats: SpeechStats.compute(segments, isSelf: match),
            ratio: SpeechStats.talkShare(segments, isSelf: match))
    }

    @ViewBuilder
    private func content(_ r: Report) -> some View {
        // The pipeline's tone read is the user's; nobody else's is on the phone.
        let ownRead = r.viewed.isSelf && r.user != nil
        let assessment = ownRead ? meta.deliveryAssessment : nil
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                if r.user == nil {
                    Text(L("delivery.self.unknown"))
                        .font(.parley.footnote)
                        .foregroundStyle(Color(.secondaryLabel))
                        .fixedSize(horizontal: false, vertical: true)
                }
                speakerSwitch(r)
                kpis(r, assessment: assessment)
            }
            if r.stats.paceTimeline.count > 1 || !r.stats.pauses.isEmpty {
                group("01", L("delivery.group.pace"), L("delivery.group.pace.desc")) {
                    if r.stats.paceTimeline.count > 1 { PaceChart(stats: r.stats, seek: seek) }
                    if !r.stats.pauses.isEmpty { PauseChart(stats: r.stats, seek: seek) }
                }
            }
            group("02", L("delivery.group.habits"), L("delivery.group.habits.desc")) {
                fillers(r.stats)
                repeats(r.stats)
            }
            group("03", L("delivery.group.tone"), L("delivery.group.tone.desc")) {
                tone(ownRead: ownRead, assessment: assessment)
            }
        }
    }

    // MARK: the speaker switch

    private func label(_ entry: DeliverySpeakers.RosterEntry) -> String {
        meta.speakerLabel(
            for: TranscriptSegment(
                id: entry.key, source: entry.source, speaker: entry.speaker, text: "",
                isFinal: true, startMs: 0, endMs: 0))
    }

    /// The desktop's shadcn tabs: one segment per speaker with their share of
    /// the talk, on a grey track, the one on screen raised in white; the user
    /// first, with a person mark. The one action for the speaker on screen sits
    /// at the row's far end, as the desktop's outline button.
    private func speakerSwitch(_ r: Report) -> some View {
        // The desktop's row wraps: the switch and the action side by side when
        // they fit, else the action drops under it. A switch wider than the
        // page (a big call on a small phone) scrolls, its far edge fading.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                track(r).fixedSize()
                Spacer(minLength: 0)
                identity(r)
            }
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    track(r).fixedSize()
                    ScrollView(.horizontal, showsIndicators: false) {
                        track(r)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                    .mask(
                        HStack(spacing: 0) {
                            Color.black
                            LinearGradient(
                                colors: [.black, .clear], startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: 28)
                        })
                }
                identity(r)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L("delivery.speaker.aria")))
    }

    /// The grey track with one segment per speaker.
    private func track(_ r: Report) -> some View {
        let total = r.roster.reduce(0) { $0 + $1.talkMs }
        return HStack(spacing: 2) {
            ForEach(r.roster) { entry in
                segment(entry, active: entry.key == r.viewed.key, total: total)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.tertiarySystemFill)))
    }

    private func segment(_ entry: DeliverySpeakers.RosterEntry, active: Bool, total: Int) -> some View {
        let share = total > 0 ? Int((Double(entry.talkMs) / Double(total) * 100).rounded()) : 0
        return Button {
            picked = entry.key
        } label: {
            HStack(spacing: 5) {
                if entry.isSelf {
                    Image(systemName: "person")
                        .font(.parley.caption)
                        .accessibilityLabel(Text(L("delivery.speaker.me")))
                }
                Text(verbatim: label(entry))
                    .font(.parley.footnote.weight(active ? .medium : .regular))
                    .lineLimit(1)
                Text(verbatim: "\(share)%")
                    .font(.parley.footnote.monospacedDigit())
                    .foregroundStyle(Color(.secondaryLabel))
            }
            .foregroundStyle(active ? Color(.label) : Color(.secondaryLabel))
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background {
                if active {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }

    /// Who the speaker on screen is to Parley, and the one action that
    /// changes it: undo the user's own mark, or 標記為我 — an outline button
    /// either way, the desktop's.
    @ViewBuilder
    private func identity(_ r: Report) -> some View {
        if r.viewed.isSelf, let user = r.user {
            // An automatic answer (the desktop's mic track) has nothing to undo.
            if user.origin == .marked, meta.selfSpeaker == r.viewed.key {
                OutlineButton(title: L("delivery.speaker.unmark"), icon: "person.slash") {
                    markSelf(nil)
                }
            }
        } else {
            OutlineButton(title: L("delivery.speaker.markMe"), icon: "person") {
                markSelf(r.viewed.key)
            }
        }
    }

    // MARK: headline numbers

    private func kpis(_ r: Report, assessment: DeliveryAssessment?) -> some View {
        let stats = r.stats
        let talkMin = Double(stats.myTalkMs) / 60_000
        let fillerRate = talkMin >= 0.5 ? String(format: "%.1f", Double(stats.fillerTotal) / talkMin) : nil
        let avgPause =
            stats.pauses.isEmpty
            ? 0 : Double(stats.pauses.reduce(0) { $0 + $1.ms }) / Double(stats.pauses.count)
        return LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
            alignment: .leading, spacing: 10
        ) {
            if let pace = stats.textPace {
                Kpi(
                    label: L("delivery.kpi.pace"), value: "\(pace)", unit: L("delivery.unit.sylPerMin"),
                    sub: L("delivery.kpi.pace.fromText"))
            }
            Kpi(
                label: L("delivery.kpi.fillers"), value: "\(stats.fillerTotal)",
                unit: L("delivery.unit.times"),
                sub: fillerRate.map { F("delivery.kpi.perMin", $0) },
                watch: assessment?.fillersFrequent ?? false)
            if let ratio = r.ratio {
                let band = TalkBand(me: ratio.me)
                Kpi(
                    label: L("delivery.card.talkRatio"), value: "\(Int((ratio.me * 100).rounded()))%",
                    sub: L(band.key), watch: band.watch)
            }
            Kpi(
                label: L("delivery.kpi.pauses"), value: "\(stats.pauses.count)",
                unit: L("delivery.unit.times"),
                sub: stats.pauses.isEmpty ? nil : F("delivery.kpi.avgSec", seconds(avgPause)))
        }
    }

    // MARK: groups

    /// A numbered section: the number and title, what it covers under them, and
    /// a hairline above — the summary's section rule.
    private func group<Content: View>(
        _ n: String, _ title: String, _ desc: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: n)
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color(.secondaryLabel))
                    Text(title)
                        .font(.parley.headline)
                        .foregroundStyle(Color(.label))
                        .accessibilityAddTraits(.isHeader)
                }
                Text(desc)
                    .font(.parley.caption)
                    .foregroundStyle(Color(.secondaryLabel))
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 20)
        .overlay(alignment: .top) {
            Rectangle().fill(Color(.separator)).frame(height: 0.5)
        }
    }

    // MARK: 02 語言習慣

    private func fillers(_ stats: SpeechStats) -> some View {
        ChartBlock(title: L("delivery.chart.fillers")) {
            if stats.fillers.isEmpty {
                Text(L("delivery.chart.fillers.none"))
                    .font(.parley.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
            } else {
                WordBars(items: stats.fillers, total: stats.fillerTotal)
            }
        }
    }

    private func repeats(_ stats: SpeechStats) -> some View {
        ChartBlock(title: L("delivery.chart.repeats")) {
            if stats.repetitions.isEmpty {
                Text(L("delivery.chart.repeats.none"))
                    .font(.parley.footnote)
                    .foregroundStyle(Color(.secondaryLabel))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: "\(stats.repetitions.count)")
                            .font(.parley.title2.monospacedDigit())
                        Text(L("delivery.unit.times"))
                            .font(.parley.caption)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(stats.repetitions.prefix(4).enumerated()), id: \.offset) { index, rep in
                            HStack(spacing: 8) {
                                Text(verbatim: "「\(rep.text)」")
                                    .font(.parley.footnote)
                                    .foregroundStyle(Color(.label).opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: 8)
                                Stamp(ms: rep.atMs, seek: seek)
                            }
                            .padding(.vertical, 2)
                            .overlay(alignment: .top) {
                                if index > 0 {
                                    Rectangle().fill(Color(.separator)).frame(height: 0.5)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 03 語氣與整體表達

    @ViewBuilder
    private func tone(ownRead: Bool, assessment: DeliveryAssessment?) -> some View {
        if let assessment, !assessment.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if let verdict = assessment.tone {
                    ToneRow(label: L("delivery.card.tone")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("delivery.tone.\(verdict.rawValue)"))
                                .font(.parley.subheadline.weight(.semibold))
                                .foregroundStyle(Self.toneColor(verdict))
                            if !assessment.toneEvidence.isEmpty {
                                Text(verbatim: "“\(assessment.toneEvidence)”")
                                    .font(.parley.footnote.italic())
                                    .foregroundStyle(Color(.secondaryLabel))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if assessment.fillerLevel != nil {
                    let frequent = assessment.fillersFrequent
                    ToneRow(label: L("delivery.card.fillers")) {
                        Text(
                            verbatim: F(
                                "delivery.chart.fillers.ai",
                                L(frequent ? "delivery.filler.frequent" : "delivery.filler.ok"))
                                + (assessment.fillerNote.isEmpty ? "" : " · \(assessment.fillerNote)")
                        )
                        .font(.parley.footnote)
                        .foregroundStyle(frequent ? Theme.warningText : Color(.label))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !assessment.summary.isEmpty {
                    Text(verbatim: assessment.summary)
                        .font(.parley.subheadline)
                        .foregroundStyle(Color(.label).opacity(0.85))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L("delivery.card.tone.advisory"))
                    .font(.parley.caption2)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
        } else {
            Text(L(ownRead ? "delivery.tone.desktop" : "delivery.tone.others"))
                .font(.parley.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The desktop's `toneClass`: neutral and firm are fine, sharp and up warn.
    static func toneColor(_ tone: DeliveryAssessment.Tone) -> Color {
        switch tone {
        case .rude, .aggressive: Theme.destructive
        case .sharp: Theme.warningText
        case .warm: Theme.success
        case .neutral, .firm: Color(.label)
        }
    }
}

// MARK: - pieces

/// Chart marks are grey only, as on the desktop: emphasis, then normal.
private enum Mark {
    static let strong = Color(.systemGray)
    static let normal = Color(.systemGray3)
}

/// A catalog string by key — the desktop's `delivery.*` keys, kept as keys so
/// the two apps' wording can be compared line for line.
private func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// A catalog format string (`%@` placeholders) filled in.
private func F(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}

/// Seconds with one decimal, the desktop's `sec`.
private func seconds(_ ms: Double) -> String {
    String(format: "%.1f", ms / 1000)
}

/// The desktop's `talkBand`: ≥65% of the talking reads as steamrolling, ≤35%
/// as quiet.
private struct TalkBand {
    let key: String
    let watch: Bool

    init(me: Double) {
        if me >= 0.65 {
            (key, watch) = ("delivery.talk.high", true)
        } else if me <= 0.35 {
            (key, watch) = ("delivery.talk.low", false)
        } else {
            (key, watch) = ("delivery.talk.balanced", false)
        }
    }
}

/// One headline number.
private struct Kpi: View {
    let label: String
    let value: String
    var unit: String?
    var sub: String?
    var watch = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.parley.caption)
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: value)
                    .font(.parley.title2.monospacedDigit())
                    .foregroundStyle(watch ? Theme.warningText : Color(.label))
                if let unit {
                    Text(unit)
                        .font(.parley.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            Text(sub ?? " ")
                .font(.parley.caption2)
                .foregroundStyle(Color(.secondaryLabel))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// The desktop's `Chart` card: a small grey title, the chart, and — under a
/// hairline — an optional one-line reading of it.
private struct ChartBlock<Content: View, Note: View>: View {
    let title: String
    let hasNote: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let note: Note

    init(title: String, @ViewBuilder content: () -> Content, @ViewBuilder note: () -> Note) {
        self.title = title
        self.hasNote = true
        self.content = content()
        self.note = note()
    }

    fileprivate init(title: String, noNote content: () -> Content) where Note == EmptyView {
        self.title = title
        self.hasNote = false
        self.content = content()
        self.note = EmptyView()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.parley.footnote.weight(.semibold))
                    .foregroundStyle(Color(.secondaryLabel))
                    .accessibilityAddTraits(.isHeader)
                content
            }
            .padding(14)
            if hasNote {
                Rectangle().fill(Color(.separator)).frame(height: 0.5)
                note
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5))
    }
}

extension ChartBlock where Note == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, noNote: content)
    }
}

/// A chart's reading: text, then the moment it points at.
private struct NoteLine: View {
    let parts: [(text: String, ms: Int)]
    let seek: (UInt64) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                HStack(spacing: 5) {
                    if index > 0 {
                        Text(verbatim: "·").foregroundStyle(Color(.tertiaryLabel))
                    }
                    Text(verbatim: part.text)
                        .font(.parley.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                    Stamp(ms: part.ms, seek: seek)
                }
            }
        }
    }
}

/// The desktop's `Stamp`: a meeting moment as a small neutral outlined chip in
/// mono digits. On the phone it also jumps to that moment on 回放.
private struct Stamp: View {
    let ms: Int
    let seek: (UInt64) -> Void

    var body: some View {
        Button {
            seek(UInt64(max(0, ms)))
        } label: {
            Text(verbatim: SpeechStats.clock(ms))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color(.secondaryLabel))
                .padding(.horizontal, 5)
                .frame(minHeight: 18)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(Color(.separator), lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The desktop's `Button variant="outline" size="sm"`: a hairline-bordered
/// rounded rectangle on the page colour, label-coloured, with a glyph.
private struct OutlineButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.parley.caption)
                    .accessibilityHidden(true)
                Text(verbatim: title)
                    .font(.parley.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .fixedSize()
            .foregroundStyle(Color(.label))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(.systemBackground)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Pace over the meeting: a thin line per bucket, the average dashed across.
private struct PaceChart: View {
    let stats: SpeechStats
    let seek: (UInt64) -> Void

    private struct Point: Identifiable {
        let x: Int
        let atMs: Int
        let perMin: Int
        var id: Int { atMs }
    }

    var body: some View {
        let points = stats.paceTimeline.map {
            Point(x: $0.atMs + stats.bucketMs / 2, atMs: $0.atMs, perMin: $0.perMin)
        }
        let values = points.map(\.perMin)
        let avg = stats.textPace ?? Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        // The desktop's reduce keeps the first of equal values.
        let fastest = points.reduce(points[0]) { $1.perMin > $0.perMin ? $1 : $0 }
        let slowest = points.reduce(points[0]) { $1.perMin < $0.perMin ? $1 : $0 }
        let low = max(0, Int((Double(min(values.min() ?? 0, avg)) * 0.85 / 10).rounded(.down)) * 10)
        let high = max(low + 10, Int((Double(max(values.max() ?? 0, avg)) * 1.08 / 10).rounded(.up)) * 10)
        let duration = max(stats.durationMs, 1)
        return ChartBlock(title: L("delivery.chart.pace")) {
            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("t", p.x), yStart: .value("lo", low), yEnd: .value("pace", p.perMin))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Mark.normal.opacity(0.35))
                    LineMark(x: .value("t", p.x), y: .value("pace", p.perMin))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .foregroundStyle(Mark.strong)
                }
                RuleMark(y: .value("avg", avg))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color(.secondaryLabel).opacity(0.6))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text(verbatim: F("delivery.chart.pace.avg", "\(avg)"))
                            .font(.parley.caption2)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                PointMark(x: .value("t", fastest.x), y: .value("pace", fastest.perMin))
                    .symbolSize(30)
                    .foregroundStyle(Mark.strong)
                PointMark(x: .value("t", slowest.x), y: .value("pace", slowest.perMin))
                    .symbolSize(30)
                    .foregroundStyle(Mark.normal)
            }
            .chartXScale(domain: 0...duration)
            .chartYScale(domain: low...high)
            .chartXAxis { timeAxis(duration) }
            .chartYAxis {
                AxisMarks(position: .leading, values: [low, (low + high + 1) / 2, high]) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color(.separator))
                    AxisValueLabel()
                        .font(.parley.caption2)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .frame(height: 144)
            .accessibilityLabel(Text(L("delivery.chart.pace")))
        } note: {
            NoteLine(
                parts: [
                    (F("delivery.chart.pace.fastest", "\(fastest.perMin)"), fastest.atMs),
                    (F("delivery.chart.pace.slowest", "\(slowest.perMin)"), slowest.atMs),
                ], seek: seek)
        }
    }
}

/// Where the pauses fell: one thin bar per pause at its time, taller for
/// longer ones, the longest drawn darker.
private struct PauseChart: View {
    let stats: SpeechStats
    let seek: (UInt64) -> Void

    var body: some View {
        let pauses = stats.pauses
        let longest = pauses.reduce(pauses[0]) { $1.ms > $0.ms ? $1 : $0 }
        let top = max(1, Int((Double(longest.ms) / 1000).rounded(.up)))
        let duration = max(stats.durationMs, 1)
        return ChartBlock(title: L("delivery.chart.pauses")) {
            Chart {
                ForEach(Array(pauses.enumerated()), id: \.offset) { _, p in
                    BarMark(
                        x: .value("t", p.atMs),
                        yStart: .value("s", 0),
                        yEnd: .value("s", max(Double(p.ms) / 1000, Double(top) * 0.03)),
                        width: .fixed(3))
                        .foregroundStyle(p == longest ? Mark.strong : Mark.normal)
                        .clipShape(Capsule())
                }
            }
            .chartXScale(domain: 0...duration)
            .chartYScale(domain: 0...Double(top))
            .chartXAxis { timeAxis(duration) }
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, Double(top)]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                        .foregroundStyle(Color(.separator))
                    AxisValueLabel {
                        Text(verbatim: "\(Int(value.as(Double.self) ?? 0))s")
                            .font(.parley.caption2)
                            .foregroundStyle(Color(.secondaryLabel))
                    }
                }
            }
            .frame(height: 120)
            .accessibilityLabel(Text(L("delivery.chart.pauses")))
        } note: {
            NoteLine(
                parts: [(F("delivery.chart.pauses.longest", seconds(Double(longest.ms))), longest.atMs)],
                seek: seek)
        }
    }
}

/// The shared time axis: start, middle and end of the meeting.
private func timeAxis(_ duration: Int) -> some AxisContent {
    AxisMarks(values: [0, duration / 2, duration]) { value in
        AxisValueLabel(anchor: anchor(value.index)) {
            Text(verbatim: SpeechStats.clock(value.as(Int.self) ?? 0))
                .font(.parley.caption2.monospacedDigit())
                .foregroundStyle(Color(.secondaryLabel))
        }
    }
}

/// Keep the end labels inside the plot: the first hangs right, the last left.
private func anchor(_ index: Int) -> UnitPoint {
    switch index {
    case 0: .topLeading
    case 2: .topTrailing
    default: .top
    }
}

/// Ranked horizontal bars: which words, how often, "n · p%" after each; the
/// top one drawn darker.
private struct WordBars: View {
    let items: [FillerCount]
    let total: Int

    var body: some View {
        let top = max(items.first?.count ?? 1, 1)
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.word) { index, item in
                GridRow {
                    Text(verbatim: item.word)
                        .font(.parley.footnote)
                        .foregroundStyle(Color(.label).opacity(0.85))
                        .lineLimit(1)
                        .fixedSize()
                    GeometryReader { g in
                        Capsule()
                            .fill(index == 0 ? Mark.strong : Mark.normal)
                            .frame(width: max(4, g.size.width * CGFloat(item.count) / CGFloat(top)))
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 12)
                    Text(
                        verbatim:
                            "\(item.count) · \(Int((Double(item.count) / Double(max(total, 1)) * 100).rounded()))%"
                    )
                    .font(.parley.caption.monospacedDigit())
                    .foregroundStyle(Color(.secondaryLabel))
                    .fixedSize()
                    .gridColumnAlignment(.trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A labelled row of the tone group: the label in a fixed column, the reading
/// beside it.
private struct ToneRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.parley.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .frame(minWidth: 44, alignment: .leading)
                .fixedSize()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

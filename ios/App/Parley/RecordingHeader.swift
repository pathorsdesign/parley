import ParleyKit
import SwiftUI

/// The result page's tabs. The row shows 總結 · 後續行動 · 評分 · 回放 in this
/// order, with 筆記 and 會議背景 behind 更多 ▾ (see `ResultTabBar`). 評分 is
/// the desktop's delivery report, computed from the transcript on the phone.
enum ResultTab: String, Hashable, CaseIterable {
    case summary, actions, delivery, notes, context, replay

    /// The desktop's `study.tab.*` labels. Keyed rather than written in
    /// English because "Summary", "Notes" and "Replay" are already catalog
    /// keys elsewhere in the app with other Chinese (摘要, 備忘錄, 重播), and
    /// these must read as the desktop's 總結, 筆記, 回放.
    var label: LocalizedStringKey {
        switch self {
        case .summary: "result.tab.summary"
        case .actions: "result.tab.actions"
        case .delivery: "result.tab.delivery"
        case .notes: "result.tab.notes"
        case .context: "result.tab.context"
        case .replay: "result.tab.replay"
        }
    }
}

// MARK: - the name

/// The recording's name, large, at the top of the page — the desktop's
/// `RecordingTitle`. Tapping it turns it into a field in place; Return or
/// tapping away saves, and an emptied field cancels. Next to it, while the
/// name is still the one the filing pass gave it this session, a quiet
/// 「自動命名」 tag: Parley named it, so the user knows it is theirs to change.
///
/// Read-only recordings (an organization's) show the name as plain text.
struct RecordingTitleView: View {
    let title: String
    let editable: Bool
    let autoNamed: Bool
    /// Saves a name the user typed. Throws back here so the line under the
    /// title can say it did not land.
    let rename: (String) async throws -> Void

    @State private var draft: String?
    @State private var saving = false
    @State private var failed: String?
    @FocusState private var focused: Bool
    /// How much of a name that just landed has typed itself in. nil = all.
    @State private var typed: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if draft != nil {
                field
            } else {
                FlowLayout(spacing: 8, lineSpacing: 6) {
                    name
                    if autoNamed { tag }
                }
            }
            if let failed {
                Text(verbatim: failed)
                    .font(.parley.caption)
                    .foregroundStyle(Theme.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The name Parley just gave it types itself in, so it reads as
        // something that just happened rather than a name that was always
        // there — only when it lands while the page is open.
        .onChange(of: autoNamed) { was, now in
            guard !was, now, !reduceMotion, !title.isEmpty else { return }
            typed = 0
            Task { @MainActor in
                for count in 1...title.count {
                    try? await Task.sleep(for: .seconds(LapMotion.perCharacter))
                    typed = count
                }
                typed = nil
            }
        }
    }

    private var shownTitle: String {
        let full = title.isEmpty ? String(localized: "Untitled recording") : title
        guard let typed else { return full }
        return LapMotion.typed(full, count: typed)
    }

    @ViewBuilder
    private var name: some View {
        let text = Text(verbatim: shownTitle)
            .font(.parley.title2)
            .foregroundStyle(Color(.label))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
        if editable {
            Button {
                failed = nil
                draft = title
                focused = true
            } label: {
                // The pencil says the name can be changed before anyone has to
                // discover it, as the desktop's does.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    text
                    Image(systemName: "pencil")
                        .font(.parley.footnote)
                        .foregroundStyle(Color(.tertiaryLabel))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityHint(Text("Tap to rename"))
        } else {
            text.accessibilityAddTraits(.isHeader)
        }
    }

    private var tag: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .accessibilityHidden(true)
            Text("Auto-named")
        }
        .font(.parley.caption2)
        .foregroundStyle(Color(.secondaryLabel))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color(.tertiarySystemFill)))
        .accessibilityHint(Text("Parley named this from the conversation. Tap the title to change it."))
    }

    private var field: some View {
        TextField("Title", text: Binding(get: { draft ?? "" }, set: { draft = $0 }), axis: .vertical)
            .font(.parley.title2)
            .foregroundStyle(Color(.label))
            .focused($focused)
            .submitLabel(.done)
            .onSubmit(commit)
            // A vertical field turns Return into a newline; a title is one
            // line, so Return saves.
            .onChange(of: draft) { _, text in
                guard let text, text.contains("\n") else { return }
                draft = text.replacingOccurrences(of: "\n", with: "")
                commit()
            }
            // Tapping away saves, as clicking away does on the desktop.
            .onChange(of: focused) { _, now in
                if !now { commit() }
            }
            .padding(.vertical, 2)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.primary).frame(height: 1).offset(y: 2)
            }
    }

    private func commit() {
        guard let typed = draft else { return }
        draft = nil
        focused = false
        let clean = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != title else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await rename(clean)
            } catch {
                failed = String(localized: "Rename failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - the filing row

/// Where this recording lives, one line under its name — the desktop's
/// `FilingRow`, in its three states:
///
/// - **filed** → the folder's name and 「變更」, which opens the folder picker;
/// - **unfiled with a folder suggestion** → 「建議放進」 and one chip per
///   suggested folder (the first one emphasized; a new-folder chip is dashed
///   and creates the folder), 「選其他資料夾…」 and 「先不歸檔」;
/// - **unfiled, nothing suggested** → 「還沒歸檔」 and 「放進資料夾」.
///
/// Only the folder is suggested here. The title was applied by the filing pass
/// already (`FilingSuggestionModel`), and the header's 「自動命名」 tag says so.
///
/// An organization's recording shows where it lives in the organization; it
/// keeps 「變更」 only when there are folders to move it between, the one move
/// its endpoint allows.
///
/// The row wraps rather than truncating a chip: a folder is a customer, and a
/// chip whose name is cut off is a chip nobody can choose.
struct FilingRow: View {
    @ObservedObject var model: FilingSuggestionModel
    /// The folder the recording is filed in, by name. nil = unfiled.
    let folderName: String?
    /// The organization's name for an org recording.
    let orgName: String?
    /// Whether the picker can move it anywhere.
    let movable: Bool
    /// Whether the suggestion may be offered — personal recordings only.
    let offers: Bool
    /// The guide bar's "look here" wash.
    let highlighted: Bool
    let openPicker: () -> Void
    let file: (FilingFolderSuggestion) -> Void
    let dismiss: () -> Void

    @State private var introduced = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var offering: Bool { offers && folderName == nil && model.hasSomethingToOffer }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: orgName == nil ? "folder" : "person.2")
                .font(.parley.footnote)
                .foregroundStyle(Color(.secondaryLabel))
                .accessibilityHidden(true)
            FlowLayout(spacing: 8, lineSpacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.parley.footnote)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Theme.primary.opacity(highlighted ? 0.12 : 0)))
        .padding(.horizontal, -6)
        .animation(.easeOut(duration: 0.6), value: highlighted)
        .disabled(model.isWriting)
        // The suggestion springs in the first time it shows, as the desktop's
        // does, so it reads as something Parley just did.
        .scaleEffect(offering && !introduced && !reduceMotion ? 0.97 : 1, anchor: .leading)
        .opacity(offering && !introduced && !reduceMotion ? 0 : 1)
        .onChange(of: offering, initial: true) { _, now in
            guard now, !introduced else { return }
            withAnimation(reduceMotion ? nil : LapMotion.spring) { introduced = true }
        }
        .animation(reduceMotion ? nil : LapMotion.spring, value: offering)
    }

    @ViewBuilder
    private var content: some View {
        if let orgName {
            pill(Text(verbatim: orgName), tinted: true)
            if let folderName { pill(Text(verbatim: folderName), tinted: false) }
            if movable { textButton(Text("Change"), action: openPicker) }
        } else if let folderName {
            pill(Text(verbatim: folderName), tinted: false)
            if movable { textButton(Text("Change"), action: openPicker) }
        } else if offering {
            Text("File under")
                .foregroundStyle(Color(.secondaryLabel))
            ForEach(Array(model.proposedFolders.enumerated()), id: \.element.name) { index, folder in
                chip(folder, primary: index == 0)
            }
            Button(action: openPicker) {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.questionmark")
                        .accessibilityHidden(true)
                    Text("Choose another folder…")
                }
                .foregroundStyle(Color(.secondaryLabel))
                .frame(minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            textButton(Text("result.filing.notNow"), muted: true, action: dismiss)
            if model.writeFailed {
                Text("That didn't save. Try again.")
                    .font(.parley.caption2)
                    .foregroundStyle(Theme.destructive)
            }
        } else {
            Text("Not filed yet")
                .foregroundStyle(Color(.secondaryLabel))
            if movable { textButton(Text("Put it in a folder"), action: openPicker) }
        }
    }

    /// One suggested folder. The best guess is filled in; the rest are
    /// outlines; a folder that does not exist yet is dashed and says it will be
    /// created. One tap files — the desktop's chip, not a choice to confirm.
    private func chip(_ folder: FilingFolderSuggestion, primary: Bool) -> some View {
        let isNew = folder.folderId == nil
        return Button {
            file(folder)
        } label: {
            HStack(spacing: 4) {
                if isNew {
                    Image(systemName: "plus")
                        .font(.parley.caption2.weight(.semibold))
                        .accessibilityHidden(true)
                }
                Group {
                    if isNew {
                        Text("New folder “\(folder.name)”")
                    } else {
                        Text(verbatim: folder.name)
                    }
                }
                .font(.parley.footnote.weight(.medium))
                .lineLimit(1)
            }
            .foregroundStyle(primary ? Theme.primary : Color(.label))
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(
                Capsule().fill(primary ? Theme.primary.opacity(0.1) : Color.clear))
            .overlay(
                Capsule().strokeBorder(
                    primary
                        ? (isNew ? Theme.primary.opacity(0.4) : Color.clear)
                        : Color(.separator),
                    style: StrokeStyle(lineWidth: 1, dash: isNew ? [3, 2] : [])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text(verbatim: folder.reason))
    }

    /// Where it is filed: a quiet capsule, the desktop's folder pill.
    private func pill(_ text: Text, tinted: Bool) -> some View {
        text
            .font(.parley.footnote.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(tinted ? Theme.primary : Color(.label))
            .padding(.horizontal, 10)
            .frame(minHeight: 26)
            .background(Capsule().fill(tinted ? Theme.primary.opacity(0.1) : Color.clear))
            .overlay(Capsule().strokeBorder(tinted ? Color.clear : Color(.separator), lineWidth: 1))
    }

    private func textButton(_ text: Text, muted: Bool = false, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            text
                .foregroundStyle(muted ? Color(.secondaryLabel) : Theme.primary)
                .frame(minHeight: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - the tabs

/// The underline tablist, the desktop's `StudyTabs`: the active tab in ink with
/// a short blue rule under it, the rest secondary. Counts ride next to 後續行動
/// and 筆記 when non-zero. It scrolls sideways when the five do not fit, which
/// in English on a small phone they do not.
struct ResultTabBar: View {
    let tabs: [ResultTab]
    @Binding var selection: ResultTab
    var counts: [ResultTab: Int] = [:]
    /// Something is playing while the replay tab is out of sight: a small
    /// pause at the end of the row, so the audio is never running with no
    /// way to stop it.
    var playingElsewhere = false
    var pause: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            // The fixed tabs — 總結, 後續行動, 評分 (when there is a
            // transcript to score), 回放 — and, when
            // the meeting has notes or a background, a 更多 ▾ menu after them for
            // those two. Five tabs in a row overran a small phone (in English,
            // Replay, the tab with the player, was off-screen), and the two
            // that come and go are the ones most meetings do not have.
            //
            // The full spacing when it fits, a tighter one when that fits, and
            // a scrolling strip with fading edges only as the last resort (the
            // largest text sizes).
            ViewThatFits(in: .horizontal) {
                row(spacing: 22, inset: 20)
                row(spacing: 14, inset: 16)
                scrollingRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if playingElsewhere {
                Button(action: pause) {
                    Image(systemName: "pause.circle.fill")
                        .font(.parley.title3)
                        .foregroundStyle(Theme.primary)
                        .frame(width: 44, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Pause"))
                .transition(.opacity)
                .padding(.trailing, 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: playingElsewhere)
        .background(Theme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator))
                .frame(height: 0.5)
        }
    }

    /// The tabs always in the row.
    private var primary: [ResultTab] { tabs.filter { $0 != .notes && $0 != .context } }
    /// The ones behind 更多: present only when the meeting has them.
    private var secondary: [ResultTab] { tabs.filter { $0 == .notes || $0 == .context } }

    private func row(spacing: CGFloat, inset: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(primary, id: \.self) { tab in
                button(tab)
            }
            if !secondary.isEmpty { moreMenu }
        }
        .padding(.horizontal, inset)
        .fixedSize()
    }

    private var scrollingRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .bottom, spacing: 18) {
                    ForEach(primary, id: \.self) { tab in
                        button(tab).id(tab)
                    }
                    if !secondary.isEmpty { moreMenu.id(ResultTab.notes) }
                }
                .padding(.leading, 16)
                .padding(.trailing, 28)
            }
            // Both edges fade, so a tab cut by either edge reads as one that
            // continues rather than as a clipped word.
            .mask(
                HStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0), .black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 16)
                    Color.black
                    LinearGradient(
                        colors: [.black, .black.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 28)
                })
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
            .onChange(of: selection) { _, tab in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(tab, anchor: .center) }
            }
        }
    }

    /// 更多 ▾: the notes and the background. Once one of them is open the
    /// menu wears its name (筆記 ▾) and the tab's underline, so the row still
    /// says where the reader is.
    private var moreMenu: some View {
        let chosen = secondary.contains(selection) ? selection : nil
        return Menu {
            ForEach(secondary, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    if tab == selection {
                        Label(tab.label, systemImage: "checkmark")
                    } else {
                        Text(tab.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(chosen?.label ?? "More")
                    .font(chosen != nil ? .parley.subheadline.weight(.semibold) : .parley.subheadline)
                    .foregroundStyle(chosen != nil ? Color(.label) : Color(.secondaryLabel))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
            }
            .padding(.top, 6)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(chosen != nil ? Theme.primary : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen != nil ? .isSelected : [])
    }

    private func button(_ tab: ResultTab) -> some View {
        let active = tab == selection
        let count = counts[tab] ?? 0
        return Button {
            selection = tab
        } label: {
            HStack(spacing: 5) {
                Text(tab.label)
                    .font(active ? .parley.subheadline.weight(.semibold) : .parley.subheadline)
                    .foregroundStyle(active ? Color(.label) : Color(.secondaryLabel))
                if count > 0 {
                    Text(verbatim: "\(count)")
                        .font(.parley.caption2.weight(.medium).monospacedDigit())
                        .foregroundStyle(active ? Theme.primary : Color(.secondaryLabel))
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(
                            Capsule().fill(
                                active ? Theme.primary.opacity(0.1) : Color(.tertiarySystemFill)))
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Capsule()
                    .fill(active ? Theme.primary : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - layout

/// Lays its children out left to right and wraps onto a new line when the
/// next one does not fit — the desktop's `flex-wrap`. A child wider than the
/// row is offered the whole row and wraps inside itself.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                // Baseline-ish: each child centred in its row's height.
                let dy = (row.height - item.size.height) / 2
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + dy), anchor: .topLeading,
                    proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

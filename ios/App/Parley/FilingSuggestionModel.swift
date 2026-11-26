import Foundation
import ParleyKit
import SwiftUI

/// The post-transcription filing pass for one recording, as its result page
/// shows it: the **name**, applied on its own, and the **folder**, suggested.
///
/// The phone names every recording after the clock — "Meeting Sep 7, 3:20 PM"
/// — and a library of rows nobody can tell apart is a dead end rather than an
/// annoyance. Neither answer can come any earlier than this: a name worth
/// having needs a transcript to read, and the right folder needs somebody to
/// know what the meeting was about.
///
/// ## The title is applied, the folder is offered
///
/// The same split as the desktop (`lib/analysis/filingRun.ts`). A recording
/// called after the clock helps nobody, and the name is trivially changed back
/// — tap it in the page header — so the pass's title is written straight away
/// and flagged as Parley's (`AutoNamedTitles`, the header's 「自動命名」 tag)
/// until anyone renames it. The folder is a different kind of answer: filing a
/// meeting under the wrong customer is a mistake the user would have to notice
/// to undo, so it stays a suggestion — the page header's filing row
/// (`FilingRow`), one tap per folder.
///
/// A name the user gave the meeting while it was recording (`Settled.named`)
/// is never written over: the pass is told, and proposes no title at all.
///
/// It waits for the UPLOAD to settle, not for the microphone to stop. A rename
/// or a re-file is a write against a recording the server has to already hold.
///
/// Every part of it is best-effort. A failed folder listing, a failed pass, a
/// failed push: each leaves the recording exactly as the upload left it, and
/// only a write the user explicitly asked for (a chip) ever says so.
///
/// ## Two ways in
///
/// A result page opened because its meeting just ended asks for the pass
/// (`consider`) — joining the one the upload already started (`FilingPass`),
/// which persists its answer into the meta. Opened any other way, the page
/// shows a suggestion already *pending* on the recording (`present`): any pass
/// — this phone's on an import or a queued upload, or the desktop's — leaves
/// one in the synced meta's `filingSuggestion`, and the bundled sample ships
/// with one. A pending suggestion that still carries a title is a pass whose
/// name nobody has applied yet, so `present` applies it too.
///
/// The writes differ only in where they land — `Target` — and both answer the
/// folder half the same way: a cloud recording's meta gets
/// `filingSuggestion: null` and `filingSuggested: true` (the desktop's
/// "resolved"), the sample's local entry gets `suggestionPending = false`.
@MainActor
final class FilingSuggestionModel: ObservableObject {

    /// Where an answer is written.
    enum Target: Equatable {
        /// A personal cloud recording: one read-modify-write of its meta.
        case cloud(id: String)
        /// The bundled sample: `SampleRecordingStore`, on this phone only. A
        /// new folder is still created in the cloud — it is a real folder the
        /// user now has — and only the filing itself stays local.
        case sample
    }

    /// The folder half still on offer. Never carries a title: the title is
    /// applied, not offered (see the type doc).
    @Published private(set) var suggestion: FilingSuggestion?
    /// What the recording is called and where it is filed right now, as the
    /// pass and every write since have left it.
    @Published private(set) var currentTitle = ""
    @Published private(set) var currentFolderId: String?
    /// The folders the user already has, as the pass listed them.
    @Published private(set) var existingFolders: [CloudFolder] = []
    /// A push is in flight. One at a time: every write read-modify-writes the
    /// same meta, so two together let the slower one push a copy it read
    /// before the faster one landed — silently undoing it.
    @Published private(set) var isWriting = false
    /// A push the user asked for did not land. Never raised for the title the
    /// pass applies by itself: nobody asked for that one, so its failure is
    /// silence.
    @Published private(set) var writeFailed = false

    /// Where the visible suggestion's answer is written. nil = nothing on offer.
    private var target: Target?
    /// Told after each write that landed: the new title (if it changed), where
    /// the recording is now filed (if that changed), and a folder created for
    /// it (if one was). The page keeps its header and folder list in step.
    var onApplied: ((_ title: String?, _ filed: FolderDestination?, _ created: CloudFolder?) -> Void)?
    /// Told once the folder offer is answered — filed, or skipped — so a page
    /// that presented it from the recording's own data stops presenting it.
    var onRetired: (() -> Void)?
    /// The recording the pass has already been spent on. Not cleared by
    /// `forget()`: a dismissed offer stays dismissed, and the page's `task`
    /// runs again every time it reappears.
    private var consideredId: String?
    /// The user has said where this recording lives. Recorded rather than
    /// compared away: a new-folder candidate has no id to compare against,
    /// and a second tap on it must not create a second folder.
    private var folderAnswered = false
    /// The pass's title being written, while it is.
    private var namingTask: Task<Void, Never>?
    private var pass: Task<Void, Never>?

    // MARK: what is left to offer

    /// The folders still worth offering — none once the user has answered.
    /// The chip pointing at the folder the recording is already in is
    /// dropped; a `nil` id is compared out explicitly rather than by equality,
    /// because `nil` is also "the personal root", and an unfiled recording is
    /// exactly the case a brand-new folder gets proposed for.
    var proposedFolders: [FilingFolderSuggestion] {
        guard !folderAnswered, let suggestion else { return [] }
        let live = suggestion.folders.filter { folder in
            folder.folderId == nil || folder.folderId != currentFolderId
        }
        return Array(live.prefix(3))
    }

    var hasSomethingToOffer: Bool { !proposedFolders.isEmpty }

    /// Identity for a candidate folder. A folder that does not exist yet has no
    /// id, so it is keyed by the name it would be created under.
    static func key(for folder: FilingFolderSuggestion) -> String {
        folder.folderId ?? "new:\(folder.name)"
    }

    // MARK: the pass

    /// Run the filing pass for a recording whose upload has settled. Safe to
    /// call more than once for the same recording: only the first call spends
    /// the pass.
    ///
    /// The work is owned by this object rather than by the view's `task`, so
    /// switching tabs mid-pass does not cancel it.
    func consider(_ settled: MeetingRecorder.Settled, app: AppState) {
        guard consideredId != settled.id else { return }
        consideredId = settled.id
        pass = Task { [weak self] in
            await self?.run(settled, app: app)
        }
    }

    /// Drop the offer without writing anything. Clears `target`, so a write
    /// ordered after this one is a no-op.
    func forget() {
        pass?.cancel()
        pass = nil
        namingTask?.cancel()
        namingTask = nil
        suggestion = nil
        target = nil
        currentTitle = ""
        currentFolderId = nil
        existingFolders = []
        folderAnswered = false
        isWriting = false
        writeFailed = false
    }

    private func run(_ settled: MeetingRecorder.Settled, app: AppState) async {
        guard app.signedIn else { return }
        // An auto-shared organization copy is the one the user will open, and
        // the phone can neither rename nor re-file it. The desktop skips the
        // same case for the same reason.
        guard !settled.sharedToOrg else { return }
        // Named and filed while it recorded: nothing left to answer.
        guard !(settled.named && settled.filed) else { return }
        // Only what was actually said. A recording with no final transcript has
        // nothing for the pass to read.
        let spoken = settled.segments.filter { segment in
            segment.isFinal
                && !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !spoken.isEmpty else { return }

        // Shared with the upload queue (`FilingPass`): the upload that landed
        // this recording has usually started it already, and asking again
        // joins that pass. A half the user answered while recording is left
        // out, so a typed name is never proposed over.
        async let proposal = FilingPass.shared.run(
            id: settled.id, cloud: app.cloud, named: settled.named, filed: settled.filed)
        // Personal folders only: a chip moves the recording, and an org folder
        // is a shared copy instead — the picker offers those.
        let folders = ((try? await app.cloud.listFolders()) ?? []).filter { $0.orgId == nil }
        guard let proposal = await proposal else { return }
        guard !Task.isCancelled else { return }
        target = .cloud(id: settled.id)
        currentTitle = settled.title
        currentFolderId = settled.folderId
        existingFolders = folders
        writeFailed = false
        show(proposal, app: app)
    }

    // MARK: a suggestion that is already pending

    /// Offer a suggestion the recording already carries. Safe to call again
    /// with a fuller folder list (the folders arrive after the meta): an offer
    /// the user has answered is left alone.
    func present(
        _ suggestion: FilingSuggestion, currentTitle: String, currentFolderId: String?,
        folders: [CloudFolder], target: Target, app: AppState
    ) {
        guard !isWriting, !folderAnswered else { return }
        self.target = target
        self.currentTitle = currentTitle
        self.currentFolderId = currentFolderId
        existingFolders = folders
        writeFailed = false
        show(suggestion, app: app)
    }

    /// Hold the folder half on offer, and name the recording with the title
    /// half when there is one and it is not the name the recording already has.
    private func show(_ proposal: FilingSuggestion, app: AppState) {
        let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestion =
            proposal.folders.isEmpty ? nil : FilingSuggestion(title: "", folders: proposal.folders)
        guard namingTask == nil else { return }
        guard !title.isEmpty, title != currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            // A title that is already the recording's and no folder left: the
            // pass is spent, so say so where every device can read it.
            if suggestion == nil, !title.isEmpty { resolveQuietly(app: app) }
            return
        }
        let expected = currentTitle
        namingTask = Task { [weak self] in
            await self?.applyTitle(title, replacing: expected, app: app)
            self?.namingTask = nil
        }
    }

    /// Write the pass's title — the desktop's `applySuggestedTitle`. Only
    /// while the recording is still called what it was when the pass started:
    /// a rename in the meantime (here, or on the Mac) is the user's answer, and
    /// the title is dropped.
    ///
    /// The folder half stays pending in the meta, title-less, so the desktop
    /// and a later visit offer the same folders and never a second name.
    private func applyTitle(_ title: String, replacing expected: String, app: AppState) async {
        guard let target else { return }
        let folders = suggestion?.folders ?? []
        let pending = folders.isEmpty ? nil : FilingSuggestion(title: "", folders: folders)
        do {
            switch target {
            case .cloud(let id):
                var renamed = false
                try await Self.write(id: id, cloud: app.cloud, resolving: false) { meta in
                    // Either way the title half is answered: written, or
                    // dropped because somebody named it first.
                    meta.filingSuggestion = pending
                    guard meta.title == expected else { return }
                    meta.title = title
                    renamed = true
                }
                guard renamed else { return }
                AutoNamedTitles.shared.mark(id)
            case .sample:
                let store = SampleRecordingStore.shared
                // A name the user gave the sample is theirs.
                guard store.entry?.title == nil else { return }
                store.setTitle(title)
                if let id = store.summary?.id { AutoNamedTitles.shared.mark(id) }
                if folders.isEmpty { store.answerSuggestion() }
            }
            guard !Task.isCancelled else { return }
            currentTitle = title
            onApplied?(title, nil, nil)
        } catch {
            // Best-effort: the suggestion still carries its title in the meta,
            // so the next visit tries again.
        }
    }

    // MARK: answering the folder half

    /// File the recording under a chip's folder — the desktop's one-tap
    /// accept. A folder that does not exist yet is created HERE and nowhere
    /// earlier: merely offering a candidate must not bring it into being.
    ///
    /// One read-modify-write, which also resolves the suggestion.
    @discardableResult
    func file(into folder: FilingFolderSuggestion, app: AppState) async -> Bool {
        guard !isWriting, let target else { return false }
        isWriting = true
        writeFailed = false
        defer { isWriting = false }
        do {
            var created: CloudFolder?
            let folderId: String
            if let id = folder.folderId {
                folderId = id
            } else {
                let made = try await app.cloud.createFolder(name: folder.name)
                created = made
                existingFolders.append(made)
                folderId = made.id
            }
            switch target {
            case .cloud(let id):
                try await Self.write(id: id, cloud: app.cloud) { meta in
                    meta.folderId = folderId
                }
            case .sample:
                SampleRecordingStore.shared.setFolder(folderId)
                SampleRecordingStore.shared.answerSuggestion()
            }
            GettingStartedStore.shared.mark(.filed)
            currentFolderId = folderId
            // Retired only once the push is back: a write that threw is still
            // worth retrying, and the same chip must not create a folder twice.
            folderAnswered = true
            onApplied?(nil, .current(orgId: nil, folderId: folderId), created)
            onRetired?()
            return true
        } catch {
            writeFailed = true
            return false
        }
    }

    /// 先不歸檔. The row changes at once — a dismiss that waits on the network
    /// reads as a broken button — and the flag is written behind it.
    func dismiss(app: AppState) {
        let target = self.target
        forget()
        onRetired?()
        Self.resolve(target, cloud: app.cloud)
    }

    /// The recording was filed some other way — the folder picker — so the
    /// suggestion is spent. Retired for good, as the desktop's `FilingRow`
    /// resolves a spent suggestion.
    func retireAfterFiling(app: AppState) {
        guard suggestion != nil else { return }
        dismiss(app: app)
    }

    /// The pass came back with nothing left to offer: write the flag so no
    /// device asks again, without telling the page anything changed.
    private func resolveQuietly(app: AppState) {
        let target = self.target
        self.target = nil
        Self.resolve(target, cloud: app.cloud)
    }

    private static func resolve(_ target: Target?, cloud: CloudClient) {
        switch target {
        case .sample:
            SampleRecordingStore.shared.answerSuggestion()
        case .cloud(let id):
            // Nothing is accepted, but `filingSuggested` still has to land.
            // Failure is ignored: the worst case is the desktop asking once
            // more about a recording already dealt with on the phone.
            Task { try? await write(id: id, cloud: cloud) { _ in } }
        case nil:
            break
        }
    }

    // MARK: renaming

    /// The page header's rename — the user naming the recording themselves.
    ///
    /// The desktop's `renameHistoryEntry` rule: every rename also retires the
    /// pending suggestion's title (the user has now named it, so a "suggested
    /// title" beside it is a competing name) and the 「自動命名」 tag. The
    /// folder half, if any, stays on offer.
    static func rename(id: String, to title: String, isSample: Bool, cloud: CloudClient) async throws {
        if isSample {
            SampleRecordingStore.shared.setTitle(title)
        } else {
            try await write(id: id, cloud: cloud, resolving: false) { meta in
                meta.title = title
                if let pending = meta.filingSuggestion {
                    meta.filingSuggestion =
                        pending.folders.isEmpty
                        ? nil : FilingSuggestion(title: "", folders: pending.folders)
                }
            }
        }
        AutoNamedTitles.shared.retire(id)
    }

    /// One read-modify-write against the recording's meta, then a push of the
    /// meta and the summary together — the library lists the summary and the
    /// report reads the meta, so a change written to only one of them is a
    /// recording that disagrees with itself.
    ///
    /// Every write sets `filingSuggested`: the desktop reads it to decide
    /// whether its own pass has been spent. `resolving` also clears the
    /// suggestion (answered, whichever way); a write that keeps the folder
    /// half on offer leaves `filingSuggestion` to its `apply`.
    private static func write(
        id: String,
        cloud: CloudClient,
        resolving: Bool = true,
        apply: (inout RecordingMeta) -> Void
    ) async throws {
        var meta = try await cloud.recordingMeta(id: id)
        apply(&meta)
        meta.filingSuggested = true
        if resolving { meta.filingSuggestion = nil }
        try await cloud.pushRecording(
            id: id, summary: CloudRecordingSummary(projecting: meta), meta: meta)
    }

    #if DEBUG
        /// ScreenshotDemo: a recording that has landed under its clock name
        /// with a home on offer, and — a beat later — the name the pass gave
        /// it. `target` is deliberately left nil, so the demo's own buttons
        /// write nothing: there is no account behind the fixtures.
        func seedDemo(
            suggestion: FilingSuggestion, currentTitle: String, folders: [CloudFolder],
            namedAs title: String?, recordingId: String
        ) {
            self.suggestion =
                suggestion.folders.isEmpty
                ? nil : FilingSuggestion(title: "", folders: suggestion.folders)
            self.currentTitle = currentTitle
            currentFolderId = nil
            existingFolders = folders
            guard let title else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1400))
                AutoNamedTitles.shared.mark(recordingId)
                self.currentTitle = title
                onApplied?(title, nil, nil)
            }
        }
    #endif
}

/// The recordings whose name is still the one Parley's filing pass gave them
/// this session — the page header's quiet 「自動命名」 tag, the desktop's
/// `titleAutoApplied`.
///
/// Process-lifetime on purpose, like the desktop's store flag: the tag says
/// "this just happened, and it is yours to change", which stops being news
/// after a relaunch. Any rename retires it.
@MainActor
final class AutoNamedTitles: ObservableObject {
    static let shared = AutoNamedTitles()

    @Published private(set) var ids: Set<String> = []

    func mark(_ id: String) { ids.insert(id) }
    func retire(_ id: String) { ids.remove(id) }
}

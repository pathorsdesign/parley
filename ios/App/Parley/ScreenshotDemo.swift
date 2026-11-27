#if DEBUG

    import Foundation
    import ParleyKit
    import SwiftUI

    /// Deterministic demo state for App Store screenshots — DEBUG builds only.
    ///
    /// Why this exists: every signed-in screen the store listing needs is behind
    /// the sign-in gate, and the gate is behind a real account. Capturing used to
    /// mean signing a simulator into the review account by hand and tapping
    /// through five screens per language, which is (a) slow, (b) impossible to
    /// reproduce exactly next release, and (c) puts a live account's data one
    /// mis-tap away from a public screenshot. Here the whole set is a launch
    /// argument plus five URLs, and no network call is ever made.
    ///
    /// Everything below is invented. No real company, person, account, or meeting
    /// is represented, and the copy is written in both shipping languages so the
    /// en-US and zh-Hant screenshot sets each read natively — a translated-looking
    /// screenshot sells the product short in whichever store it lands in.
    ///
    /// Two ways in, one code path (`route(_:)`):
    ///
    ///     # scripted: the route travels with the launch, nothing else is involved
    ///     xcrun simctl launch <device> com.pathors.parley.ios \
    ///         -ParleyDemo signedIn -ParleyDemoRoute library
    ///
    ///     # by hand: re-route a running app without relaunching it
    ///     xcrun simctl openurl <device> parley://demo/library
    ///
    /// The capture script uses the launch argument because as of the iOS 26.5
    /// simulator runtime `openurl` raises a SpringBoard confirmation alert
    /// — `Open in "Parley"?` — that no `simctl` command can dismiss, so every
    /// routed frame came out as the launch tab behind a modal. A launch
    /// argument never leaves the process.
    ///
    /// Routes: `record`, `record-paused`, `settled`, `adjust`, `library`, `transcript`,
    /// `keyboard`, `settings`, `dictation`, and some that are not store frames
    /// but review frames: `movetofolder` (the transcript with the folder
    /// picker open over fifteen folders), `resetchecklist` (Settings'
    /// "Show the getting-started list again", pressed, landing on the Library),
    /// `summary` / `jump` / `nosummary` (the recording page's two faces — see
    /// `docs/design/ios-recording-page.md`), and `voicehistory` (Library ›
    /// Voice typing, one entry per polish outcome), and the onboarding's steps:
    /// `onboarding-account` (run with `-ParleyDemo signedOut`), then, signed in
    /// and over the tabs, `onboarding-signed-in`, `onboarding-org` /
    /// `onboarding-invited` / `onboarding-joined`, `onboarding-perms`,
    /// `onboarding-mic`, `onboarding-context` and `onboarding-done`.
    @MainActor
    final class ScreenshotDemo: ObservableObject {
        static let shared = ScreenshotDemo()

        @Published var tab: AppTab = .record
        /// Library pushes the demo transcript when this flips.
        @Published var showTranscript = false
        /// Settings scrolls the voice-keyboard section into view.
        @Published var focusKeyboardSection = false
        /// The Record tab before any meeting, nothing seeded (`record-idle`).
        @Published var showIdleRecord = false
        /// A meeting that has just landed, handed to its result page through
        /// the real `TabRouter.openEndedMeeting` (`settled`, `adjust`).
        /// `MainTabs` passes it on; the Library takes it like any other.
        @Published var endedMeeting: EndedMeeting?
        /// The record screen's meeting in progress is seeded paused.
        var showPausedMeeting = false
        /// The filing row's 「選其他資料夾…」 picker, open. Flipped by
        /// `seedEndedMeetingFiling` rather than by the route, because the page
        /// watches this and cannot know which of its two `task`s SwiftUI ran
        /// first — set from the route it can open onto a page that has not
        /// loaded its folders yet.
        @Published var openFilingAdjust = false
        /// The transcript opens the folder picker over `pickerFolders`.
        @Published var openFolderPicker = false
        /// Settings runs its "Show the getting-started list again" action, the
        /// same function the button calls.
        @Published var pressResetChecklist = false
        /// The Library draws the checklist even though it is serving fixtures.
        /// Off for every store frame, which must not carry it.
        @Published var allowsChecklist = false
        /// Library pushes the sample recording, as the lap opens it.
        @Published var showSample = false
        /// The onboarding step to open on (`onboarding-*` routes). The account
        /// step runs signed out; the rest run signed in, over the tabs.
        @Published var onboarding: OnboardingScenario?

        enum OnboardingScenario: Equatable {
            case account, accountConfirmed, org, orgInvited, orgJoined, perms, mic, context, done

            /// The step the scenario opens the wizard on.
            var step: OnboardingStep {
                switch self {
                case .account, .accountConfirmed: return .account
                case .org, .orgInvited, .orgJoined: return .org
                case .perms: return .perms
                case .mic: return .mic
                case .context: return .context
                case .done: return .done
                }
            }

            /// Runs signed in, over the tabs. Only the sign-in card itself is
            /// signed out (`-ParleyDemo signedOut`).
            var isAfterSignIn: Bool { self != .account }
        }

        /// The invitation the `onboarding-invited` route offers.
        static var onboardingInvitation: CloudInvitation {
            CloudInvitation(
                id: "demo-invitation", organizationId: "demo-org-invite",
                organizationName: t("Northwind Sales", "北風業務部"), role: "member",
                status: "pending", expiresAtMs: nil)
        }
        /// Library switches to its Voice typing section, seeded with one
        /// history entry per polish outcome (`voicehistory`).
        @Published var showVoiceTyping = false
        /// A sheet with a focused text field, so the Parley keyboard is on
        /// screen, and an Action-Button-style demo dictation into it a moment
        /// later (`keyboardharness`). The only way to watch the keyboard's
        /// voice pane follow a session on a simulator with no touch input and
        /// no microphone. While it is up the dictation screen is not presented
        /// over it (see `ParleyApp.dictationPresented`).
        @Published var keyboardHarness = false
        /// Which fixture `showTranscript` pushes. The featured one unless a
        /// route asks for the unanalysed one.
        @Published var recordingID = "demo-renewal"
        /// The tab the pushed recording opens on, overriding the "summary when
        /// analysed" rule — the store's transcript frame has to stay a
        /// transcript, and the empty summary is only reachable by force.
        var forcedTab: ResultTab?
        /// A summary timestamp the pushed recording "taps" once it is up, and
        /// whether the lit turn stays lit so the frame can be taken.
        var jumpOnOpen: UInt64?
        var holdsLitTurn = false
        /// `adjust` asks for the sheet; `seedEndedMeetingFiling` is what grants
        /// it.
        private var wantsFilingAdjust = false

        /// `-ParleyDemo signedIn` seeds an account; `-ParleyDemo signedOut` runs
        /// the demo with the sign-in wall up (the welcome frame). Absent, the app
        /// behaves exactly as it does in a normal build.
        private static let mode = UserDefaults.standard.string(forKey: "ParleyDemo")
        static var isActive: Bool { mode != nil }
        static var startsSignedIn: Bool { mode == "signedIn" }

        /// `-ParleyDemoRoute <route>` routes the launch itself, with the same
        /// vocabulary as `parley://demo/<route>`. Absent, the app opens on the
        /// tab it normally opens on.
        private static let launchRoute = UserDefaults.standard.string(forKey: "ParleyDemoRoute")

        /// True when the app should answer from the fixtures below instead of the
        /// cloud. Guards every injection point so a normal DEBUG run is untouched.
        static var servesFixtures: Bool { isActive && startsSignedIn }

        /// `-ParleyDemoHoldFinishing <seconds>` keeps a demo dictation in
        /// `finishing` that long after ⏹, standing in for the AI polish, so
        /// the keyboard's polish wave and its "insert without polishing" tap
        /// can be seen and captured. Absent, a demo dictation settles the
        /// moment it stops, as it always has.
        static var finishingHold: Duration? {
            guard isActive else { return nil }
            let seconds = UserDefaults.standard.double(forKey: "ParleyDemoHoldFinishing")
            return seconds > 0 ? .milliseconds(Int(seconds * 1000)) : nil
        }

        /// `-ParleyDemoLoseConnectionAfter <seconds>` ends a demo dictation
        /// that long after it starts listening as if the relay's reconnect
        /// ladder had run out — through the real `endAfterLostConnection` —
        /// so the lost-connection delivery and its notice can be seen with no
        /// network to cut.
        static var loseConnectionAfter: Duration? {
            guard isActive else { return nil }
            let seconds = UserDefaults.standard.double(forKey: "ParleyDemoLoseConnectionAfter")
            return seconds > 0 ? .milliseconds(Int(seconds * 1000)) : nil
        }

        private init() {
            // Applying the launch route here — not from a view — is what lets the
            // script skip `openurl`. Nothing observes these properties yet, so the
            // first value `MainTabs`/`LibraryView`/`SettingsView` see on subscribing
            // is already the routed one.
            if Self.isActive, let route = Self.launchRoute { self.route(route) }
        }

        /// Handles `parley://demo/…`. Returns false for everything else so the
        /// real `parley://` handlers (auth callback, dictation) still see it.
        @discardableResult
        func handle(_ url: URL) -> Bool {
            guard Self.isActive, url.scheme == "parley", url.host == "demo" else { return false }
            return route(url.pathComponents.last ?? "")
        }

        /// The routing table both entry points share. Returns false for an
        /// unknown route so `handle(_:)` can pass the URL on.
        @discardableResult
        func route(_ route: String) -> Bool {
            showTranscript = false
            focusKeyboardSection = false
            endedMeeting = nil
            showIdleRecord = false
            showPausedMeeting = false
            openFilingAdjust = false
            wantsFilingAdjust = false
            openFolderPicker = false
            pressResetChecklist = false
            allowsChecklist = false
            showSample = false
            onboarding = nil
            showVoiceTyping = false
            keyboardHarness = false
            recordingID = Self.featured.id
            forcedTab = nil
            jumpOnOpen = nil
            holdsLitTurn = false
            switch route {
            case "record": tab = .record
            case "record-idle":
                // The Record tab before a meeting: nothing seeded.
                tab = .record
                showIdleRecord = true
            case "record-paused":
                tab = .record
                showPausedMeeting = true
            case "settled":
                tab = .library
                endedMeeting = Self.endedMeetingFixture
            case "adjust":
                tab = .library
                wantsFilingAdjust = true
                endedMeeting = Self.endedMeetingFixture
            case "library": tab = .library
            case "voicehistory":
                // Review frame for the history's polish labels (1.25): one
                // entry per outcome, plus one from before 1.25 with none.
                // Deferred a turn for the same reason `dictation` is.
                tab = .library
                showVoiceTyping = true
                Task { @MainActor in DictationHistory.shared.seedDemo(Self.voiceHistory) }
            case "transcript", "replay":
                // 回放: the player, the highlights and the transcript.
                tab = .library
                forcedTab = .replay
                showTranscript = true
            case "summary":
                tab = .library
                forcedTab = .summary
                showTranscript = true
            case "actions":
                // 後續行動, grouped 我們 / 對方, with the brief's next steps.
                tab = .library
                forcedTab = .actions
                showTranscript = true
            case "notes":
                tab = .library
                forcedTab = .notes
                showTranscript = true
            case "delivery":
                // 評分: the delivery report for the user (speaker B), with
                // every section filled and the desktop's tone read.
                tab = .library
                forcedTab = .delivery
                showTranscript = true
            case "delivery-unmarked":
                // The same report for a recording nobody has said who the
                // user is in: the question above it, 標記為我 beside the
                // speakers, and no tone read.
                tab = .library
                recordingID = "demo-review"
                forcedTab = .delivery
                showTranscript = true
            case "delivery-group":
                // 評分 on a four-person call: the speaker switch full.
                tab = .library
                recordingID = "demo-discovery"
                forcedTab = .delivery
                showTranscript = true
            case "jump":
                // A moment in the summary, tapped: 回放 with that turn lit and
                // the 💡 notes beside it.
                tab = .library
                forcedTab = .summary
                jumpOnOpen = 44_000
                holdsLitTurn = true
                showTranscript = true
            case "lap1", "lap3", "lapdone":
                // The guided lap on the sample, at step 1 (suggestion card and
                // bar), step 3 (hand it to your AI), or finishing — the last
                // one ticks the share a beat after the screen is up, so the
                // finish is reached the way a user reaches it.
                tab = .library
                let step = route
                Task { @MainActor in
                    let sample = SampleRecordingStore.shared
                    sample.remove()
                    sample.load()
                    if let id = sample.summary?.id { LapMotion.forgetCelebration(id) }
                    var state = GettingStartedState(recorded: true)
                    if step != "lap1" {
                        state.filed = true
                        state.replayed = true
                        sample.setTitle(sample.manifest?.suggestion?.title ?? "")
                        sample.setFolder(Self.folders.first?.id)
                        sample.answerSuggestion()
                    }
                    GettingStartedStore.shared.seedDemo(state)
                    showSample = true
                    if step == "lapdone" {
                        try? await Task.sleep(for: .seconds(2.5))
                        GettingStartedStore.shared.mark(.sharedToAI)
                    }
                }
            case "nosummary":
                tab = .library
                recordingID = "demo-review"
                forcedTab = .summary
                showTranscript = true
            case "keyboard":
                tab = .settings
                focusKeyboardSection = true
            case "onboarding-account": onboarding = .account
            case "onboarding-signed-in": onboarding = .accountConfirmed
            case "onboarding-org": onboarding = .org
            case "onboarding-invited": onboarding = .orgInvited
            case "onboarding-joined": onboarding = .orgJoined
            case "onboarding-perms": onboarding = .perms
            case "onboarding-mic": onboarding = .mic
            case "onboarding-context": onboarding = .context
            case "onboarding-done": onboarding = .done
            case "settings": tab = .settings
            case "movetofolder":
                tab = .library
                forcedTab = .replay
                showTranscript = true
                openFolderPicker = true
            case "resetchecklist":
                tab = .settings
                allowsChecklist = true
                pressResetChecklist = true
            case "keyboardharness":
                // Review frames for the voice pane following a session: the
                // countdown and the cap's ending (with
                // `-ParleyDebugDictationLimit`), the lost-connection notice
                // (with `-ParleyDemoLoseConnectionAfter`). The session starts
                // the way the Action Button starts one, so the keyboard adopts
                // it the way it adopts any session it did not mint.
                keyboardHarness = true
                // `-ParleyDemoResetCopyHint YES`: the keyboard's first-run
                // "Tap text to copy" hint back to never shown, so its first
                // sessions — and its retirement — can be captured again. The
                // keyboard reads the ledger on its next appearance.
                if UserDefaults.standard.bool(forKey: "ParleyDemoResetCopyHint") {
                    CopyHintLedger.shared.reset()
                }
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    await DictationCoordinator.shared.beginFromIntent()
                }
            case "dictation":
                // The keyboard hand-off screen in its stranded-listening state
                // (manual swipe-back, the iOS 26.4+ regime). Deferred a turn
                // because this route can run from `init`, which SwiftUI triggers
                // lazily while evaluating a body — and the coordinator is
                // observed by the app scene, which must not be mutated mid-update.
                Task { @MainActor in
                    DictationCoordinator.shared.seedDemoListening(
                        committed: Self.t(
                            "Hi Anna, just wanted to let you know that my new number is ",
                            "安納你好，跟你說一聲我的新電話號碼是"),
                        partial: Self.t("four zero eight", "零九一二"))
                }
            default: return false
            }
            return true
        }

        // MARK: language

        /// The demo copy follows the app's own localization so a zh-Hant capture
        /// is a Chinese screenshot all the way down, transcript included.
        private static var isChinese: Bool {
            (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
        }

        private static func t(_ en: String, _ zh: String) -> String { isChinese ? zh : en }

        // MARK: dictation fixture

        /// The dictation transcript, pre-chunked roughly the way the relay
        /// settles text. `DictationCoordinator.streamDemoTranscript` plays it
        /// back at speaking pace.
        ///
        /// `-ParleyDemoLongDictation YES` plays a paragraph instead of a line —
        /// past the transcript slot's three visible lines, with an emoji and
        /// Latin inside the Chinese — so the slot's scrolling and the polish
        /// wave can be seen on text that needs them.
        static var dictationScript: [String] {
            let text =
                UserDefaults.standard.bool(forKey: "ParleyDemoLongDictation")
                ? t(
                    "Hi Anna, just wanted to let you know that my new number is 0912 345 678. I'll be at Tuesday's Q3 review on time 👍 and I'll send you the deck tonight. The client also asked to move the contract to two years at the same price, so let's go over the details when we meet. Talk soon!",
                    "嗨 Anna，跟你說一聲我的新電話號碼是 0912345678。下週二的 Q3 review 我會準時到 👍，簡報我今晚先寄給你看。另外客戶那邊說合約想改成兩年約，價格維持不變，細節我們見面再討論。之後再聊！")
                : t(
                    "Hi Anna, just wanted to let you know that my new number is 0912 345 678. Talk soon!",
                    "嗨 Anna，跟你說一聲我的新電話號碼是 0912345678，之後再聊！")
            var chunks: [String] = []
            var current = ""
            for ch in text {
                current.append(ch)
                if current.count >= 3 {
                    chunks.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { chunks.append(current) }
            return chunks
        }

        /// The Voice typing history for `voicehistory`: one entry per polish
        /// outcome, newest first in the order below, and a last one with no
        /// outcome at all — what every entry written before 1.25 looks like.
        /// The second is polished with the concise style, so both polished
        /// labels can be seen.
        /// Two carry an ending as well (`DictationEnding`): one stopped by the
        /// cap, and one delivered after its connection was lost, which never
        /// reached the polish and so has no polish label.
        static var voiceHistory: [DictationHistoryEntry] {
            let now = Date()
            func entry(
                _ minutesAgo: Double, _ en: String, _ zh: String, _ outcome: PolishOutcome?,
                raw: (String, String)? = nil, host: String? = nil,
                style: PolishStyle? = nil, ending: DictationEnding? = nil
            ) -> DictationHistoryEntry {
                DictationHistoryEntry(
                    text: t(en, zh), startedAt: now.addingTimeInterval(-minutesAgo * 60),
                    durationMs: ending == .limitReached
                        ? Int(MicActivityPolicy.dictationLimit * 1000)
                        : 3_000 + t(en, zh).count * 180,
                    source: .keyboard, hostBundleID: host, rawText: raw.map { t($0.0, $0.1) },
                    polish: outcome, polishStyle: style, ending: ending)
            }
            return [
                entry(
                    2,
                    "Three things for tomorrow:\n1. Send the quote.\n2. Check the contract.\n3. Book the client meeting.",
                    "明天三件事：\n1. 寄出報價。\n2. 確認合約。\n3. 約客戶開會。",
                    .polished,
                    raw: (
                        "um so three things for tomorrow first send the quote uh second check the contract and third book the client meeting",
                        "那個明天有三件事啦第一個就是寄報價然後第二個是合約要再看一下呃第三個就是要約客戶開會"
                    ),
                    host: "com.apple.mobilenotes"),
                entry(
                    5, "and that is the whole plan for the offsite, the rest we can decide on the day",
                    "以上就是外訓的整個規劃，其他的我們當天再決定", .polished,
                    host: "com.apple.mobilenotes", style: .concise, ending: .limitReached),
                entry(
                    7, "the numbers for last quarter are in the shared folder under",
                    "上一季的數字在共用資料夾的", nil, host: "com.apple.MobileSMS",
                    ending: .connectionLost),
                entry(9, "OK", "好", .tooShort, host: "jp.naver.line"),
                entry(
                    15, "running five minutes late sorry start without me",
                    "我會晚五分鐘到你們先開始不用等我", .skipped, host: "com.apple.MobileSMS"),
                entry(
                    38, "can you send me the file from yesterday's meeting when you get a chance",
                    "你方便的時候把昨天開會的檔案傳給我一下", .timedOut),
                entry(
                    64, "the deploy is done and the numbers look fine on staging",
                    "部署已經好了測試環境的數字看起來都正常", .rejectedScript),
                entry(
                    95, "what time does the store close on Sundays",
                    "星期天店裡幾點關門", .rejectedLength),
                entry(
                    140, "let's move the review to Thursday afternoon",
                    "檢討會改到禮拜四下午", .failed),
                entry(
                    200, "remind me to call the bank about the transfer",
                    "提醒我打給銀行問轉帳的事", .overdue),
                entry(
                    320, "pick up milk and eggs on the way home",
                    "回家路上買牛奶跟雞蛋", .off),
                entry(
                    1_500, "notes from last week before the update",
                    "更新前的舊紀錄，沒有潤飾標籤", nil),
            ]
        }

        // MARK: account fixtures

        static let user = CloudUser(
            id: "demo-user", name: t("Alex Rivera", "李書瑋"),
            email: "alex@example.com", image: nil)

        static let orgs = [
            CloudOrg(
                id: "demo-org", name: t("Sales team", "業務團隊"),
                slug: "sales", role: "admin")
        ]

        static let quota = HostedQuota(
            plan: "free", sttSecondsUsed: 8_640, sttSecondsLimit: 36_000,
            llmCreditsUsed: 180, llmCreditsLimit: 500, periodResetTs: nil)

        static let folders = [
            CloudFolder(
                id: "f-renewals", name: t("Renewals", "續約"),
                orgId: nil, createdAt: nil, updatedAt: nil),
            CloudFolder(
                id: "f-new", name: t("New business", "新客戶"),
                orgId: nil, createdAt: nil, updatedAt: nil),
        ]

        /// The demo org's shared folders, so the picker shows an organization
        /// heading under the personal ones.
        static let orgFolders = [
            CloudFolder(
                id: "f-org-pipeline", name: t("Pipeline review", "業務檢討"),
                orgId: "demo-org", createdAt: nil, updatedAt: nil),
            CloudFolder(
                id: "f-org-accounts", name: t("Key accounts", "重點客戶"),
                orgId: "demo-org", createdAt: nil, updatedAt: nil),
        ]

        /// Enough folders that the picker has to scroll and the search earns its
        /// place — the account the action sheet failed. The first two are the
        /// library's own, so the featured recording's folder is ticked.
        static var pickerFolders: [CloudFolder] {
            let more: [(String, String)] = [
                ("Halcyon Labs", "晴光實驗室"), ("Meridian", "子午線"),
                ("Acme Logistics", "頂峰物流"), ("Blue Harbor Hotels", "藍港酒店"),
                ("Café Luna", "月光咖啡"), ("Evergreen Clinics", "長青診所"),
                ("Foxglove Retail", "毛地黃零售"), ("Granite Insurance", "磐石保險"),
                ("Harbourline Freight", "港線貨運"), ("Ironwood Motors", "鐵木汽車"),
                ("Juniper Schools", "杜松教育"), ("Kestrel Energy", "紅隼能源"),
                ("Lumen Dental", "流明牙醫"),
            ]
            return folders
                + more.enumerated().map { i, names in
                    CloudFolder(
                        id: "f-picker-\(i)", name: t(names.0, names.1),
                        orgId: nil, createdAt: nil, updatedAt: nil)
                }
        }

        // MARK: library fixtures

        /// Fixed clock so a re-capture months later produces the same frames.
        /// 2026-05-14 09:40 local, then walking backwards.
        private static let epoch: Double = 1_778_751_600_000

        static let recordings: [CloudRecordingSummary] = [
            CloudRecordingSummary(
                id: "demo-renewal",
                title: t("Renewal terms — Northwind", "續約條件討論 — 北風工業"),
                source: "live", createdAt: epoch, durationMs: 1_122_000,
                speakerCount: 2, findingsCount: 3, actionItemsCount: 3, hasAudio: true,
                snippet: t(
                    "Forty seats against an eighty-seat quote; price held through the next renewal.",
                    "四十席對上八十席的報價；價格鎖到下一次續約。"),
                folderId: "f-renewals", updatedAt: nil),
            CloudRecordingSummary(
                id: "demo-discovery",
                title: t("Discovery call — Halcyon Labs", "新客戶需求訪談 — 晴光實驗室"),
                source: "live", createdAt: epoch - 86_400_000, durationMs: 1_925_000,
                speakerCount: 3, findingsCount: 5, actionItemsCount: 4, hasAudio: true,
                snippet: t(
                    "Security questionnaire due Friday; invoicing split across two cost centres.",
                    "資安問卷週五前回覆；請款要拆成兩個成本中心。"),
                folderId: "f-new", updatedAt: nil),
            CloudRecordingSummary(
                id: "demo-review",
                title: t("Quarterly review — Meridian", "季度檢討 — 子午線"),
                source: "upload", createdAt: epoch - 5 * 86_400_000, durationMs: 2_831_000,
                speakerCount: 2, findingsCount: 2, actionItemsCount: 1, hasAudio: true,
                snippet: t(
                    "Usage up 22% quarter on quarter; two action items carried over.",
                    "使用量季增 22%；兩項待辦順延到下一季。"),
                folderId: nil, updatedAt: nil),
        ]

        static var featured: CloudRecordingSummary { recordings[0] }

        /// What the Library lists: the fixtures, with the featured one still
        /// unfiled and still under its clock name while it is the meeting that
        /// has just ended (`settled`, `adjust`) — a recording that lands with
        /// its name about to arrive and its home still on offer, which is the
        /// state the result page's header is about.
        static var libraryRecordings: [CloudRecordingSummary] {
            guard shared.endedMeeting != nil else { return recordings }
            var list = recordings
            list[0].folderId = nil
            list[0].title = clockTitle
            return list
        }

        /// The fixture `showTranscript` pushes.
        static var pushed: CloudRecordingSummary {
            recordings.first { $0.id == shared.recordingID } ?? featured
        }

        /// Which fixtures count as "audio is on this phone".
        ///
        /// Only the featured one, which is the state worth showing: a library
        /// where one row was recorded here and the others came from the desktop
        /// says what the `iphone` glyph means far better than a set where every
        /// row carries it. A simulator has no store to put a file in, so the
        /// download model reads this instead of `LocalAudioStore` while the
        /// fixtures are being served.
        static let localAudioIds: Set<String> = ["demo-renewal"]

        static func audioState(for id: String) -> AudioDownloadState {
            localAudioIds.contains(id) ? .local : .absent
        }

        /// The bundled Ogg the featured recording plays.
        ///
        /// A real 16 kHz mono Ogg/Opus, written by the app's own encoder, with
        /// the six turns of the transcript below spoken at the timecodes they
        /// claim — see `ios/AppStore/make-demo-audio.sh`. So the player in the
        /// transcript screenshot has a waveform with speech and silence in the
        /// right places, and in the simulator it actually plays, scrubs, and
        /// lights the turn the playhead is inside.
        ///
        /// Its duration (1:45) is not the 18:42 the fixture *summary* claims.
        /// The summary's number is what makes a plausible library screenshot and
        /// the audio's is what makes a demo somebody can press play on, and no
        /// single number does both — so the player tells the truth about the file
        /// it has, and only the two numbers being side by side is odd.
        static func audioURL(for id: String) -> URL? {
            guard servesFixtures, localAudioIds.contains(id) else { return nil }
            return Bundle.main.url(forResource: "demo-renewal", withExtension: "ogg")
        }

        /// What the Settings size row reads while the fixtures are being served:
        /// 134 MB, which is about an hour of Opus — a plausible amount for a phone
        /// that has kept a few meetings, and enough to make the row worth having.
        static let storedAudioBytes: Int64 = 134_000_000

        // MARK: transcript fixtures

        /// The renewal conversation, written the way a real B2B negotiation
        /// sounds — seat counts, a price hold, an onboarding estimate with a
        /// condition attached. A screenshot reading "test test test" tells a
        /// reviewer nothing about what the product does.
        private static var lines: [(speaker: Int, ms: UInt64, text: String)] {
            [
                (1, 12_000, t(
                    "We're happy with the platform overall. The blocker is the seat count — we budgeted for forty and the quote came back at eighty.",
                    "平台整體我們用得很滿意，卡住的是席次——我們編了四十席，但報價回來是八十席。")),
                (2, 27_000, t(
                    "Forty is the floor on the enterprise tier, so I can't go under it. What I can do is hold this year's price through the next renewal.",
                    "四十席是企業版的最低門檻，我沒辦法再往下。我能做的是把今年的價格鎖到下一次續約。")),
                (1, 44_000, t(
                    "A price hold helps. What about the onboarding time you mentioned last week — you said two weeks?",
                    "鎖價有幫助。那你上週提到的導入時間呢，你說兩週？")),
                (2, 58_000, t(
                    "Two weeks assumes your SSO is already on Okta. If it isn't, add a week for the identity mapping.",
                    "兩週的前提是你們的 SSO 已經在 Okta 上。如果不是，身分對應要再加一週。")),
                (1, 76_000, t(
                    "It is. Send the revised quote with the price hold in writing and I'll take it to finance on Thursday.",
                    "是在 Okta 上。你把含鎖價條款的修訂報價寄來，我週四拿去給財務。")),
                (2, 92_000, t(
                    "I'll have it to you tomorrow morning, and I'll include the security questionnaire your team asked for.",
                    "明天早上寄給你，並附上你們團隊要的資安問卷。")),
            ]
        }

        /// How the meeting goes on past the six turns the bundled audio
        /// speaks: the walk through onboarding and pricing, with the user
        /// (speaker 2) talking in runs — so 評分 has a pace line with several
        /// points, pauses between the user's own lines, the fillers a real
        /// explanation carries (然後, 就是, 那個 / like, you know) and one
        /// stumble repeated back to back. Only the result page's meta carries
        /// them; the live and just-ended frames keep the six.
        private static var laterLines: [(speaker: Int, start: UInt64, end: UInt64, text: String)] {
            [
                (1, 110_000, 118_000, t(
                    "Before you send it, can you walk me through what the first month looks like?",
                    "寄之前，可以先跟我講一下第一個月會怎麼進行嗎？")),
                (2, 120_000, 134_000, t(
                    "Sure. So the first week, like, we set up the accounts, and then we, you know, connect your Okta.",
                    "好，那個第一週我們會先開帳號，然後就是把你們的 Okta 接起來。")),
                (2, 137_000, 150_000, t(
                    "The second week is basically training. We can split it into two sessions so the the whole team fits in.",
                    "然後第二週其實就是教育訓練，我們可以我們可以分兩梯，讓不同部門都排得進來。")),
                (2, 154_000, 166_000, t(
                    "Week three is go-live, and basically anything that comes up, you come straight to me.",
                    "第三週開始就是正式上線，那個期間有問題都可以直接找我。")),
                (1, 168_000, 178_000, t(
                    "That works. What finance will ask is how you got from the eighty-seat number to forty.",
                    "聽起來可以。財務一定會問的是，八十席跟四十席的價差你們怎麼算。")),
                (2, 180_000, 196_000, t(
                    "Right, I actually have that ready. Forty is the enterprise unit price, and, like, the price hold goes in an addendum.",
                    "對，這個我其實有準備。就是四十席是用企業版的單價，然後鎖價的部分會寫在附約裡。")),
                (2, 198_500, 212_000, t(
                    "And if you add seats next year, it's this year's unit price, you know, no new quote.",
                    "然後如果明年你們要加席次，就是照今年的單價往上加，不會重新報價。")),
                (1, 214_000, 222_000, t(
                    "Good. That needs to be in writing.",
                    "好，這個要寫清楚。")),
                (2, 224_000, 236_000, t(
                    "No problem. I'll put that clause in and, like, send it all over tomorrow.",
                    "沒問題，我會把那個條款寫進去，然後明天一起寄給你。")),
                (2, 241_000, 252_000, t(
                    "Actually, I can send a draft first so your legal team can take a look.",
                    "其實我也可以先寄一份草稿，你們法務可以先看。")),
                (1, 254_000, 262_000, t(
                    "Even better. Send the draft first.",
                    "那更好，先寄草稿吧。")),
                (2, 264_000, 274_000, t(
                    "Great, so that's the plan. Thanks for your time today.",
                    "好，那就這樣，謝謝你今天的時間。")),
            ]
        }

        /// The desktop's tone read of the user, as its analysis leaves it on
        /// the meta (`DeliveryAssessment`).
        private static var deliveryAssessment: [String: Any] {
            [
                "tone": "warm",
                "toneEvidence": t(
                    "No problem. I'll put that clause in", "沒問題，我會把那個條款寫進去"),
                "fillers": [
                    "level": "frequent",
                    "examples": isChinese ? ["然後", "就是"] : ["like", "you know"],
                    "note": t(
                        "“Like” and “you know” stack up while walking through onboarding.",
                        "說明導入流程時「然後」「就是」接連出現。"),
                ] as [String: Any],
                "pace": "comfortable",
                "summary": t(
                    "Warm and well prepared, with a clear account of the pricing. Fillers pile up when walking through the plan — a beat of silence between points would land better.",
                    "語氣親和、回答有準備，價格說明清楚；講流程時贅字偏多，可以在每一點之間先停一下再接下一點。"),
            ]
        }

        /// The three findings `featured.findingsCount` has always claimed.
        /// Written as an analyst would: what happened, and why it matters to the
        /// next conversation. The transcript frame renders them above the turns,
        /// so the store listing shows what a recording is worth *after* the
        /// meeting rather than only during it.
        private static var findings: [[String: Any]] {
            [
                [
                    "id": "f-seats", "atMs": 27_000.0,
                    "severity": "info", "source": "extra",
                    "title": t("Forty seats is the floor", "四十席是底線"),
                    "detail": t(
                        "The enterprise tier can't go below forty, so the seat count is not the lever — the price hold is.",
                        "企業版不能低於四十席，所以席次不是可以談的項目，鎖價才是。"),
                ],
                [
                    "id": "f-hold", "atMs": 44_000.0,
                    "severity": "info", "source": "extra",
                    "title": t("Price held to the next renewal", "價格鎖到下一次續約"),
                    "detail": t(
                        "Offered in place of a discount, and accepted — it has to be in the revised quote in writing.",
                        "以鎖價取代折扣，對方接受了，修訂報價要把這條寫進去。"),
                ],
                [
                    "id": "f-sso", "atMs": 58_000.0,
                    "severity": "warn", "source": "extra",
                    "title": t("Two weeks assumes Okta", "兩週的前提是 Okta"),
                    "detail": t(
                        "Identity mapping adds a week if SSO isn't already on Okta. Confirmed it is.",
                        "如果 SSO 不在 Okta 上，身分對應要再加一週。已確認是在 Okta 上。"),
                ],
            ]
        }

        /// The meta the detail screen reads for a fixture: the featured
        /// recording's, analysed, or a bare transcript for any other — which is
        /// what the "no summary yet" frame needs.
        static func meta(for id: String) -> RecordingMeta {
            guard id != featured.id else { return meta }
            var bare = meta
            bare.raw["id"] = id
            bare.raw["findings"] = [Any]()
            bare.raw["actionItems"] = [Any]()
            bare.raw["brief"] = nil
            bare.raw["meetingContext"] = nil
            // Nobody marked as the user and no tone read: 評分 asks who is who.
            bare.raw["selfSpeaker"] = nil
            bare.raw["deliveryAssessment"] = nil
            if id == "demo-discovery" {
                // A four-way call (`delivery-group`): the same lines spread
                // over four diarized speakers with no names, the user marked
                // as B — what 評分's speaker switch looks like when it is full.
                let pattern = [2, 1, 2, 3, 4, 1, 2, 3, 4, 2, 1, 3]
                if let segments = bare.raw["segments"] as? [[String: Any]] {
                    bare.raw["segments"] = segments.enumerated().map { index, seg in
                        var seg = seg
                        seg["speaker"] = pattern[index % pattern.count]
                        return seg
                    }
                }
                bare.raw["speakerNames"] = [String: String]()
                bare.raw["selfSpeaker"] = "mix-2"
            }
            return bare
        }

        /// The analysis's short read, with the moments it cites as links — in the
        /// desktop brief's shape: English `## ` headings the page translates,
        /// and a "Next steps" section that 後續行動 shows instead of 總結.
        private static var brief: String {
            t(
                "## Where this landed\nRenewal held at forty seats, the enterprise floor. The client budgeted forty against an eighty-seat quote [0:12]; forty is the minimum, so the lever became a price hold through the next renewal [0:27].\n\n## Their pain and objections\n- Eighty seats is double what finance approved [0:12]\n- Onboarding time decides whether they can go live this quarter [0:44]\n\n## Next steps\n- Send the revised quote with the price hold in writing [1:32]\n- Confirm onboarding is two weeks, since SSO is already on Okta [0:58]",
                "## Where this landed\n續約鎖在四十席，企業版的底線。客戶編了四十席、報價是八十席 [0:12]；四十席已是最低門檻，可談的變成把價格鎖到下一次續約 [0:27]。\n\n## Their pain and objections\n- 八十席是財務核准的兩倍 [0:12]\n- 導入時間決定這一季能不能上線 [0:44]\n\n## Next steps\n- 寄出含鎖價條款的修訂報價 [1:32]\n- SSO 已在 Okta 上，確認導入兩週 [0:58]")
        }

        /// What the desktop synced as the meeting's context: the background
        /// prepared before it, then the notes typed during it under the
        /// desktop's heading — so 筆記 and 會議背景 both have something to show.
        private static var meetingContext: String {
            t(
                "Northwind renewal. Their budget is forty seats; last year they churned a pilot over onboarding time.\n\nNotes taken during the meeting:\n- Forty seats is firm on their side\n- Ask for the price hold in writing\n- Okta confirmed [0:58]",
                "北風工業續約。對方預算是四十席；去年有一個試用因為導入太久而流失。\n\n會議中的筆記：\n- 四十席是對方的底線\n- 鎖價要寫進報價\n- 已確認在 Okta 上 [0:58]")
        }

        private static var actionItems: [[String: Any]] {
            [
                [
                    "id": "a-quote", "done": false, "atMs": 92_000.0, "side": "us",
                    "owner": t("You", "我"),
                    "text": t(
                        "Send the revised quote with the price hold in writing",
                        "寄出含鎖價條款的修訂報價"),
                ],
                [
                    "id": "a-security", "done": false, "atMs": 92_000.0, "side": "us",
                    "text": t(
                        "Attach the security questionnaire", "附上資安問卷"),
                ],
                [
                    "id": "a-finance", "done": false, "atMs": 76_000.0, "side": "them",
                    "owner": t("Client lead", "客戶窗口"),
                    "text": t(
                        "Take the revised quote to finance on Thursday",
                        "週四把修訂報價交給財務"),
                ],
            ]
        }

        static var meta: RecordingMeta {
            RecordingMeta(raw: [
                "id": featured.id,
                "title": featured.title,
                "source": "live",
                "createdAt": featured.createdAt,
                "durationMs": featured.durationMs,
                "segments": lines.map { line in
                    [
                        "id": "mix-\(line.ms)", "source": "mix", "speaker": line.speaker,
                        "text": line.text, "isFinal": true,
                        "startMs": Double(line.ms), "endMs": Double(line.ms + 12_000),
                    ] as [String: Any]
                }
                    + laterLines.map { line in
                        [
                            "id": "mix-\(line.start)", "source": "mix", "speaker": line.speaker,
                            "text": line.text, "isFinal": true,
                            "startMs": Double(line.start), "endMs": Double(line.end),
                        ] as [String: Any]
                    },
                "selfSpeaker": "mix-2",
                "deliveryAssessment": deliveryAssessment,
                "speakerNames": [
                    "mix-1": t("Client lead", "客戶窗口"),
                    "mix-2": t("You", "我"),
                ],
                "findings": findings, "actionItems": actionItems, "brief": brief,
                "meetingContext": meetingContext,
                "audio": "audio.ogg", "analyzed": true,
            ])
        }

        // MARK: filing suggestion fixture

        /// What a live meeting is called the moment it lands: the clock, in the
        /// user's locale, exactly as `MeetingUploader` names it. This is the
        /// title the suggestion exists to replace, and the block shows it — so
        /// it has to be the real thing rather than a plausible-looking string.
        static var clockTitle: String {
            let stamp = Date(timeIntervalSince1970: epoch / 1_000).formatted(
                .dateTime.month(.abbreviated).day().hour().minute())
            return String(localized: "Meeting \(stamp)")
        }

        /// The pass's answer for the featured recording: the title the library
        /// fixtures already carry, the folder it belongs in, and one folder that
        /// does not exist yet — which is the case worth showing, because
        /// accepting it is what brings the folder into being.
        static var filingSuggestion: FilingSuggestion {
            FilingSuggestion(
                title: featured.title,
                folders: [
                    FilingFolderSuggestion(
                        folderId: "f-renewals", name: t("Renewals", "續約"),
                        reason: t(
                            "The renewal terms for an account you already have — seat count and a price hold.",
                            "既有客戶的續約條件討論——席次與鎖價。")),
                    FilingFolderSuggestion(
                        folderId: nil, name: t("Northwind", "北風工業"),
                        reason: t(
                            "Northwind comes up in three recordings and has no folder of its own yet.",
                            "北風工業出現在三場錄音裡，但還沒有自己的資料夾。")),
                ])
        }

        // MARK: live screen

        /// The record screen with a meeting in progress, unless the route asked
        /// for it before a meeting (`record-idle`) or for a meeting that has
        /// already ended and gone to its result page (`settled`, `adjust`) —
        /// which leaves Record as the handoff leaves it, cleared. One entry
        /// point so `LiveView` does not have to know the routes.
        static func seedRecordScreen(_ recorder: MeetingRecorder) {
            guard servesFixtures, !shared.showIdleRecord, shared.endedMeeting == nil else {
                return
            }
            seedLive(recorder)
        }

        /// The meeting that has just landed under its clock name, without a
        /// folder, every turn final — so the filing pass has both halves to
        /// answer: the name it applies, the folder it suggests.
        private static var endedMeetingFixture: EndedMeeting {
            EndedMeeting(
                settled: MeetingRecorder.Settled(
                    id: featured.id, title: clockTitle, folderId: nil,
                    segments: lines.map { line in
                        TranscriptSegment(
                            id: "mix-\(line.ms)", source: "mix", speaker: line.speaker,
                            text: line.text, isFinal: true,
                            startMs: line.ms, endMs: line.ms + 12_000)
                    },
                    named: false, filed: false),
                finished: nil)
        }

        /// The result page's filing pass for the ended meeting, seeded straight
        /// into its model rather than run, which would need the network the
        /// demo exists to avoid: the folders on offer at once, and the name a
        /// beat later — so the frame catches the header's 「自動命名」 tag
        /// arriving.
        static func seedEndedMeetingFiling(_ filing: FilingSuggestionModel) {
            filing.seedDemo(
                suggestion: filingSuggestion, currentTitle: clockTitle, folders: folders,
                namedAs: filingSuggestion.title, recordingId: featured.id)
            guard shared.wantsFilingAdjust else { return }
            // A beat for the push and the card to be on screen: the card opens
            // its sheet on this flag changing, and cannot see a change made
            // before it existed.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                shared.openFilingAdjust = true
            }
        }

        /// Fills the live screen with a recording already in progress: settled
        /// runs plus an unfinished tail, which is the state worth showing.
        private static func seedLive(_ recorder: MeetingRecorder) {
            guard recorder.segments.isEmpty else { return }
            var seeded: [TranscriptSegment] = lines.prefix(3).map { line in
                TranscriptSegment(
                    id: "mix-\(line.ms)", source: "mix", speaker: line.speaker,
                    text: line.text, isFinal: true,
                    startMs: line.ms, endMs: line.ms + 12_000)
            }
            seeded.append(
                TranscriptSegment(
                    id: "mix-tail", source: "mix", speaker: 2,
                    text: t(
                        "Two weeks assumes your SSO is already",
                        "兩週的前提是你們的 SSO 已經"),
                    isFinal: false, startMs: 58_000, endMs: 62_000))
            recorder.seedDemo(
                segments: seeded, status: String(localized: "Transcribing live"),
                paused: shared.showPausedMeeting,
                title: featured.title,
                folder: .init(
                    destination: SaveDestination(
                        scope: "personal", orgId: nil, folderId: folders[0].id),
                    label: folders[0].name))
        }
    }

    /// The `keyboardharness` sheet: a text field that takes focus as soon as it
    /// appears, so whichever keyboard the simulator has selected — the Parley
    /// keyboard, on the review simulator — comes up and stays up while a demo
    /// dictation runs and lands in the field.
    struct KeyboardHarnessView: View {
        @State private var text = ""
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: "Keyboard harness (DEBUG)")
                    .font(.headline)
                TextField(text: $text, axis: .vertical) { Text(verbatim: "Dictation lands here") }
                    .lineLimit(4...8)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                Spacer()
            }
            .padding()
            .task {
                try? await Task.sleep(for: .milliseconds(600))
                focused = true
            }
            .interactiveDismissDisabled()
        }
    }

    /// Presents `KeyboardHarnessView` while `ScreenshotDemo.keyboardHarness`
    /// is set. A modifier so the app scene can observe the flag without
    /// holding the demo object itself.
    struct KeyboardHarnessPresenter: ViewModifier {
        @ObservedObject private var demo = ScreenshotDemo.shared

        func body(content: Content) -> some View {
            content.sheet(isPresented: $demo.keyboardHarness) { KeyboardHarnessView() }
        }
    }

#endif

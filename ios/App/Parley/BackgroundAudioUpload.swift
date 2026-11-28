import Foundation
import ParleyKit

/// Sends a queued recording's audio through a background `URLSession`, so the
/// PUT survives the app being suspended or terminated (parley#727).
///
/// Only the audio goes this way. It is the one request that is minutes long;
/// everything after it (the meta push, the org share, the filing pass) is a
/// small JSON call that `MeetingUploader` makes in-process once the audio has
/// landed — right away when somebody is waiting on the transfer, or from
/// `onUploadedWithoutWaiter` when the app was woken or relaunched to hear about
/// it.
///
/// Which queue entry a task belongs to lives in the task's own
/// `taskDescription` (`BackgroundUploadPlan.taskDescription`), which the system
/// persists with the task. A finished transfer is written onto the entry's
/// manifest (`MeetingUploader.markAudioUploaded`) before anything else happens,
/// so a relaunched app that never saw the transfer start still knows the audio
/// is there and skips straight to the follow-up calls.
final class BackgroundAudioUpload: NSObject, @unchecked Sendable {
    static let shared = BackgroundAudioUpload()

    /// Thrown to a caller that stopped waiting while the transfer carries on
    /// in the system — a stalled transfer (no signal) or a caller that was
    /// cancelled (its `beginBackgroundTask` ran out). Not a failure of the
    /// recording: the entry stays queued and the transfer's completion, or the
    /// next pass, finishes the job.
    struct StillUploading: Error {}

    /// Called, on an arbitrary queue, for a transfer that landed with nobody in
    /// this process waiting for it. Set once at launch by `AppDelegate`.
    var onUploadedWithoutWaiter: (@Sendable (String) -> Void)?

    private let lock = NSLock()
    private var session: URLSession!
    /// Continuations waiting on a transfer, by the task's `taskDescription`
    /// (a whole recording's audio, or one part of a multipart upload). Each
    /// is resumed with the server's answer body.
    private var waiters: [String: [UUID: CheckedContinuation<Data, Error>]] = [:]
    /// What the server said, collected as it arrives, by task identifier.
    /// Capped: the only bodies this code reads are error messages.
    private var bodies: [Int: Data] = [:]
    private static let bodyCap = 64 * 1_024
    /// The system's completion handler from
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    private var systemCompletion: (() -> Void)?
    /// Resolved once the session's surviving tasks have been read back, so the
    /// first decision about starting a transfer is made knowing about them.
    private var restored: Task<Void, Never>?

    private override init() { super.init() }

    /// Create the session — once, as early in launch as possible. Re-creating a
    /// background session with the same identifier is what reconnects this
    /// process to transfers an earlier process started, and its delegate is
    /// what hears about them, so this has to happen before the system delivers
    /// any events.
    func activate() {
        lock.lock()
        defer { lock.unlock() }
        guard session == nil else { return }
        let config = URLSessionConfiguration.background(
            withIdentifier: BackgroundUploadPlan.sessionIdentifier)
        // Relaunch the app in the background when a transfer finishes, so the
        // meta push does not wait for the user to open the app.
        config.sessionSendsLaunchEvents = true
        // Started from the foreground the transfer is not discretionary, but
        // iOS may still treat one started from the background as such
        // (e.g. waiting for Wi-Fi). Nothing here can override that.
        config.isDiscretionary = false
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.allowsConstrainedNetworkAccess = true
        config.timeoutIntervalForResource = BackgroundUploadPlan.resourceTimeout
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.pathors.parley.audio-upload"
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        let session = session!
        restored = Task {
            let tasks = await session.allTasks
            AppLog.sync.info("background audio session restored \(tasks.count, privacy: .public) task(s)")
        }
    }

    /// The system woke or relaunched the app for this session's events. The
    /// handler is called once every event has been delivered.
    func handleEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == BackgroundUploadPlan.sessionIdentifier else {
            completion()
            return
        }
        activate()
        lock.lock()
        systemCompletion = completion
        lock.unlock()
    }

    /// Get `fileURL` to the server as recording `id`'s audio, reusing a
    /// transfer already in flight for it. Returns when the server accepted it;
    /// throws `CloudError` for a refusal, a `URLError` for a transport failure,
    /// and `StillUploading` when the caller stopped waiting but the transfer
    /// goes on.
    ///
    /// The caller has already checked the manifest's `audioUploadedAt`.
    func upload(id: String, fileURL: URL, request: URLRequest, bytes: Int) async throws {
        _ = try await transfer(
            description: BackgroundUploadPlan.taskDescription(forRecording: id),
            fileURL: fileURL, request: request, bytes: bytes)
    }

    /// One part of a multipart upload (parley#755), as its own background
    /// transfer of `fileURL` (the part's bytes, already cut out of the Ogg).
    /// Returns the server's answer body, which carries the part's etag. The
    /// delegate has written the etag onto the queue entry by the time this
    /// returns (`MeetingUploader.markPartUploaded`), exactly as a whole-audio
    /// transfer is written down before anyone hears about it.
    func uploadPart(
        id: String, uploadId: String, part: Int, fileURL: URL, request: URLRequest, bytes: Int
    ) async throws -> Data {
        try await transfer(
            description: MultipartUploadPlan.taskDescription(recording: id, uploadId: uploadId, part: part),
            fileURL: fileURL, request: request, bytes: bytes)
    }

    /// Start (or attach to) the background transfer named `description` and
    /// wait for it.
    private func transfer(
        description: String, fileURL: URL, request: URLRequest, bytes: Int
    ) async throws -> Data {
        activate()
        await restored?.value
        let live = await liveTasks()
        let key = description

        let task: URLSessionTask
        let isNew: Bool
        if let existing = live.first(where: { $0.taskDescription == description }) {
            AppLog.sync.info("upload \(description, privacy: .public) already in flight, attaching")
            task = existing
            isNew = false
        } else {
            let created = session.uploadTask(with: request, fromFile: fileURL)
            created.taskDescription = description
            created.countOfBytesClientExpectsToSend = Int64(bytes)
            created.countOfBytesClientExpectsToReceive = 4_096
            task = created
            isNew = true
        }

        let token = UUID()
        let overallLimit = AudioUploadTimeout.forBody(bytes: bytes)
        // Watches the byte count so a transfer that is waiting for a network
        // (which a background session does silently, for as long as it takes)
        // lets the caller go instead of holding the screen on "Uploading…".
        let watchdog = Task { [weak self] in
            let startedAt = Date()
            var lastProgressAt = startedAt
            var lastSent: Int64 = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let sent = task.countOfBytesSent
                if sent != lastSent {
                    lastSent = sent
                    lastProgressAt = Date()
                }
                if BackgroundUploadPlan.shouldStopWaiting(
                    now: Date(), startedAt: startedAt, lastProgressAt: lastProgressAt,
                    overallLimit: overallLimit)
                {
                    self?.resume(key: key, token: token, with: .failure(StillUploading()))
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                lock.lock()
                waiters[key, default: [:]][token] = continuation
                lock.unlock()
                // Resumed after registering, so a transfer that finishes at
                // once cannot complete before anyone is listening.
                if isNew { task.resume() }
                // Cancelled before the continuation existed: `onCancel` had
                // nothing to resume, so let the caller go here.
                if Task.isCancelled {
                    resume(key: key, token: token, with: .failure(StillUploading()))
                }
            }
        } onCancel: {
            // The caller is gone — the transfer is not. Never cancel the task
            // here: that is the whole point of handing it to the system.
            self.resume(key: key, token: token, with: .failure(StillUploading()))
        }
    }

    /// Stop any transfer of recording `id` — the user deleted the queued
    /// recording, and its file is about to go.
    func cancel(id: String) async {
        guard session != nil else { return }
        for task in await liveTasks()
        where BackgroundUploadPlan.recordingId(fromTaskDescription: task.taskDescription) == id
            || MultipartUploadPlan.partTask(fromTaskDescription: task.taskDescription)?.recordingId == id
        {
            task.cancel()
        }
    }

    private func liveTasks() async -> [URLSessionTask] {
        await session.allTasks.filter { $0.state == .running || $0.state == .suspended }
    }

    private func resume(key: String, token: UUID, with result: Result<Data, Error>) {
        lock.lock()
        let continuation = waiters[key]?.removeValue(forKey: token)
        if waiters[key]?.isEmpty == true { waiters[key] = nil }
        lock.unlock()
        continuation?.resume(with: result)
    }

    /// Resume everyone waiting on the transfer `key`; false if nobody was.
    private func resumeAll(key: String, with result: Result<Data, Error>) -> Bool {
        lock.lock()
        let pending = waiters.removeValue(forKey: key) ?? [:]
        lock.unlock()
        pending.values.forEach { $0.resume(with: result) }
        return !pending.isEmpty
    }
}

extension BackgroundAudioUpload: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        var body = bodies[dataTask.taskIdentifier] ?? Data()
        if body.count < Self.bodyCap { body.append(data.prefix(Self.bodyCap - body.count)) }
        bodies[dataTask.taskIdentifier] = body
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()
        let http = task.response as? HTTPURLResponse
        let outcome = BackgroundUploadPlan.outcome(
            httpStatus: http?.statusCode, body: body,
            retryAfterHeader: http?.value(forHTTPHeaderField: "Retry-After"), error: error)
        if let part = MultipartUploadPlan.partTask(fromTaskDescription: task.taskDescription) {
            partCompleted(part, key: task.taskDescription ?? "", outcome: outcome, body: body)
            return
        }
        guard let description = task.taskDescription,
            let id = BackgroundUploadPlan.recordingId(fromTaskDescription: description)
        else { return }

        switch outcome {
        case .uploaded:
            // Written down first: whatever happens to this process next, the
            // queue now knows the audio is on the server.
            MeetingUploader.markAudioUploaded(id: id)
            AppLog.sync.info("upload \(id, privacy: .public) audio landed (background session)")
            DiagnosticsJournal.record("sync_audio_landed_background", "background audio upload finished")
            if !resumeAll(key: description, with: .success(body)) {
                onUploadedWithoutWaiter?(id)
            }
        case .refused(let status, let message, let retryAfter):
            let failure = CloudError(status: status, message: message, retryAfter: retryAfter)
            if !resumeAll(key: description, with: .failure(failure)) {
                // Nobody to count it, so count it here: it was an attempt, and
                // a refusal has to reach the parking ladder either way.
                MeetingUploader.noteBackgroundFailure(id: id, error: failure)
            }
        case .transportFailed(let code, let forceQuit):
            let failure = URLError(URLError.Code(rawValue: code))
            AppLog.sync.error(
                "upload \(id, privacy: .public) background transfer ended: \(code, privacy: .public) forceQuit=\(forceQuit, privacy: .public)"
            )
            if !resumeAll(key: description, with: .failure(failure)), !forceQuit {
                MeetingUploader.noteBackgroundFailure(id: id, error: failure)
            }
        }
    }

    /// A part of a multipart upload finished. Its etag is written onto the
    /// queue entry first, whoever is listening; with nobody listening (the
    /// app was relaunched for it) the next pass is started, which sends the
    /// next part or completes the upload.
    private func partCompleted(
        _ part: MultipartUploadPlan.PartTask, key: String,
        outcome: BackgroundUploadPlan.Outcome, body: Data
    ) {
        let id = part.recordingId
        switch outcome {
        case .uploaded:
            guard let etag = MultipartUploadPlan.etag(fromPartResponse: body) else {
                let failure = CloudError(status: 0, message: "bad_part_response")
                if !resumeAll(key: key, with: .failure(failure)) {
                    MeetingUploader.noteBackgroundFailure(id: id, error: failure)
                }
                return
            }
            MeetingUploader.markPartUploaded(
                id: id, uploadId: part.uploadId, part: part.part, etag: etag)
            AppLog.sync.info(
                "upload \(id, privacy: .public) part \(part.part, privacy: .public) landed (background session)")
            if !resumeAll(key: key, with: .success(body)) {
                onUploadedWithoutWaiter?(id)
            }
        case .refused(let status, let message, let retryAfter):
            let failure = CloudError(status: status, message: message, retryAfter: retryAfter)
            if !resumeAll(key: key, with: .failure(failure)) {
                MeetingUploader.noteBackgroundPartFailure(id: id, uploadId: part.uploadId, error: failure)
            }
        case .transportFailed(let code, let forceQuit):
            let failure = URLError(URLError.Code(rawValue: code))
            AppLog.sync.error(
                "upload \(id, privacy: .public) part \(part.part, privacy: .public) transfer ended: \(code, privacy: .public)"
            )
            if !resumeAll(key: key, with: .failure(failure)), !forceQuit {
                MeetingUploader.noteBackgroundFailure(id: id, error: failure)
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let completion = systemCompletion
        systemCompletion = nil
        lock.unlock()
        // UIKit requires the main queue. The follow-up work started from
        // `didCompleteWithError` holds its own `beginBackgroundTask`, so
        // telling the system we are done here does not cut it off.
        DispatchQueue.main.async { completion?() }
    }
}

import Foundation

/// The decisions behind sending a long recording's audio in parts
/// (parley#755), kept free of `URLSession` so they can be unit-tested on macOS.
///
/// Cloudflare's edge refuses any request body over 100 MB with an HTML 413
/// before the Worker runs. Opus at our bitrate is about 10.8 MB an hour, so a
/// meeting of nine hours or more could never reach the cloud through the
/// single `PUT /recordings/:id/audio`. Above `threshold` the audio goes up as a
/// multipart upload instead:
///
/// 1. `POST /recordings/{id}/audio/multipart` → `{ uploadId, partSize }`
/// 2. `PUT  /recordings/{id}/audio/multipart/{uploadId}/{partNumber}` (raw
///    bytes, 1-based, ≤ 64 MiB) → `{ partNumber, etag }`, once per part
/// 3. `POST /recordings/{id}/audio/multipart/{uploadId}/complete`
///    `{ parts: [{ partNumber, etag }] }` → `{ ok, size }`
///
/// `DELETE /recordings/{id}/audio/multipart/{uploadId}` aborts. Each part is
/// its own background transfer, so the state below is persisted on the queue
/// entry: a relaunched app continues with the parts that have not landed.
public enum MultipartUploadPlan {
    /// The largest part the server accepts, and the largest body sent in one
    /// piece. Anything at or below it keeps using the single PUT.
    public static let maxPartBytes = 64 * 1_024 * 1_024
    /// What the server hands out today. Used when its answer is unusable.
    public static let defaultPartBytes = 32 * 1_024 * 1_024
    /// Bodies larger than this go up in parts.
    public static let threshold = maxPartBytes

    public static func usesMultipart(bytes: Int) -> Bool { bytes > threshold }

    /// The part size to use given what the server said: its own value when it
    /// is one the server will also accept back, otherwise the default.
    public static func partSize(fromServer value: Int?) -> Int {
        guard let value, value > 0, value <= maxPartBytes else { return defaultPartBytes }
        return value
    }

    /// One slice of the file.
    public struct Part: Equatable, Sendable {
        /// 1-based, as the server numbers them.
        public let number: Int
        public let offset: Int
        public let length: Int
    }

    /// The file cut into `partSize` slices, the last one smaller. Empty for an
    /// empty file or a nonsensical part size.
    public static func parts(totalBytes: Int, partSize: Int) -> [Part] {
        guard totalBytes > 0, partSize > 0 else { return [] }
        var out: [Part] = []
        var offset = 0
        var number = 1
        while offset < totalBytes {
            let length = min(partSize, totalBytes - offset)
            out.append(Part(number: number, offset: offset, length: length))
            offset += length
            number += 1
        }
        return out
    }

    /// A multipart upload in progress, persisted on the queue entry.
    public struct State: Codable, Equatable, Sendable {
        public let uploadId: String
        public let partSize: Int
        /// The size of the file the plan was cut for. A file that no longer has
        /// this size is not the one these parts came from.
        public let totalBytes: Int
        /// Etags of the parts that landed, by part number.
        public private(set) var etags: [Int: String]

        public init(uploadId: String, partSize: Int, totalBytes: Int, etags: [Int: String] = [:]) {
            self.uploadId = uploadId
            self.partSize = partSize
            self.totalBytes = totalBytes
            self.etags = etags
        }

        public var parts: [Part] { MultipartUploadPlan.parts(totalBytes: totalBytes, partSize: partSize) }

        /// The parts still to send, in order.
        public var remaining: [Part] { parts.filter { etags[$0.number] == nil } }

        public var isComplete: Bool { !parts.isEmpty && remaining.isEmpty }

        /// Whether this state can continue the file as it is now.
        public func matches(totalBytes bytes: Int) -> Bool {
            bytes == totalBytes && partSize > 0 && partSize <= MultipartUploadPlan.maxPartBytes
        }

        /// The same state with one more part landed. A part number outside the
        /// plan, or an empty etag, changes nothing.
        public func recording(part number: Int, etag: String) -> State {
            guard !etag.isEmpty, parts.contains(where: { $0.number == number }) else { return self }
            var next = self
            next.etags[number] = etag
            return next
        }

        /// The body of the `complete` call, parts in order.
        public var completionParts: [CompletedPart] {
            etags.keys.sorted().map { CompletedPart(partNumber: $0, etag: etags[$0]!) }
        }
    }

    public struct CompletedPart: Codable, Equatable, Sendable {
        public let partNumber: Int
        public let etag: String
    }

    // MARK: server answers

    public struct Started: Decodable, Equatable, Sendable {
        public let uploadId: String
        public let partSize: Int?
    }

    struct PartAnswer: Decodable {
        let partNumber: Int?
        let etag: String
    }

    /// The etag in a part's 2xx body, or nil when the body is not the answer
    /// the contract promises (nothing to complete with).
    public static func etag(fromPartResponse body: Data) -> String? {
        guard let answer = try? JSONDecoder().decode(PartAnswer.self, from: body),
            !answer.etag.isEmpty
        else { return nil }
        return answer.etag
    }

    /// What a refused part or `complete` call means for the upload.
    public enum Refusal: Equatable, Sendable {
        /// 408: the part timed out on the way in. Send the same part again.
        case retryPart
        /// 404 `no_such_upload`, 400 `invalid_parts`: the server no longer has
        /// (or never had) what this state describes. Start a new upload.
        case restart
        /// 410 `gone`: the recording itself is gone. Stop; the queue's usual
        /// handling of the refusal applies.
        case gone
        /// Anything else: handled exactly as the single PUT's refusal would be.
        case other
    }

    public static func refusal(status: Int, message: String) -> Refusal {
        switch status {
        case 408: return .retryPart
        case 404 where message.contains("no_such_upload"): return .restart
        case 400 where message.contains("invalid_parts"): return .restart
        case 410: return .gone
        default: return .other
        }
    }

    /// How many times one pass sends the same part after a 408, and how many
    /// times it starts the whole upload over, before leaving it to the next.
    public static let partRetries = 3
    public static let restarts = 1

    // MARK: background tasks

    private static let partPrefix = "parley-audio-part:"

    /// A part transfer's `taskDescription`: part, recording id, then the
    /// upload id last, because it is the server's opaque string and may
    /// contain anything — including the separator. Deliberately not
    /// `BackgroundUploadPlan.taskDescription`'s prefix: a landed *part* must
    /// never be mistaken for the whole audio having landed.
    public static func taskDescription(recording id: String, uploadId: String, part: Int) -> String {
        "\(partPrefix)\(part):\(id):\(uploadId)"
    }

    public struct PartTask: Equatable, Sendable {
        public let recordingId: String
        public let uploadId: String
        public let part: Int
    }

    public static func partTask(fromTaskDescription description: String?) -> PartTask? {
        guard let description, description.hasPrefix(partPrefix) else { return nil }
        let fields = description.dropFirst(partPrefix.count).split(
            separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3, let part = Int(fields[0]), part > 0,
            !fields[1].isEmpty, !fields[2].isEmpty
        else { return nil }
        return PartTask(recordingId: String(fields[1]), uploadId: String(fields[2]), part: part)
    }
}

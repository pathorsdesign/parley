import XCTest

@testable import ParleyKit

final class MultipartUploadPlanTests: XCTestCase {
    private let mib = 1_024 * 1_024

    // MARK: when

    func testOnlyBodiesOver64MiBGoInParts() {
        XCTAssertFalse(MultipartUploadPlan.usesMultipart(bytes: 0))
        XCTAssertFalse(MultipartUploadPlan.usesMultipart(bytes: 64 * mib))
        XCTAssertTrue(MultipartUploadPlan.usesMultipart(bytes: 64 * mib + 1))
        XCTAssertTrue(MultipartUploadPlan.usesMultipart(bytes: 150_000_000))
    }

    func testPartSizeTakesTheServersValueOnlyWhenItIsAcceptable() {
        XCTAssertEqual(MultipartUploadPlan.partSize(fromServer: 33_554_432), 33_554_432)
        XCTAssertEqual(MultipartUploadPlan.partSize(fromServer: 16 * mib), 16 * mib)
        XCTAssertEqual(MultipartUploadPlan.partSize(fromServer: nil), 32 * mib)
        XCTAssertEqual(MultipartUploadPlan.partSize(fromServer: 0), 32 * mib)
        XCTAssertEqual(MultipartUploadPlan.partSize(fromServer: 65 * mib), 32 * mib)
    }

    // MARK: the plan

    func testPartsCoverTheFileExactlyWithASmallerLastPart() {
        let total = 150_000_000
        let parts = MultipartUploadPlan.parts(totalBytes: total, partSize: 32 * mib)
        XCTAssertEqual(parts.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(parts.reduce(0) { $0 + $1.length }, total)
        XCTAssertEqual(parts.first?.offset, 0)
        for (a, b) in zip(parts, parts.dropFirst()) { XCTAssertEqual(a.offset + a.length, b.offset) }
        XCTAssertTrue(parts.dropLast().allSatisfy { $0.length == 32 * mib })
        XCTAssertEqual(parts.last?.length, total - 4 * 32 * mib)
        XCTAssertTrue(parts.allSatisfy { $0.length <= MultipartUploadPlan.maxPartBytes })
    }

    func testAnExactMultipleHasNoEmptyTail() {
        let parts = MultipartUploadPlan.parts(totalBytes: 96 * mib, partSize: 32 * mib)
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts.last?.length, 32 * mib)
    }

    func testDegenerateInputsHaveNoParts() {
        XCTAssertEqual(MultipartUploadPlan.parts(totalBytes: 0, partSize: 32 * mib), [])
        XCTAssertEqual(MultipartUploadPlan.parts(totalBytes: 10, partSize: 0), [])
    }

    // MARK: state

    func testStateTracksRemainingPartsAndCompletesInOrder() {
        var state = MultipartUploadPlan.State(uploadId: "u1", partSize: 32 * mib, totalBytes: 100 * mib)
        XCTAssertEqual(state.remaining.map(\.number), [1, 2, 3, 4])
        XCTAssertFalse(state.isComplete)

        state = state.recording(part: 3, etag: "e3").recording(part: 1, etag: "e1")
        XCTAssertEqual(state.remaining.map(\.number), [2, 4])

        state = state.recording(part: 4, etag: "e4").recording(part: 2, etag: "e2")
        XCTAssertTrue(state.isComplete)
        XCTAssertEqual(
            state.completionParts,
            [.init(partNumber: 1, etag: "e1"), .init(partNumber: 2, etag: "e2"),
             .init(partNumber: 3, etag: "e3"), .init(partNumber: 4, etag: "e4")])
    }

    func testStateIgnoresPartsOutsideThePlanAndEmptyEtags() {
        let state = MultipartUploadPlan.State(uploadId: "u1", partSize: 32 * mib, totalBytes: 40 * mib)
        XCTAssertEqual(state.recording(part: 3, etag: "x"), state)
        XCTAssertEqual(state.recording(part: 0, etag: "x"), state)
        XCTAssertEqual(state.recording(part: 1, etag: ""), state)
    }

    func testRecordingAPartTwiceKeepsTheLatestEtag() {
        let state = MultipartUploadPlan.State(uploadId: "u1", partSize: 32 * mib, totalBytes: 40 * mib)
            .recording(part: 1, etag: "old").recording(part: 1, etag: "new")
        XCTAssertEqual(state.completionParts, [.init(partNumber: 1, etag: "new")])
    }

    func testStateOnlyContinuesTheSameFile() {
        let state = MultipartUploadPlan.State(uploadId: "u1", partSize: 32 * mib, totalBytes: 100 * mib)
        XCTAssertTrue(state.matches(totalBytes: 100 * mib))
        XCTAssertFalse(state.matches(totalBytes: 100 * mib + 1))
        let bogus = MultipartUploadPlan.State(uploadId: "u1", partSize: 128 * mib, totalBytes: 100 * mib)
        XCTAssertFalse(bogus.matches(totalBytes: 100 * mib))
    }

    func testStateSurvivesTheManifestRoundTrip() throws {
        let state = MultipartUploadPlan.State(uploadId: "u1", partSize: 32 * mib, totalBytes: 100 * mib)
            .recording(part: 2, etag: "\"abc\"")
        let decoded = try JSONDecoder().decode(
            MultipartUploadPlan.State.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.remaining.map(\.number), [1, 3, 4])
    }

    // MARK: server answers

    func testEtagIsReadFromThePartAnswer() {
        XCTAssertEqual(
            MultipartUploadPlan.etag(fromPartResponse: Data(#"{"partNumber":2,"etag":"\"9f\""}"#.utf8)),
            "\"9f\"")
        XCTAssertNil(MultipartUploadPlan.etag(fromPartResponse: Data(#"{"partNumber":2}"#.utf8)))
        XCTAssertNil(MultipartUploadPlan.etag(fromPartResponse: Data(#"{"etag":""}"#.utf8)))
        XCTAssertNil(MultipartUploadPlan.etag(fromPartResponse: Data("<html>".utf8)))
    }

    func testStartAnswerDecodes() throws {
        let started = try JSONDecoder().decode(
            MultipartUploadPlan.Started.self,
            from: Data(#"{"uploadId":"abc","partSize":33554432}"#.utf8))
        XCTAssertEqual(started, .init(uploadId: "abc", partSize: 33_554_432))
    }

    func testRefusalsMapToTheContract() {
        XCTAssertEqual(MultipartUploadPlan.refusal(status: 408, message: ""), .retryPart)
        XCTAssertEqual(
            MultipartUploadPlan.refusal(status: 404, message: #"{"error":"no_such_upload"}"#), .restart)
        XCTAssertEqual(
            MultipartUploadPlan.refusal(status: 400, message: #"{"error":"invalid_parts"}"#), .restart)
        XCTAssertEqual(MultipartUploadPlan.refusal(status: 410, message: #"{"error":"gone"}"#), .gone)
        // A plain 404 (recording not found) or a 400 for another reason is not
        // "start over" — it is the queue's ordinary refusal.
        XCTAssertEqual(MultipartUploadPlan.refusal(status: 404, message: "not_found"), .other)
        XCTAssertEqual(MultipartUploadPlan.refusal(status: 400, message: "bad"), .other)
        XCTAssertEqual(MultipartUploadPlan.refusal(status: 500, message: ""), .other)
    }

    // MARK: background tasks

    func testPartTaskDescriptionRoundTrips() {
        let id = "8f0c2a4e-1b3d-4e5f-9a7b-6c5d4e3f2a1b"
        let description = MultipartUploadPlan.taskDescription(recording: id, uploadId: "up:load", part: 3)
        // The upload id is opaque and may itself contain the separator.
        XCTAssertEqual(
            MultipartUploadPlan.partTask(fromTaskDescription: description),
            .init(recordingId: id, uploadId: "up:load", part: 3))
        let plain = MultipartUploadPlan.taskDescription(recording: id, uploadId: "u-1", part: 3)
        XCTAssertEqual(
            MultipartUploadPlan.partTask(fromTaskDescription: plain),
            .init(recordingId: id, uploadId: "u-1", part: 3))
    }

    func testAPartIsNeverMistakenForTheWholeAudio() {
        let description = MultipartUploadPlan.taskDescription(recording: "a", uploadId: "u", part: 1)
        XCTAssertNil(BackgroundUploadPlan.recordingId(fromTaskDescription: description))
        XCTAssertNil(
            MultipartUploadPlan.partTask(
                fromTaskDescription: BackgroundUploadPlan.taskDescription(forRecording: "a")))
    }

    func testMalformedPartDescriptionsBelongToNothing() {
        for bad in [nil, "", "parley-audio-part:", "parley-audio-part:x:a:u", "parley-audio-part:0:a:u",
                    "parley-audio-part:1::u", "parley-audio-part:1:a:", "parley-audio-part:1:a"] {
            XCTAssertNil(MultipartUploadPlan.partTask(fromTaskDescription: bad), String(describing: bad))
        }
    }

    // MARK: requests

    func testPartRequestCarriesTheContractsPathAndLength() {
        let cloud = CloudClient(baseURL: URL(string: "https://example.test")!) { "tok" }
        let req = cloud.multipartPartRequest(id: "rec", uploadId: "u1", partNumber: 2, bytes: 1_234)
        XCTAssertEqual(req.url?.absoluteString, "https://example.test/recordings/rec/audio/multipart/u1/2")
        XCTAssertEqual(req.httpMethod, "PUT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Length"), "1234")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertNil(req.httpBody)
    }
}

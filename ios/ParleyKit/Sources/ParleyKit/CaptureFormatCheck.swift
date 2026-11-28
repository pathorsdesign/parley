import Foundation

/// Whether the microphone's input node is in a state `installTap(onBus:)` will
/// accept, decided *before* the call (parley#748).
///
/// `AVAudioInputNode.installTap` does not throw a Swift error when the format
/// it is handed does not match the hardware: it raises an Objective-C
/// exception ("required condition is false: format.sampleRate ==
/// hwFormat.sampleRate", or the `IsFormatSampleRateAndChannelCountValid` one
/// for a 0 Hz format), which Swift cannot catch and which takes the whole app
/// down. iOS 1.38 (56) died exactly there, on the capture's rebuild path
/// (`AudioCapture.startEngine` ← `attemptRebuild`), right after the audio
/// session had been reactivated.
///
/// The way into that state is a stale engine: an `AVAudioEngine` that outlived
/// a session reactivation or a route change can keep reporting the input
/// format it was built with while the hardware has moved on to another sample
/// rate. So the capture compares three readings of the same fact — the node's
/// output format (what the tap would be built with), the node's input format
/// (the hardware side of the node), and the session's own hardware sample
/// rate — and only installs the tap when they agree. Kept free of
/// AVFoundation so it can be tested with `swift test` on macOS.
public enum CaptureFormatCheck {
    /// The two properties of an audio format the tap's precondition checks.
    public struct Shape: Equatable, Sendable {
        public var sampleRate: Double
        public var channels: UInt32

        public init(sampleRate: Double, channels: UInt32) {
            self.sampleRate = sampleRate
            self.channels = channels
        }

        /// A format the tap can be built against at all. 0 Hz / 0 channels is
        /// what the input node reports for a beat while the route settles.
        public var isUsable: Bool {
            sampleRate.isFinite && sampleRate > 0 && channels > 0
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Install the tap with the node's output format.
        case ready
        /// The hardware is not back yet: one of the formats is 0 Hz or has no
        /// channels. Retry later; a fresh engine would read the same thing.
        case notReady
        /// The node's formats disagree with each other or with the session:
        /// this engine's picture of the hardware is out of date. Build a fresh
        /// engine and look again before touching the tap.
        case stale
    }

    /// - Parameters:
    ///   - tap: `inputNode.outputFormat(forBus: 0)` — what the tap is built with.
    ///   - hardware: `inputNode.inputFormat(forBus: 0)`.
    ///   - sessionSampleRate: `AVAudioSession.sampleRate`, or nil to leave the
    ///     session out of it. Passed on the first look only: a session rate
    ///     that still disagrees with a *fresh* engine's node is not something
    ///     another engine can fix, and refusing to record over it would trade
    ///     a rare crash for a capture that never starts.
    public static func verdict(
        tap: Shape, hardware: Shape, sessionSampleRate: Double? = nil
    ) -> Verdict {
        guard tap.isUsable, hardware.isUsable else { return .notReady }
        if tap.sampleRate != hardware.sampleRate || tap.channels != hardware.channels {
            return .stale
        }
        if let session = sessionSampleRate, session > 0, session != tap.sampleRate {
            return .stale
        }
        return .ready
    }
}

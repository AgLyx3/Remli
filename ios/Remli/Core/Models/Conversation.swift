import Foundation

/// One entry in the flowing timeline. Deliberately richer than chat bubbles: the design doc asks
/// for assistant turns, "I heard" summaries, and reviewable cards in a single stream.
struct TimelineEntry: Identifiable, Hashable {
    enum Content: Hashable {
        /// Assistant prose.
        case assistant(text: String, narrationSource: NarrationSource)
        /// Something the user said or typed.
        case user(text: String, wasSpoken: Bool)
        /// The periodic "I heard" recap.
        case heard(summary: String, detail: String?)
        /// A reviewable reminder proposal card.
        case proposal(ReminderProposal)
        /// Confirmation that a reminder is now scheduled.
        case scheduled(ApprovedReminder)
        /// A neutral system note, e.g. import finished.
        case note(String)
        /// Remli noticed a pattern and is asking about it. Never more than one at a time, and
        /// governed by `InterruptionPolicy` — see `RemliSession.considerCheckIn`.
        case checkIn(NoticedPattern)
    }

    let id: String
    let timestamp: Date
    var content: Content

    init(id: String = UUID().uuidString, timestamp: Date = .init(), content: Content) {
        self.id = id
        self.timestamp = timestamp
        self.content = content
    }
}

/// Who actually wrote a given assistant sentence. Surfaced in the UI so the demo never overstates
/// what the on-device model produced.
enum NarrationSource: String, Codable, Hashable {
    /// Written by Gemma running on this device.
    case gemmaOnDevice
    /// Deterministic template — either Gemma was unavailable or SafetyGuard rejected its output.
    case deterministicTemplate
    /// Fixed product copy.
    case staticCopy

    var badge: String? {
        switch self {
        case .gemmaOnDevice: return "Gemma · on device"
        case .deterministicTemplate: return "Scripted"
        case .staticCopy: return nil
        }
    }
}

/// Live privacy/status state backing the status strip. Reflects reality, not decoration.
struct SessionStatus: Hashable {
    /// Retained for the deferred voice-input path (`ios/Deferred/SpeechCapture.swift`), which is
    /// kept out of the build target. Dictation was cut from v1: it sits outside the
    /// connect → cite → propose → approve → notify loop, and it was the single most fragile thing
    /// to demonstrate live. Text input and spoken read-back cover the interaction need.
    enum MicrophoneState: Hashable {
        case off
        case listening
        case unavailable(reason: String)
    }

    var storageDescription: String = "Encrypted, this device"
    var modelDescription: String = "Starting…"
    var modelIsOnDevice: Bool = true
    var networkEgressDescription: String = "Nothing leaves this phone"
}

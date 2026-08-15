import Combine
import Foundation
import UIKit
import os

/// A locally recorded SafetyGuard rejection.
///
/// Kept so Settings can show "Gemma was overruled 2 times today" with the reason, which is the
/// difference between a safety net and a rumour. Contains no PHI: `jobLabel` is the *kind* of
/// narration ("Introducing a reminder"), never the medication, and `evidence` is either a fixed
/// phrase from Remli's own rule table or a token that by definition was not in the record.
struct SafetyEvent: Identifiable, Hashable {
    let id: String
    let date: Date
    let rule: SafetyRule
    let evidence: String?
    let jobLabel: String

    var summary: String { "\(rule.title) while \(jobLabel.lowercased())" }
}

/// Why the scripted narrator is running instead of Gemma.
enum ScriptedReason: Equatable {
    case simulator
    case packageNotLinked
    case modelFileMissing
    case modelFileDownloading(progress: Double)
    case startupFailed(String)

    /// Shown to the user verbatim. Every one of these is an honest sentence, not a shrug.
    var explanation: String {
        switch self {
        case .simulator:
            return LiteRTRuntime.simulatorExplanation
        case .packageNotLinked:
            return LiteRTRuntime.missingPackageExplanation
        case .modelFileMissing:
            return "Gemma's weights are not on this phone yet, so narration is scripted. "
                + "Open Privacy & Settings from the shield button to download them."
        case .modelFileDownloading(let progress):
            let percent = progress >= 0 ? " (\(Int(progress * 100))%)" : ""
            return "Gemma's weights are still downloading\(percent). Narration is scripted until that finishes."
        case .startupFailed(let detail):
            return "Gemma could not start on this phone, so narration is scripted. \(detail)"
        }
    }
}

/// Which narrator is live.
enum LanguageModelSelection: Equatable {
    case gemmaOnDevice
    case scripted(ScriptedReason)

    var isGemma: Bool { self == .gemmaOnDevice }
}

/// Picks the language model at runtime and is the only thing the rest of the app talks to.
///
/// The selection rule, in full:
///
/// - **Simulator** → `ScriptedModel`, always, with a user-visible explanation. LiteRT-LM cannot do
///   inference there, so pretending otherwise would mean a demo that works on a laptop and dies on
///   stage.
/// - **Device, package linked, weights present** → `LiteRTGemmaModel`.
/// - **Anything else on device** → `ScriptedModel`, with the specific reason.
///
/// `narrate(_:)` deliberately does not throw. A language failure must never be able to stop a
/// health reminder from being reviewed, so every error path lands on the deterministic template
/// and is recorded rather than raised.
@MainActor
final class LanguageModelProvider: ObservableObject {

    @Published private(set) var selection: LanguageModelSelection
    @Published private(set) var model: RemliLanguageModel
    /// Local, PHI-free record of SafetyGuard interventions, newest first.
    @Published private(set) var safetyEvents: [SafetyEvent] = []
    @Published private(set) var isPreparing = false

    let modelManager: GemmaModelManager

    private var cancellables: Set<AnyCancellable> = []
    private let scriptedFallback: ScriptedModel
    private let maximumRecordedEvents = 50
    /// Once Gemma has failed to start in this session, stop trying. Engine initialisation is
    /// expensive and a retry loop mid-demo is worse than a scripted demo.
    private var gemmaFailedThisSession = false
    /// Reused so a selection flap does not rebuild the engine.
    private var cachedGemmaModel: RemliLanguageModel?

    init(modelManager: GemmaModelManager = .shared) {
        self.modelManager = modelManager
        let initial = LanguageModelProvider.resolveSelection(modelManager: modelManager)
        self.selection = initial
        let scripted = ScriptedModel(availabilityNote: LanguageModelProvider.note(for: initial))
        self.scriptedFallback = scripted
        // Start on the scripted narrator no matter what, then swap in Gemma if it is the right
        // choice. This guarantees the provider is usable the instant it exists, which is what
        // lets `prepare()` stay off the launch path.
        self.model = scripted
        self.model = makeModel(for: initial)

        // Re-resolve when the weights land, so a download finishing upgrades the app without a
        // relaunch.
        // Gemma holds ~1.45 GB on the GPU backend. On a 6 GB phone that is exactly the kind of
        // resident allocation iOS reclaims by killing the app. `unload()` existed for this and was
        // never wired to anything, so the only available behaviour was termination.
        NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                Self.log.error("memory warning — unloading the engine")
                DiagnosticLog.note("memory warning: unloading engine")
                (self.cachedGemmaModel as? LiteRTUnloadable)?.unload()
            }
            .store(in: &cancellables)

        modelManager.$availability
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reevaluate() }
            .store(in: &cancellables)
    }

    // MARK: - Status

    /// One line for the privacy status strip. Says what is true, including when what is true is
    /// "this is not really Gemma".
    var statusDescription: String {
        switch selection {
        case .gemmaOnDevice:
            return model.displayName
        case .scripted(let reason):
            switch reason {
            case .simulator: return "Scripted narration · simulator"
            case .packageNotLinked: return "Scripted narration · runtime not linked"
            case .modelFileMissing: return "Scripted narration · weights not downloaded"
            case .modelFileDownloading: return modelManager.availability.statusDescription
            case .startupFailed: return "Scripted narration · Gemma did not start"
            }
        }
    }

    /// Longer, user-facing explanation for Settings. Nil when there is nothing to explain.
    var statusExplanation: String? {
        switch selection {
        case .gemmaOnDevice:
            return model.availabilityNote
        case .scripted(let reason):
            return reason.explanation
        }
    }

    /// True when a neural model is producing the words. Distinct from "everything is local",
    /// which is always true in this app.
    var isNarrationModelOnDevice: Bool { model.isOnDevice }

    // MARK: - Preparation

    /// Warms the model. Safe to call from `.task {}` on the first screen; never from `init`.
    func prepare() async {
        guard !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            try await model.prepare()
        } catch let error as LanguageModelError where error.isPermanent {
            downgrade(to: .startupFailed(error.localizedDescription))
        } catch {
            downgrade(to: .startupFailed(error.localizedDescription))
        }
    }

    // MARK: - Narration

    /// The call site API. Never throws; falls back and records instead.
    /// Always narrate through here, never through `provider.model` directly.
    ///
    /// This is the only path that records safety interventions and downgrades the status when the
    /// engine fails permanently. `RemliSession` called `model.narrate` directly for a while, and
    /// the result was a status line reporting "Gemma 4 E2B · on device" while every reply came from
    /// a template — because the code that would have corrected the status was never reached.
    func narrate(_ request: NarrationRequest) async -> NarrationResult {
        DiagnosticLog.note("narrate: selection=\(self.selection) model=\(self.model.displayName)"); Self.log.info("narrate: selection=\(String(describing: self.selection), privacy: .public) model=\(self.model.displayName, privacy: .public)")
        do {
            let result = try await model.narrate(request)
            record(result, for: request)
            DiagnosticLog.note("narrate: source=\(result.source.rawValue) rule=\(result.verdict?.rule?.rawValue ?? "none") intervened=\(result.safetyDidIntervene)"); Self.log.info("narrate: source=\(result.source.rawValue, privacy: .public) rule=\(result.verdict?.rule?.rawValue ?? "none", privacy: .public)")
            return result
        } catch let error as LanguageModelError {
            DiagnosticLog.note("narrate: THREW \(error.localizedDescription) permanent=\(error.isPermanent)"); Self.log.error("narrate: threw \(error.localizedDescription, privacy: .public) permanent=\(error.isPermanent)")
            if error.isPermanent {
                downgrade(to: .startupFailed(error.localizedDescription))
            }
            return .template(text: NarrationTemplates.render(request))
        } catch {
            Self.log.error("narrate: threw \(error.localizedDescription, privacy: .public)")
            return .template(text: NarrationTemplates.render(request))
        }
    }

    /// Lets the provider drop the engine without importing LiteRT types, which are behind
    /// `#if canImport`.
    ///
    /// Nothing is lost by unloading: `prepare()` rebuilds on the next request, so the cost of a
    /// memory warning becomes one slow reply rather than a terminated app.
    /// Diagnostics only. Carries model state and rule names — never prompt or health content.
    static let log = Logger(subsystem: "app.remli.Remli", category: "language")

    /// Streaming variant. Records the verdict when the stream completes.
    func narrateStream(_ request: NarrationRequest) -> AsyncThrowingStream<NarrationEvent, Error> {
        let upstream = model.narrateStream(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        if case .completed(let result) = event {
                            await MainActor.run { self.record(result, for: request) }
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    // Never surface a language failure as a broken timeline entry.
                    continuation.yield(.completed(.template(text: NarrationTemplates.render(request))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ result: NarrationResult, for request: NarrationRequest) {
        guard let verdict = result.verdict, verdict.decision == .rejected, let rule = verdict.rule else { return }
        let event = SafetyEvent(
            id: UUID().uuidString,
            date: verdict.reviewedAt,
            rule: rule,
            evidence: verdict.evidence,
            jobLabel: request.job.label
        )
        safetyEvents.insert(event, at: 0)
        if safetyEvents.count > maximumRecordedEvents {
            safetyEvents.removeLast(safetyEvents.count - maximumRecordedEvents)
        }
    }

    func clearSafetyEvents() { safetyEvents.removeAll() }

    // MARK: - Selection

    /// Recomputes the selection, e.g. after the weights finish downloading.
    func reevaluate() {
        var resolved = LanguageModelProvider.resolveSelection(modelManager: modelManager)
        if gemmaFailedThisSession, case .gemmaOnDevice = resolved {
            resolved = selection
        }
        guard resolved != selection else { return }
        apply(resolved)
    }

    private func downgrade(to reason: ScriptedReason) {
        if case .startupFailed = reason { gemmaFailedThisSession = true }
        apply(.scripted(reason))
    }

    private func apply(_ newSelection: LanguageModelSelection) {
        selection = newSelection
        scriptedFallback.availabilityNote = LanguageModelProvider.note(for: newSelection)
        model = makeModel(for: newSelection)
    }

    private func makeModel(for selection: LanguageModelSelection) -> RemliLanguageModel {
        switch selection {
        case .gemmaOnDevice:
            #if canImport(LiteRTLM)
            if let cachedGemmaModel { return cachedGemmaModel }
            let gemma = LiteRTGemmaModel(modelManager: modelManager)
            cachedGemmaModel = gemma
            return gemma
            #else
            // Unreachable: `resolveSelection` requires `LiteRTRuntime.isLinked`. Belt and braces,
            // because "unreachable" and "cannot compile" are different guarantees.
            return scriptedFallback
            #endif
        case .scripted:
            return scriptedFallback
        }
    }

    private static func resolveSelection(modelManager: GemmaModelManager) -> LanguageModelSelection {
        #if targetEnvironment(simulator)
        return .scripted(.simulator)
        #else
        guard LiteRTRuntime.isLinked else { return .scripted(.packageNotLinked) }
        switch modelManager.availability {
        case .ready:
            return .gemmaOnDevice
        case .downloading(let progress):
            return .scripted(.modelFileDownloading(progress: progress))
        case .absent:
            return .scripted(.modelFileMissing)
        case .failed(let reason):
            return .scripted(.startupFailed(reason))
        }
        #endif
    }

    private static func note(for selection: LanguageModelSelection) -> String? {
        if case .scripted(let reason) = selection { return reason.explanation }
        return nil
    }
}

// MARK: - PHI-free labels

extension NarrationJob {
    /// A description of the *kind* of narration, safe to record and display. Never includes the
    /// medication, the instruction, or anything the user said.
    var label: String {
        switch self {
        case .introduceProposal: return "Introducing a reminder"
        case .answerFollowUp: return "Answering a question about a reminder"
        case .heardRecap: return "Recapping what was heard"
        case .confirmScheduled: return "Confirming a scheduled reminder"
        }
    }
}

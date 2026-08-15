// swift-tools-version: 5.9
import PackageDescription

// Remli's evaluation suite.
//
// This package deliberately does not vendor or copy a single line of app code. `Sources/RemliCore`
// is a SYMLINK to `../ios/Remli/Core`, so the evals compile the exact sources the app ships. A
// drifted copy of SafetyGuard that passes its own tests is worse than no tests at all.
//
// Everything here builds and runs on macOS with `swift test` — no simulator, no device, no model
// weights. That is possible because Remli's clinical and safety core is Foundation-only by design
// (see the note at the top of HealthSourceConnector.swift), and it is what keeps these evals fast
// enough to run on every change.
let package = Package(
    name: "RemliEval",
    platforms: [.macOS(.v13)],
    targets: [
        // The app's own Core, compiled as-is.
        //
        // Only genuinely platform-bound files are excluded: `Notifications` needs UserNotifications
        // and UIKit, `LanguageModelProvider` imports UIKit, and `Speech` uses AVAudioSession, which
        // is unavailable on macOS. Everything else — SafetyGuard, GroundedPromptBuilder, the
        // normalizer, the proposal engine, the adherence ledger — is Foundation-only and compiles
        // here untouched.
        //
        // If a new file under Core starts importing UIKit, this build breaks. That is intended: the
        // breakage is the signal that something left the portable core. Add it here only after
        // confirming it genuinely needs a device framework.
        .target(
            name: "RemliCore",
            path: "Sources/RemliCore",
            exclude: [
                "Notifications",
                "Speech",
                "Language/LanguageModelProvider.swift",
            ]
        ),

        // Fixture loading, corpus types, and report emission shared by every test target.
        //
        // Deliberately does NOT depend on RemliCore. Fixtures name rules as plain strings, and the
        // test targets map those onto `SafetyRule` via `@testable import`. That keeps this target
        // free of Core's internal types, and means a fixture file can be read by the Python judge
        // in `judge/` with no Swift involved.
        .target(
            name: "EvalKit",
            path: "Sources/EvalKit"
        ),

        // Family 1: does SafetyGuard reject what it must, and allow what it must?
        .testTarget(
            name: "GuardEvalTests",
            dependencies: ["EvalKit", "RemliCore"],
            path: "Tests/GuardEvalTests"
        ),

        // Family 2: does the streaming tripwire stay in step with the full-text guard?
        .testTarget(
            name: "TripwireEvalTests",
            dependencies: ["EvalKit", "RemliCore"],
            path: "Tests/TripwireEvalTests"
        ),

        // Grounding scope: can a prompt ever see a fact it was not supposed to?
        .testTarget(
            name: "GroundingScopeTests",
            dependencies: ["EvalKit", "RemliCore"],
            path: "Tests/GroundingScopeTests"
        ),

        // FHIR bundle → normalizer → proposal engine, pinned against golden snapshots.
        .testTarget(
            name: "NormalizerEvalTests",
            dependencies: ["EvalKit", "RemliCore"],
            path: "Tests/NormalizerEvalTests"
        ),

        .testTarget(
            name: "ModelManagerTests",
            dependencies: ["RemliCore"],
            path: "Tests/ModelManagerTests"
        ),
    ]
)

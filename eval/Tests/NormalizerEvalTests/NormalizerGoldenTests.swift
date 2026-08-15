import XCTest
import EvalKit
@testable import RemliCore

/// FHIR bundle → `CareRecordNormalizer` → `ReminderProposalEngine`, pinned against golden snapshots.
///
/// This is the family the root README already claims ("Executed against both real bundles via a CLI
/// harness") but which had no harness in the repo. It runs the two bundled sample files through the
/// exact decoding path production data uses — only the transport is different, per
/// `SyntheaBundleConnector`.
///
/// ## Why goldens rather than hand-written assertions
///
/// The interesting output here is a *shape*: eleven proposals, each with slots, provenance, flags and
/// an activation tier. Hand-asserting that is unreadable and nobody updates it. A golden file diffs
/// cleanly, so a change to `DosageInstructionParser` shows up as three changed lines in review rather
/// than as a green build.
///
/// The behavioural invariants below are *not* goldens, because they must hold for any input, not just
/// these two files.
///
/// Regenerate after an intentional change:
///
///     REMLI_EVAL_UPDATE_GOLDENS=1 swift test --filter NormalizerEvalTests
///
/// then read the diff before committing it. A golden updated without reading the diff is worse than
/// no golden, because it launders a regression into the baseline.
final class NormalizerGoldenTests: XCTestCase {

    /// Fixed so `importedAt` cannot make a golden churn.
    private let fixedImportDate = Date(timeIntervalSince1970: 1_700_000_000)

    private var sampleDataDirectory: URL {
        // eval/Tests/NormalizerEvalTests/… → repo root → ios/Remli/Resources/SampleData
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/Remli/Resources/SampleData", isDirectory: true)
    }

    private func descriptor(
        id: String,
        name: String,
        origin: DataOrigin
    ) -> HealthSourceDescriptor {
        HealthSourceDescriptor(
            id: id,
            displayName: name,
            subtitle: "Bundled sample, loaded from disk by the eval suite",
            dataOrigin: origin
        )
    }

    private func load(
        file: String,
        descriptorID: String,
        displayName: String,
        origin: DataOrigin
    ) async throws -> ImportedSource {
        let url = sampleDataDirectory.appendingPathComponent(file)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Sample bundle not found at \(url.path)")
        }
        let connector = SyntheaBundleConnector.file(
            url,
            descriptor: descriptor(id: descriptorID, name: displayName, origin: origin)
        )
        try await connector.authorize()
        return try await connector.importedSource()
    }

    private func syntheaSource() async throws -> ImportedSource {
        try await load(
            file: "synthea-glover.json",
            descriptorID: "sample.synthea.glover",
            displayName: "Remli Demo Hospital",
            origin: .syntheaSynthetic
        )
    }

    private func portalSource() async throws -> ImportedSource {
        try await load(
            file: "portal-export-demo.json",
            descriptorID: "sample.portal.export",
            displayName: "Remli Demo Primary Care",
            origin: .authoredDemo
        )
    }

    // MARK: - Goldens

    func testSyntheaBundleGolden() async throws {
        let source = try await syntheaSource()
        try assertGolden(named: "synthea-glover", for: [source])
    }

    func testPortalExportGolden() async throws {
        let source = try await portalSource()
        try assertGolden(named: "portal-export-demo", for: [source])
    }

    /// Both sources together — the state the app actually launches into.
    ///
    /// Worth its own golden because the interesting behaviour only appears with two sources: the
    /// normalizer must keep two similar orders from different organisations as two items so the
    /// engine can surface the disagreement, rather than collapsing them and destroying it.
    func testBothSourcesTogetherGolden() async throws {
        let sources = [try await syntheaSource(), try await portalSource()]
        try assertGolden(named: "both-sources", for: sources)
    }

    // MARK: - Invariants that must hold for any input

    /// As-needed medications must never receive a scheduled time.
    ///
    /// A recurring alarm on "as needed for pain" converts an as-needed prescription into a standing
    /// one. That is a clinical change made by a scheduling bug.
    func testAsNeededMedicationsAreNeverScheduled() async throws {
        for proposal in try await allProposals() where proposal.isAsNeeded {
            XCTAssertEqual(
                proposal.activationTier, .onDemand,
                "\(proposal.title) is as-needed but its tier is \(proposal.activationTier)"
            )
            XCTAssertTrue(
                proposal.slots.compactMap(\.timeOfDay).isEmpty,
                """
                As-needed proposal "\(proposal.title)" carries \
                \(proposal.slots.compactMap(\.timeOfDay).count) concrete time(s). Approving it would \
                schedule a standing alarm for a medication meant to be taken only when needed.
                """
            )
        }
    }

    /// Anything with a possible concern must wait for a person.
    func testPossibleConcernsNeverAutoActivate() async throws {
        for proposal in try await allProposals() where proposal.hasPossibleConcern {
            XCTAssertNotEqual(
                proposal.activationTier, .ready,
                """
                "\(proposal.title)" carries a possible concern but is tier .ready. A cross-source \
                disagreement would become a daily alarm with no human ever looking at it.
                flags: \(proposal.flags.map(\.title).joined(separator: "; "))
                """
            )
        }
    }

    /// A slot with no time must never be presented as ready to schedule.
    func testUntimedSlotsNeverActivate() async throws {
        for proposal in try await allProposals() where proposal.needsTimeOfDay {
            XCTAssertNotEqual(
                proposal.activationTier, .ready,
                "\"\(proposal.title)\" has an untimed slot but is tier .ready — the UI would silently pick a time."
            )
        }
    }

    /// Proposal ids must be stable across re-imports.
    ///
    /// Ids derive from resource identity rather than a fresh UUID, which is the entire mechanism
    /// behind "skipped items stay skipped". If ids churn, every re-import resurrects everything the
    /// user already dismissed.
    func testProposalIDsAreStableAcrossReimport() async throws {
        let first = try await allProposals()
        let second = try await allProposals()
        XCTAssertEqual(
            first.map(\.id), second.map(\.id),
            "Proposal ids changed between two identical imports; skipped items would reappear."
        )
    }

    /// Skipping removes exactly one proposal and leaves the rest untouched.
    func testSkippingRemovesOnlyThatProposal() async throws {
        let all = try await allProposals()
        let victim = try XCTUnwrap(all.first, "No proposals produced by the sample bundles")

        let engine = ReminderProposalEngine()
        let snapshot = CareRecordNormalizer().snapshot(
            from: [try await syntheaSource(), try await portalSource()],
            importedAt: fixedImportDate
        )
        let remaining = engine.proposals(from: snapshot, skippedProposalIDs: [victim.id])

        XCTAssertEqual(remaining.count, all.count - 1)
        XCTAssertFalse(remaining.contains { $0.id == victim.id })
        XCTAssertEqual(
            Set(remaining.map(\.id)),
            Set(all.map(\.id)).subtracting([victim.id]),
            "Skipping one proposal changed which others were produced."
        )
    }

    /// Every proposal must cite something.
    ///
    /// A proposal with no source facts cannot answer "why am I seeing this", and its narration would
    /// have an almost-empty grounding corpus — so the guard would reject anything the model said
    /// about it.
    func testEveryProposalCitesItsSource() async throws {
        for proposal in try await allProposals() {
            XCTAssertFalse(
                proposal.sourceLabel.isEmpty,
                "\(proposal.id) has no source label"
            )
            if case .fromYourRecord = proposal.primaryProvenance {
                XCTAssertFalse(
                    proposal.sourceFacts.isEmpty,
                    """
                    "\(proposal.title)" claims provenance .fromYourRecord but carries no source \
                    facts. The disclosure would be empty and its grounding corpus nearly so.
                    """
                )
            }
        }
    }

    /// The sparse bundle must actually exercise the gap paths.
    ///
    /// Synthea output has no dosage text, no time of day and no PT detail — which is the case the
    /// reminder policy is written for. If this ever produces a clean set of fully-timed proposals,
    /// the sample data has been replaced with something easier and the suite has stopped testing the
    /// interesting path.
    func testSyntheaBundleStillExercisesTheGapPaths() async throws {
        let snapshot = CareRecordNormalizer().snapshot(
            from: [try await syntheaSource()],
            importedAt: fixedImportDate
        )
        let proposals = ReminderProposalEngine().proposals(from: snapshot)
        XCTAssertFalse(proposals.isEmpty, "Synthea bundle produced no proposals at all")

        let needingAHuman = proposals.filter { $0.activationTier != .ready }
        XCTAssertFalse(
            needingAHuman.isEmpty,
            """
            Every Synthea proposal came out tier .ready. That bundle is deliberately sparse, so this \
            means either the sample data changed or the engine started filling gaps on its own.
            """
        )
    }

    // MARK: - Helpers

    private func allProposals() async throws -> [ReminderProposal] {
        let snapshot = CareRecordNormalizer().snapshot(
            from: [try await syntheaSource(), try await portalSource()],
            importedAt: fixedImportDate
        )
        return ReminderProposalEngine().proposals(from: snapshot)
    }

    /// Renders a stable summary and compares it with `fixtures/goldens/<name>.txt`.
    private func assertGolden(named name: String, for sources: [ImportedSource]) throws {
        let snapshot = CareRecordNormalizer().snapshot(from: sources, importedAt: fixedImportDate)
        let proposals = ReminderProposalEngine().proposals(from: snapshot)
        let rendered = render(snapshot: snapshot, proposals: proposals)

        let directory = Fixtures.root.appendingPathComponent("goldens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).txt")

        if ProcessInfo.processInfo.environment["REMLI_EVAL_UPDATE_GOLDENS"] != nil {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            print("golden updated: \(url.path) — read the diff before committing")
            return
        }

        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            try rendered.write(to: url, atomically: true, encoding: .utf8)
            XCTFail(
                """
                No golden existed for '\(name)'; one has been written to \(url.path).
                Read it, confirm it describes what the engine should produce, and commit it.
                """
            )
            return
        }

        if rendered != expected {
            XCTFail(
                """
                Golden mismatch for '\(name)'.
                \(firstDifference(expected: expected, actual: rendered))

                If this change is intentional:
                  REMLI_EVAL_UPDATE_GOLDENS=1 swift test --filter NormalizerEvalTests
                and read the diff before committing.
                """
            )
        }
    }

    /// Deliberately avoids `formattedTime`, which goes through `DateFormatter` and is therefore
    /// locale-dependent — a golden built from it would fail on a machine set to a 24-hour clock.
    private func render(snapshot: CareRecordSnapshot, proposals: [ReminderProposal]) -> String {
        var lines: [String] = []
        lines.append("patient: \(snapshot.patientDisplayName ?? "—")")
        lines.append("sources: \(snapshot.sourceLabels.sorted().joined(separator: " | "))")
        lines.append("medications: \(snapshot.medications.count)")
        lines.append("therapyTasks: \(snapshot.therapyTasks.count)")
        lines.append("dietaryGuidance: \(snapshot.dietaryGuidance.count)")
        lines.append("allergies: \(snapshot.allergies.sorted().joined(separator: ", "))")
        lines.append("proposals: \(proposals.count)")
        lines.append("")

        for proposal in proposals.sorted(by: { $0.id < $1.id }) {
            lines.append("── \(proposal.id)")
            lines.append("   kind: \(proposal.kind.rawValue)")
            lines.append("   title: \(proposal.title)")
            lines.append("   subtitle: \(proposal.subtitle ?? "—")")
            lines.append("   source: \(proposal.sourceLabel) [\(proposal.dataOrigin.rawValue)]")
            lines.append("   provenance: \(badge(for: proposal.primaryProvenance))")
            lines.append("   tier: \(tier(proposal.activationTier))")
            lines.append("   needsTimeOfDay: \(proposal.needsTimeOfDay)   asNeeded: \(proposal.isAsNeeded)")
            if let reason = proposal.schedulingDeclinedReason {
                lines.append("   schedulingDeclined: \(reason.rawValue)")
            }
            for slot in proposal.slots {
                let time = slot.timeOfDay.map { components in
                    String(format: "%02d:%02d", components.hour ?? -1, components.minute ?? -1)
                } ?? "unset"
                let suggestion = slot.suggestion.map { " suggestion=\($0.clockTime.hour ?? -1):"
                    + String(format: "%02d", $0.clockTime.minute ?? 0) } ?? ""
                lines.append("   slot: \(slot.label) @ \(time) [\(badge(for: slot.provenance))]\(suggestion)")
            }
            for flag in proposal.flags.sorted(by: { $0.title < $1.title }) {
                lines.append("   flag(\(flag.severity.rawValue)): \(flag.title)")
            }
            for fact in proposal.sourceFacts.sorted(by: { $0.label < $1.label }) {
                lines.append("   fact[\(fact.label)]: \"\(fact.verbatim)\"")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func badge(for provenance: Provenance) -> String {
        switch provenance {
        case .fromYourRecord(let citation):
            return "fromYourRecord(\(citation.resourceType))"
        case .patternNoticed(let basis):
            return "patternNoticed(\(basis))"
        case .needsReview(let reason):
            return "needsReview(\(reason.rawValue))"
        case .convenienceSuggestion(let basis):
            return "convenienceSuggestion(\(basis))"
        }
    }

    private func tier(_ tier: ReminderProposal.ActivationTier) -> String {
        switch tier {
        case .ready: return "ready"
        case .needsYou: return "needsYou"
        case .onDemand: return "onDemand"
        }
    }

    /// First differing line, with context. Cheaper to read than a full diff of a long golden.
    private func firstDifference(expected: String, actual: String) -> String {
        let expectedLines = expected.components(separatedBy: "\n")
        let actualLines = actual.components(separatedBy: "\n")
        for index in 0..<max(expectedLines.count, actualLines.count) {
            let lhs = index < expectedLines.count ? expectedLines[index] : "<end of file>"
            let rhs = index < actualLines.count ? actualLines[index] : "<end of file>"
            if lhs != rhs {
                return """
                first difference at line \(index + 1):
                  expected: \(lhs)
                  actual:   \(rhs)
                (\(expectedLines.count) expected lines vs \(actualLines.count) actual)
                """
            }
        }
        return "files differ only in trailing whitespace"
    }
}

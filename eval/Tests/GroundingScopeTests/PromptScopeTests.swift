import XCTest
@testable import RemliCore

/// Grounding scope — can a prompt ever see a fact it was not supposed to?
///
/// `GroundedPromptBuilder`'s header makes three promises, and this file is where they stop being
/// prose. The one that matters most: **only one proposal is ever in context.** Never the vault,
/// never the medication list, never the conversation history. That is the property behind
/// `LiteRTGemmaModel` opening a fresh conversation per request — "history is a grounding leak."
///
/// This is deliberately tested through the builder's real output rather than by inspecting its
/// source, because the leak that actually happens is a new field being added to `proposalFields`
/// that quietly carries something from elsewhere.
final class PromptScopeTests: XCTestCase {

    // MARK: - Fixtures

    /// Two proposals from two different organisations, with deliberately distinctive tokens so a
    /// leak is unambiguous rather than a coincidence of shared vocabulary.
    private func makeProposal(
        id: String,
        title: String,
        dose: String,
        sourceLabel: String,
        hour: Int,
        slotLabel: String
    ) -> ReminderProposal {
        let citation = SourceCitation(
            sourceLabel: sourceLabel,
            resourceType: "MedicationRequest",
            resourceID: id,
            fieldPath: "dosageInstruction[0].text",
            verbatimText: dose,
            dataOrigin: .authoredDemo
        )
        return ReminderProposal(
            id: id,
            kind: .medication,
            title: title,
            subtitle: dose,
            sourceFacts: [
                SourceFact(label: "Instruction", verbatim: dose, citation: citation)
            ],
            slots: [
                ProposedSlot(
                    id: "\(id)-slot-0",
                    timeOfDay: DateComponents(hour: hour, minute: 0),
                    provenance: .fromYourRecord(citation),
                    label: slotLabel
                )
            ],
            flags: [],
            primaryProvenance: .fromYourRecord(citation),
            sourceLabel: sourceLabel,
            dataOrigin: .authoredDemo,
            schedulingDeclinedReason: nil
        )
    }

    private var proposalA: ReminderProposal {
        makeProposal(
            id: "prop-a",
            title: "Lisinopril",
            dose: "Take 1 tablet (10 mg) by mouth once daily.",
            sourceLabel: "Remli Demo Primary Care",
            hour: 8,
            slotLabel: "Morning"
        )
    }

    private var proposalB: ReminderProposal {
        makeProposal(
            id: "prop-b",
            title: "Warfarin",
            dose: "Take 3 mg by mouth at 7 PM.",
            sourceLabel: "Remli Demo Hospital",
            hour: 19,
            slotLabel: "Evening"
        )
    }

    // MARK: - One proposal at a time

    func testPromptForOneProposalContainsNothingFromAnother() {
        let promptB = GroundedPromptBuilder.build(for: .introduce(proposalB))
        let haystack = promptB.userMessage + "\n" + promptB.grounding.corpus

        // Tokens unique to proposal A. If any appears, the builder reached beyond its argument.
        for leak in ["Lisinopril", "Remli Demo Primary Care", "10 mg", "prop-a"] {
            XCTAssertFalse(
                haystack.contains(leak),
                """
                Grounding leak: "\(leak)" belongs to proposal A but appears in the prompt for
                proposal B. Only one proposal may ever be in context — a model shown two
                medications can confuse them, and SafetyGuard would then accept the wrong dose as
                grounded.
                """
            )
        }

        // And the prompt does contain its own facts, so the assertion above is not passing merely
        // because the prompt is empty.
        XCTAssertTrue(haystack.contains("Warfarin"), "Prompt for B is missing B's own name")
        XCTAssertTrue(haystack.contains("Remli Demo Hospital"), "Prompt for B is missing B's own source")
    }

    /// The guard's view of the world must be scoped the same way the prompt is.
    ///
    /// A prompt correctly limited to one proposal is worthless if the grounding corpus handed to
    /// `SafetyGuard` is wider, because then the guard would happily accept the other medication's
    /// dose as grounded. This asserts the two are scoped together.
    func testGuardRejectsTheOtherProposalsDoseAsUngrounded() {
        let promptB = GroundedPromptBuilder.build(for: .introduce(proposalB))

        // "10 mg" is proposal A's dose. Against B's grounding it must be ungrounded.
        let verdict = SafetyGuard.review(
            "Your record says 10 mg once daily.",
            against: promptB.grounding
        )
        XCTAssertEqual(
            verdict.decision, .rejected,
            "Proposal A's dose was accepted against proposal B's grounding — the corpora are not scoped."
        )
    }

    // MARK: - Follow-up turns do not accumulate

    /// Turn three must not be able to restate turn one's medication.
    ///
    /// Each `NarrationRequest` is built independently, so a follow-up about B carries only B — plus
    /// the person's own question, which is legitimately grounding for restatement. This is the
    /// property that makes a per-request conversation the right design rather than an optimisation.
    func testFollowUpCarriesOnlyItsOwnProposalAndTheQuestion() {
        let question = "Is 850 mg right?"
        let prompt = GroundedPromptBuilder.build(
            for: .followUp(question, about: proposalB)
        )
        let haystack = prompt.userMessage + "\n" + prompt.grounding.corpus

        for leak in ["Lisinopril", "Remli Demo Primary Care"] {
            XCTAssertFalse(
                haystack.contains(leak),
                "Follow-up about proposal B leaked \"\(leak)\" from proposal A."
            )
        }
        XCTAssertTrue(
            prompt.grounding.corpus.contains("850"),
            """
            The person's own question is missing from the grounding corpus. Without it the only
            honest answer — "your record does not mention 850 mg" — would itself be rejected as an
            ungrounded number.
            """
        )
    }

    // MARK: - Gaps are stated, not filled

    /// A missing time must appear in the prompt as explicitly missing.
    ///
    /// "The most important lines in most of these prompts are the `Not in the record:` ones. A model
    /// that is never told what is missing will fill it in."
    func testMissingTimeIsStatedExplicitly() {
        let citation = SourceCitation(
            sourceLabel: "Remli Demo Primary Care",
            resourceType: "MedicationRequest",
            resourceID: "prop-c",
            fieldPath: "dosageInstruction[0].text",
            verbatimText: "Take 1 tablet by mouth once daily.",
            dataOrigin: .authoredDemo
        )
        let proposal = ReminderProposal(
            id: "prop-c",
            kind: .medication,
            title: "Atorvastatin",
            subtitle: nil,
            sourceFacts: [SourceFact(label: "Instruction", verbatim: citation.verbatimText, citation: citation)],
            slots: [
                ProposedSlot(
                    id: "prop-c-slot-0",
                    timeOfDay: nil,
                    provenance: .needsReview(.timeOfDayNotSpecified),
                    label: "Dose 1 of 1"
                )
            ],
            flags: [],
            primaryProvenance: .needsReview(.timeOfDayNotSpecified),
            sourceLabel: "Remli Demo Primary Care",
            dataOrigin: .authoredDemo,
            schedulingDeclinedReason: nil
        )

        let prompt = GroundedPromptBuilder.build(for: .introduce(proposal))
        XCTAssertTrue(
            prompt.userMessage.lowercased().contains("not stated in the record"),
            """
            A slot with no time did not produce an explicit "not stated in the record" line.
            The model will invent one.
            prompt was:
            \(prompt.userMessage)
            """
        )
    }

    /// Every prompt must carry a usable fallback, since that is what ships when the guard says no.
    func testEveryPromptHasANonEmptyFallback() {
        let requests: [NarrationRequest] = [
            .introduce(proposalA),
            .introduce(proposalB),
            .followUp("Why am I seeing this?", about: proposalA),
        ]
        for request in requests {
            let prompt = GroundedPromptBuilder.build(for: request)
            XCTAssertFalse(
                prompt.fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "A prompt with an empty fallback means a guard rejection shows the user nothing."
            )
            XCTAssertFalse(
                prompt.grounding.isEmpty,
                "An empty grounding corpus makes every number the model says ungrounded."
            )
        }
    }
}

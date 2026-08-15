import Foundation

/// Where a piece of data physically came from.
///
/// This is surfaced in the UI so a demo audience — and a real patient — can always tell
/// synthetic data from a live chart pull. It is deliberately not optional.
enum DataOrigin: String, Codable, Hashable {
    /// MITRE Synthea synthetic patient record.
    case syntheaSynthetic
    /// Hand-authored sample data used to demonstrate fields Synthea does not populate.
    case authoredDemo
    /// Pulled from a real patient-authorized FHIR endpoint.
    case liveFHIR
    /// The user typed it in themselves.
    case manualEntry
    /// The medication-label photo affordance. Demo only in v1; never becomes a reminder by itself.
    case photoDemo

    var shortLabel: String {
        switch self {
        case .syntheaSynthetic: return "Synthetic record"
        case .authoredDemo: return "Sample data"
        case .liveFHIR: return "Your chart"
        case .manualEntry: return "You entered this"
        case .photoDemo: return "Label photo (demo)"
        }
    }

    /// True when the data describes a real person's real care.
    var isRealPatientData: Bool { self == .liveFHIR || self == .manualEntry }
}

/// A pointer back to the exact record a statement came from.
///
/// `verbatimText` is never paraphrased before display. Paraphrasing a dosage instruction is
/// exactly how "twice daily with meals" quietly becomes "twice daily".
struct SourceCitation: Codable, Hashable, Identifiable {
    let id: String
    /// Human-readable origin, e.g. "Remli Demo Primary Care".
    let sourceLabel: String
    let resourceType: String
    let resourceID: String
    /// FHIR-ish path the text was read from, e.g. `dosageInstruction[0].text`.
    let fieldPath: String
    let verbatimText: String
    let recordedDate: Date?
    let dataOrigin: DataOrigin

    init(
        sourceLabel: String,
        resourceType: String,
        resourceID: String,
        fieldPath: String,
        verbatimText: String,
        recordedDate: Date? = nil,
        dataOrigin: DataOrigin
    ) {
        self.id = "\(resourceType)/\(resourceID)#\(fieldPath)"
        self.sourceLabel = sourceLabel
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.fieldPath = fieldPath
        self.verbatimText = verbatimText
        self.recordedDate = recordedDate
        self.dataOrigin = dataOrigin
    }

    /// Short attribution shown on the citation chip.
    var chipLabel: String { sourceLabel }
}

/// Why a proposal needs the user to look at it before anything is scheduled.
enum ReviewReason: String, Codable, Hashable {
    case timeOfDayNotSpecified
    case frequencyNotSpecified
    case asNeededMedication
    case conflictingFoodInstruction
    case therapyDetailIncomplete
    case equipmentUnclear
    case remindersCluster

    var plainLanguage: String {
        switch self {
        case .timeOfDayNotSpecified:
            return "Your record says how often, but not what time of day."
        case .frequencyNotSpecified:
            return "Your record does not say how often to take this."
        case .asNeededMedication:
            return "Your record lists this as taken only when needed."
        case .conflictingFoodInstruction:
            return "Two of your records describe this differently."
        case .therapyDetailIncomplete:
            return "Your record names this exercise but does not describe how to do it."
        case .equipmentUnclear:
            return "It is not clear from your record what equipment this needs."
        case .remindersCluster:
            return "Several reminders would land close together."
        }
    }
}

/// The design doc's rule categories, expressed as a type.
///
/// Every clinical statement Remli shows carries one of these. There is no way to construct a
/// displayable claim without one, which is what keeps "the assistant made this up" off the screen.
enum Provenance: Codable, Hashable {
    /// Directly sourced chart or label text.
    case fromYourRecord(SourceCitation)
    /// Inferred from the user's routine, calendar, or app usage.
    case patternNoticed(basis: String)
    /// The user must confirm before this can activate.
    case needsReview(ReviewReason)
    /// Remli's own scheduling idea. Explicitly not a clinical recommendation.
    case convenienceSuggestion(basis: String)

    var badgeText: String {
        switch self {
        case .fromYourRecord: return "From your record"
        case .patternNoticed: return "Pattern noticed"
        case .needsReview: return "Needs review"
        case .convenienceSuggestion: return "Remli's suggestion"
        }
    }

    var citation: SourceCitation? {
        if case .fromYourRecord(let citation) = self { return citation }
        return nil
    }

    /// True when this represents a fact from the chart rather than something Remli inferred.
    var isClinicalFact: Bool {
        if case .fromYourRecord = self { return true }
        return false
    }
}

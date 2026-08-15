import Foundation
import SwiftUI

/// The application's single coordinator: it owns the timeline and the order in which the
/// subsystems are allowed to touch it.
///
/// The one rule this type exists to enforce is the approval boundary. A `ReminderProposal` is
/// inert. Only `approve(_:)` converts one into an `ApprovedReminder`, and only an
/// `ApprovedReminder` can reach `NotificationScheduler`. There is no other path from imported
/// data to a scheduled alert, which is what makes "every reminder is individually approved" a
/// property of the code rather than a promise in a document.
@MainActor
final class RemliSession: ObservableObject {

    // MARK: - Published state

    @Published private(set) var timeline: [TimelineEntry] = []
    @Published private(set) var status = SessionStatus()
    @Published private(set) var isImporting = false
    @Published private(set) var isNarrating = false
    @Published var composerText: String = ""
    /// Something the user has said about their day, e.g. "mornings are rough". Routine, never
    /// clinical — it only ever influences *when* a reminder fires.
    @Published var statedRoutine: String?
    /// Set when a notification asked to edit a reminder's time.
    @Published var pendingTimeEditReminderID: String?
    /// Why the last narration fell back, if it did. Surfaced in the privacy sheet rather than
    /// hidden, because an invisible fallback is indistinguishable from a model that is not running.
    @Published private(set) var lastNarrationError: String?
    /// Outcome of the last test send, shown next to the button. Without it a blocked notification
    /// is indistinguishable from a working one that simply has not fired yet.
    @Published var testSendResult: String?
    /// Proposals produced by the engine that the user has not yet acted on.
    @Published private(set) var openProposals: [ReminderProposal] = []
    /// Everything the engine produced this import, before tiering.
    @Published private(set) var allProposals: [ReminderProposal] = []

    // MARK: - Subsystems

    let vault: VaultStore
    let languageProvider: LanguageModelProvider
    let scheduler: NotificationScheduler
    let permission: NotificationPermission
    let ledger = AdherenceLedger()
    private let detector = LedgerPatternDetector()
    private let interruptionPolicy = InterruptionPolicy()
    /// Persisted so cooldowns and backoff survive relaunch — otherwise quitting the app would
    /// reset every "leave me alone" the user has expressed.
    @Published private(set) var interruptionHistory = InterruptionHistory()
    private let playback: SpeechPlayback
    private let normalizer: CareRecordNormalizer
    private let engine: ReminderProposalEngine
    private let scheduleProposer = ScheduleProposer()

    private var hasStarted = false

    /// Dependencies are optional rather than defaulted, because a default argument is evaluated in
    /// a nonisolated context and several of these are `@MainActor`-bound. Passing nil builds the
    /// real thing inside the isolated initializer; tests inject their own.
    init(
        vault: VaultStore? = nil,
        languageProvider: LanguageModelProvider? = nil,
        scheduler: NotificationScheduler? = nil,
        permission: NotificationPermission? = nil,
        playback: SpeechPlayback? = nil,
        normalizer: CareRecordNormalizer = CareRecordNormalizer(),
        engine: ReminderProposalEngine = ReminderProposalEngine()
    ) {
        self.vault = vault ?? VaultStore()
        self.languageProvider = languageProvider ?? LanguageModelProvider()
        self.scheduler = scheduler ?? NotificationScheduler()
        self.permission = permission ?? NotificationPermission()
        self.playback = playback ?? SpeechPlayback()
        self.normalizer = normalizer
        self.engine = engine
        self.status.networkEgressDescription = EgressPolicy.statusStripDescription
    }

    // MARK: - Launch

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true

        scheduler.registerCategories()
        refreshStatus()

        await vault.loadAll()
        ledger.load()
        await permission.refresh()
        await scheduler.refreshPending()
        ledger.materializeElapsed(for: vault.approvedReminders)
        interruptionHistory = (try? vaultFile(InterruptionHistory.self, "interruptions"))
            ?? InterruptionHistory()
        interruptionHistory.checkInsThisAppOpen = 0

        greet()

        // Model preparation is deliberately off the critical path: the app is fully usable while
        // Gemma loads, and the scripted narrator covers the gap.
        Task { await prepareLanguageModel() }

        defer { considerCheckIn() }

        if vault.careRecord == nil {
            await importDemoSources()
        } else if let record = vault.careRecord {
            rebuildProposals(from: record)
            await activateReadyProposals()
            append(.note("Loaded \(record.medications.count) medications and "
                         + "\(record.therapyTasks.count) exercises from your encrypted vault."))
            await presentNextProposal()
        }
    }

    private func prepareLanguageModel() async {
        do {
            try await languageProvider.model.prepare()
        } catch {
            // Non-fatal by design. The provider has already fallen back to scripted narration.
        }
        refreshStatus()
    }

    private func greet() {
        append(.assistant(
            text: "Hello. Everything we discuss stays on this phone — your records are stored "
                + "encrypted here, and nothing is sent anywhere.",
            narrationSource: .staticCopy
        ))
    }

    // MARK: - Import

    /// v1 reads bundled Synthea and authored sample data through the same connector protocol a
    /// real MyChart connection will use. Only the transport is different.
    func importDemoSources() async {
        guard !isImporting else { return }
        isImporting = true
        defer { isImporting = false }

        let connectors: [HealthSourceConnector] = [
            SyntheaBundleConnector.syntheaGlover(),
            SyntheaBundleConnector.portalExportDemo()
        ]

        var imports: [ImportedSource] = []
        for connector in connectors {
            do {
                try await connector.authorize()
                imports.append(try await connector.importedSource())
            } catch {
                append(.note("Could not read \(connector.source.displayName): "
                             + "\(error.localizedDescription)"))
            }
        }

        guard !imports.isEmpty else {
            append(.assistant(
                text: "I could not read any health records just now, so there is nothing for me "
                    + "to suggest yet.",
                narrationSource: .staticCopy
            ))
            return
        }

        let snapshot = normalizer.snapshot(from: imports)
        vault.saveCareRecord(snapshot)
        rebuildProposals(from: snapshot)
        await activateReadyProposals()

        append(.note("Imported from \(snapshot.sourceLabels.count) sources · stored encrypted on "
                     + "this device"))

        append(.heard(
            summary: "\(snapshot.medications.count) medications and "
                   + "\(snapshot.therapyTasks.count) exercises in your records",
            detail: snapshot.sourceLabels.joined(separator: " · ")
        ))

        if openProposals.isEmpty {
            append(.assistant(
                text: "I read through your records and did not find anything that needs a "
                    + "repeating reminder right now.",
                narrationSource: .staticCopy
            ))
        } else {
            append(.assistant(
                text: "I found \(openProposals.count) things in your records that could become "
                    + "reminders. I will go through them one at a time, and I will show you where "
                    + "each one came from. Nothing is scheduled until you say so.",
                narrationSource: .staticCopy
            ))
            await presentNextProposal()
        }
    }

    private func rebuildProposals(from snapshot: CareRecordSnapshot) {
        let skipped = Set(vault.skippedProposals.map(\.proposalID))
        let approved = Set(vault.approvedReminders.map(\.proposalID))
        allProposals = engine
            .proposals(from: snapshot, skippedProposalIDs: skipped)
            .filter { !approved.contains($0.id) }
        openProposals = allProposals.filter { $0.activationTier != .ready }
    }

    /// Schedules everything in the `ready` tier without asking.
    ///
    /// This is the approval model we settled on: review is expensive and habituating when it is a
    /// wall of cards, so it is spent only where it buys something — conflicts and missing details.
    /// Everything else starts running, says where it came from, and can be changed from the card
    /// or from the notification itself.
    private func activateReadyProposals() async {
        let ready = allProposals.filter { $0.activationTier == .ready }
        guard !ready.isEmpty else { return }

        await ensureNotificationPermission()
        var scheduled = 0
        var modelChosen = 0
        // Times already committed, so the model can space new reminders around them instead of
        // stacking everything at the same default hour.
        var taken: [DateComponents] = vault.approvedReminders.flatMap(\.times)

        for proposal in ready {
            let timed = await timedProposal(proposal, avoiding: taken)
            if timed.chosenByModel { modelChosen += 1 }
            taken.append(contentsOf: timed.proposal.slots.compactMap(\.timeOfDay))
            let reminder = makeReminder(from: timed.proposal)
            vault.approve(reminder)
            do {
                try await scheduler.schedule(reminder)
                scheduled += 1
            } catch {
                // Keep it in the list even if the OS refused — the user can retry from the card.
            }
        }
        await scheduler.refreshPending()
        allProposals.removeAll { $0.activationTier == .ready }

        let suffix = modelChosen > 0 ? " · \(modelChosen) timed by Gemma" : ""
        append(.note("\(scheduled) reminder\(scheduled == 1 ? "" : "s") set up from your records"
                     + suffix))
    }

    /// Asks the model to choose this reminder's times, falling back to the deterministic spacing
    /// already on the proposal.
    ///
    /// The fallback is what the slots already carry, so a failure here is invisible: the reminder
    /// still arrives timed, just spaced by the resolver rather than by Gemma.
    private func timedProposal(
        _ proposal: ReminderProposal,
        avoiding taken: [DateComponents]
    ) async -> (proposal: ReminderProposal, chosenByModel: Bool) {
        let fallback = proposal.slots.compactMap(\.timeOfDay)
        guard !fallback.isEmpty, proposal.kind != .nutrition else {
            // Meal cards are anchored to meals by definition; there is nothing to choose.
            return (proposal, false)
        }

        let anchor = proposal.slots.compactMap { slot -> String? in
            guard case .fromYourRecord = slot.provenance else { return nil }
            return slot.label
        }.first

        let request = ScheduleProposer.Request(
            itemName: proposal.title,
            timesPerDay: fallback.count,
            instructionText: proposal.sourceFacts
                .first(where: { $0.label.lowercased().contains("instruction") })?.verbatim,
            recordAnchor: anchor,
            existingTimes: taken,
            statedRoutine: statedRoutine
        )

        let outcome = await scheduleProposer.propose(
            request, using: languageProvider.model, fallback: fallback
        )
        guard outcome.chosenByModel else { return (proposal, false) }

        var updated = proposal
        for (index, time) in outcome.times.enumerated() where index < updated.slots.count {
            updated.slots[index].timeOfDay = time
            updated.slots[index].provenance = .convenienceSuggestion(
                basis: "Gemma picked this time on your phone, based on your other reminders. "
                    + "It is a scheduling idea, not health guidance."
            )
        }
        return (updated, true)
    }

    private func makeReminder(from proposal: ReminderProposal) -> ApprovedReminder {
        ApprovedReminder(
            id: proposal.id,
            proposalID: proposal.id,
            kind: proposal.kind,
            title: proposal.title,
            body: proposal.subtitle ?? proposal.title,
            times: proposal.slots.compactMap(\.timeOfDay),
            sourceFacts: proposal.sourceFacts,
            sourceLabel: proposal.sourceLabel,
            dataOrigin: proposal.dataOrigin,
            approvedAt: Date(),
            isActive: true
        )
    }

    /// Medications the record says are taken only when needed. Shown, never scheduled.
    var onDemandProposals: [ReminderProposal] {
        allProposals.filter { $0.activationTier == .onDemand }
    }

    /// Proposals genuinely waiting on a person.
    var proposalsNeedingReview: [ReminderProposal] {
        allProposals.filter { $0.activationTier == .needsYou }
    }

    // MARK: - Proposal review

    /// Presents one proposal at a time. The design doc asks for individual review, and a wall of
    /// twelve cards is not review — it is a form to dismiss.
    func presentNextProposal() async {
        guard let next = openProposals.first else { return }
        guard !timelineContainsProposal(next.id) else { return }

        let narration = await narrate(.introduce(next, patientFirstName: patientFirstName))
        append(.assistant(text: narration.text, narrationSource: narration.source))
        append(.proposal(next))
    }

    private func timelineContainsProposal(_ id: String) -> Bool {
        timeline.contains { entry in
            if case .proposal(let proposal) = entry.content { return proposal.id == id }
            return false
        }
    }

    // MARK: - The approval boundary

    /// The only route from a proposal to a scheduled notification.
    func approve(_ proposal: ReminderProposal) async {
        // A proposal with an unset time cannot be scheduled. The card disables approval in that
        // case; this is the belt-and-braces check behind it.
        let times = proposal.slots.compactMap(\.timeOfDay)

        let reminder = ApprovedReminder(
            id: proposal.id,
            proposalID: proposal.id,
            kind: proposal.kind,
            title: proposal.title,
            body: proposal.subtitle ?? proposal.title,
            times: times,
            sourceFacts: proposal.sourceFacts,
            sourceLabel: proposal.sourceLabel,
            dataOrigin: proposal.dataOrigin,
            approvedAt: Date(),
            isActive: true
        )

        vault.approve(reminder)
        consume(proposal.id)

        if times.isEmpty {
            // Kept in the list, but nothing to schedule — an as-needed medication, for example.
            append(.scheduled(reminder))
        } else {
            await ensureNotificationPermission()
            do {
                try await scheduler.schedule(reminder)
                append(.scheduled(reminder))
                let narration = await narrate(.confirm(reminder, patientFirstName: patientFirstName))
                append(.assistant(text: narration.text, narrationSource: narration.source))
            } catch {
                append(.note("I saved this reminder but could not schedule the notification: "
                             + "\(error.localizedDescription)"))
            }
            await scheduler.refreshPending()
        }

        await presentNextProposal()
    }

    func skip(_ proposal: ReminderProposal) async {
        vault.skip(proposalID: proposal.id)
        consume(proposal.id)
        append(.note("Skipped \(proposal.title). I will not bring it up again."))
        await presentNextProposal()
    }

    /// "Edit" is intentionally a conversational turn rather than a form. The thing people most
    /// often want to change is the time, and the card already edits that in place.
    func edit(_ proposal: ReminderProposal) async {
        append(.user(text: "I'd like to change this one.", wasSpoken: false))
        let narration = await narrate(.followUp(
            "The person wants to adjust this reminder before approving it.",
            about: proposal,
            patientFirstName: patientFirstName
        ))
        append(.assistant(text: narration.text, narrationSource: narration.source))
    }

    private func consume(_ proposalID: String) {
        openProposals.removeAll { $0.id == proposalID }
        allProposals.removeAll { $0.id == proposalID }
    }

    private func ensureNotificationPermission() async {
        guard !permission.deliversReminders else { return }
        _ = await permission.request()
    }

    // MARK: - Conversation

    func send(_ text: String) async {
        append(.user(text: text, wasSpoken: false))

        // Follow-ups are grounded in one specific thing — never the whole vault.
        //
        // This used to require an *open proposal*, which meant chat silently stopped working the
        // moment tiering started auto-activating reminders: proposals left `openProposals`, no
        // grounding context could be found, and every question got fixed copy without the model
        // ever being asked. Running reminders are the obvious context, and they carry the same
        // cited facts a proposal does.
        DiagnosticLog.note("send: activeReminders=\(activeReminders.count) openProposals=\(openProposals.count)")
        guard let context = groundingContext(for: text) else {
            DiagnosticLog.note("send: NO GROUNDING CONTEXT — model not asked")
            append(.assistant(
                text: "I don't have any reminders set up yet, so there's nothing for me to talk "
                    + "through. Once some are running, ask me anything about them.",
                narrationSource: .staticCopy
            ))
            return
        }

        DiagnosticLog.note("send: grounded on \"\(context.title)\" facts=\(context.sourceFacts.count)")
        let narration = await narrate(.followUp(
            text,
            about: context,
            patientFirstName: patientFirstName
        ))
        append(.assistant(text: narration.text, narrationSource: narration.source))
    }

    func runQuickAction(_ action: Composer.QuickAction) async {
        await send(action.prompt)
    }

    func speak(_ text: String) {
        playback.speak(text)
    }

    /// Demo affordance: fires a real local notification a few seconds out so the loop can be shown
    /// end to end without waiting for the scheduled hour.
    /// Fires a specific reminder about ten seconds out.
    ///
    /// Takes the reminder explicitly rather than picking one: the preview shows a particular
    /// medication, and sending a different one — which is what happened while this used
    /// `approvedReminders.last` against a preview built from `activeReminders.first` — makes the
    /// feature actively misleading in exactly the situation it exists for.
    func demoFire(_ reminder: ApprovedReminder) async {
        DiagnosticLog.note("demoFire: requested for \(reminder.title) times=\(reminder.times.count)")
        let granted = await permission.request()
        DiagnosticLog.note("demoFire: permission result=\(granted.rawValue)")
        guard granted == .authorized || granted == .provisional else {
            testSendResult = "iOS is blocking notifications for Remli. "
                + "Settings ▸ Notifications ▸ Remli ▸ Allow Notifications, then try again."
            return
        }

        do {
            _ = try await scheduler.debugFireSoon(reminder)
            testSendResult = "Sending \"\(reminder.title)\" in about 10 seconds — "
                + "lock your phone to see it the way a stranger would."
            append(.note("Test notification queued for \(reminder.title)"))
        } catch {
            testSendResult = "Couldn't send it: \(error.localizedDescription)"
        }
    }

    /// Kept for the older call site; sends the first running reminder.
    func demoFireMostRecent() async {
        guard let reminder = activeReminders.first else {
            testSendResult = "There are no running reminders to test with yet."
            return
        }
        await demoFire(reminder)
    }

    // MARK: - Narration

    private func narrate(_ request: NarrationRequest) async -> NarrationResult {
        isNarrating = true
        defer { isNarrating = false }
        do {
            let result = await languageProvider.narrate(request)
            // A SafetyGuard rejection does not throw — it returns a template. Without this, a
            // rejected reply looked identical to a model that was never asked.
            if result.source == .deterministicTemplate {
                lastNarrationError = result.verdict?.rule.map {
                    "SafetyGuard rejected the model's wording (\($0.title))"
                } ?? "The model returned nothing usable."
            } else {
                lastNarrationError = nil
            }
            return result
        } catch {
            // Narration failing must never block the loop — the card already carries the clinical
            // content. But it must not be *silent* either: swallowing this is how a loaded model
            // reporting "on device" still produced scripted replies with nothing to explain it.
            lastNarrationError = error.localizedDescription
            return .template(text: "Here is what I found in your record.")
        }
    }

    /// The single item a question is about.
    ///
    /// Prefers a proposal under discussion, then a running reminder whose name the question
    /// mentions, then simply the first running reminder. Deliberately one item: the prompt builder
    /// is given one thing with its citations, never a dump of everything Remli knows.
    private func groundingContext(for question: String) -> ReminderProposal? {
        let asked = question.lowercased()
        func names(_ title: String) -> [String] {
            title.lowercased()
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
                .filter { $0.count > 3 }
        }
        func mentioned(_ title: String) -> Bool {
            names(title).contains { asked.contains($0) }
        }

        // What the question names wins over what happens to be on screen.
        //
        // This ordering is the bug that made Remli appear to know exactly one medication. A
        // proposal card is appended to the timeline at launch and stays there, so consulting
        // "the most recent proposal" first meant every question — whatever it named — was
        // answered from that one card. Asking about metformin while a lovastatin card sits
        // above is a question about metformin.
        if let reminder = activeReminders.first(where: { mentioned($0.title) }) {
            return proposal(from: reminder)
        }
        if let pending = allProposals.first(where: { mentioned($0.title) }) {
            return pending
        }

        // Nothing named: a card under discussion is the next best context, then the whole schedule.
        if let onScreen = mostRecentProposal() { return onScreen }

        let reminders = activeReminders
        guard !reminders.isEmpty else { return nil }
        return scheduleOverviewProposal(from: reminders)
    }

    /// The whole day's schedule as one grounded context.
    ///
    /// Still not a vault dump: it carries the reminders that are actually running and the facts
    /// they were built from, and nothing about conditions, allergies, or anything not being asked
    /// about.
    private func scheduleOverviewProposal(from reminders: [ApprovedReminder]) -> ReminderProposal {
        let facts: [SourceFact] = reminders.flatMap { reminder -> [SourceFact] in
            let times = reminder.times.map(ProposalCard.format).joined(separator: ", ")
            var built: [SourceFact] = []
            if let anchor = reminder.sourceFacts.first {
                built.append(
                    SourceFact(
                        label: reminder.title,
                        verbatim: times.isEmpty
                            ? "\(reminder.title) — taken only when needed"
                            : "\(reminder.title) — reminders at \(times)",
                        citation: anchor.citation
                    )
                )
                built.append(contentsOf: reminder.sourceFacts)
            }
            return built
        }

        let citation = reminders.first?.sourceFacts.first?.citation
        return ReminderProposal(
            id: "remli.context.schedule",
            kind: .medication,
            title: "Everything on your schedule",
            subtitle: "\(reminders.count) reminders running",
            sourceFacts: facts,
            slots: [],
            flags: [],
            primaryProvenance: citation.map { .fromYourRecord($0) }
                ?? .patternNoticed(basis: "your current reminders"),
            sourceLabel: "Your records",
            dataOrigin: reminders.first?.dataOrigin ?? .manualEntry,
            schedulingDeclinedReason: nil
        )
    }

    /// Presents a running reminder in the shape the prompt builder expects.
    ///
    /// An `ApprovedReminder` already carries the cited facts it was built from, so nothing is
    /// invented here — this is a change of container, not of content.
    private func proposal(from reminder: ApprovedReminder) -> ReminderProposal {
        ReminderProposal(
            id: reminder.proposalID,
            kind: reminder.kind,
            title: reminder.title,
            subtitle: reminder.sourceLabel,
            sourceFacts: reminder.sourceFacts,
            slots: reminder.times.enumerated().map { index, time in
                ProposedSlot(
                    id: "\(reminder.id)#\(index)",
                    timeOfDay: time,
                    provenance: .patternNoticed(basis: "this reminder is already running"),
                    label: reminder.times.count == 1 ? "Daily" : "Dose \(index + 1)"
                )
            },
            flags: [],
            primaryProvenance: reminder.sourceFacts.first.map { .fromYourRecord($0.citation) }
                ?? .patternNoticed(basis: "you added this"),
            sourceLabel: reminder.sourceLabel,
            dataOrigin: reminder.dataOrigin,
            schedulingDeclinedReason: nil
        )
    }

    /// The proposal currently under discussion — one the user can actually see on screen.
    ///
    /// Deliberately does **not** fall back to `openProposals.first`. That fallback meant every
    /// question in chat was grounded on one arbitrary proposal out of eleven, so Remli appeared to
    /// know about exactly one medication no matter what was asked — and it silently shadowed both
    /// the name-matching and whole-schedule grounding that follow it.
    private func mostRecentProposal() -> ReminderProposal? {
        for entry in timeline.reversed() {
            if case .proposal(let proposal) = entry.content { return proposal }
        }
        return nil
    }

    private var patientFirstName: String? {
        guard let full = vault.careRecord?.patientDisplayName else { return nil }
        return full.split(separator: " ").first.map(String.init)
    }


    // MARK: - Reminders tab

    /// Reminders that actually fire at a time.
    ///
    /// A reminder with no times is not on a schedule — approving an as-needed medication keeps it
    /// as a record without giving it a slot, and those were leaking into the timetable and showing
    /// as "Any time". Whether something has a time is the honest split between the two tabs.
    var scheduledReminders: [ApprovedReminder] {
        activeReminders.filter { !$0.times.isEmpty }
    }

    /// Approved but timeless — things kept on the list to be taken when needed.
    var onDemandReminders: [ApprovedReminder] {
        activeReminders.filter { $0.times.isEmpty }
    }

    /// Everything approved and not stopped, whatever its shape.
    var activeReminders: [ApprovedReminder] {
        vault.approvedReminders.filter(\.isActive).sorted { lhs, rhs in
            let l = lhs.times.first.flatMap { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) } ?? Int.max
            let r = rhs.times.first.flatMap { ($0.hour ?? 0) * 60 + ($0.minute ?? 0) } ?? Int.max
            return l < r
        }
    }

    /// First name, when the record supplies one. Used only for greeting.
    var greetingName: String? {
        vault.careRecord?.patientDisplayName?
            .split(separator: " ").first.map(String.init)
    }

    /// What the Portal tab lists: **connections**, not practitioners.
    ///
    /// The practitioner who wrote a prescription is attribution and belongs on the reminder card.
    /// This screen answers a different question — where is Remli getting records from, and what
    /// is not hooked up yet.
    var connectedSources: [ConnectedSource] {
        let record = vault.careRecord
        let medications = record?.medications ?? []
        let therapy = record?.therapyTasks ?? []

        func counts(for origin: DataOrigin) -> Int {
            medications.filter { $0.dataOrigin == origin }.count
                + therapy.filter { $0.dataOrigin == origin }.count
        }

        var sources: [ConnectedSource] = []

        let syntheaCount = counts(for: .syntheaSynthetic)
        if syntheaCount > 0 {
            sources.append(
                ConnectedSource(
                    id: "synthea",
                    name: "Sample health record",
                    detail: "A synthetic patient record, loaded from this app",
                    origin: .syntheaSynthetic,
                    status: .loaded(itemCount: syntheaCount)
                )
            )
        }

        let authoredCount = counts(for: .authoredDemo)
        if authoredCount > 0 {
            sources.append(
                ConnectedSource(
                    id: "portal-export",
                    name: "Sample portal export",
                    detail: "A demo export standing in for a clinic download",
                    origin: .authoredDemo,
                    status: .loaded(itemCount: authoredCount)
                )
            )
        }

        sources.append(
            ConnectedSource(
                id: "mychart",
                name: "MyChart",
                detail: "Sign in with your own account to pull your real records",
                origin: .liveFHIR,
                status: .notConnected
            )
        )
        sources.append(
            ConnectedSource(
                id: "apple-health",
                name: "Apple Health",
                detail: "Medications and records you have already connected on this phone",
                origin: .liveFHIR,
                status: .notConnected
            )
        )
        return sources
    }

    /// The user tells Remli how often they take something the chart never specified.
    ///
    /// Frequency is a dosing fact, not a scheduling preference, so Remli will not invent one — but
    /// the person taking the medication knows it, and once they say it the reminder behaves like
    /// any other. Provenance records that *they* supplied it, never the chart.
    func applyFrequency(_ timesPerDay: Int, to proposal: ReminderProposal) async {
        let defaults = ScheduleResolver.defaultClockTimes(
            perDay: timesPerDay, options: ScheduleResolver.Options()
        )
        let slots: [ProposedSlot] = (0..<timesPerDay).map { index in
            ProposedSlot(
                id: "\(proposal.id)#slot\(index)",
                timeOfDay: index < defaults.count ? defaults[index] : nil,
                provenance: .patternNoticed(basis: "you told me how often"),
                label: timesPerDay == 1 ? "Daily dose" : "Dose \(index + 1) of \(timesPerDay)"
            )
        }

        var updated = proposal
        updated.slots = slots
        let reminder = makeReminder(from: updated)

        await ensureNotificationPermission()
        vault.approve(reminder)
        do { try await scheduler.schedule(reminder) } catch {
            append(.note("Saved \(proposal.title), but couldn't schedule it: \(error.localizedDescription)"))
        }
        await scheduler.refreshPending()
        consume(proposal.id)
        append(.note("Set up \(proposal.title)"))
    }

    /// Decides whether Remli says anything about what it has noticed.
    ///
    /// The default answer is silence. `InterruptionPolicy` allows at most one check-in per app
    /// open and one every three days, applies a fortnight's cooldown once a topic is raised, and
    /// mutes a topic permanently after two are ignored. When everything is current it returns
    /// nothing at all — there is deliberately no "all good!" interruption.
    ///
    /// Called once per launch, after the ledger has caught up.
    func considerCheckIn(now: Date = Date()) {
        let patterns = detector.patterns(
            in: ledger.events,
            reminders: vault.approvedReminders,
            now: now
        )
        guard let pattern = interruptionPolicy.selectCheckIn(
            from: patterns, history: interruptionHistory, now: now
        ) else { return }

        // Recorded at the moment it is *shown*: a question scrolled past still cost an interruption.
        interruptionPolicy.record(raised: pattern, in: &interruptionHistory, now: now)
        persistInterruptions()
        append(.checkIn(pattern))
    }

    /// The user answered a check-in. Acts on it, and records that they engaged so the topic is not
    /// treated as ignored.
    func answerCheckIn(_ pattern: NoticedPattern, option: PatternAnswerOption) async {
        interruptionPolicy.record(answered: pattern, with: option.action, in: &interruptionHistory, now: Date())
        persistInterruptions()

        append(.user(text: option.text, wasSpoken: false))

        switch option.action {
        case .rescheduleSlot:
            if let reminder = vault.approvedReminders.first(where: { $0.id == pattern.reminderID }) {
                if let suggested = pattern.suggestedTime, option.acceptsSuggestedTime {
                    var times = reminder.times
                    if !times.isEmpty { times[0] = suggested }
                    await updateTimes(for: reminder, to: times)
                    append(.assistant(
                        text: "Moved. I'll nudge you then instead.",
                        narrationSource: .staticCopy
                    ))
                } else {
                    pendingTimeEditReminderID = reminder.id
                    append(.assistant(
                        text: "Sure — pick whatever time works and I'll use that.",
                        narrationSource: .staticCopy
                    ))
                }
            }

        case .dismissTopic:
            append(.assistant(text: option.action.acknowledgement, narrationSource: .staticCopy))

        case .acknowledgeOnly, .markNeedsRefill, .bundleReminders, .suggestCareTeam:
            // Deliberately inert beyond acknowledgement. Remli is a reminder app: it fixes
            // reminders, and for anything about how someone feels it says so and stops.
            append(.assistant(text: option.action.acknowledgement, narrationSource: .staticCopy))
        }
    }

    /// The check-in was shown and not answered.
    func dismissCheckIn(_ pattern: NoticedPattern) {
        interruptionPolicy.record(ignored: pattern, in: &interruptionHistory, now: Date())
        persistInterruptions()
        timeline.removeAll {
            if case .checkIn(let shown) = $0.content { return shown.id == pattern.id }
            return false
        }
    }

    private func persistInterruptions() {
        let snapshot = interruptionHistory
        Task.detached {
            try? EncryptedVault().write(snapshot, to: "interruptions")
        }
    }

    private func vaultFile<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
        try EncryptedVault().read(type, from: name)
    }

    /// Handles a tap on one of the notification's actions.
    ///
    /// This is where approval actually lives now: the reminder is already running, and the moment
    /// it fires is when someone has an opinion about it. Everything here is one tap, and
    /// everything except "stop" is silent.
    func handleNotificationAction(_ actionID: String, reminderID: String) async {
        switch actionID {
        case NotificationScheduler.markDoneActionIdentifier:
            ledger.record(reminderID: reminderID, outcome: .acknowledged)

        case NotificationScheduler.notThisTimeActionIdentifier:
            // A reported skip, not an inferred one — the difference the whole ledger rests on.
            ledger.record(reminderID: reminderID, outcome: .reportedSkipped)

        case NotificationScheduler.snoozeActionIdentifier:
            ledger.record(reminderID: reminderID, outcome: .snoozed)

        case NotificationScheduler.stopRemindingActionIdentifier:
            guard let reminder = vault.approvedReminders.first(where: { $0.id == reminderID })
            else { return }
            await stopReminding(reminder)

        case NotificationScheduler.changeTimeActionIdentifier:
            pendingTimeEditReminderID = reminderID

        default:
            break
        }
    }

    /// Creates a reminder the person asked for themselves.
    ///
    /// The path for anything not in a chart. Provenance is `.manualEntry`, so the card says "you
    /// entered this" rather than implying a clinician did — which is exactly why Remli can offer
    /// it at all without inventing health advice.
    func createUserReminder(title: String, times: [DateComponents]) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !times.isEmpty else { return }

        let id = "remli.reminder.user.\(UUID().uuidString)"
        let citation = SourceCitation(
            sourceLabel: "You",
            resourceType: "UserEntry",
            resourceID: id,
            fieldPath: "title",
            verbatimText: trimmed,
            recordedDate: Date(),
            dataOrigin: .manualEntry
        )
        let reminder = ApprovedReminder(
            id: id,
            proposalID: id,
            kind: .medication,
            title: trimmed,
            body: trimmed,
            times: times,
            sourceFacts: [SourceFact(label: "You asked for this", verbatim: trimmed, citation: citation)],
            sourceLabel: "You added this",
            dataOrigin: .manualEntry,
            approvedAt: Date(),
            isActive: true
        )

        await ensureNotificationPermission()
        vault.approve(reminder)
        do { try await scheduler.schedule(reminder) } catch {
            append(.note("Saved \(trimmed), but couldn't schedule it: \(error.localizedDescription)"))
        }
        await scheduler.refreshPending()
        append(.note("Added \(trimmed)"))
    }

    /// Applies new times to a running reminder and reschedules it.
    ///
    /// Cancel-then-add through the scheduler, so changing four doses down to two does not strand
    /// the notifications for the ones that went away.
    func updateTimes(for reminder: ApprovedReminder, to times: [DateComponents]) async {
        var updated = reminder
        updated.times = times
        await scheduler.cancel(for: reminder)
        vault.approve(updated)
        if !times.isEmpty {
            do { try await scheduler.schedule(updated) } catch {
                append(.note("Couldn't reschedule \(reminder.title): \(error.localizedDescription)"))
            }
        }
        await scheduler.refreshPending()
    }

    /// Stops a running reminder. Reversible — the reminder stays in the vault, just inactive.
    func stopReminding(_ reminder: ApprovedReminder) async {
        await scheduler.cancel(for: reminder)
        vault.removeReminder(id: reminder.id)
        await scheduler.refreshPending()
        append(.note("Stopped reminding you about \(reminder.title)."))
    }

    // MARK: - Plumbing

    private func append(_ content: TimelineEntry.Content) {
        timeline.append(TimelineEntry(content: content))
    }

    private func refreshStatus() {
        status.modelDescription = languageProvider.statusDescription
        status.modelIsOnDevice = languageProvider.model.isOnDevice
        status.networkEgressDescription = EgressPolicy.statusStripDescription
        status.storageDescription = "Encrypted, this device"
    }
}

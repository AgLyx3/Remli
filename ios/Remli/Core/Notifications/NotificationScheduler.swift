import Foundation
import UserNotifications

/// Everything that can stop an approved reminder from becoming a real alarm.
///
/// None of these cases carry a medication name, an exercise, or a source organization. They are
/// surfaced in Settings and in error copy, and error copy is one of the easiest places to leak PHI
/// by accident. A reminder is identified by its opaque id, never by what it is for.
enum NotificationSchedulingError: Error, LocalizedError, Equatable {
    /// The user has explicitly turned notifications off in Settings. Nothing to do but explain.
    case notAuthorized
    /// The reminder is archived/paused. Scheduling it would resurrect something the user turned off.
    case reminderInactive(reminderID: String)
    /// An approved reminder somehow has no times. The proposal engine should never emit this.
    case noTimes(reminderID: String)
    /// A time component lacks an hour or a minute, so it cannot describe a daily repeat.
    case incompleteTime(reminderID: String, index: Int)
    /// `UNUserNotificationCenter` refused the request.
    case systemRejected(reminderID: String, underlyingDescription: String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Notifications are turned off for Remli, so this reminder cannot be delivered."
        case .reminderInactive(let id):
            return "Reminder \(id) is paused and was not scheduled."
        case .noTimes(let id):
            return "Reminder \(id) has no approved times."
        case .incompleteTime(let id, let index):
            return "Time \(index + 1) of reminder \(id) has no hour or minute."
        case .systemRejected(let id, let underlying):
            return "The system declined to schedule reminder \(id): \(underlying)"
        }
    }
}

/// Turns approved reminders into local `UNNotificationRequest`s. Nothing else in the app may create
/// a notification.
///
/// # The invariant
///
/// **`ApprovedReminder` is the only input that can produce a notification.** There is deliberately
/// no `schedule(title:body:at:)` on this type. The design doc's rule is "every generated reminder
/// must be approved individually in v1", and an `ApprovedReminder` is by construction a proposal a
/// human looked at and accepted. Making it the sole parameter means the v1 approval rule is enforced
/// by the function signature rather than by everyone remembering it. If a future feature wants to
/// fire a notification, it must first produce an `ApprovedReminder`, which means it must first go
/// through review.
///
/// The one exception is `debugFireSoon(_:)`, which still takes an `ApprovedReminder` — it changes
/// *when* the alarm fires, never *whether* it was approved.
///
/// # Lock-screen discretion
///
/// See `content(for:)`. The short version: a lock screen is a public surface, so the notification
/// says the user has something to do without saying what condition they have.
///
/// # Idempotence
///
/// `schedule(_:)` is cancel-then-add. Re-approving an edited reminder, or replaying an import,
/// converges on exactly one pending request per approved time — never a duplicate, never an orphan
/// left over from a time the user deleted.
@MainActor
final class NotificationScheduler: ObservableObject {

    // MARK: - Identifiers the app layer responds to

    /// Category attached to every Remli reminder. Registering it is what makes the actions appear.
    static let categoryIdentifier = "remli.reminder"

    /// "Mark done" — the user took the medication or did the exercise.
    static let markDoneActionIdentifier = "remli.action.markDone"

    /// "Snooze 15 min" — ask again shortly.
    static let snoozeActionIdentifier = "remli.action.snooze15"

    /// "Not this time" — the user telling us the dose slipped.
    ///
    /// This action exists because the alternative is inference, and inference here is unsafe.
    /// Without it, a phone face-down in a bag is indistinguishable from a genuinely missed dose,
    /// and anything built on that ambiguity would end up telling people they missed medication we
    /// have no evidence they missed. A tapped "Not this time" is a fact the user reported. Silence
    /// remains what it is: silence.
    ///
    /// Deliberately worded without judgement. "Missed" and "Skipped" both read as a small
    /// accusation on a lock screen, and an accusation is a thing people stop tapping.
    static let notThisTimeActionIdentifier = "remli.action.notThisTime"

    /// "Change the time" — opens the app on this reminder's time editor.
    static let changeTimeActionIdentifier = "remli.action.changeTime"

    /// "Stop reminding me" — deactivates immediately, undoable in the app.
    ///
    /// Deliberately separate from "Not this time". They look similar and mean opposite things:
    /// one is *fix this*, the other is *end this*. Collapsing them would destroy the most
    /// actionable signal there is.
    static let stopRemindingActionIdentifier = "remli.action.stopReminding"

    /// How long `snoozeActionIdentifier` defers by. Named so the app layer and the UI copy cannot
    /// drift apart.
    static let snoozeInterval: TimeInterval = 15 * 60

    /// `userInfo` key carrying the `ApprovedReminder.id` so a tapped notification can open the right
    /// card. The payload is an opaque id on purpose — `userInfo` is written to disk by the system.
    static let reminderIDKey = "remli.reminderID"

    /// `userInfo` key carrying the index into `ApprovedReminder.times`.
    static let slotIndexKey = "remli.slotIndex"

    /// `userInfo` marker for `debugFireSoon(_:)` deliveries, so the demo path is distinguishable.
    static let demoKey = "remli.isDemo"

    // MARK: - Published state

    /// Identifiers currently pending with the system. Refreshed by `refreshPending()`; this is
    /// mirrored state, never the source of truth.
    @Published private(set) var pendingIdentifiers: Set<String> = []

    /// Count of pending requests as of the last refresh. Backs the "N reminders scheduled" line.
    @Published private(set) var pendingRequestCount: Int = 0

    @Published private(set) var lastRefreshedAt: Date?

    /// Most recent failure, already stripped of anything clinical. Shown in Settings so a silent
    /// scheduling failure becomes visible instead of the user simply never being reminded.
    @Published private(set) var lastFailureDescription: String?

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    // MARK: - Category registration

    /// Registers the reminder category. Call once at launch, before anything is scheduled.
    ///
    /// `hiddenPreviewsBodyPlaceholder` matters here: when the user's previews setting is
    /// "When Unlocked" (the default on Face ID devices), iOS replaces the body with this string on
    /// the lock screen. We supply a neutral one rather than accepting the system default so the
    /// hidden state reads as intentional calm rather than a redaction.
    func registerCategories() {
        let markDone = UNNotificationAction(
            identifier: Self.markDoneActionIdentifier,
            title: "Taken",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeActionIdentifier,
            title: "Remind me later",
            options: []
        )
        let stopReminding = UNNotificationAction(
            identifier: Self.stopRemindingActionIdentifier,
            title: "Stop reminding me",
            options: [.destructive]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            // Three, deliberately. iOS stacks these on long-press and past three or four
            // people stop reading them. "Not this time" and "Change the time" live in the app,
            // where there is room to distinguish "skip today" from "end this" without a
            // mis-tap costing someone their reminder.
            actions: [markDone, snooze, stopReminding],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "Remli has a message for you",
            options: [
                // Show the title even when previews are hidden. This is only safe because the title
                // is a fixed, non-clinical phrase — see `content(for:)`. Subtitle is deliberately
                // never populated, so there is nothing else that could surface.
                .hiddenPreviewsShowTitle
            ]
        )
        center.setNotificationCategories([category])
    }

    // MARK: - Scheduling

    /// Schedules one repeating daily notification per approved time.
    ///
    /// Cancel-then-add, so calling this twice for the same reminder leaves the same set of pending
    /// requests as calling it once. Identifiers come from `ApprovedReminder.notificationIdentifiers()`
    /// so the model owns the naming and this type cannot invent a scheme that drifts from it.
    func schedule(_ reminder: ApprovedReminder) async throws {
        guard reminder.isActive else {
            // Not an error the user caused, but scheduling a paused reminder would be a bug worth
            // hearing about. Cancel anything stale first so "paused" actually means silent.
            await cancel(for: reminder)
            throw NotificationSchedulingError.reminderInactive(reminderID: reminder.id)
        }
        guard !reminder.times.isEmpty else {
            throw NotificationSchedulingError.noTimes(reminderID: reminder.id)
        }

        let settings = await center.notificationSettings()
        guard settings.authorizationStatus != .denied else {
            let error = NotificationSchedulingError.notAuthorized
            lastFailureDescription = error.errorDescription
            throw error
        }

        // Remove first, including any request left behind by a *longer* previous version of this
        // reminder. `notificationIdentifiers()` is index-derived, so dropping a time from three to
        // two would otherwise strand `…reminder.<id>.2` forever.
        await cancel(for: reminder)

        let identifiers = reminder.notificationIdentifiers()
        for (index, time) in reminder.times.enumerated() {
            guard let hour = time.hour, let minute = time.minute else {
                throw NotificationSchedulingError.incompleteTime(reminderID: reminder.id, index: index)
            }

            // Rebuild the components from scratch. An approved time may carry a year or a day from
            // wherever it was constructed, and a repeating calendar trigger with a year in it fires
            // exactly once, silently, in a way nobody notices until the demo.
            var daily = DateComponents()
            daily.hour = hour
            daily.minute = minute

            let request = UNNotificationRequest(
                identifier: identifiers[index],
                content: content(for: reminder, slotIndex: index),
                trigger: UNCalendarNotificationTrigger(dateMatching: daily, repeats: true)
            )

            do {
                try await center.add(request)
            } catch {
                let failure = NotificationSchedulingError.systemRejected(
                    reminderID: reminder.id,
                    underlyingDescription: error.localizedDescription
                )
                lastFailureDescription = failure.errorDescription
                throw failure
            }
        }

        lastFailureDescription = nil
        await refreshPending()
    }

    /// Removes every pending request belonging to this reminder.
    ///
    /// Matches by identifier prefix as well as by the model's current identifiers, so a reminder
    /// that lost a time still gets fully cleaned up.
    func cancel(for reminder: ApprovedReminder) async {
        let prefix = Self.identifierPrefix(for: reminder.id)
        let pending = await center.pendingNotificationRequests()
        var doomed = Set(reminder.notificationIdentifiers())
        doomed.formUnion(pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        doomed.insert(Self.demoIdentifier(for: reminder.id))

        center.removePendingNotificationRequests(withIdentifiers: Array(doomed))
        // Also clear anything already sitting in Notification Center for this reminder, so
        // "I turned that off" does not leave a card on the lock screen.
        center.removeDeliveredNotifications(withIdentifiers: Array(doomed))
        await refreshPending()
    }

    /// Cancels every Remli notification. Used by "pause all reminders" and by the erase-everything
    /// flow, where leaving a scheduled alarm behind would outlive the vault it came from.
    func cancelAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        await refreshPending()
    }

    /// Number of pending requests according to the system, not according to our mirror.
    func pendingCount() async -> Int {
        await center.pendingNotificationRequests().count
    }

    /// Pulls published state back in line with `UNUserNotificationCenter`.
    ///
    /// The system is the source of truth: the user can clear notifications, iOS can drop requests
    /// past the 64-pending limit, and a restore can leave state behind. The status strip should
    /// report what is actually scheduled, not what we believe we scheduled.
    func refreshPending() async {
        let requests = await center.pendingNotificationRequests()
        pendingIdentifiers = Set(requests.map(\.identifier))
        pendingRequestCount = requests.count
        lastRefreshedAt = Date()
    }

    /// Pending identifiers belonging to one reminder. Lets a card say "scheduled" honestly.
    func pendingIdentifiers(for reminder: ApprovedReminder) -> [String] {
        let prefix = Self.identifierPrefix(for: reminder.id)
        return pendingIdentifiers.filter { $0.hasPrefix(prefix) }.sorted()
    }

    // MARK: - Demo affordance

    /// **Demo affordance.** Fires one non-repeating notification a few seconds from now.
    ///
    /// This exists for one reason: a live demo has to show a real iOS notification arriving, and the
    /// approved time is usually 8:00 PM. It is not part of the reminder lifecycle — it does not
    /// touch the repeating requests, it carries `demoKey` in `userInfo` so the app layer can label
    /// it, and it uses a separate identifier so `cancel(for:)` still cleans it up.
    ///
    /// It still takes an `ApprovedReminder`. Even the demo path cannot conjure an unapproved alarm.
    @discardableResult
    func debugFireSoon(_ reminder: ApprovedReminder, after seconds: TimeInterval = 10) async throws -> String {
        // Unique per send, rather than one identifier per reminder.
        //
        // A constant identifier meant each test *replaced* the previous request instead of adding
        // one, and only pending requests were cleared — a delivered notification stayed in
        // Notification Center and later sends collapsed onto it. The symptom was a test that
        // worked once or twice and then appeared to stop.
        let identifier = "\(Self.demoIdentifier(for: reminder.id)).\(Int(Date().timeIntervalSince1970))"

        // Clear earlier test sends, delivered as well as pending, so the tray does not accumulate
        // and nothing groups onto a stale banner.
        let stale = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.demoIdentifier(for: reminder.id)) }
        let delivered = await center.deliveredNotifications()
            .map(\.request.identifier)
            .filter { $0.hasPrefix(Self.demoIdentifier(for: reminder.id)) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        center.removeDeliveredNotifications(withIdentifiers: delivered)

        let demoContent = content(for: reminder, slotIndex: 0)
        demoContent.userInfo[Self.demoKey] = true
        // No thread grouping for a test send. Grouping is right for a twice-daily medication —
        // one stack rather than two banners — but it is what makes a repeated test look like it
        // stopped working, because the new banner collapses under the old one.
        demoContent.threadIdentifier = identifier

        let request = UNNotificationRequest(
            identifier: identifier,
            content: demoContent,
            // The system floors this at 1 second; 10 is comfortable for backgrounding the app first.
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        )

        let settings = await center.notificationSettings()
        DiagnosticLog.note(
            "demoFire: authorization=\(settings.authorizationStatus.rawValue) "
            + "alert=\(settings.alertSetting.rawValue) lockScreen=\(settings.lockScreenSetting.rawValue) "
            + "notificationCenter=\(settings.notificationCenterSetting.rawValue)"
        )

        do {
            try await center.add(request)
            let pending = await center.pendingNotificationRequests().count
            DiagnosticLog.note("demoFire: queued \(identifier) — pending now \(pending)")
        } catch {
            DiagnosticLog.note("demoFire: center.add THREW \(error.localizedDescription)")
            let failure = NotificationSchedulingError.systemRejected(
                reminderID: reminder.id,
                underlyingDescription: error.localizedDescription
            )
            lastFailureDescription = failure.errorDescription
            throw failure
        }

        await refreshPending()
        return identifier
    }

    // MARK: - Content

    /// What the notification says.
    ///
    /// ## Two audiences, one notification
    ///
    /// A lock screen is a public surface, and "Metformin 500 mg — Remli Demo Primary Care" announces
    /// a diagnosis and a care relationship to whoever is nearby, several times a day. But a
    /// notification that says nothing cannot be acted on without unlocking, which is most of its
    /// value gone.
    ///
    /// iOS resolves this rather than forcing a choice. With previews set to **When Unlocked** —
    /// the Face ID default — a stranger sees `hiddenPreviewsBodyPlaceholder` and the owner sees the
    /// real content the moment they look at it. So the content below is written for the owner, and
    /// the placeholder is written for the room.
    ///
    /// **The honest caveat:** if the user sets *Show Previews* to **Always**, the medication name
    /// will appear on a locked screen. That is their setting to make and we cannot override it —
    /// but it means this design leans on a system default rather than on a guarantee.
    ///
    /// - **Title** — the medication or exercise, so the notification answers "which one" without
    ///   being opened.
    /// - **Subtitle** — the time and where it came from.
    /// - **Body** — the record's own instruction, verbatim. Not a paraphrase: "with meals" is the
    ///   part most worth carrying, and it is exactly the part a summary would drop.
    private func content(for reminder: ApprovedReminder, slotIndex: Int) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminder.title

        let time = slotIndex < reminder.times.count
            ? Self.formatted(reminder.times[slotIndex])
            : nil
        content.subtitle = [time, reminder.sourceLabel]
            .compactMap { $0 }
            .joined(separator: " · ")

        // The record's own words where there are any, and a plain statement where there are not.
        // Never an invented instruction.
        if let instruction = reminder.sourceFacts.first(where: {
            $0.label.lowercased().contains("instruction")
        })?.verbatim {
            content.body = "Your record says: \(instruction)"
        } else {
            content.body = Self.discreetBody(for: reminder.kind)
        }

        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        // Groups a twice-daily medication's two alarms into one stack rather than two.
        content.threadIdentifier = reminder.id
        // `.timeSensitive` would break through Focus, which a medication reminder arguably deserves,
        // but it requires the `com.apple.developer.usernotifications.time-sensitive` entitlement.
        // v1 stays at `.active` rather than shipping an entitlement the demo build cannot sign.
        content.interruptionLevel = .active
        content.userInfo = [
            Self.reminderIDKey: reminder.id,
            Self.slotIndexKey: slotIndex,
        ]
        return content
    }

    /// The one sentence that appears on the lock screen.
    /// What a bystander could read.
    ///
    /// A lock screen is a public surface, so the body names nothing — not the medication, not the
    /// clinic, not even the category. Anyone glancing at the phone learns only that this person
    /// uses Remli.
    ///
    /// The detail is not lost, it is *gated*: with iOS previews set to "When Unlocked" (the Face ID
    /// default) the placeholder shows to a stranger and the real body appears the moment the owner
    /// looks at it. So the same notification is discreet in a waiting room and useful in a kitchen,
    /// without us having to choose one.
    static func formatted(_ components: DateComponents) -> String? {
        guard let hour = components.hour, let minute = components.minute,
              let date = Calendar.current.date(
                from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)
              ) else { return nil }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func discreetBody(for kind: ReminderKind) -> String {
        // Deliberately identical for every kind. A body that varied by category would still leak
        // something, and the `kind` parameter is kept so the signature cannot quietly grow into
        // one that accepts a medication name.
        _ = kind
        return "It's time for one of your reminders. Tap to see it."
    }

    // MARK: - Identifiers

    /// Mirrors `ApprovedReminder.notificationIdentifiers()`, which builds
    /// `remli.reminder.<id>.<index>`. Kept as a prefix so cancellation can sweep indices this
    /// reminder no longer has.
    private static func identifierPrefix(for reminderID: String) -> String {
        "remli.reminder.\(reminderID)."
    }

    private static func demoIdentifier(for reminderID: String) -> String {
        "remli.demo.\(reminderID)"
    }
}

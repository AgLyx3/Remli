import SwiftUI

/// Renders one entry in the flowing timeline.
///
/// The design doc explicitly rejects "support-chat bubbles as the only structure". So assistant
/// prose is set as unadorned text in the page's own voice, and only *reviewable objects* —
/// proposals, recaps, confirmations — get card treatment. The visual weight tracks how much the
/// user is being asked to do, not who is speaking.
struct TimelineEntryView: View {
    let entry: TimelineEntry
    var onApprove: (ReminderProposal) -> Void = { _ in }
    var onEdit: (ReminderProposal) -> Void = { _ in }
    var onSkip: (ReminderProposal) -> Void = { _ in }
    var onSpeak: (String) -> Void = { _ in }
    var onAnswerCheckIn: (NoticedPattern, PatternAnswerOption) -> Void = { _, _ in }
    var onDismissCheckIn: (NoticedPattern) -> Void = { _ in }

    var body: some View {
        switch entry.content {
        case .assistant(let text, let source):
            AssistantTurn(text: text, source: source, timestamp: entry.timestamp, onSpeak: onSpeak)

        case .user(let text, let wasSpoken):
            UserTurn(text: text, wasSpoken: wasSpoken)

        case .heard(let summary, let detail):
            HeardCard(summary: summary, detail: detail)

        case .proposal(let proposal):
            ProposalCard(
                proposal: proposal,
                onApprove: onApprove,
                onEdit: onEdit,
                onSkip: onSkip
            )

        case .scheduled(let reminder):
            ScheduledCard(reminder: reminder)

        case .note(let text):
            NoteRow(text: text)

        case .checkIn(let pattern):
            CheckInCard(
                pattern: pattern,
                onAnswer: { onAnswerCheckIn(pattern, $0) },
                onDismiss: { onDismissCheckIn(pattern) }
            )
        }
    }
}

// MARK: - Assistant

private struct AssistantTurn: View {
    let text: String
    let source: NarrationSource
    let timestamp: Date
    var onSpeak: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(RemliTheme.Typeface.bodyLarge())
                .foregroundStyle(RemliTheme.Palette.onSurface)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                // Naming who wrote the sentence keeps the demo honest about when Gemma is
                // actually running versus when the scripted fallback is speaking.
                if let badge = source.badge {
                    HStack(spacing: 4) {
                        Image(systemName: source == .gemmaOnDevice ? "cpu" : "text.alignleft")
                            .font(.system(size: 8))
                        Text(badge)
                    }
                    .font(RemliTheme.Typeface.labelSmall())
                    .foregroundStyle(
                        source == .gemmaOnDevice
                            ? RemliTheme.Palette.primary
                            : RemliTheme.Palette.onSurfaceMuted
                    )
                }

                Button {
                    onSpeak(text)
                } label: {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 10))
                        .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Read this aloud")

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - User

private struct UserTurn: View {
    let text: String
    let wasSpoken: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(RemliTheme.Palette.tertiary.opacity(0.35))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(RemliTheme.Typeface.bodyLarge())
                    .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                if wasSpoken {
                    Label("Transcribed on this device", systemImage: "waveform")
                        .font(RemliTheme.Typeface.labelSmall())
                        .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
                }
            }
        }
        .padding(.leading, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - "I heard"

/// The periodic recap the design doc asks for. Its job is to let someone correct Remli's
/// understanding *before* that understanding turns into a reminder.
private struct HeardCard: View {
    let summary: String
    let detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("I HEARD")
                    .font(RemliTheme.Typeface.labelSmall())
                    .kerning(0.8)
                    .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)

                Text(summary)
                    .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
                    .foregroundStyle(RemliTheme.Palette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(detail)
                        .font(RemliTheme.Typeface.bodyMedium())
                        .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RemliTheme.Palette.surfaceLow, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(RemliTheme.Palette.primary.opacity(0.5))
                .frame(width: 3)
                .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }
}

// MARK: - Scheduled confirmation

private struct ScheduledCard: View {
    let reminder: ApprovedReminder

    private var timeList: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        let times = reminder.times.compactMap { components -> String? in
            guard let hour = components.hour, let minute = components.minute,
                  let date = Calendar.current.date(
                    from: DateComponents(year: 2000, month: 1, day: 1, hour: hour, minute: minute)
                  ) else { return nil }
            return formatter.string(from: date)
        }
        return times.joined(separator: " and ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(RemliTheme.Palette.primary)

            VStack(alignment: .leading, spacing: 3) {
                Text(reminder.title)
                    .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
                    .foregroundStyle(RemliTheme.Palette.onSurface)

                Text(timeList.isEmpty
                     ? "Saved to your list."
                     : "Reminding you at \(timeList), on this phone.")
                    .font(RemliTheme.Typeface.bodyMedium())
                    .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RemliTheme.Palette.secondaryContainer, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Note

private struct NoteRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(RemliTheme.Palette.hairline)
                .frame(height: 1)
            Text(text)
                .font(RemliTheme.Typeface.labelSmall())
                .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
                .layoutPriority(1)
            Rectangle()
                .fill(RemliTheme.Palette.hairline)
                .frame(height: 1)
        }
        .padding(.vertical, 4)
    }
}


/// Remli asking about something it noticed.
///
/// A question, never a correction. The wording throughout describes *Remli's* uncertainty rather
/// than the person's behaviour — "this hasn't been coming back to me as done" instead of "you
/// missed three doses" — because we genuinely cannot tell the difference from here, and pretending
/// otherwise is both untrue and the fastest way to make someone stop answering.
private struct CheckInCard: View {
    /// Weaves a concrete time into an answer when there is one, so the option reads "Yes, move it
    /// to 9:30." rather than the generic "Yes, move it later." Options that opt out keep their
    /// open wording — someone asking for a different time has just told us our guess was wrong.
    static func label(for option: PatternAnswerOption, suggestedTime: DateComponents?) -> String {
        guard option.acceptsSuggestedTime,
              let template = option.timeTemplate,
              let time = suggestedTime,
              let formatted = ScheduleProposer.format(time) else { return option.text }
        return String(format: template, formatted)
    }

    let pattern: NoticedPattern
    var onAnswer: (PatternAnswerOption) -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RemliTheme.Metric.sm) {
            HStack(spacing: RemliTheme.Metric.xs) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.system(size: 13))
                    .foregroundStyle(RemliTheme.Palette.tertiary)
                Text("SOMETHING I NOTICED")
                    .font(RemliTheme.Typeface.labelSmall())
                    .kerning(0.7)
                    .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
                Spacer(minLength: 0)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not now")
            }

            Text(pattern.question)
                .font(RemliTheme.Typeface.bodyLarge())
                .foregroundStyle(RemliTheme.Palette.onSurface)
                .fixedSize(horizontal: false, vertical: true)

            // What Remli actually observed, stated as a fact about its own inbox.
            Text(pattern.basis)
                .font(RemliTheme.Typeface.labelMedium())
                .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)

            VStack(spacing: RemliTheme.Metric.xs) {
                ForEach(pattern.answerOptions()) { option in
                    Button {
                        onAnswer(option)
                    } label: {
                        HStack {
                            Text(Self.label(for: option, suggestedTime: pattern.suggestedTime))
                                .font(RemliTheme.Typeface.bodyMedium())
                                .foregroundStyle(RemliTheme.Palette.onSurface)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(RemliTheme.Metric.sm)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RemliTheme.Palette.surfaceLow,
                            in: RoundedRectangle(cornerRadius: RemliTheme.Metric.radius)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(RemliTheme.Metric.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .remliCard()
    }
}

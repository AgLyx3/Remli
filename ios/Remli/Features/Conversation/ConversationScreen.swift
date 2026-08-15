import SwiftUI

/// The single screen.
///
/// A flowing timeline rather than a chat transcript: assistant turns, recaps, reviewable proposal
/// cards, and confirmations all share one vertical thread, with visual weight tracking how much
/// the reader is being asked to do rather than who is speaking.
struct ConversationScreen: View {
    @EnvironmentObject private var session: RemliSession
    @State private var showPrivacySheet = false
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            RemliHeader(status: session.ledger.status) { showPrivacySheet = true }

            timeline

            Composer(
                text: $session.composerText,
                isFocused: $isComposerFocused,
                onSend: { text in Task { await session.send(text) } },
                onQuickAction: { action in Task { await session.runQuickAction(action) } }
            )
        }
        .background(RemliTheme.Palette.background.ignoresSafeArea())
        .sheet(isPresented: $showPrivacySheet) {
            PrivacySheet(status: session.status, provider: session.languageProvider, narrationError: session.lastNarrationError)
        }
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RemliTheme.Metric.md + 4) {
                    ForEach(session.timeline) { entry in
                        TimelineEntryView(
                            entry: entry,
                            onApprove: { proposal in Task { await session.approve(proposal) } },
                            onEdit: { proposal in Task { await session.edit(proposal) } },
                            onSkip: { proposal in Task { await session.skip(proposal) } },
                            onSpeak: { text in session.speak(text) },
                            onAnswerCheckIn: { pattern, option in
                                Task { await session.answerCheckIn(pattern, option: option) }
                            },
                            onDismissCheckIn: { pattern in session.dismissCheckIn(pattern) }
                        )
                        .id(entry.id)
                    }

                    if session.isImporting || session.isNarrating {
                        ThinkingRow(
                            label: session.isImporting
                                ? "Reading your records on this device…"
                                : "Composing…"
                        )
                        .id("thinking")
                    }

                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.horizontal, RemliTheme.Metric.containerMargin)
                .padding(.top, 4)
            }
            // Tapping the conversation puts the keyboard away, and dragging it does too — the
            // usual two ways people expect to get a keyboard off the screen.
            .scrollDismissesKeyboard(.interactively)
            .contentShape(Rectangle())
            .onTapGesture { isComposerFocused = false }
            .onChange(of: session.timeline.count) { _, _ in
                withAnimation(.easeOut(duration: 0.28)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

/// A quiet activity indicator. Deliberately not a spinner — this app should never look busy.
private struct ThinkingRow: View {
    let label: String
    @State private var isDim = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(RemliTheme.Palette.primary)
                .frame(width: 6, height: 6)
                .opacity(isDim ? 0.25 : 1)
                .animation(
                    .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: isDim
                )

            Text(label)
                .font(RemliTheme.Typeface.labelSmall())
                .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
        }
        .onAppear { isDim = true }
    }
}

/// What the header's "On device" pill opens.
///
/// The point of this sheet is that every claim on it is derived from live state — including the
/// unflattering ones. If Gemma is not actually running, this is where it says so.
struct PrivacySheet: View {
    let status: SessionStatus
    @ObservedObject var provider: LanguageModelProvider
    var narrationError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RemliTheme.Metric.md) {
                    claim(
                        icon: "lock.doc",
                        title: "Your records are encrypted here",
                        detail: "Stored on this phone with a key held in the device keychain. "
                              + "The key never syncs to iCloud and never leaves this device, so "
                              + "the records cannot be restored or read anywhere else."
                    )

                    claim(
                        icon: "network.slash",
                        title: status.networkEgressDescription,
                        detail: EgressPolicy.auditSummary
                    )

                    claim(
                        icon: provider.model.isOnDevice ? "cpu" : "text.alignleft",
                        title: provider.statusDescription,
                        detail: provider.model.availabilityNote
                            ?? "The language model runs on this phone. Your health details are "
                             + "never sent to a server to be summarised."
                    )

                    ModelManagementSection(manager: provider.modelManager)

                    claim(
                        icon: "checkmark.shield",
                        title: "Nothing is scheduled without you",
                        detail: "Every reminder is reviewed and approved one at a time. Remli "
                              + "will not invent a dose, a time, or an instruction that is not in "
                              + "your record."
                    )

                    claim(
                        icon: "cross.case",
                        title: "Remli is not medical advice",
                        detail: "Check with your doctor or pharmacist before starting, stopping, "
                              + "or changing any medication, therapy, diet, or care plan."
                    )

                    if let failure = narrationError {
                        claim(
                            icon: "exclamationmark.triangle",
                            title: "Last reply used fixed wording",
                            detail: "The model was asked but could not answer, so Remli used its "
                                  + "own wording instead. Reason: \(failure)"
                        )
                    }

                    if !provider.safetyEvents.isEmpty {
                        safetySection
                    }

                    SupportSection()
                }
                .padding(RemliTheme.Metric.containerMargin)
            }
            .background(RemliTheme.Palette.background)
            .navigationTitle("Privacy & Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// Surfacing SafetyGuard interventions rather than hiding them. If the model said something
    /// unsafe and was overridden, that is worth being able to see.
    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAFETY INTERVENTIONS")
                .font(RemliTheme.Typeface.labelSmall())
                .kerning(0.6)
                .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)

            Text("\(provider.safetyEvents.count) time(s) this session, Remli replaced the model's "
                 + "wording with fixed text because it did not meet the safety rules. No health "
                 + "details are recorded here.")
                .font(RemliTheme.Typeface.bodyMedium())
                .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RemliTheme.Palette.concernContainer, in: RoundedRectangle(cornerRadius: 12))
    }

    private func claim(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(RemliTheme.Palette.primary)
                .frame(width: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
                    .foregroundStyle(RemliTheme.Palette.onSurface)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(RemliTheme.Typeface.bodyMedium())
                    .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RemliTheme.Palette.surface, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct ModelManagementSection: View {
    @ObservedObject var manager: GemmaModelManager
    @State private var confirmDownload = false
    @State private var confirmDelete = false
    @State private var operationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RemliTheme.Metric.sm) {
            Label("On-device model", systemImage: "cpu")
                .font(RemliTheme.Typeface.bodyMedium().weight(.semibold))
                .foregroundStyle(RemliTheme.Palette.onSurface)

            Text(manager.availability.statusDescription)
                .font(RemliTheme.Typeface.bodyMedium())
                .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)

            controls
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RemliTheme.Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        .confirmationDialog(
            "Download Gemma?",
            isPresented: $confirmDownload,
            titleVisibility: .visible
        ) {
            Button("Download over Wi-Fi") { manager.startDownload() }
        } message: {
            Text("The model is about 2.58 GB. Remli downloads it over Wi-Fi and stores it only on this device.")
        }
        .confirmationDialog(
            "Remove Gemma from this phone?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Remove model", role: .destructive, action: removeModel)
        } message: {
            Text("Remli will use scripted narration until you download the model again.")
        }
        .alert(
            "Could not remove model",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { operationError = nil }
        } message: {
            Text(operationError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch manager.availability {
        case .absent, .failed:
            Button { confirmDownload = true } label: {
                Label("Download 2.58 GB", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(RemliTheme.Palette.primary)

        case .downloading(let progress):
            if progress >= 0 {
                ProgressView(value: progress)
                    .tint(RemliTheme.Palette.primary)
                    .accessibilityLabel("Model download progress")
                    .accessibilityValue("\(Int(progress * 100)) percent")
            } else {
                ProgressView()
                    .tint(RemliTheme.Palette.primary)
                    .accessibilityLabel("Downloading model")
            }

            Button { manager.pauseDownload() } label: {
                Label("Pause download", systemImage: "pause")
            }
            .buttonStyle(.bordered)

        case .ready:
            Button(role: .destructive) { confirmDelete = true } label: {
                Label("Remove model", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
    }

    private func removeModel() {
        do {
            try manager.deleteModel()
        } catch {
            operationError = error.localizedDescription
        }
    }
}

private struct SupportSection: View {
    private let supportURL = URL(string: "https://github.com/AgLyx3/Remli/issues")!

    var body: some View {
        Link(destination: supportURL) {
            HStack(spacing: RemliTheme.Metric.sm) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(RemliTheme.Palette.primary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Contact support")
                        .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
                        .foregroundStyle(RemliTheme.Palette.onSurface)
                    Text("Report a problem or ask a question")
                        .font(RemliTheme.Typeface.bodyMedium())
                        .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(RemliTheme.Palette.primary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RemliTheme.Palette.surface, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}

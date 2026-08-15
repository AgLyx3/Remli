import SwiftUI

/// The Portal tab — where health records come from.
///
/// The mockup this is based on showed MyChart and Apple Health as live, syncing connections. This
/// version shows what is actually true: sample records, loaded locally, with the real connectors
/// marked as not yet built. Overstating a connection here would undercut the one thing the app is
/// asking to be trusted about.
struct PortalScreen: View {
    @EnvironmentObject private var session: RemliSession
    @State private var showStatus = false

    var body: some View {
        VStack(spacing: 0) {
            RemliHeader(status: session.ledger.status) { showStatus = true }

            ScrollView {
                VStack(alignment: .leading, spacing: RemliTheme.Metric.md) {
                    greeting

                    ForEach(session.connectedSources) { source in
                        SourceCard(source: source)
                    }

                    addPlaceholder
                    privacyNote
                    scopeNote
                }
                .padding(.horizontal, RemliTheme.Metric.containerMargin)
                .padding(.top, RemliTheme.Metric.md)
                .padding(.bottom, RemliTheme.Metric.xl)
            }
        }
        .background(RemliTheme.Palette.background.ignoresSafeArea())
        .sheet(isPresented: $showStatus) {
            PrivacySheet(status: session.status, provider: session.languageProvider, narrationError: session.lastNarrationError)
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.greetingName.map { "Hello, \($0)" } ?? "Your records")
                .font(RemliTheme.Typeface.headlineMedium())
                .foregroundStyle(RemliTheme.Palette.onSurface)
            Text("Everything here lives on this phone. Nothing is uploaded.")
                .font(RemliTheme.Typeface.bodyMedium())
                .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, RemliTheme.Metric.xs)
    }

    private var addPlaceholder: some View {
        VStack(spacing: RemliTheme.Metric.xs) {
            Image(systemName: "plus.circle")
                .font(.system(size: 22))
                .foregroundStyle(RemliTheme.Palette.outline)
            Text("Connect a provider")
                .font(RemliTheme.Typeface.bodyMedium().weight(.medium))
                .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
            Text("Sign-in through MyChart is coming — it isn't built yet.")
                .font(RemliTheme.Typeface.labelMedium())
                .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(RemliTheme.Metric.lg)
        .background(
            RoundedRectangle(cornerRadius: RemliTheme.Metric.radiusLarge)
                .stroke(
                    RemliTheme.Palette.outlineVariant,
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        )
    }

    private var privacyNote: some View {
        InfoTile(
            icon: "lock.shield",
            title: "Your records stay on this phone",
            message: "They're encrypted here with a key that never leaves this device — so they can't "
                + "be read anywhere else, even from a backup.",
            tint: RemliTheme.Palette.primary,
            background: RemliTheme.Palette.secondaryContainer.opacity(0.4)
        )
    }

    private var scopeNote: some View {
        InfoTile(
            icon: "info.circle",
            title: "What I do and don't do",
            message: "I turn what's already written in your records into reminders, and I show you "
                + "where each one came from. I don't provide medical advice. Check with your doctor "
                + "or pharmacist before starting, stopping, or changing medication, therapy, diet, "
                + "or any care plan.",
            tint: RemliTheme.Palette.tertiary,
            background: RemliTheme.Palette.tertiaryContainer.opacity(0.35)
        )
    }
}

/// One connected — or not yet connected — health source.
struct ConnectedSource: Identifiable, Hashable {
    enum Status: Hashable {
        case loaded(itemCount: Int)
        case notConnected
    }

    let id: String
    let name: String
    let detail: String
    let origin: DataOrigin
    let status: Status
}

private struct SourceCard: View {
    let source: ConnectedSource

    private var statusLabel: String {
        switch source.status {
        case .loaded(let count): return count == 1 ? "1 item" : "\(count) items"
        case .notConnected: return "Not connected"
        }
    }

    private var isLoaded: Bool {
        if case .loaded = source.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RemliTheme.Metric.xs) {
            HStack(spacing: RemliTheme.Metric.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: RemliTheme.Metric.radius)
                        .fill(RemliTheme.Palette.surfaceLow)
                        .frame(width: 32, height: 32)
                    Image(systemName: isLoaded ? "doc.text" : "link")
                        .font(.system(size: 14))
                        .foregroundStyle(RemliTheme.Palette.primary)
                }

                Text(source.name)
                    .font(RemliTheme.Typeface.titleLarge())
                    .foregroundStyle(RemliTheme.Palette.onSurface)
                    .lineLimit(1)

                Spacer(minLength: RemliTheme.Metric.xs)

                Text(statusLabel)
                    .font(RemliTheme.Typeface.labelSmall())
                    .foregroundStyle(isLoaded
                                     ? RemliTheme.Palette.onSecondaryContainer
                                     : RemliTheme.Palette.onSurfaceMuted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        isLoaded
                            ? RemliTheme.Palette.secondaryContainer
                            : RemliTheme.Palette.surfaceContainer,
                        in: Capsule()
                    )
            }

            VStack(alignment: .leading, spacing: RemliTheme.Metric.xs) {
                Text(source.detail)
                    .font(RemliTheme.Typeface.bodyMedium())
                    .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)

                // Provenance sits on the source itself, so synthetic records can never be mistaken
                // for a real chart pull. Nothing is loaded from an unconnected source, so it gets
                // no origin tag — claiming one would be describing data that isn't there.
                if isLoaded {
                    Text(source.origin.shortLabel)
                        .font(RemliTheme.Typeface.labelSmall())
                        .foregroundStyle(RemliTheme.Palette.onSurfaceMuted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RemliTheme.Palette.surfaceLow, in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 44)
        }
        .padding(RemliTheme.Metric.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .remliCard()
    }
}

struct InfoTile: View {
    let icon: String
    let title: String
    let message: String
    let tint: Color
    let background: Color

    var body: some View {
        HStack(alignment: .top, spacing: RemliTheme.Metric.sm) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(tint)
                .frame(width: 20)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(RemliTheme.Typeface.bodyMedium().weight(.semibold))
                    .foregroundStyle(RemliTheme.Palette.onSurface)
                Text(message)
                    .font(RemliTheme.Typeface.bodyMedium())
                    .foregroundStyle(RemliTheme.Palette.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(RemliTheme.Metric.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: RemliTheme.Metric.radiusMedium))
    }
}

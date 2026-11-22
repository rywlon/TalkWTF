import SwiftUI

/// First-run setup: the two permissions dictation needs, explained in order.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var microphone = Permissions.microphoneGranted
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            pageHeader(
                L("onboarding.permissions.title"),
                subtitle: L("onboarding.permissions.description")
            )

            stepIndicator()

            VStack(spacing: Theme.Spacing.row) {
                permissionCard(
                    symbol: "mic.fill",
                    title: L("onboarding.permissions.microphone.title"),
                    detail: L("onboarding.permissions.microphone.description"),
                    granted: microphone,
                    action: {
                        Permissions.requestMicrophone { granted in microphone = granted }
                    }
                )

                permissionCard(
                    symbol: "hand.raised.fill",
                    title: L("onboarding.permissions.accessibility.title"),
                    detail: L("onboarding.permissions.accessibility.description"),
                    granted: accessibility,
                    action: {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                )
            }

            HStack {
                if microphone && accessibility {
                    Label(L("onboarding.permissions.allGranted"), systemImage: "checkmark.seal.fill")
                        .font(Theme.Fonts.callout)
                        .foregroundStyle(.green)
                }
                Spacer()
                Button(microphone ? L("common.close") : "稍后设置，先看看") { onFinish() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(width: 560)
        .onAppear {
            // The Accessibility grant happens outside the app, so poll for it.
            timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                microphone = Permissions.microphoneGranted
                accessibility = Permissions.accessibilityGranted
            }
        }
        .onDisappear { timer?.invalidate() }
    }

    // MARK: - step indicator

    private func stepIndicator() -> some View {
        HStack(spacing: 8) {
            stepPill(
                number: 1,
                title: L("onboarding.permissions.microphone.title"),
                done: microphone,
                active: !microphone
            )
            stepPill(
                number: 2,
                title: L("onboarding.permissions.accessibility.title"),
                done: accessibility,
                active: microphone && !accessibility
            )
        }
    }

    private func stepPill(number: Int, title: String, done: Bool, active: Bool) -> some View {
        HStack(spacing: 6) {
            Group {
                if done {
                    Image(systemName: "checkmark")
                } else {
                    Text("\(number)")
                }
            }
            .font(.system(size: 10, weight: .bold))
            .frame(width: 14, height: 14)
            .background(
                Circle().fill(done || active ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(done || active ? Color.white : Color.secondary)

            Text(title).font(Theme.Fonts.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(done || active ? Theme.Colors.selectionAccent : Theme.Colors.cardFill)
        )
        .foregroundStyle(done || active ? Color.accentColor : Color.secondary)
    }

    // MARK: - permission card

    private func permissionCard(
        symbol: String,
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(
                    Theme.Colors.selectionAccent,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Fonts.headline)
                Text(detail).font(Theme.Fonts.callout).foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if granted {
                Label(L("onboarding.permissions.granted"), systemImage: "checkmark.circle.fill")
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(L("onboarding.permissions.grant"), action: action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}

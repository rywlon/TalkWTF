import SwiftUI

/// First-run setup: the two permissions dictation needs, explained in order.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var microphone = Permissions.microphoneGranted
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SETUP  ·  TALKWTF")
                .font(Theme.Fonts.mono(10.5, weight: .semibold))
                .tracking(2.4)
                .foregroundStyle(Theme.Colors.inkTertiary)

            Text(L("onboarding.permissions.title"))
                .font(.system(size: 30, weight: .semibold))
                .tracking(-0.7)
                .foregroundStyle(Theme.Colors.ink)
                .padding(.top, 12)

            Text(L("onboarding.permissions.description"))
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Colors.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            stepRow.padding(.top, 26)

            VStack(spacing: 10) {
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
            .padding(.top, 16)

            HStack(spacing: 10) {
                if microphone && accessibility {
                    Label(L("onboarding.permissions.allGranted"), systemImage: "checkmark")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.ok)
                } else {
                    Text("\(microphone ? 1 : 0) / 2")
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.inkTertiary)
                }
                Spacer(minLength: 16)
                if !(microphone && accessibility) {
                    StudioButton(title: L("onboarding.permissions.later"), kind: .ghost, height: 32) { onFinish() }
                }
                StudioButton(
                    title: microphone && accessibility
                        ? L("onboarding.permissions.start")
                        : L("onboarding.permissions.grant"),
                    kind: .accent,
                    height: 32
                ) {
                    if microphone && accessibility {
                        onFinish()
                    } else if !microphone {
                        Permissions.requestMicrophone { granted in microphone = granted }
                    } else {
                        Permissions.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
            }
            .padding(.top, 26)
        }
        .padding(36)
        .frame(width: 620)
        .background(Theme.Colors.canvas)
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

    private var stepRow: some View {
        HStack(alignment: .bottom, spacing: 26) {
            step(
                number: "01",
                title: L("onboarding.permissions.microphone.title"),
                done: microphone,
                active: !microphone
            )
            step(
                number: "02",
                title: L("onboarding.permissions.accessibility.title"),
                done: accessibility,
                active: microphone && !accessibility
            )
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Hairline() }
    }

    private func step(number: String, title: String, done: Bool, active: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Text(number)
                    .font(Theme.Fonts.mono(10.5, weight: .semibold))
                    .foregroundStyle(active || done ? Theme.Colors.accent : Theme.Colors.inkTertiary)
                Text(title)
                    .font(.system(size: 12.5, weight: active ? .semibold : .regular))
                    .foregroundStyle(active || done ? Theme.Colors.ink : Theme.Colors.inkSecondary)
                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.Colors.ok)
                }
            }
            .fixedSize()
            Rectangle()
                .fill(active || done ? Theme.Colors.accent : .clear)
                .frame(height: 2)
        }
    }

    // MARK: - permission card

    private func permissionCard(
        symbol: String,
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.Colors.accent)
                .frame(width: 36, height: 36)
                .overlay(Rectangle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.ink)
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if granted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                    Text(L("onboarding.permissions.granted"))
                        .font(Theme.Fonts.mono(10.5))
                }
                .foregroundStyle(Theme.Colors.ok)
            } else {
                StudioButton(title: L("onboarding.permissions.grant"), kind: .accent, height: 30) {
                    action()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface)
        .overlay(Rectangle().strokeBorder(Theme.Colors.hairline, lineWidth: 1))
    }
}

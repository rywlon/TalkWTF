import SwiftUI

/// First-run setup: the two permissions dictation needs, explained in order.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var microphone = Permissions.microphoneGranted
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "waveform").font(.system(size: 40)).foregroundStyle(.tint)
                Text(L("onboarding.permissions.title")).font(.largeTitle.bold())
                Text(L("onboarding.permissions.description"))
                    .foregroundStyle(.secondary)
            }

            permissionRow(
                title: L("onboarding.permissions.microphone.title"),
                detail: L("onboarding.permissions.microphone.description"),
                granted: microphone,
                action: {
                    Permissions.requestMicrophone { granted in microphone = granted }
                }
            )

            permissionRow(
                title: L("onboarding.permissions.accessibility.title"),
                detail: L("onboarding.permissions.accessibility.description"),
                granted: accessibility,
                action: {
                    Permissions.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            )

            HStack {
                Spacer()
                Button(L("common.close")) { onFinish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!microphone)
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

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(L("onboarding.permissions.grant"), action: action)
            }
        }
    }
}

import SwiftUI

/// One place to surface the "a dictation is in progress" message.
///
/// Commands that would fight an in-flight dictation are refused by the core with
/// a `busy:` error; any view can hand that error here instead of inventing its
/// own wording.
@MainActor
final class BusyAlert: ObservableObject {
    static let shared = BusyAlert()

    @Published var isPresented = false

    /// Show the alert when `error` is the core's busy refusal.
    /// Returns `true` when it was handled.
    @discardableResult
    func handle(_ error: Error) -> Bool {
        let message = error.localizedDescription
        guard message.contains("busy:") else { return false }
        isPresented = true
        return true
    }
}

extension View {
    /// Attach the shared busy alert once, near the root.
    func busyAlert() -> some View {
        modifier(BusyAlertModifier())
    }
}

private struct BusyAlertModifier: ViewModifier {
    @ObservedObject private var alert = BusyAlert.shared

    func body(content: Content) -> some View {
        content.alert(L("settings.history.busyTitle"), isPresented: $alert.isPresented) {
            Button(L("common.close"), role: .cancel) {}
        } message: {
            Text(L("settings.history.busyMessage"))
        }
    }
}

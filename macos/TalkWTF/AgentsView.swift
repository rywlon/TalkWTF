import SwiftUI
import AppKit

@MainActor
final class AgentHub: ObservableObject {
    static let shared = AgentHub()
    @Published var reply = ""
    @Published var status = ""
    @Published var sending = false
    @Published var failedText: String?
    @Published var failedTarget: AgentTarget?
    @Published var recordingTarget: AgentTarget?
    /// A sentence the router could not place, kept with its shortlist so the
    /// user can pick one instead of losing the recording.
    @Published var pendingRoute: PendingRoute?

    struct PendingRoute: Identifiable {
        let id = UUID()
        let text: String
        let candidates: [AgentTarget]
        let reason: String
    }

    /// Pseudo binding id for "one key, the right agent".
    static let routerBindingID = "agent_auto"

    var targets: [AgentTarget] {
        let raw = SettingsStore.shared.string("voice_agent_targets", "[]")
        return (try? JSONDecoder().decode([AgentTarget].self, from: Data(raw.utf8))) ?? []
    }

    func save(_ targets: [AgentTarget]) throws {
        for target in targets { try AgentTransport.validate(target) }
        let encoded = try JSONEncoder().encode(targets)
        let store = SettingsStore.shared
        var bindings = store.settings["bindings"] as? [String: Any] ?? [:]
        let valid = Set(targets.map(\.bindingID))
        for key in Array(bindings.keys) where key.hasPrefix("agent_")
            && key != Self.routerBindingID && !valid.contains(key) {
            // Core patches deep-merge maps. Clearing disables removed bindings.
            if var binding = bindings[key] as? [String: Any] {
                binding["current_binding"] = ""
                bindings[key] = binding
            }
        }
        for target in targets where bindings[target.bindingID] == nil {
            bindings[target.bindingID] = ["id": target.bindingID, "name": target.name,
                "description": "Voice to Agent", "default_binding": "", "current_binding": ""]
        }
        if bindings[Self.routerBindingID] == nil {
            bindings[Self.routerBindingID] = [
                "id": Self.routerBindingID, "name": "智能路由",
                "description": "一句话交给对的本地 Agent",
                "default_binding": "option+a", "current_binding": "option+a",
            ]
        }
        guard store.patch(["voice_agent_targets": String(decoding: encoded, as: UTF8.self), "bindings": bindings]) else {
            throw AgentDeliveryError.invalid(store.error ?? "保存失败。")
        }
        try Core.invoke("start_hotkeys")
    }

    private func rememberConversation(_ conversation: String, for target: AgentTarget) {
        guard !conversation.isEmpty else { return }
        var updated = targets
        guard let index = updated.firstIndex(where: { $0.id == target.id }) else { return }
        updated[index].conversation = conversation
        do { try save(updated) }
        catch { status += "（会话未能保存，请重新连接后再发送。）" }
    }

    /// Route a finished transcript to the best local agent, or park it when the
    /// candidates are too close to call.
    func route(_ text: String) {
        let agents = targets
        guard !agents.isEmpty else {
            OverlayController.shared.show(.agentMessage(text: "还没有连接 Agent，先在 TalkWTF 里连一个。", failed: true))
            return
        }
        let decision = AgentRouter.route(text, agents: agents)
        if let target = decision.target, decision.autoDispatch {
            status = "\(target.name) · \(decision.tier.label) \(Int((decision.confidence * 100).rounded()))%"
            markUsed(target)
            deliver(text, to: target)
            return
        }
        pendingRoute = PendingRoute(text: text, candidates: decision.candidates, reason: decision.reason)
        OverlayController.shared.show(.agentMessage(
            text: "这句话不确定交给谁，打开 TalkWTF 选一下。", failed: false))
    }

    /// Deliver a parked sentence to the agent the user picked.
    func deliverPending(_ target: AgentTarget) {
        guard let pending = pendingRoute else { return }
        pendingRoute = nil
        markUsed(target)
        deliver(pending.text, to: target)
    }

    /// Give the router binding the ⌥A default once, so "one key, right agent"
    /// works without the user visiting this page first.
    func ensureRouterBinding() {
        let store = SettingsStore.shared
        var bindings = store.settings["bindings"] as? [String: Any] ?? [:]
        guard bindings[Self.routerBindingID] == nil else { return }
        // Never steal a shortcut the user already gave to something else.
        let taken = bindings.values.contains { entry in
            (entry as? [String: Any])?["current_binding"] as? String == "option+a"
        }
        guard !taken else { return }
        bindings[Self.routerBindingID] = [
            "id": Self.routerBindingID, "name": "智能路由",
            "description": "一句话交给对的本地 Agent",
            "default_binding": "option+a", "current_binding": "option+a",
        ]
        if store.patch(["bindings": bindings]) { try? Core.invoke("start_hotkeys") }
    }

    private func markUsed(_ target: AgentTarget) {
        var updated = targets
        guard let index = updated.firstIndex(where: { $0.id == target.id }) else { return }
        updated[index].lastUsedAt = Date().timeIntervalSince1970
        try? save(updated)
    }

    func deliver(_ text: String, to target: AgentTarget) {
        sending = true
        reply = ""
        status = target.kind == .codex ? "\(target.name) 正在处理…" : "正在发送到 \(target.name)…"
        OverlayController.shared.show(.processing(label: status))
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let receipt = try AgentTransport.deliver(to: target, text: text)
                DispatchQueue.main.async {
                    self.sending = false
                    self.status = target.kind == .codex ? "\(target.name) 已回复" : "已发送到 \(target.name)"
                    self.reply = receipt.reply
                    self.rememberConversation(receipt.conversation, for: target)
                    self.failedText = nil
                    self.failedTarget = nil
                    self.markUsed(target)
                    OverlayController.shared.show(.agentMessage(text: self.status, failed: false))
                }
            } catch {
                DispatchQueue.main.async {
                    self.sending = false
                    self.status = error.localizedDescription
                    if case let AgentDeliveryError.agentFailed(_, conversation) = error {
                        self.rememberConversation(conversation, for: target)
                    }
                    self.failedText = text
                    self.failedTarget = target
                    OverlayController.shared.show(.agentMessage(text: "发送未确认，内容已保留。打开 TalkWTF 查看或复制。", failed: true))
                }
            }
        }
    }
}

struct AgentsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @ObservedObject private var hub = AgentHub.shared
    @ObservedObject private var recorder = ShortcutRecorder.shared
    @State private var editing: AgentTarget?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                if let pending = hub.pendingRoute {
                    pendingBanner(pending).padding(.top, 22)
                }
                if let error {
                    Text(error).font(Theme.Fonts.callout).foregroundStyle(Theme.Colors.err)
                        .padding(.top, 18).textSelection(.enabled)
                }
                if let recorderError = recorder.error {
                    Text(recorderError).font(Theme.Fonts.callout).foregroundStyle(Theme.Colors.err)
                        .padding(.top, 18).textSelection(.enabled)
                }
                if !hub.status.isEmpty { statusSection.padding(.top, 22) }
                routerSection.padding(.top, 30)
                listSection.padding(.top, 32)
                Text(L("agents.footer"))
                    .font(Theme.Fonts.callout)
                    .foregroundStyle(Theme.Colors.inkTertiary)
                    .padding(.top, 24)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .pageLayout()
        }
        .sheet(item: $editing) { target in
            AgentPairingSheet(target: target) { updated in
                var targets = hub.targets
                if let index = targets.firstIndex(where: { $0.id == updated.id }) { targets[index] = updated }
                else { targets.append(updated) }
                try hub.save(targets)
            }
        }
        .onDisappear { recorder.cancel() }
    }

    // MARK: Routing

    private var routerBinding: String {
        let bindings = store.settings["bindings"] as? [String: Any] ?? [:]
        let entry = bindings[AgentHub.routerBindingID] as? [String: Any]
        return entry?["current_binding"] as? String ?? ""
    }

    private var routerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: L("agents.route.title"))
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("agents.route.hint"))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                if routerBinding.isEmpty {
                    Text(L("agents.route.unbound"))
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(Theme.Colors.inkTertiary)
                } else {
                    KeycapCombo(combo: routerBinding)
                }
            }
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Hairline() }
        }
    }

    private func pendingBanner(_ pending: AgentHub.PendingRoute) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
                Text(L("agents.pending.title"))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                StudioIconButton(systemImage: "xmark") { hub.pendingRoute = nil }
            }
            Text(pending.text)
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.Colors.ink)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("agents.pending.hint"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.Colors.inkTertiary)
            HStack(spacing: 8) {
                ForEach(pending.candidates) { agent in
                    StudioButton(title: agent.name, kind: .ghost, height: 30) {
                        hub.deliverPending(agent)
                    }
                }
                Spacer()
                StudioButton(title: L("dashboard.actions.copy"), kind: .quiet, height: 30) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pending.text, forType: .string)
                }
            }
        }
        .padding(16)
        .background(Theme.Colors.well)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("VOICE → AGENT")
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .tracking(2.6)
                    .foregroundStyle(.white.opacity(0.55))
                Text(L("agents.hero.title"))
                    .font(.system(size: 31, weight: .bold))
                    .tracking(-0.8)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("agents.hero.subtitle"))
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white.opacity(0.74))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 470, alignment: .leading)
            }
            HStack(spacing: 10) {
                StudioButton(title: L("agents.connect"), systemImage: "plus", kind: .accent) {
                    editing = AgentTarget(name: "")
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(heroBackground)
        .frame(height: 268)
        .clipped()
        .overlay(alignment: .topTrailing) {
            Text(String(format: L("agents.count"), hub.targets.count))
                .font(Theme.Fonts.mono(11))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 24)
                .padding(.trailing, 26)
        }
    }

    private var heroBackground: some View {
        ZStack {
            Color.black
            if let image = StudioAssets.waveguide {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            }
            LinearGradient(
                colors: [Color.black.opacity(0.72), Color.black.opacity(0.35), Color.black.opacity(0.86)],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: hub.sending ? "arrow.up.circle" : hub.failedText == nil ? "checkmark.circle" : "exclamationmark.circle")
                    .font(.system(size: 13))
                Text(hub.status)
                    .font(Theme.Fonts.body)
                Spacer()
                if hub.sending { ProgressView().controlSize(.small) }
            }
            .foregroundStyle(hub.failedText == nil ? Theme.Colors.inkSecondary : Theme.Colors.warn)

            if !hub.reply.isEmpty {
                Text(hub.reply)
                    .font(Theme.Fonts.body)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.well)
            }
            if let text = hub.failedText {
                Text(text)
                    .font(Theme.Fonts.callout)
                    .textSelection(.enabled)
                    .lineLimit(8)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.well)
                HStack(spacing: 8) {
                    StudioButton(title: L("dashboard.actions.copy"), systemImage: "doc.on.doc", kind: .ghost) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    StudioButton(title: L("common.clear"), systemImage: "xmark", kind: .quiet) {
                        hub.failedText = nil
                        hub.failedTarget = nil
                        hub.status = ""
                    }
                }
                Text(L("agents.failedHint"))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkTertiary)
            }
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Hairline() }
        .overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: List

    private var listSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: L("agents.list.title"), trailing: "\(hub.targets.count)")

            if hub.targets.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("agents.empty.title"))
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.4)
                    Text(L("agents.empty.subtitle"))
                        .font(Theme.Fonts.body)
                        .foregroundStyle(Theme.Colors.inkSecondary)
                        .frame(maxWidth: 520, alignment: .leading)
                    StudioButton(title: L("agents.connect"), systemImage: "plus", kind: .accent) {
                        editing = AgentTarget(name: "")
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Hairline() }
                .overlay(alignment: .bottom) { Hairline() }
            } else {
                VStack(spacing: 0) {
                    Hairline()
                    ForEach(hub.targets) { target in
                        row(target)
                        Hairline()
                    }
                }
            }
        }
    }

    private func row(_ target: AgentTarget) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Image(systemName: icon(for: target))
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Theme.Colors.ink)
            }
            .frame(width: 40, height: 40)
            .overlay(Rectangle().stroke(Theme.Colors.hairline, lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(target.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Colors.ink)
                    if let provider = target.provider, provider != target.name, !provider.isEmpty {
                        Text(provider)
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.Colors.inkTertiary)
                    }
                }
                Text(detail(for: target))
                    .font(Theme.Fonts.caption)
                    .foregroundStyle(Theme.Colors.inkSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            hotkeyButton(target)
            StudioIconButton(systemImage: "slider.horizontal.3", help: L("agents.edit")) { editing = target }
            Menu {
                Button(L("agents.remove"), role: .destructive) {
                    do { try hub.save(hub.targets.filter { $0.id != target.id }) }
                    catch { self.error = error.localizedDescription }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.inkSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.vertical, 16)
        .contentShape(Rectangle())
    }

    private func hotkeyButton(_ target: AgentTarget) -> some View {
        let isRecording = recorder.recording == target.bindingID
        let label = isRecording ? recorder.preview : shortcut(target)
        return Button {
            isRecording ? recorder.cancel() : recorder.begin(target.bindingID)
        } label: {
            Text(label.isEmpty ? L("agents.hotkey") : label)
                .font(Theme.Fonts.mono(11.5))
                .lineLimit(1)
                .foregroundStyle(isRecording ? Theme.Colors.accent : Theme.Colors.inkSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .overlay(Rectangle().stroke(isRecording ? Theme.Colors.accent : Theme.Colors.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(recorder.recording != nil && !isRecording)
    }

    private func icon(for target: AgentTarget) -> String {
        switch target.kind {
        case .codex: return "sparkles"
        case .http: return "network"
        case .command: return "terminal"
        }
    }

    private func detail(for target: AgentTarget) -> String {
        if let directory = target.workingDirectory, !directory.isEmpty { return directory }
        if !target.address.isEmpty { return target.address }
        return "\(kindLabel(target)) · \(L("agents.paired"))"
    }

    private func kindLabel(_ target: AgentTarget) -> String {
        switch target.kind {
        case .codex: return "Codex"
        case .http: return "HTTP"
        case .command: return L("agents.local")
        }
    }

    private func shortcut(_ target: AgentTarget) -> String {
        let bindings = store.settings["bindings"] as? [String: [String: Any]] ?? [:]
        let value = bindings[target.bindingID]?["current_binding"] as? String ?? ""
        return value.isEmpty ? L("agents.hotkey") : KeyGlyphs.parse(value).joined(separator: " ")
    }
}

@MainActor
private final class PairingCoordinator: ObservableObject {
    @Published var pairing: AgentPairing?
    @Published var connected: AgentTarget?
    @Published var error: String?
    private var timer: Timer?

    func begin(provider: AgentChoice, targetID: String, save: @escaping (AgentTarget) throws -> Void) {
        cancel()
        error = nil
        connected = nil
        do {
            guard let executable = Bundle.main.executableURL?.path else {
                throw AgentDeliveryError.invalid("找不到连接程序，请重新打开 TalkWTF。")
            }
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.talkwtf.app/agent-pairings")
            pairing = try AgentPairing.create(root: root, provider: provider, executable: executable, targetID: targetID)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll(save: save) }
            }
        } catch { self.error = error.localizedDescription }
    }

    private func poll(save: (AgentTarget) throws -> Void) {
        guard let pairing else { return }
        do {
            guard let target = try pairing.readResponse() else { return }
            try save(target)
            connected = target
            timer?.invalidate()
            timer = nil
            try? pairing.cancel()
        } catch {
            self.error = error.localizedDescription
            timer?.invalidate()
            timer = nil
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        try? pairing?.cancel()
        pairing = nil
    }
}

private struct AgentPairingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = PairingCoordinator()
    let target: AgentTarget
    var save: (AgentTarget) throws -> Void
    @State private var choice = AgentChoice.codex
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if let connected = coordinator.connected {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 40)).foregroundStyle(.tint)
                Text("已连接 \(connected.name)").font(Theme.Fonts.title)
                Text("最后，给这个会话设置一个快捷键。以后按键说话，就能直接发给它。")
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("设置快捷键") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            ShortcutRecorder.shared.begin(connected.bindingID)
                        }
                    }.buttonStyle(.borderedProminent)
                }
            } else if let pairing = coordinator.pairing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("把这句话发给 \(choice.rawValue)").font(Theme.Fonts.title)
                    Text("粘贴到你想接收语音的会话，让 Agent 帮你完成连接。")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("请将当前 \(choice.rawValue) 会话连接到 TalkWTF。")
                        .font(Theme.Fonts.headline)
                    Text("所需连接说明会随提示词一起复制。")
                        .font(Theme.Fonts.callout).foregroundStyle(.secondary)
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: 12))
                DisclosureGroup("查看完整提示词") {
                    Text(pairing.prompt).font(Theme.Fonts.caption).textSelection(.enabled).padding(.top, 8)
                }.font(Theme.Fonts.callout).foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(pairing.prompt, forType: .string)
                    copied = true
                } label: {
                    Label(copied ? "已复制，再复制一次" : "复制连接提示词", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).controlSize(.large)
                if let error = coordinator.error {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                } else {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(copied ? "发给 Agent 后，这里会自动确认连接。" : "等待 Agent 连接…")
                    }.font(Theme.Fonts.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Button("重新选择") { coordinator.cancel(); copied = false }
                    Spacer()
                    if coordinator.error != nil {
                        Button("重新生成") { begin() }
                    }
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("你正在用哪个 Agent？").font(Theme.Fonts.title)
                    Text("选好后，复制一句话发给它，就能开始连接。")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 8) {
                    ForEach(AgentChoice.allCases) { item in
                        Button { choice = item } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item == .other ? "terminal" : "sparkles")
                                    .foregroundStyle(.tint).frame(width: 24)
                                Text(item.rawValue).font(Theme.Fonts.body)
                                Spacer()
                                if choice == item { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }.padding(14).contentShape(Rectangle())
                                .background(choice == item ? Theme.Colors.selectionAccent : Theme.Colors.cardFill,
                                            in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                }
                Text("适用于能读取本机文件、执行命令的 Agent。仅网页聊天的客户端暂不支持。")
                    .font(Theme.Fonts.callout).foregroundStyle(.secondary)
                if let error = coordinator.error { Text(error).foregroundStyle(.orange) }
                HStack {
                    Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("生成连接提示词") { begin() }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(28).frame(width: 540)
            .onAppear {
                choice = target.provider.flatMap(AgentChoice.init(rawValue:)) ?? (target.kind == .codex ? .codex : .other)
                if target.address.isEmpty { choice = .codex }
            }
            .onDisappear { coordinator.cancel() }
    }

    private func begin() {
        copied = false
        coordinator.begin(provider: choice, targetID: target.id, save: save)
    }
}

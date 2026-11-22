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
        for key in Array(bindings.keys) where key.hasPrefix("agent_") && !valid.contains(key) {
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
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    pageHeader("Voice to Agent", subtitle: "保持专注，把下一句话交给对的 Agent。")
                    Spacer()
                    Button { editing = AgentTarget(name: "") } label: {
                        Label("连接 Agent", systemImage: "plus")
                    }.buttonStyle(.borderedProminent)
                }
                HStack(spacing: 16) {
                    Image(systemName: "waveform").font(.system(size: 32, weight: .light)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("一个热键，一句话，继续你的思路。")
                            .font(.system(size: 22, weight: .medium))
                        Text("让你正在用的 Agent 帮你连上。以后按键说话，直接交给它。")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(24).frame(maxWidth: .infinity).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))

                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if let error = recorder.error { Text(error).foregroundStyle(.red) }
                if !hub.status.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(hub.status, systemImage: hub.sending ? "arrow.up.circle" : hub.failedText == nil ? "checkmark.circle" : "exclamationmark.circle")
                            .foregroundStyle(hub.failedText == nil ? Color.secondary : Color.orange)
                        if !hub.reply.isEmpty {
                            Text(hub.reply).textSelection(.enabled)
                        }
                        if let text = hub.failedText {
                            Text(text).textSelection(.enabled).lineLimit(8)
                            HStack {
                                Button("复制内容") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(text, forType: .string)
                                }
                                Button("清除提示") { hub.failedText = nil; hub.failedTarget = nil; hub.status = "" }
                            }
                            Text("发送结果可能未知，请先检查接收端，避免重复执行。原始听写也可在资料库查找。")
                                .font(Theme.Fonts.caption).foregroundStyle(.secondary)
                        }
                    }.cardSurface()
                }
                if hub.targets.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("想让谁接收你的语音？").font(Theme.Fonts.title)
                        Text("选择你正在用的 Agent，把连接提示词发给它。剩下的交给它完成。")
                            .foregroundStyle(.secondary)
                        Button("连接 Agent") { editing = AgentTarget(name: "") }
                    }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    VStack(spacing: 0) {
                        ForEach(hub.targets) { target in
                            HStack(spacing: 16) {
                                Image(systemName: target.kind == .codex ? "sparkles" : target.kind == .http ? "network" : "terminal")
                                    .font(.system(size: 20)).foregroundStyle(.tint)
                                    .frame(width: 44, height: 44)
                                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(target.name).font(Theme.Fonts.headline)
                                    Text((target.provider ?? (target.kind == .codex ? "Codex" : "本地 Agent")) + " · 已配对")
                                        .font(Theme.Fonts.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { recorder.recording == target.bindingID ? recorder.cancel() : recorder.begin(target.bindingID) } label: {
                                    Text(recorder.recording == target.bindingID ? recorder.preview : shortcut(target))
                                        .font(.system(size: 12, design: .monospaced))
                                }.disabled(recorder.recording != nil && recorder.recording != target.bindingID)
                                Button { editing = target } label: { Image(systemName: "slider.horizontal.3") }.help("编辑 Agent")
                                Menu {
                                    Button("移除 Agent", role: .destructive) {
                                        do { try hub.save(hub.targets.filter { $0.id != target.id }) }
                                        catch { self.error = error.localizedDescription }
                                    }
                                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                            }.padding(20)
                            if target.id != hub.targets.last?.id { Divider().padding(.leading, 80) }
                        }
                    }.background(Theme.Colors.cardFill, in: RoundedRectangle(cornerRadius: 16))
                }
                Text("连接的是你粘贴提示词的那个会话。需要换会话时，再连接一次即可。")
                    .font(Theme.Fonts.callout).foregroundStyle(.secondary)
            }.pageLayout()
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

    private func shortcut(_ target: AgentTarget) -> String {
        let bindings = store.settings["bindings"] as? [String: [String: Any]] ?? [:]
        let value = bindings[target.bindingID]?["current_binding"] as? String ?? ""
        return value.isEmpty ? "设置热键" : value
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

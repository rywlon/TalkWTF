import SwiftUI

/// Migration phases shown inside the app, so progress is visible without asking.
/// Keep the statuses in sync with docs/specs/phase-9-swiftui-native-shell.md.
enum PhaseStatus {
    case done
    case inProgress
    case pending

    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .inProgress: return "clock.fill"
        case .pending: return "circle"
        }
    }

    var tint: Color {
        switch self {
        case .done: return .green
        case .inProgress: return .orange
        case .pending: return .secondary
        }
    }
}

struct Phase: Identifiable {
    let id: String
    let title: String
    let detail: String
    var status: PhaseStatus
}

/// The live migration plan. Update the statuses here as phases complete.
let migrationPhases: [Phase] = [
    Phase(
        id: "P0",
        title: "P0 · 打通桥",
        detail: "Rust 静态库 + SwiftUI 链接 + JSON invoke + 事件回调",
        status: .done
    ),
    Phase(
        id: "P1",
        title: "P1 · 抽出 talkwtf-core",
        detail: "引擎层已全部入 core（设置/数据/模型/音频/ASR/LLM/词典/学词）；余外壳层（管线/热键/托盘/悬浮窗）",
        status: .inProgress
    ),
    Phase(
        id: "P2",
        title: "P2 · FFI 命令面",
        detail: "设置/词典/历史/模型/Dashboard 已通；余异步命令与事件对齐",
        status: .inProgress
    ),
    Phase(
        id: "P3",
        title: "P3 · SwiftUI 外壳",
        detail: "主窗口 / 设置 / 资料库 / Dashboard（原生控件）",
        status: .pending
    ),
    Phase(
        id: "P4",
        title: "P4 · 原生悬浮窗",
        detail: "NSPanel + glassEffect，对标 Spokenly 面板",
        status: .pending
    ),
    Phase(
        id: "P5",
        title: "P5 · 平台集成与收尾",
        detail: "热键/托盘/权限/i18n/数据迁移/移除 Tauri",
        status: .pending
    ),
]

struct MigrationProgressView: View {
    var body: some View {
        GroupBox("迁移进度") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(migrationPhases) { phase in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: phase.status.symbol)
                            .foregroundStyle(phase.status.tint)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(phase.title).font(.headline)
                            Text(phase.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

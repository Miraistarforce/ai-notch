import AppKit
import SwiftUI

/// 設定ウィンドウの状態管理
final class SettingsModel: ObservableObject {
    @Published var tools: [AITool] = []
    @Published var errorMessage: String?

    // 自動起動（ログイン項目）
    @Published var launchAtLogin = false
    @Published var launchAtLoginAvailable = true
    @Published var launchAtLoginNeedsApproval = false
    @Published var launchAtLoginMessage: String?

    func refresh() {
        tools = HookSetup.shared.tools()
        refreshLoginItem()
    }

    func toggle(_ id: String, _ on: Bool) {
        do {
            try HookSetup.shared.setEnabled(id, on)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    func refreshLoginItem() {
        let item = LoginItem.shared
        launchAtLogin = item.isEnabled
        launchAtLoginAvailable = item.isAvailable
        launchAtLoginNeedsApproval = item.needsApproval
        if !item.needsApproval { launchAtLoginMessage = nil }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            try LoginItem.shared.setEnabled(on)
            launchAtLoginMessage = nil
        } catch {
            launchAtLoginMessage = error.localizedDescription
        }
        refreshLoginItem()
    }
}

/// メニューバーのClawdアイコンから開く連携設定画面。
/// このMacにインストールされているAI CLIを検出し、hook連携をオン/オフする。
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    let port: UInt16

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ヘッダー
            HStack(spacing: 10) {
                ClawdSprite(stepUp: false, blink: false, arms: .bothUp, mark: nil, markBob: 0)
                    .frame(width: 30, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Notch 連携設定")
                        .font(.system(size: 15, weight: .bold))
                    Text("オンにしたAIの動きがノッチに表示されます")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            // ツール一覧
            VStack(spacing: 0) {
                ForEach(model.tools) { tool in
                    toolRow(tool)
                    if tool.id != model.tools.last?.id {
                        Divider().padding(.leading, 16)
                    }
                }
            }

            Divider()

            // 起動設定
            launchAtLoginRow

            Divider()

            // フッター
            VStack(alignment: .leading, spacing: 6) {
                if let err = model.errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                Text("オンにすると各AIの設定ファイルにhookを登録します（既存設定はバックアップ）。次に起動するAIセッションから反映され、オフにすると登録を解除します。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("受信ポート: 127.0.0.1:\(String(port))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400)
    }

    /// ログイン時の自動起動トグル。Macを再起動してもノッチが出るようにする。
    private var launchAtLoginRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("ログイン時に自動起動")
                            .font(.system(size: 13, weight: .semibold))
                        if model.launchAtLogin {
                            Text("オン")
                                .font(.system(size: 9.5, weight: .medium))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Capsule().fill(Color.green.opacity(0.18)))
                                .foregroundStyle(.green)
                        }
                    }
                    Text("Macを再起動・シャットダウンしても、ログインすると自動で立ち上がります")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(LoginItem.shared.bundlePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!model.launchAtLoginAvailable)
            }

            if let msg = model.launchAtLoginMessage {
                Text(msg)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.launchAtLoginNeedsApproval {
                Button("システム設定のログイン項目を開く") {
                    LoginItem.shared.openSystemSettings()
                }
                .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(model.launchAtLoginAvailable ? 1 : 0.55)
    }

    private func toolRow(_ tool: AITool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(tool.name)
                        .font(.system(size: 13, weight: .semibold))
                    if !tool.detected {
                        Text("未検出")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundStyle(.secondary)
                    } else if tool.enabled {
                        Text("連携中")
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.green.opacity(0.18)))
                            .foregroundStyle(.green)
                    }
                }
                Text(tool.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(tool.configPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { tool.enabled },
                set: { model.toggle(tool.id, $0) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!tool.detected)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .opacity(tool.detected ? 1 : 0.55)
    }
}

/// 設定ウィンドウの表示制御（アプリはaccessoryのため、開くときに前面化する）
final class SettingsWindowController {
    private let model = SettingsModel()
    private let window: NSWindow

    init(port: UInt16) {
        let hosting = NSHostingController(rootView: SettingsView(model: model, port: port))
        window = NSWindow(contentViewController: hosting)
        window.title = "AI Notch"
        window.styleMask = [.titled, .closable]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
    }

    func open() {
        model.refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

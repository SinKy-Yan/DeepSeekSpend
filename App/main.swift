// DeepSeekSpend Lite — macOS 菜单栏余额显示器
// 编译: swiftc -O -target arm64-apple-macosx13.0 main.swift -o DeepSeekSpend \
//        -framework AppKit -framework SwiftUI -framework ServiceManagement
//
// 设计意图：只回答两个问题 —— 我还剩多少钱（余额，大字）、我这一小时花了多少（小字）。
// 不再有项目 / 会话 / WorkBuddy 分栏，整个界面只有「余额 + 花费」。

import AppKit
import SwiftUI
import ServiceManagement

// MARK: - 快照模型（与 collector.mjs 输出的 snapshot.json 对应）

struct Snapshot: Decodable {
    var generatedAt: Double
    var hourStart: Double
    var overall: Overall
    var balance: Balance?
    var balanceError: String?
    var errors: [String]?

    struct Overall: Decodable {
        var hour: Double
        var today: Double
        var total: Double
    }

    struct Balance: Decodable {
        var currency: String?
        var totalBalance: String?
        var grantedBalance: String?
        var toppedUpBalance: String?
        var fetchedAt: Double?
    }

    var balanceValue: Double? {
        guard let raw = balance?.totalBalance else { return nil }
        return Double(raw)
    }
}

// MARK: - 状态模型

final class SpendingModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var loadError: String?
    @Published var launchAtLogin = false

    var statusItem: NSStatusItem?
    var quitting = false

    private var timer: Timer?
    private var collector: Process?
    private let posix = Locale(identifier: "en_US_POSIX")

    let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DeepSeekSpend")
    var configPath: URL { supportDir.appendingPathComponent("config.json") }
    var snapshotPath: URL { supportDir.appendingPathComponent("snapshot.json") }
    var triggerPath: URL { supportDir.appendingPathComponent("refresh.trigger") }

    var config: [String: Any] = [:]

    /// 余额（元）；查不到时为 nil
    var balance: Double? { snapshot?.balanceValue }

    /// 界面底部需要提示的问题（余额取不到优先）
    var warning: String? {
        if let err = loadError { return err }
        if let err = snapshot?.balanceError { return err }
        return nil
    }

    /// 未定价模型的提示（不打断主信息，只在脚注里一句）
    var unpricedNote: String? {
        let list = (snapshot?.errors ?? []).filter { $0.contains("单价") }
        return list.isEmpty ? nil : "部分模型未配置单价，估算偏低"
    }

    func start() {
        prepareSupportFiles()
        loadConfig()
        refreshLaunchAtLoginStatus()
        startCollector()
        timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.readSnapshot()
        }
        timer?.tolerance = 1.0
        readSnapshot()
    }

    /// 首次运行把包内的 collector / config 复制到 Application Support。
    /// 采集器始终跟随 App 内版本；配置保留用户的路径与轮询设置，价目表跟随 App 版本。
    func prepareSupportFiles() {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let resources = Bundle.main.resourceURL else { return }
        let bundledCollector = resources.appendingPathComponent("collector.mjs")
        let bundledConfig = resources.appendingPathComponent("config.json")
        let targetCollector = supportDir.appendingPathComponent("collector.mjs")
        if FileManager.default.fileExists(atPath: bundledCollector.path) {
            let same = (try? Data(contentsOf: bundledCollector)) == (try? Data(contentsOf: targetCollector))
            if !same {
                try? FileManager.default.removeItem(at: targetCollector)
                try? FileManager.default.copyItem(at: bundledCollector, to: targetCollector)
            }
        }
        if !FileManager.default.fileExists(atPath: configPath.path) {
            try? FileManager.default.copyItem(at: bundledConfig, to: configPath)
        } else if let bundledData = try? Data(contentsOf: bundledConfig),
                  let currentData = try? Data(contentsOf: configPath),
                  let bundled = try? JSONSerialization.jsonObject(with: bundledData) as? [String: Any],
                  var current = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any] {
            current["prices"] = bundled["prices"]
            current["pricingSource"] = bundled["pricingSource"]
            current["pricingVerifiedAt"] = bundled["pricingVerifiedAt"]
            if let free = bundled["freeModels"] { current["freeModels"] = free }
            if let merged = try? JSONSerialization.data(withJSONObject: current, options: [.prettyPrinted, .sortedKeys]) {
                try? merged.write(to: configPath, options: .atomic)
            }
        }
    }

    func loadConfig() {
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            loadError = "无法读取配置文件"
            return
        }
        config = obj
    }

    func resolveNode() -> String? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("node").path,
           nodeSupportsZstd(bundled) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
        ]
        for c in candidates where nodeSupportsZstd(c) { return c }
        return nil
    }

    private func nodeSupportsZstd(_ path: String) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-e", "require('node:zlib').zstdDecompressSync"]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus == 0
        } catch {
            return false
        }
    }

    func startCollector() {
        collector?.terminate()
        guard let node = resolveNode() else {
            loadError = "未找到 Node.js（需要 v22.15+ 以解压 zstd 日志）"
            return
        }
        let collectorPath = supportDir.appendingPathComponent("collector.mjs")
        guard FileManager.default.fileExists(atPath: collectorPath.path) else {
            loadError = "采集器脚本缺失"
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [
            collectorPath.path, "--config", configPath.path,
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self, !self.quitting else { return }
                if proc.terminationStatus != 0 && self.collector === proc {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.startCollector() }
                }
            }
        }
        do {
            try p.run()
            collector = p
            loadError = nil
        } catch {
            loadError = "启动采集器失败: \(error.localizedDescription)"
        }
    }

    func readSnapshot() {
        guard let data = try? Data(contentsOf: snapshotPath) else { return }
        do {
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            DispatchQueue.main.async {
                self.snapshot = snap
                self.updateStatusTitle()
            }
        } catch {
            DispatchQueue.main.async { self.loadError = "快照解析失败: \(error.localizedDescription)" }
        }
    }

    /// 状态栏只显示余额，数字等宽，避免跳动
    func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let hour = money(snapshot?.overall.hour ?? 0)
        let text = balance.map(money) ?? "¥—"
        button.attributedTitle = NSAttributedString(
            string: text,
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]
        )
        button.toolTip = "DeepSeek 余额 \(text) ｜ 本小时 \(hour)"
    }

    func forceRefresh() {
        try? "refresh".write(to: triggerPath, atomically: true, encoding: .utf8)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.readSnapshot() }
    }

    func openPlatform() {
        let url = config["platformUrl"] as? String ?? "https://platform.deepseek.com/usage"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            loadError = "开机自启设置失败: \(error.localizedDescription)"
        }
        refreshLaunchAtLoginStatus()
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func money(_ v: Double) -> String {
        if v > 0 && v < 0.01 {
            return String(format: "¥%.4f", locale: posix, v)
        }
        return String(format: "¥%.2f", locale: posix, v)
    }

    func plainMoney(_ v: Double) -> String {
        String(format: "%.2f", locale: posix, v)
    }
}

// MARK: - 弹窗视图

struct MenuView: View {
    @ObservedObject var model: SpendingModel
    private let width: CGFloat = 300
    /// 次级文字：系统 .secondary 在浅色模式只有 ~3.9:1，这里提到 0.66 保证 AA
    private let dim = Color.primary.opacity(0.66)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            balanceBlock.padding(.top, 10)
            Divider().padding(.vertical, 12)
            spendRow
            if let note = model.warning ?? model.unpricedNote {
                warningLine(note).padding(.top, 10)
            }
            Divider().padding(.vertical, 12)
            footer
        }
        .padding(16)
        .frame(width: width, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 顶部：标题 + 账单入口

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("DeepSeek 余额")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(dim)
            Spacer(minLength: 8)
            Button(action: { model.openPlatform() }) {
                HStack(spacing: 2) {
                    Text("账单")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .semibold))
                }
                .font(.system(size: 11))
                .foregroundStyle(dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("在浏览器打开 DeepSeek 平台用量页")
        }
    }

    // MARK: 余额（大字）

    private var balanceBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("¥")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(dim)
                Text(balanceText)
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.balance.map { "余额，人民币 \(model.plainMoney($0)) 元" } ?? "余额不可用")
            .help(balanceHelp)

            // 小字：本小时消耗
            HStack(spacing: 5) {
                Text("本小时")
                    .font(.system(size: 11))
                    .foregroundStyle(dim)
                Text(model.money(model.snapshot?.overall.hour ?? 0))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(dim)
            }
        }
    }

    private var balanceText: String {
        guard let value = model.balance else { return "——" }
        return model.plainMoney(value)
    }

    private var balanceHelp: String {
        guard let ts = model.snapshot?.balance?.fetchedAt else { return "余额来自 DeepSeek 官方接口" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return "余额更新于 \(f.string(from: Date(timeIntervalSince1970: ts / 1000)))"
    }

    // MARK: 花费：今日 / 累计

    private var spendRow: some View {
        HStack(alignment: .top, spacing: 24) {
            statCell(label: "今日花费", value: model.snapshot?.overall.today ?? 0)
            statCell(label: "累计花费", value: model.snapshot?.overall.total ?? 0)
            Spacer(minLength: 0)
        }
    }

    private func statCell(label: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(dim)
            Text(model.money(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 提示（余额取不到 / 未定价模型）

    private func warningLine(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(dim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(model.warning ?? (model.snapshot?.errors ?? []).joined(separator: "\n"))
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: { model.forceRefresh() }) {
                Label("刷新", systemImage: "arrow.clockwise")
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
            Spacer(minLength: 8)
            Toggle("开机自启", isOn: Binding(
                get: { model.launchAtLogin },
                set: { _ in model.toggleLaunchAtLogin() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("登录 Mac 时自动启动本应用")
            Button(role: .destructive, action: { NSApp.terminate(nil) }) {
                Label("退出", systemImage: "power")
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.borderless)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = SpendingModel()
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var panelWindow: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        model.statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.delegate = self
        if let forced = NSApp.appearance { popover.appearance = forced } // 跟随 --appearance 调试开关
        let host = NSHostingController(
            rootView: MenuView(model: model).environment(\.font, .system(size: 12))
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 300, height: 250)

        model.start()
        if CommandLine.arguments.contains("--show-window") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showPanelWindow()
            }
        }
    }

    /// 供截图 / 调试：把同一个面板放进普通窗口
    private func showPanelWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "DeepSeek 余额"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingController(
            rootView: MenuView(model: model)
                .environment(\.font, .system(size: 12))
                .frame(width: 300)
        )
        window.contentViewController = host
        window.center()
        let controller = NSWindowController(window: window)
        panelWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.quitting = true
        // 采集器子进程会随父进程退出自行结束
    }
}

// MARK: - 入口

let app = NSApplication.shared
// 调试用：--appearance light|dark 强制外观，便于截图核对明暗两套配色
if let i = CommandLine.arguments.firstIndex(of: "--appearance"), i + 1 < CommandLine.arguments.count {
    let light = CommandLine.arguments[i + 1] == "light"
    app.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(CommandLine.arguments.contains("--show-window") ? .regular : .accessory)
app.run()

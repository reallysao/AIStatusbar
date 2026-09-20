// AI Statusbar — Touch Bar 状态条: 并行监控主流 AI 应用(豆包/ChatGPT/DeepSeek/通义千问…)
// 常驻项: 空闲 / 进行中(阿拉伯数字 N 个) / 等待确认(红) / 完成闪烁
// 一级详情: 各活跃 AI 一栏(状态/并发/步骤), 点击进入二级; 二级详情: 任务进度+免费额度(估算)
// 自动识别: 安装到 /Applications 的主流 AI 应用即被识别, 最多显示活跃的 maxActive(4) 个
import AppKit
import Foundation

// MARK: - 日志
let logPath = NSString(string: "~/Library/Logs/AIStatusbar.log").expandingTildeInPath
func log(_ msg: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "[\(formatter.string(from: Date()))] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var monitors: [AppMonitor] = []
    private let touchBar = TouchBarController()
    private var config = Config()
    private var timer: Timer?
    private var paused = false
    private var menu: NSMenu!
    private var appMenuItems: [NSMenuItem] = []
    private var autoDismissTimer: Timer?
    private var selectedAppName: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        config = Config.load()
        monitors = config.apps.map { AppMonitor(config: $0) }
        for m in monitors {
            m.onDisplay = { [weak self] in
                DispatchQueue.main.async { self?.refreshUI() }
            }
        }
        // 防止系统自动终止后台应用
        ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: "AI Statusbar 常驻监控")
        setupStatusItem()
        touchBar.install()
        touchBar.onToggle = { [weak self] in
            guard let self = self else { return }
            if self.paused { return }
            self.touchBar.toggleDetail(snapshots: self.activeSnapshots())
            self.scheduleAutoDismiss()
        }
        touchBar.onTileTap = { [weak self] name in
            guard let self = self else { return }
            self.selectedAppName = name
            if let s = self.snapshots().first(where: { $0.name == name }) {
                self.touchBar.presentAppDetail(snapshot: s)
                self.scheduleAutoDismiss()
            }
        }
        touchBar.onBack = { [weak self] in
            guard let self = self else { return }
            self.selectedAppName = nil
            self.touchBar.presentDetail(snapshots: self.activeSnapshots())
            self.scheduleAutoDismiss()
        }
        log("===== AI Statusbar 启动, 已识别: \(config.apps.map { $0.name }.joined(separator: "、")) =====")

        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.touchBar.uninstall()
        }

        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.pollSeconds), repeats: true) { [weak self] _ in
            self?.tick()
        }
        refreshUI()

        // 自检钩子: DOUBAO_TB_TEST_DETAIL=1 时启动后自动弹出一级详情数秒
        if ProcessInfo.processInfo.environment["DOUBAO_TB_TEST_DETAIL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self = self else { return }
                log("自检: 自动弹出详情面板")
                self.touchBar.presentDetail(snapshots: self.activeSnapshots())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
                self?.touchBar.dismissDetail()
            }
        }
    }

    // MARK: - 界面
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menu = NSMenu()
        menu.addItem(NSMenuItem(title: "AI Statusbar", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        appMenuItems = monitors.map { m in
            let it = NSMenuItem(title: m.config.name, action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            return it
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "测试状态条", action: #selector(testDisplay), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "显示/收起详情面板", action: #selector(toggleDetailMenu), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "暂停监控", action: #selector(togglePause), keyEquivalent: "p"))
        menu.addItem(NSMenuItem(title: "开机自动启动", action: #selector(toggleAutoStart), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.image = makeIcon(color: .systemGray)
    }

    private func makeIcon(color: NSColor) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let r = rect.insetBy(dx: 3.5, dy: 3.5)
            let path = NSBezierPath(ovalIn: r)
            color.setFill()
            path.fill()
            return true
        }
        img.isTemplate = false
        return img
    }

    private func updateMenuUI() {
        let snaps = snapshots()
        for (i, it) in appMenuItems.enumerated() where i < snaps.count {
            let s = snaps[i]
            let st: String
            switch s.stateKey {
            case "working": st = "执行中"
            case "awaiting": st = "等待确认 ⚠️"
            case "flashing": st = "完成"
            case "idle": st = "空闲"
            case "notRunning": st = "未运行"
            default: st = "—"
            }
            var t = "\(s.name): \(st)"
            if !s.detailText.isEmpty { t += " \(s.detailText)" }
            it.title = t
        }
        for it in menu.items {
            if it.title == "暂停监控" || it.title == "恢复监控" { it.title = paused ? "恢复监控" : "暂停监控" }
            if it.title == "开机自动启动" || it.title == "取消开机自动启动" { it.title = autoStartInstalled() ? "取消开机自动启动" : "开机自动启动" }
        }
        let awaiting = snaps.contains { $0.stateKey == "awaiting" }
        let working = snaps.contains { $0.stateKey == "working" }
        let flashing = snaps.contains { $0.stateKey == "flashing" }
        let color: NSColor = awaiting ? .systemRed : (flashing ? .systemOrange : (working ? .systemGreen : .systemGray))
        statusItem.button?.image = makeIcon(color: color)
    }

    // MARK: - 轮询与聚合
    private func tick() {
        if paused { return }
        for m in monitors {
            m.tick(enterSeconds: config.enterSeconds, exitSeconds: config.exitSeconds,
                   awaitingSeconds: config.awaitingSeconds,
                   awaitingEnterSeconds: config.awaitingEnterSeconds,
                   flashCount: config.flashCount) {
                DispatchQueue.main.async { [weak self] in self?.refreshUI() }
            }
        }
        refreshUI()
    }

    private func snapshots() -> [AppSnapshot] {
        monitors.map { $0.snapshot() }
    }

    /// 一级详情只显示"正在运行"的应用, 有活动优先, 最多 maxActive 个
    private func activeSnapshots() -> [AppSnapshot] {
        let running = snapshots().filter { $0.stateKey != "notRunning" }
        let priority: [String: Int] = Dictionary(uniqueKeysWithValues: config.apps.enumerated().map { ($0.element.name, $0.offset) })
        let sorted = running.sorted { a, b in
            let aw = a.stateKey != "idle"
            let bw = b.stateKey != "idle"
            if aw != bw { return aw }
            return (priority[a.name] ?? 99) < (priority[b.name] ?? 99)
        }
        return Array(sorted.prefix(config.maxActive))
    }

    private func refreshUI() {
        let snaps = snapshots()
        updateCompact(snaps)
        updateMenuUI()
        touchBar.updateDetail(snapshots: activeSnapshots())
        if let name = selectedAppName, let s = snaps.first(where: { $0.name == name }) {
            touchBar.updateAppDetail(snapshot: s)
        }
    }

    /// 常驻项: 空闲 / 进行中(阿拉伯数字 N 个) / 等待(红) / 完成闪烁
    private func updateCompact(_ snaps: [AppSnapshot]) {
        if paused { touchBar.set(state: .paused); return }
        // 等待确认/权限: 红色提醒 (优先)
        if let awaiting = snaps.first(where: { $0.stateKey == "awaiting" }) {
            touchBar.set(state: .awaiting, cpu: awaiting.name)
            return
        }
        if snaps.contains(where: { $0.stateKey == "flashing" }) {
            touchBar.set(state: .flashing)
            return
        }
        let working = snaps.filter { $0.stateKey == "working" }
        if working.isEmpty {
            let anyRunning = snaps.contains { $0.stateKey != "notRunning" }
            touchBar.set(state: anyRunning ? .idle : .notRunning)
            return
        }
        // 进行中: 阿拉伯数字几个任务 (不显示步骤/思考字样)
        touchBar.set(state: .working, cpu: "\(working.count)个")
    }

    private func scheduleAutoDismiss() {
        autoDismissTimer?.invalidate()
        autoDismissTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.touchBar.dismissDetail()
        }
    }

    // MARK: - 菜单动作
    @objc private func testDisplay() {
        log("手动测试状态条")
        touchBar.flash(times: 3) {}
    }

    @objc private func toggleDetailMenu() {
        touchBar.toggleDetail(snapshots: activeSnapshots())
        scheduleAutoDismiss()
    }

    @objc private func togglePause() {
        paused.toggle()
        log(paused ? "已暂停" : "已恢复")
        refreshUI()
    }

    @objc private func toggleAutoStart() {
        if autoStartInstalled() { uninstallAutoStart() } else { installAutoStart() }
        updateMenuUI()
    }

    private func autoStartPlistPath() -> String {
        return NSString(string: "~/Library/LaunchAgents/com.aistatusbar.plist").expandingTildeInPath
    }
    private func autoStartInstalled() -> Bool {
        return FileManager.default.fileExists(atPath: autoStartPlistPath())
    }
    private func installAutoStart() {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.aistatusbar</string>
            <key>ProgramArguments</key>
            <array><string>\(Bundle.main.executablePath!)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
        </dict>
        </plist>
        """
        let path = autoStartPlistPath()
        do {
            try plist.write(toFile: path, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["load", "-w", path]
            try p.run()
            p.waitUntilExit()
            log("开机自启已开启")
        } catch {
            log("自启安装失败: \(error)")
        }
    }
    private func uninstallAutoStart() {
        let path = autoStartPlistPath()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["unload", "-w", path]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: path)
        log("开机自启已关闭")
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

// TouchBarController.swift — AI Statusbar 控制条 + 两级详情面板
// 常驻项: 空闲/进行中数字/等待确认(红)/完成闪烁
// 一级详情: 各活跃 AI 一栏 (名称/状态/并发数/步骤), 点击某栏进入二级
// 二级详情: 任务进度(动画条+已完成步数) + 免费额度进度条(估算) + 快用完提醒
// 原理: 公开 API NSTouchBarItem.addSystemTrayItem + DFRFoundation 私有函数
//       DFRElementSetControlStripPresenceForIdentifier (dlsym 动态调用)
//       详情面板: NSTouchBar 类方法 presentSystemModalTouchBar:systemTrayItemIdentifier: (MTMR 同款)
import AppKit
import Foundation

typealias DFRElementSetControlStripPresenceFn = @convention(c) (CFString, Bool) -> Void
typealias PresentModalFn = @convention(c) (AnyObject, Selector, NSTouchBar, NSTouchBarItem.Identifier) -> Void
typealias DismissModalFn = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void

enum TBState {
    case idle        // 空闲
    case working     // 进行中 (显示阿拉伯数字)
    case awaiting    // 等待确认/权限 (红色)
    case flashing    // 完成闪烁
    case notRunning  // 全部未运行
    case paused      // 用户暂停
}

/// 简单进度条 (轨道+填充, 可换色)
final class ProgressBarView: NSView {
    private let track = NSView()
    private let fill = NSView()
    private var fillWidth: NSLayoutConstraint!

    var fraction: CGFloat = 0 { didSet { needsLayout = true } }
    var color: NSColor = .systemGreen {
        didSet { fill.layer?.backgroundColor = color.cgColor }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        track.layer?.cornerRadius = 3
        fill.wantsLayer = true
        fill.layer?.cornerRadius = 3
        fill.layer?.backgroundColor = color.cgColor
        track.translatesAutoresizingMaskIntoConstraints = false
        fill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        addSubview(fill)
        fillWidth = fill.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: leadingAnchor),
            track.trailingAnchor.constraint(equalTo: trailingAnchor),
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            fillWidth,
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        fillWidth.constant = max(0, min(1, fraction)) * bounds.width
    }
}

final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let identifier = NSTouchBarItem.Identifier("com.aistatusbar.status")

    /// 点击常驻项的开关回调
    var onToggle: (() -> Void)?
    /// 一级详情点击某 AI 栏回调 (参数: 应用名)
    var onTileTap: ((String) -> Void)?
    /// 二级详情"返回"回调
    var onBack: (() -> Void)?
    private(set) var isDetailPresented = false
    private(set) var currentLevel = 0     // 0=收起 1=一级 2=二级

    private var button: NSButton?
    private var item: NSCustomTouchBarItem?
    private var setPresence: DFRElementSetControlStripPresenceFn?
    private var presentModal: PresentModalFn?
    private var dismissModal: DismissModalFn?

    // 详情面板
    private var detailBar: NSTouchBar?
    private var snapshotsByName: [String: AppSnapshot] = [:]
    private var tileButtons: [String: NSButton] = [:]
    private var appDetail: AppSnapshot?
    private let backId = NSTouchBarItem.Identifier("com.aistatusbar.back")
    private let closeId = NSTouchBarItem.Identifier("com.aistatusbar.close")
    private let titleId = NSTouchBarItem.Identifier("com.aistatusbar.title")
    private let taskId = NSTouchBarItem.Identifier("com.aistatusbar.task")
    private let quotaId = NSTouchBarItem.Identifier("com.aistatusbar.quota")
    private var detailTitleLabel: NSTextField?
    private var taskStepsLabel: NSTextField?
    private var taskBar: NSProgressIndicator?
    private var quotaBar: ProgressBarView?
    private var quotaLabel: NSTextField?

    // 保活: 系统 DFR 重配置(睡眠唤醒/设置变更/外接显示切换)会清掉第三方控制条项目
    private var keepAliveTimer: Timer?
    private var presenceTicks = 0
    private var lastState: TBState = .idle
    private var lastCPU = ""

    // MARK: - 私有 API 加载
    private func loadDFR() {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW) else {
            NSLog("DFRFoundation dlopen failed")
            return
        }
        if let p = dlsym(h, "DFRElementSetControlStripPresenceForIdentifier") {
            setPresence = unsafeBitCast(p, to: DFRElementSetControlStripPresenceFn.self)
        }
    }

    private func loadSystemModal() {
        let presentSel = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
        if let m = class_getClassMethod(NSTouchBar.self, presentSel) {
            presentModal = unsafeBitCast(method_getImplementation(m), to: PresentModalFn.self)
        }
        let dismissSel = NSSelectorFromString("dismissSystemModalTouchBar:")
        if let m = class_getClassMethod(NSTouchBar.self, dismissSel) {
            dismissModal = unsafeBitCast(method_getImplementation(m), to: DismissModalFn.self)
        }
    }

    private func invokeSystemTray(_ selectorName: String, item: NSTouchBarItem) {
        let sel = NSSelectorFromString(selectorName)
        guard let method = class_getClassMethod(NSTouchBarItem.self, sel) else { return }
        let imp = method_getImplementation(method)
        typealias Fn = @convention(c) (AnyClass, Selector, NSTouchBarItem) -> Void
        let fn = unsafeBitCast(imp, to: Fn.self)
        fn(NSTouchBarItem.self, sel, item)
    }

    // MARK: - 常驻控制条项目
    func install() {
        loadDFR()
        loadSystemModal()
        let btn = NSButton()
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.font = .systemFont(ofSize: 11, weight: .semibold)
        btn.attributedTitle = makeTitle(text: "空闲", color: .systemGray)
        btn.target = self
        btn.action = #selector(handleTap)
        button = btn

        let custom = NSCustomTouchBarItem(identifier: Self.identifier)
        custom.view = btn
        item = custom

        invokeSystemTray("addSystemTrayItem:", item: custom)
        setPresence?(Self.identifier.rawValue as CFString, true)
        NSLog("AIStatusbar item installed; presentModal=\(presentModal != nil), dismissModal=\(dismissModal != nil)")
        startKeepAlive()
    }

    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.presenceKeepAlive()
        }
    }

    func uninstall() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        dismissDetail()
        if let it = item {
            invokeSystemTray("removeSystemTrayItem:", item: it)
            setPresence?(Self.identifier.rawValue as CFString, false)
        }
        item = nil
        button = nil
    }

    private func presenceKeepAlive() {
        presenceTicks += 1
        setPresence?(Self.identifier.rawValue as CFString, true)
        if presenceTicks % 12 == 0 {
            reregisterItem()
        }
    }

    private func reregisterItem() {
        if let old = item {
            invokeSystemTray("removeSystemTrayItem:", item: old)
        }
        let btn = NSButton()
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.font = .systemFont(ofSize: 11, weight: .semibold)
        btn.target = self
        btn.action = #selector(handleTap)
        button = btn
        let custom = NSCustomTouchBarItem(identifier: Self.identifier)
        custom.view = btn
        item = custom
        invokeSystemTray("addSystemTrayItem:", item: custom)
        setPresence?(Self.identifier.rawValue as CFString, true)
        applyLastState()
        NSLog("AIStatusbar item re-registered (keep-alive)")
    }

    private func applyLastState() {
        let (text, color) = stateDisplay(lastState, cpu: lastCPU)
        setText(text, color: color)
    }

    @objc private func handleTap() {
        onToggle?()
    }

    // MARK: - 常驻项显示
    private func makeTitle(text: String, color: NSColor) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color,
        ]
        return NSAttributedString(string: "● \(text)", attributes: attrs)
    }

    private func setText(_ text: String, color: NSColor) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let btn = self.button else { return }
            btn.attributedTitle = self.makeTitle(text: text, color: color)
        }
    }

    private func stateDisplay(_ state: TBState, cpu: String) -> (String, NSColor) {
        switch state {
        case .idle: return ("空闲", .systemGray)
        case .working: return (cpu.isEmpty ? "进行" : cpu, .systemGreen)
        case .awaiting: return ("等待", .systemRed)
        case .flashing: return ("完成", .systemOrange)
        case .notRunning: return ("未运行", .systemGray)
        case .paused: return ("暂停", .systemGray)
        }
    }

    func set(state: TBState, cpu: String = "") {
        lastState = state
        lastCPU = cpu
        let (text, color) = stateDisplay(state, cpu: cpu)
        setText(text, color: color)
    }

    func flash(times: Int, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            for _ in 0..<times {
                self.setText("完成", color: .systemOrange)
                usleep(240_000)
                self.setText("完成", color: .systemGray)
                usleep(240_000)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - 详情面板 (一级/二级)
    private func tileId(_ name: String) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("com.aistatusbar.tile." + name)
    }

    /// 一级详情: 各活跃 AI 一栏
    func presentDetail(snapshots: [AppSnapshot]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.snapshotsByName = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.name, $0) })
            self.tileButtons.removeAll()
            self.appDetail = nil
            var ids = snapshots.map { self.tileId($0.name) }
            ids.append(.fixedSpaceSmall)
            ids.append(self.closeId)
            self.switchModal(ids: ids)
            self.currentLevel = 1
        }
    }

    /// 二级详情: 某 AI 的任务进度 + 额度进度
    func presentAppDetail(snapshot: AppSnapshot) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.appDetail = snapshot
            var ids: [NSTouchBarItem.Identifier] = [self.backId, .fixedSpaceSmall, self.titleId, .flexibleSpace]
            ids.append(self.taskId)
            if snapshot.quotaLimit > 0 { ids.append(self.quotaId) }
            ids.append(.flexibleSpace)
            ids.append(self.closeId)
            self.switchModal(ids: ids)
            self.currentLevel = 2
        }
    }

    func dismissDetail() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let bar = self.detailBar else { return }
            if let f = self.dismissModal {
                f(NSTouchBar.self, NSSelectorFromString("dismissSystemModalTouchBar:"), bar)
            }
            self.detailBar = nil
            self.tileButtons.removeAll()
            self.appDetail = nil
            self.isDetailPresented = false
            self.currentLevel = 0
            NSLog("AIStatusbar detail dismissed")
        }
    }

    func toggleDetail(snapshots: [AppSnapshot]) {
        if isDetailPresented || detailBar != nil {
            dismissDetail()
        } else {
            presentDetail(snapshots: snapshots)
        }
    }

    /// 收起当前面板并展示新面板 (DFR 模态需先 dismiss 再 present)
    private func switchModal(ids: [NSTouchBarItem.Identifier]) {
        if let bar = detailBar, let f = dismissModal {
            f(NSTouchBar.self, NSSelectorFromString("dismissSystemModalTouchBar:"), bar)
        }
        detailBar = nil
        let newBar = NSTouchBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self else { return }
            newBar.delegate = self
            newBar.defaultItemIdentifiers = ids
            self.detailBar = newBar
            if let f = self.presentModal {
                f(NSTouchBar.self, NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:"), newBar, Self.identifier)
                self.isDetailPresented = true
                NSLog("AIStatusbar detail presented (level \(self.currentLevel), \(ids.count) items)")
            }
        }
    }

    /// 刷新一级详情 (每轮询)
    func updateDetail(snapshots: [AppSnapshot]) {
        guard detailBar != nil, currentLevel == 1 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.snapshotsByName = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.name, $0) })
            for s in snapshots {
                if let btn = self.tileButtons[s.name] {
                    btn.attributedTitle = self.tileTitle(snapshot: s)
                }
            }
        }
    }

    /// 刷新二级详情 (每轮询)
    func updateAppDetail(snapshot: AppSnapshot) {
        guard detailBar != nil, currentLevel == 2 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.appDetail = snapshot
            self.detailTitleLabel?.stringValue = "\(snapshot.name) · \(self.statusWord(snapshot))"
            self.taskStepsLabel?.stringValue = "已完成 \(snapshot.steps) 步"
            if let q = self.quotaBar, let ql = self.quotaLabel {
                self.applyQuota(snapshot: snapshot, bar: q, label: ql)
            }
        }
    }

    // MARK: - 详情面板 delegate
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == backId {
            let it = NSCustomTouchBarItem(identifier: identifier)
            let b = NSButton(title: "← 返回", target: self, action: #selector(handleBack))
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            it.view = b
            return it
        }
        if identifier == closeId {
            let it = NSCustomTouchBarItem(identifier: identifier)
            let b = NSButton(title: "关闭", target: self, action: #selector(handleClose))
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            it.view = b
            return it
        }
        if identifier == titleId {
            let it = NSCustomTouchBarItem(identifier: identifier)
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 15, weight: .bold)
            detailTitleLabel = label
            it.view = label
            if let s = appDetail { label.stringValue = "\(s.name) · \(statusWord(s))" }
            return it
        }
        if identifier == taskId {
            let it = NSCustomTouchBarItem(identifier: identifier)
            let nameL = NSTextField(labelWithString: "任务进度")
            nameL.font = .systemFont(ofSize: 11, weight: .semibold)
            let bar = NSProgressIndicator()
            bar.style = .bar
            bar.isIndeterminate = true
            bar.controlSize = .small
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 170),
                bar.heightAnchor.constraint(equalToConstant: 10),
            ])
            bar.startAnimation(nil)
            taskBar = bar
            let stepsL = NSTextField(labelWithString: "")
            stepsL.font = .systemFont(ofSize: 11)
            stepsL.textColor = .secondaryLabelColor
            taskStepsLabel = stepsL
            let stack = NSStackView(views: [nameL, bar, stepsL])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 3
            it.view = stack
            if let s = appDetail { stepsL.stringValue = "已完成 \(s.steps) 步" }
            return it
        }
        if identifier == quotaId {
            let it = NSCustomTouchBarItem(identifier: identifier)
            let nameL = NSTextField(labelWithString: "免费额度（估算）")
            nameL.font = .systemFont(ofSize: 11, weight: .semibold)
            let bar = ProgressBarView(frame: .zero)
            bar.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 170),
                bar.heightAnchor.constraint(equalToConstant: 10),
            ])
            quotaBar = bar
            let statusL = NSTextField(labelWithString: "")
            statusL.font = .systemFont(ofSize: 11)
            quotaLabel = statusL
            let stack = NSStackView(views: [nameL, bar, statusL])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 3
            it.view = stack
            if let s = appDetail { applyQuota(snapshot: s, bar: bar, label: statusL) }
            return it
        }
        // 一级详情 tile
        let name = identifier.rawValue.replacingOccurrences(of: "com.aistatusbar.tile.", with: "")
        guard let snap = snapshotsByName[name] else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        let btn = NSButton()
        btn.isBordered = false
        btn.bezelStyle = .regularSquare
        btn.attributedTitle = tileTitle(snapshot: snap)
        btn.target = self
        btn.action = #selector(handleTileTap(_:))
        tileNameByButton[btn] = name
        tileButtons[name] = btn
        item.view = btn
        return item
    }

    @objc private func handleBack() { onBack?() }
    @objc private func handleClose() { dismissDetail() }
    @objc private func handleTileTap(_ sender: NSButton) {
        guard let name = tileNameByButton[sender] else { return }
        onTileTap?(name)
    }

    private var tileNameByButton: [NSButton: String] = [:]
    private func tileTitle(snapshot: AppSnapshot) -> NSAttributedString {
        let status = statusWord(snapshot)
        let stateColor = colorFor(snapshot)
        var info = status
        if !snapshot.detailText.isEmpty { info += " · " + snapshot.detailText }

        let s = NSMutableAttributedString(string: "● \(snapshot.name)\n\(info)")
        let full = NSRange(location: 0, length: s.length)
        s.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: full)
        s.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        // 第一行: 圆点用状态色, 应用名黑色
        let line1Len = "● \(snapshot.name)".utf16.count
        s.addAttribute(.foregroundColor, value: stateColor, range: NSRange(location: 0, length: 1))  // ●
        s.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 2, length: line1Len - 2))
        // 第二行: 状态色 + 小字
        let line2 = NSRange(location: line1Len + 1, length: s.length - line1Len - 1)
        s.addAttribute(.foregroundColor, value: stateColor, range: line2)
        s.addAttribute(.font, value: NSFont.systemFont(ofSize: 10.5), range: line2)
        return s
    }

    private func statusWord(_ s: AppSnapshot) -> String {
        switch s.stateKey {
        case "working": return s.children > 0 ? "执行中" : "思考中"
        case "awaiting": return "等待确认"
        case "flashing": return s.flashOn ? "完成" : "完成"
        case "idle": return "空闲"
        case "notRunning": return "未运行"
        default: return ""
        }
    }

    private func applyQuota(snapshot: AppSnapshot, bar: ProgressBarView, label: NSTextField) {
        guard snapshot.quotaLimit > 0 else { return }
        let frac = CGFloat(snapshot.quotaUsed) / CGFloat(snapshot.quotaLimit)
        bar.fraction = frac
        if frac >= 0.9 {
            bar.color = .systemRed
            label.textColor = .systemRed
            label.stringValue = "已用 \(snapshot.quotaUsed)/\(snapshot.quotaLimit) \(snapshot.quotaUnit) · 即将用完，记得用掉！"
        } else if frac >= 0.75 {
            bar.color = .systemOrange
            label.textColor = .systemOrange
            label.stringValue = "已用 \(snapshot.quotaUsed)/\(snapshot.quotaLimit) \(snapshot.quotaUnit) · 快用完了，记得用掉"
        } else {
            bar.color = .systemGreen
            label.textColor = .secondaryLabelColor
            label.stringValue = "已用 \(snapshot.quotaUsed)/\(snapshot.quotaLimit) \(snapshot.quotaUnit)"
        }
    }

    private func colorFor(_ s: AppSnapshot) -> NSColor {
        switch s.stateKey {
        case "working": return .systemGreen
        case "awaiting": return .systemRed
        case "flashing": return .systemOrange
        case "notRunning": return .systemGray
        default: return .systemGray
        }
    }
}

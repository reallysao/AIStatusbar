// TouchBarController.swift — AI Statusbar 控制条 + 一级详情面板
// 常驻项: 空闲/进行中数字/等待确认(红)/完成闪烁
// 详情面板: 各活跃 AI 一栏 (名称/状态/并发数/步骤), 只保留 AI 状态显示
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

final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let identifier = NSTouchBarItem.Identifier("com.aistatusbar.status")

    /// 点击常驻项的开关回调
    var onToggle: (() -> Void)?
    private(set) var isDetailPresented = false

    private var button: NSButton?
    private var item: NSCustomTouchBarItem?
    private var setPresence: DFRElementSetControlStripPresenceFn?
    private var presentModal: PresentModalFn?
    private var dismissModal: DismissModalFn?

    // 详情面板
    private var detailBar: NSTouchBar?
    private var snapshotsByName: [String: AppSnapshot] = [:]
    private var detailLabels: [String: (label: NSTextField, dot: NSView)] = [:]
    private let closeId = NSTouchBarItem.Identifier("com.aistatusbar.close")

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
        let key = text + "\u{0}" + color.description
        if key == lastTitleKey { return }   // 内容没变则跳过, 避免每 tick 重绘
        lastTitleKey = key
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let btn = self.button else { return }
            btn.attributedTitle = self.makeTitle(text: text, color: color)
        }
    }

    private var lastTitleKey = ""

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

    // MARK: - 详情面板 (一级: 各活跃 AI 一栏)
    private func tileId(_ name: String) -> NSTouchBarItem.Identifier {
        NSTouchBarItem.Identifier("com.aistatusbar.tile." + name)
    }

    func presentDetail(snapshots: [AppSnapshot]) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.snapshotsByName = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.name, $0) })
            self.detailLabels.removeAll()
            var ids = snapshots.map { self.tileId($0.name) }
            ids.append(.fixedSpaceSmall)
            ids.append(self.closeId)
            self.switchModal(ids: ids)
        }
    }

    func dismissDetail() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let bar = self.detailBar else { return }
            if let f = self.dismissModal {
                f(NSTouchBar.self, NSSelectorFromString("dismissSystemModalTouchBar:"), bar)
            }
            self.detailBar = nil
            self.detailLabels.removeAll()
            self.isDetailPresented = false
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
                NSLog("AIStatusbar detail presented (\(ids.count) items)")
            }
        }
    }

    /// 刷新详情面板 (每轮询)
    func updateDetail(snapshots: [AppSnapshot]) {
        guard detailBar != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.snapshotsByName = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.name, $0) })
            for s in snapshots {
                if let (label, dot) = self.detailLabels[s.name] {
                    self.apply(snapshot: s, to: label, dot: dot)
                }
            }
        }
    }

    // MARK: - 详情面板 delegate
    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        if identifier == closeId {
            let it = NSCustomTouchBarItem(identifier: identifier)
            let b = NSButton(title: "关闭", target: self, action: #selector(handleClose))
            b.font = .systemFont(ofSize: 12, weight: .semibold)
            it.view = b
            return it
        }
        let name = identifier.rawValue.replacingOccurrences(of: "com.aistatusbar.tile.", with: "")
        guard let snap = snapshotsByName[name] else { return nil }

        let item = NSCustomTouchBarItem(identifier: identifier)
        let tile = makeTile(snapshot: snap)
        item.view = tile.view
        detailLabels[name] = (tile.label, tile.dot)
        return item
    }

    @objc private func handleClose() {
        dismissDetail()
    }

    private func makeTile(snapshot: AppSnapshot) -> (view: NSView, label: NSTextField, dot: NSView) {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
        ])

        let nameL = NSTextField(labelWithString: snapshot.name)
        nameL.font = .systemFont(ofSize: 13, weight: .semibold)

        let infoL = NSTextField(labelWithString: "")
        infoL.font = .systemFont(ofSize: 11)
        infoL.textColor = .secondaryLabelColor
        infoL.lineBreakMode = .byTruncatingTail
        infoL.maximumNumberOfLines = 1

        let textStack = NSStackView(views: [nameL, infoL])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        let stack = NSStackView(views: [dot, textStack])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 150),
        ])
        apply(snapshot: snapshot, to: infoL, dot: dot)
        return (stack, infoL, dot)
    }

    private func statusWord(_ s: AppSnapshot) -> String {
        switch s.stateKey {
        case "working": return s.children > 0 ? "执行中" : "思考中"
        case "awaiting": return "等待确认"
        case "flashing": return "完成"
        case "idle": return "空闲"
        case "notRunning": return "未运行"
        default: return ""
        }
    }

    private func apply(snapshot: AppSnapshot, to label: NSTextField, dot: NSView) {
        dot.layer?.backgroundColor = colorFor(snapshot).cgColor
        var text = statusWord(snapshot)
        if !snapshot.detailText.isEmpty { text += " · \(snapshot.detailText)" }
        label.stringValue = text
        label.textColor = snapshot.stateKey == "working" ? .systemGreen
            : (snapshot.stateKey == "awaiting" ? .systemRed
            : (snapshot.stateKey == "flashing" ? .systemOrange : .secondaryLabelColor))
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

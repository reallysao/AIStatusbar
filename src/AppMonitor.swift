// AppMonitor.swift — 单个被监控应用的状态机与指标采集
// 信号1: 基础设施进程(如 AgentInfraService)的直接子进程 => 并发任务数 (逐个消亡=步骤进度)
// 信号2: 应用全部进程聚合 CPU% 超过阈值 => 正在思考/生成 (仅无子进程活动时才计算 CPU, 省开销)
// 状态机: 空闲 → 连续enter秒工作 → 工作中 → 连续无活动 → 等待确认(红色) → 持续无活动 → 闪烁 → 空闲
// 进程表: 复用 ProcessTable.shared (每 tick 全系统只枚举一次)
import Foundation
import Darwin

enum AppState {
    case idle
    case pendingUp(Int)
    case working
    case pendingDown(Int)
    case awaiting(Int)      // 等待用户确认/权限 (红色提醒)
    case flashing
}

/// 展示快照 (UI 无关, 由 UI 层映射颜色)
struct AppSnapshot {
    let name: String
    let stateKey: String   // idle / working / awaiting / flashing / notRunning
    let cpuText: String
    let detailText: String
    let flashOn: Bool
    let children: Int      // 当前并发任务数
    let steps: Int         // 本次任务已完成步骤数
}

final class AppMonitor {
    let config: AppConfig
    private(set) var state: AppState = .idle
    private(set) var cpu = 0.0
    private(set) var children = 0
    private(set) var flashOn = false
    private(set) var stepsCompleted = 0

    /// 展示刷新回调 (闪烁期间 240ms 高频触发, 需自行切主线程)
    var onDisplay: (() -> Void)?

    private var prevCPUTime: [pid_t: UInt64] = [:]
    private var prevSampleTime: UInt64 = 0
    private var prevChildPIDs: Set<pid_t> = []

    init(config: AppConfig) { self.config = config }

    private var table: ProcessTable { ProcessTable.shared }

    func appPIDs() -> Set<pid_t> {
        table.pids(matching: config.processes)
    }

    func infraPID() -> pid_t? {
        table.firstPID(matching: config.infraProcesses)
    }

    /// 基础设施下的活动直接子进程 PID 集合
    /// 豆包: AgentInfraService 的直接子进程都是 /bin/bash, 每个 = 一个正在执行的工具调用
    func activeTaskPIDs() -> Set<pid_t> {
        guard let pid = infraPID() else { return [] }
        return Set(table.directChildren(of: pid).map { $0.pid })
    }

    /// 是否有任意活动子进程 (工具执行阶段信号)
    func hasInfraActivity() -> Bool {
        guard let pid = infraPID() else { return false }
        return !table.descendants(of: pid).isEmpty
    }

    /// 应用全部进程聚合 CPU% (可超 100)
    func cpuPercent() -> Double {
        let now = mach_absolute_time()
        var total: Double = 0
        let pids = appPIDs()
        for p in table.all where pids.contains(p.pid) {
            var info = proc_taskinfo()
            let r = proc_pidinfo(p.pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
            guard r > 0 else { continue }
            let t = info.pti_total_user &+ info.pti_total_system
            if let prev = prevCPUTime[p.pid], prevSampleTime != 0 {
                let dt = t &- prev
                let elapsed = now &- prevSampleTime
                if elapsed > 0 {
                    var tb = mach_timebase_info_data_t()
                    mach_timebase_info(&tb)
                    let elapsedNs = Double(elapsed) * Double(tb.numer) / Double(tb.denom)
                    total += Double(dt) / elapsedNs * 100.0
                }
            }
            prevCPUTime[p.pid] = t
        }
        prevSampleTime = now
        return total
    }

    func appRunning() -> Bool {
        !appPIDs().isEmpty
    }

    /// 综合判断: 有活动子进程 => 工作中 (免算 CPU); 否则看聚合 CPU 是否超阈值
    func isWorking() -> Bool {
        children = activeTaskPIDs().count
        if children > 0 || hasInfraActivity() {
            return true
        }
        cpu = cpuPercent()
        return cpu > config.cpuThreshold
    }

    // MARK: - 状态机 (由主定时器驱动)
    func tick(enterSeconds: Int, awaitingSeconds: Int, awaitingEnterSeconds: Int,
              flashCount: Int, onFlashEnd: @escaping () -> Void) {
        if case .flashing = state { return }
        let currentChildPIDs = activeTaskPIDs()
        let working = isWorking()

        if !appRunning() {
            if case .idle = state {} else {
                log("[\(config.name)] 未运行 -> 空闲")
                state = .idle
            }
            stepsCompleted = 0
            prevChildPIDs = []
            return
        }

        // 步骤计数: 上一轮还在、这一轮消失的直接子进程 = 完成的工具调用 (逐个计数, 支持并发)
        let midTask: Bool
        switch state {
        case .working, .pendingDown, .awaiting: midTask = true
        default: midTask = false
        }
        if midTask {
            let completed = prevChildPIDs.subtracting(currentChildPIDs)
            if !completed.isEmpty {
                stepsCompleted += completed.count
                log("[\(config.name)] 完成 \(completed.count) 步, 累计 \(stepsCompleted) 步")
            }
        }

        switch state {
        case .idle:
            if working {
                state = .pendingUp(1)
                log("[\(config.name)] 检测到工作信号 (children=\(children), cpu=\(String(format: "%.1f", cpu))%)")
            }
        case .pendingUp(let n):
            if working {
                if n + 1 >= enterSeconds {
                    state = .working
                    stepsCompleted = 0
                    prevChildPIDs = []
                    log("[\(config.name)] → 工作开始")
                } else {
                    state = .pendingUp(n + 1)
                }
            } else {
                state = .idle
            }
        case .working:
            if !working {
                state = .pendingDown(1)
                log("[\(config.name)] 工作信号消失, 等待恢复 (children=\(children), cpu=\(String(format: "%.1f", cpu))%)")
            }
        case .pendingDown(let n):
            if working {
                state = .working
            } else {
                // 分级阈值: 任务已完成过步骤 => 处于多步任务中间, 思考/工具间隙更长, 放宽到 3 倍;
                // 一步未完成就长时间无活动 => 更可能是刚启动就等确认/权限, 用基础阈值
                let threshold = stepsCompleted > 0 ? awaitingEnterSeconds * 3 : awaitingEnterSeconds
                if n + 1 >= threshold {
                    // 无活动持续超过阈值: 可能卡在等待确认/权限, 进入红色提醒
                    state = .awaiting(1)
                    log("[\(config.name)] → 等待确认/权限 (红色提醒, 已无活动 \(n + 1) 秒)")
                } else {
                    state = .pendingDown(n + 1)
                }
            }
        case .awaiting(let n):
            if working {
                state = .working
                log("[\(config.name)] 恢复活动, 回到工作中")
            } else if n + 1 >= awaitingSeconds {
                state = .flashing
                log("[\(config.name)] → 任务结束, 闪烁")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    guard let self = self else { return }
                    for _ in 0..<flashCount {
                        self.flashOn = true
                        self.onDisplay?()
                        usleep(240_000)
                        self.flashOn = false
                        self.onDisplay?()
                        usleep(240_000)
                    }
                    self.flashOn = false
                    self.state = .idle
                    self.stepsCompleted = 0
                    self.prevChildPIDs = []
                    onFlashEnd()
                }
            } else {
                state = .awaiting(n + 1)
            }
        default:
            break
        }
        prevChildPIDs = currentChildPIDs
    }

    // MARK: - 展示快照
    func snapshot() -> AppSnapshot {
        let cpuText = String(format: "%.0f%%", cpu)
        var detailParts: [String] = []
        if children > 0 { detailParts.append("并发 \(children)") }
        if stepsCompleted > 0 { detailParts.append("步骤 \(stepsCompleted)") }
        // 无基础设施的应用(如 ChatGPT)没有并发/步骤信号, 用 CPU 作为活动指标
        if config.infraProcesses.isEmpty { detailParts.append(cpuText) }

        let stateKey: String
        switch state {
        case .flashing: stateKey = "flashing"
        case .awaiting: stateKey = "awaiting"
        case .working, .pendingUp, .pendingDown: stateKey = "working"
        default: stateKey = appRunning() ? "idle" : "notRunning"
        }
        return AppSnapshot(name: config.name, stateKey: stateKey, cpuText: cpuText,
                           detailText: detailParts.joined(separator: " · "), flashOn: flashOn,
                           children: children, steps: stepsCompleted)
    }
}

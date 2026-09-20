// Config.swift — AI Statusbar 配置与主流 AI 应用自动识别
// 自动识别: 扫描 /Applications 与 ~/Applications, 匹配已知主流 AI 应用表;
//           UI 层只显示"正在运行"的, 最多 maxActive 个
// 手动接管: 在 config.json 里写 apps 数组即可完全自定义监控列表
import Foundation

struct AppConfig {
    var name: String
    var processes: [String]       // .app 包名/进程关键词 (大小写不敏感)
    var infraProcesses: [String]  // 任务基础设施进程 (直接子进程=并发任务, 逐个消亡=步骤)
    var cpuThreshold: Double      // 聚合 CPU% 阈值, 高于视为工作中(思考/生成)
}

struct Config {
    var apps: [AppConfig] = []
    var pollSeconds = 2           // 轮询间隔(秒): 1 秒过密, 2 秒足够且省 CPU
    var enterSeconds = 2
    var exitSeconds = 4
    var flashCount = 3
    var awaitingSeconds = 15      // 进入"等待确认"后, 持续无活动多久视为任务结束(闪烁)
    var awaitingEnterSeconds = 10 // 任务刚启动(一步未完成)时, 无活动多久进入"等待确认"(红色)
                                  // 已跑过多步的任务思考间隙更长, 自动用 3 倍阈值(30s), 避免误报
    var maxActive = 4             // 详情面板最多显示的活跃应用数

    // MARK: - 已知主流 AI 应用表 (含优先级顺序)
    static let knownApps: [AppConfig] = [
        AppConfig(name: "豆包", processes: ["Doubao.app"], infraProcesses: ["AgentInfraService"], cpuThreshold: 15),
        AppConfig(name: "ChatGPT", processes: ["ChatGPT.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "DeepSeek", processes: ["DeepSeek.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "通义千问", processes: ["通义千问.app", "Qianwen.app", "Tongyi.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "Kimi", processes: ["Kimi.app", "Moonshot.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "智谱清言", processes: ["智谱清言.app", "ChatGLM.app", "GLM.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "文心一言", processes: ["文心一言.app", "ERNIE.app", "Wenxin.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "腾讯元宝", processes: ["元宝.app", "Yuanbao.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "Copilot", processes: ["Copilot.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "Claude", processes: ["Claude.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "Gemini", processes: ["Gemini.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "Grok", processes: ["Grok.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "天工", processes: ["Tiangong.app", "天工.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "秘塔", processes: ["Metaso.app", "秘塔.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "讯飞星火", processes: ["讯飞星火.app", "Spark.app"], infraProcesses: [], cpuThreshold: 20),
        AppConfig(name: "Poe", processes: ["Poe.app"], infraProcesses: [], cpuThreshold: 20),
    ]

    /// 自动识别: 默认候选表(含已安装扫描结果), 按 knownApps 优先级排序
    static func autoDiscover() -> [AppConfig] {
        var found: [String: AppConfig] = [:]
        for a in knownApps { found[a.name] = a }

        let dirs = ["/Applications", NSString(string: "~/Applications").expandingTildeInPath]
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                for known in knownApps {
                    for kw in known.processes where item.lowercased() == kw.lowercased() {
                        found[known.name] = known
                    }
                }
            }
        }
        let order = knownApps.map { $0.name }
        return found.values.sorted { a, b in
            let ia = order.firstIndex(of: a.name) ?? 99
            let ib = order.firstIndex(of: b.name) ?? 99
            return ia < ib
        }
    }

    static func load() -> Config {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = dir.appendingPathComponent("AIStatusbar", isDirectory: true)
        let file = folder.appendingPathComponent("config.json")
        var cfg = Config()
        cfg.apps = autoDiscover()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let v = json["pollSeconds"] as? Int, v >= 1 { cfg.pollSeconds = v }
                    if let v = json["enterSeconds"] as? Int { cfg.enterSeconds = v }
                    if let v = json["exitSeconds"] as? Int { cfg.exitSeconds = v }
                    if let v = json["flashCount"] as? Int { cfg.flashCount = v }
                    if let v = json["awaitingSeconds"] as? Int { cfg.awaitingSeconds = v }
                    if let v = json["awaitingEnterSeconds"] as? Int { cfg.awaitingEnterSeconds = v }
                    if let v = json["maxActive"] as? Int, v > 0 { cfg.maxActive = v }

                    // 手动接管: 有 apps 数组则完全采用
                    if let arr = json["apps"] as? [[String: Any]] {
                        var apps: [AppConfig] = []
                        for a in arr {
                            guard let name = a["name"] as? String,
                                  let procs = a["processes"] as? [String], !procs.isEmpty else { continue }
                            apps.append(AppConfig(name: name, processes: procs,
                                                  infraProcesses: a["infraProcesses"] as? [String] ?? [],
                                                  cpuThreshold: a["cpuThreshold"] as? Double ?? 20))
                        }
                        if !apps.isEmpty { cfg.apps = apps }
                    } else if let oldApps = json["apps"] as? [String], !oldApps.isEmpty {
                        // 极旧格式: 字符串数组
                        var apps = autoDiscover()
                        for k in oldApps {
                            if !apps.contains(where: { $0.processes.contains { $0.lowercased() == k.lowercased() } }) {
                                apps.append(AppConfig(name: k.replacingOccurrences(of: ".app", with: ""),
                                                      processes: [k], infraProcesses: json["infraProcesses"] as? [String] ?? [],
                                                      cpuThreshold: json["cpuThreshold"] as? Double ?? 20))
                            }
                        }
                        cfg.apps = apps
                    }
                }
            }
            // 回写规范配置
            let out: [String: Any] = [
                "pollSeconds": cfg.pollSeconds,
                "enterSeconds": cfg.enterSeconds,
                "exitSeconds": cfg.exitSeconds,
                "flashCount": cfg.flashCount,
                "awaitingSeconds": cfg.awaitingSeconds,
                "awaitingEnterSeconds": cfg.awaitingEnterSeconds,
                "maxActive": cfg.maxActive,
                "apps": cfg.apps.map { a -> [String: Any] in
                    var d: [String: Any] = ["name": a.name, "processes": a.processes, "cpuThreshold": a.cpuThreshold]
                    if !a.infraProcesses.isEmpty { d["infraProcesses"] = a.infraProcesses }
                    return d
                },
            ]
            let outData = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
            try outData.write(to: file)
        } catch {
            log("config error: \(error)")
        }
        return cfg
    }
}

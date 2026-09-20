// UsageStore.swift — 工作会话用量持久化 (额度进度条的估算依据)
// 记录: 每个应用每月完成的工作会话数; 额度 = 手动配额上限 vs 已用会话数 (估算, 非官方数据)
import Foundation

final class UsageStore {
    static let shared = UsageStore()

    private let file: URL
    private var usage: [String: [String: Int]] = [:]   // "2026-09" -> appName -> count

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = dir.appendingPathComponent("AIStatusbar", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("usage.json")
        load()
    }

    private func monthKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return f.string(from: Date())
    }

    private func load() {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Int]] else { return }
        usage = json
    }

    private func save() {
        guard let data = try? JSONSerialization.data(withJSONObject: usage, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: file)
    }

    /// 当前月某应用已用会话数
    func used(app: String) -> Int {
        usage[monthKey()]?[app] ?? 0
    }

    /// 记录一次工作会话
    func recordSession(app: String) {
        let m = monthKey()
        var month = usage[m] ?? [:]
        month[app] = (month[app] ?? 0) + 1
        usage[m] = month
        save()
    }
}

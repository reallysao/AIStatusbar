// ProcessTable.swift — 共享系统进程表 (性能关键)
// 背景: 旧实现里每个 AppMonitor 每秒各自 proc_listallpids + 对每个进程 proc_pidpath,
//       16 个监控实例 = 每秒 16 次全量进程枚举, 是 CPU 占用高的主因。
// 优化: 整个 App 每 tick 只枚举一次系统进程表, 所有 AppMonitor 复用;
//       先拿轻量的 bsdinfo(短名/ppid), 只有短名命中监控关键词的进程才取完整路径
//       (proc_pidpath 开销大, 全系统 ~500 进程只对少数候选调用)。
import Foundation
import Darwin

struct ProcInfo {
    let pid: pid_t
    let ppid: pid_t
    let path: String
}

final class ProcessTable {
    static let shared = ProcessTable()

    private(set) var all: [ProcInfo] = []

    /// 短名粗筛关键词 (所有监控应用的 processes + infraProcesses 去 .app 后缀, 小写)
    var nameFilters: [String] = []

    func refresh() {
        var pids = [pid_t](repeating: 0, count: 16384)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }

        // 第一遍: 全量 bsdinfo (轻量), 收集 ppid + 短名, 找出候选进程
        struct Entry { let pid: pid_t; let ppid: pid_t; let name: String }
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var candidates = Set<pid_t>()
        for i in 0..<Int(count) {
            let pid = pids[i]
            var bsd = proc_bsdinfo()
            let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
            if r <= 0 { continue }
            let name = withUnsafeBytes(of: bsd.pbi_name) { raw -> String in
                guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
                return String(cString: base)
            }
            entries.append(Entry(pid: pid, ppid: pid_t(bsd.pbi_ppid), name: name))
            let lower = name.lowercased()
            for f in nameFilters where lower.contains(f) || f.contains(lower) {
                candidates.insert(pid)
                break
            }
        }

        // 第二遍: 仅对候选进程取完整路径
        var list: [ProcInfo] = []
        list.reserveCapacity(entries.count)
        for e in entries {
            var path = ""
            if candidates.contains(e.pid) {
                var pathBuf = [CChar](repeating: 0, count: 4096)
                let len = proc_pidpath(e.pid, &pathBuf, UInt32(pathBuf.count))
                path = len > 0 ? String(cString: pathBuf) : ""
            }
            list.append(ProcInfo(pid: e.pid, ppid: e.ppid, path: path))
        }
        all = list
    }

    /// 路径匹配关键词的进程 PID 集合
    func pids(matching keywords: [String]) -> Set<pid_t> {
        guard !keywords.isEmpty else { return [] }
        var s = Set<pid_t>()
        for p in all {
            let lp = p.path.lowercased()
            for kw in keywords where lp.contains(kw.lowercased()) {
                s.insert(p.pid)
                break
            }
        }
        return s
    }

    func firstPID(matching keywords: [String]) -> pid_t? {
        for p in all {
            let lp = p.path.lowercased()
            for kw in keywords where lp.contains(kw.lowercased()) { return p.pid }
        }
        return nil
    }

    func directChildren(of root: pid_t) -> [ProcInfo] {
        all.filter { $0.ppid == root }
    }

    func descendants(of root: pid_t) -> Set<pid_t> {
        var result = Set<pid_t>()
        var frontier = [root]
        while !frontier.isEmpty {
            let parent = frontier.removeLast()
            for p in all where p.ppid == parent && p.pid != parent {
                if !result.contains(p.pid) {
                    result.insert(p.pid)
                    frontier.append(p.pid)
                }
            }
        }
        return result
    }
}

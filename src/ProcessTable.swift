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
    let pathBytes: [UInt8]   // 小写字节 (ASCII 转小写, 高位原样), 供快速匹配
}

final class ProcessTable {
    static let shared = ProcessTable()

    private(set) var all: [ProcInfo] = []

    /// 短名粗筛关键词 (所有监控应用的 processes + infraProcesses 去 .app 后缀, 小写)
    /// 注意: 匹配用字节级实现, 避免每 tick 创建 600 个 String 的开销(实测 ~30ms/tick)
    var nameFilters: [String] = [] {
        didSet { byteFilters = nameFilters.map { Array($0.lowercased().utf8) } }
    }
    private var byteFilters: [[UInt8]] = []

    /// 路径缓存: 进程路径稳定不变, 只在新出现的候选进程上取一次 proc_pidpath (开销大)
    private var pathCache: [pid_t: String] = [:]

    /// 字节级子串匹配 (haystack/needle 均为小写 ASCII 或原样高位字节)
    private func bytesContains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        if needle.isEmpty || needle.count > hay.count { return false }
        let limit = hay.count - needle.count
        var i = 0
        while i <= limit {
            var j = 0
            while j < needle.count && hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
            i += 1
        }
        return false
    }

    /// 把短名原始字节转小写 (仅 ASCII 大写转小写, 高位字节原样保留以支持中文)
    private func lowerASCII(_ bytes: [UInt8]) -> [UInt8] {
        var out = bytes
        for i in out.indices where out[i] >= 0x41 && out[i] <= 0x5A {
            out[i] = out[i] &+ 0x20
        }
        return out
    }

    func refresh() {
        var pids = [pid_t](repeating: 0, count: 16384)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return }

        // 第一遍: 全量 bsdinfo (轻量), 收集 ppid + 短名, 字节级粗筛候选进程
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
            // 字节级匹配: 短名 bytes(小写) vs 每个 filter bytes
            let nameBytes = lowerASCII(Array(name.utf8))
            for f in byteFilters where bytesContains(nameBytes, f) || bytesContains(f, nameBytes) {
                candidates.insert(pid)
                break
            }
        }

        // 第二遍: 仅对候选进程取完整路径 (命中缓存则复用)
        var list: [ProcInfo] = []
        list.reserveCapacity(entries.count)
        var liveCandidates = Set<pid_t>()
        for e in entries {
            var path = ""
            if candidates.contains(e.pid) {
                liveCandidates.insert(e.pid)
                if let cached = pathCache[e.pid] {
                    path = cached
                } else {
                    var pathBuf = [CChar](repeating: 0, count: 4096)
                    let len = proc_pidpath(e.pid, &pathBuf, UInt32(pathBuf.count))
                    path = len > 0 ? String(cString: pathBuf) : ""
                    pathCache[e.pid] = path
                }
            }
            list.append(ProcInfo(pid: e.pid, ppid: e.ppid, path: path,
                                 pathBytes: path.isEmpty ? [] : lowerASCII(Array(path.utf8))))
        }
        // 清理已消失进程的缓存 (不频繁, 避免每 tick 遍历)
        if pathCache.count > liveCandidates.count * 2 + 16 {
            pathCache = pathCache.filter { liveCandidates.contains($0.key) }
        }
        all = list
    }

    /// 路径匹配关键词的进程 PID 集合 (字节级, 无 String 分配)
    func pids(matching keywords: [String]) -> Set<pid_t> {
        guard !keywords.isEmpty else { return [] }
        var s = Set<pid_t>()
        for p in all where !p.pathBytes.isEmpty {
            for kw in keywords {
                let kb = lowerASCII(Array(kw.lowercased().utf8))
                if bytesContains(p.pathBytes, kb) || bytesContains(kb, p.pathBytes) {
                    s.insert(p.pid)
                    break
                }
            }
        }
        return s
    }

    func firstPID(matching keywords: [String]) -> pid_t? {
        for p in all where !p.pathBytes.isEmpty {
            for kw in keywords {
                let kb = lowerASCII(Array(kw.lowercased().utf8))
                if bytesContains(p.pathBytes, kb) || bytesContains(kb, p.pathBytes) { return p.pid }
            }
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

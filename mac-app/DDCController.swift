import Foundation

// DDC 读写协调：枚举外部显示器、切换输入源（带守护）、自动识别输入口。

struct DisplayInfo {
    let productName: String
    let manufacturer: String
    let alphaSerial: String
    let registryID: UInt64
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32
    let driven: Bool

    init(_ d: NSDictionary) {
        productName = d["productName"] as? String ?? "未知显示器"
        manufacturer = d["manufacturer"] as? String ?? ""
        alphaSerial = d["alphaSerial"] as? String ?? ""
        registryID = (d["registryID"] as? NSNumber)?.uint64Value ?? 0
        vendor = (d["vendor"] as? NSNumber)?.uint32Value ?? 0
        model = (d["model"] as? NSNumber)?.uint32Value ?? 0
        serial = (d["serial"] as? NSNumber)?.uint32Value ?? 0
        driven = (d["driven"] as? NSNumber)?.boolValue ?? false
    }

    var configID: String { alphaSerial.isEmpty ? "\(vendor):\(model)" : alphaSerial }
    var displayName: String { manufacturer.isEmpty ? productName : "\(manufacturer) \(productName)" }
}

final class DDCController {
    static let shared = DDCController()

    private(set) var displays: [DisplayInfo] = []

    @discardableResult
    func refreshDisplays() -> [DisplayInfo] {
        displays = DDC.listDisplays().map { DisplayInfo($0 as NSDictionary) }
        return displays
    }

    /// 读当前输入源（切换瞬间常读失败，内部重试）；失败返回 nil。
    func currentInput(_ rid: UInt64) -> Int? {
        for i in 0..<4 {
            if let v = readOnce(rid) { return v }
            if i < 3 { usleep(200_000) }
        }
        return nil
    }

    private func readOnce(_ rid: UInt64) -> Int? {
        var cur: UInt16 = 0
        return DDC.getVCP(0x60, registryID: rid, cur: &cur, max: nil) ? Int(cur) : nil
    }

    enum SwitchResult {
        case ok
        case unverified     // 已发送，但这台显示器不支持读回
        case bounced(Int)   // 显示器切过去后又自己跳回（目标口没有画面信号）
        case noReply
    }

    /// 切换输入源并「守住」：目标电脑的画面接通要几秒，显示器的自动信号源会在这段时间跳回
    /// 有信号的口。所以写入后观察，被跳走就补发，连续稳定 4 秒才算成功。
    func switchInput(_ rid: UInt64, to code: Int) -> SwitchResult {
        let maxWrites = 6
        var writes = 0
        var lastOther: Int? = nil
        var anyReply = false
        var failedReads = 0
        var stableSince: Date? = nil
        var lastWrite = Date.distantPast

        func write() {
            _ = DDC.setVCP(0x60, registryID: rid, value: UInt16(code))
            writes += 1
            lastWrite = Date()
            stableSince = nil
        }

        write()
        let deadline = Date().addingTimeInterval(14)
        while Date() < deadline {
            usleep(400_000)
            guard let v = readOnce(rid) else {
                failedReads += 1
                // 一直读不到：这台显示器不支持读回，发了就算
                if !anyReply && failedReads >= 10 { return .unverified }
                continue
            }
            anyReply = true
            if v == code {
                if stableSince == nil { stableSince = Date() }
                if Date().timeIntervalSince(stableSince!) >= 4,
                   Date().timeIntervalSince(lastWrite) >= 6 { return .ok }
            } else {
                lastOther = v
                stableSince = nil
                // 显示器切换期间读回会短暂乱跳，留 1.2 秒再补发
                if writes < maxWrites, Date().timeIntervalSince(lastWrite) >= 1.2 { write() }
            }
        }
        if let s = stableSince, Date().timeIntervalSince(s) >= 2 { return .ok }
        if let v = lastOther { return .bounced(v) }
        return anyReply ? .ok : .noReply
    }

    private let guardLock = NSLock()
    private var guardGeneration = 0

    /// 新的切换开始时调用，让上一次的后台守护停下。
    func cancelGuard() {
        guardLock.lock(); guardGeneration += 1; guardLock.unlock()
    }

    /// 切换成功后的后台守护：目标电脑的 USB-C/DP 画面在切换后会重新握手、短暂断信号，
    /// 显示器的自动信号源会趁机跳回别的口。守护期内发现被跳走就补发，最多补 4 次。
    func guardInput(_ rid: UInt64, code: Int, seconds: Double = 30) {
        guardLock.lock(); guardGeneration += 1; let gen = guardGeneration; guardLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            var rewrites = 0
            var lastWrite = Date()
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                usleep(700_000)
                self.guardLock.lock(); let alive = gen == self.guardGeneration; self.guardLock.unlock()
                if !alive { return }
                guard let v = self.readOnce(rid) else { continue }
                if v != code, rewrites < 4, Date().timeIntervalSince(lastWrite) >= 1.5 {
                    _ = DDC.setVCP(0x60, registryID: rid, value: UInt16(code))
                    rewrites += 1
                    lastWrite = Date()
                }
            }
        }
    }

    /// 等显示器稳定停在某个输入上（连续 3 次读回相同），返回该输入。
    private func waitStable(_ rid: UInt64, timeout: Double = 8) -> Int? {
        var last: Int? = nil, same = 0
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            usleep(250_000)
            guard let v = readOnce(rid) else { same = 0; continue }
            if v == last { same += 1; if same >= 2 { return v } } else { last = v; same = 0 }
        }
        return last
    }

    /// 回到本机输入并等稳定。
    private func returnHome(_ rid: UInt64, _ home: Int) {
        for _ in 0..<3 {
            _ = DDC.setVCP(0x60, registryID: rid, value: UInt16(home))
            if waitStable(rid) == home { return }
        }
    }

    /// 写一个编号并观察读回，判断显示器是否真的有这个口：
    /// - 读回出现过这个编号 → 有这个口（没接电脑的口也会先短暂停在这个编号，再自己扫描别的口）
    /// - 读回一直是本机的口，或直接变成别的口 → 没有这个口
    /// 返回 nil 表示结果不确定（离开了本机但没看到该编号），由调用方重试。
    private func tryCodeOnce(_ rid: UInt64, _ code: Int, home: Int) -> Bool? {
        _ = DDC.setVCP(0x60, registryID: rid, value: UInt16(code))
        var homeReads = 0
        var leftHome = false
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 3.5 {
            usleep(100_000)
            guard let v = readOnce(rid) else { continue }
            if v == code { return true }
            if v == home {
                homeReads += 1
                if !leftHome && homeReads >= 4 && Date().timeIntervalSince(t0) > 1.2 { return false }
            } else {
                leftHome = true
            }
        }
        return leftHome ? nil : false
    }

    private func tryCode(_ rid: UInt64, _ code: Int, home: Int) -> Bool {
        for attempt in 0..<2 {
            let r = tryCodeOnce(rid, code, home: home)
            if let r = r { if !r { return false }; return true }
            if attempt == 0 { returnHome(rid, home) }
        }
        return false
    }

    enum ProbeResult {
        case found(home: Int, ports: [Int])
        case unreadable     // 显示器不支持读回当前输入，无法自动识别
    }

    /// 自动识别接口：从本机输入出发，逐个写候选编号；每命中一个就切回本机、等稳定，
    /// 避免显示器还在自动扫描时误判。命中的编号再复核一次。没接电脑的口同样能识别。
    func probeInputs(_ rid: UInt64, progress: @escaping (Double) -> Void) -> ProbeResult {
        cancelGuard()
        guard let home = waitStable(rid) ?? currentInput(rid) else { return .unreadable }
        var hits: [Int] = []
        for (idx, code) in probeCandidates.enumerated() {
            progress(Double(idx) / Double(probeCandidates.count + 8))
            if code == home { continue }
            let hit = tryCode(rid, code, home: home)
            if hit { hits.append(code) }
            if readOnce(rid) != home { returnHome(rid, home) }
        }
        var found: [Int] = []
        for code in hits {
            if tryCode(rid, code, home: home) { found.append(code) }
            returnHome(rid, home)
        }
        progress(0.97)
        _ = switchInput(rid, to: home)
        progress(1)
        return .found(home: home, ports: [home] + found)
    }
}

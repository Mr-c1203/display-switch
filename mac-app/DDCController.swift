import Foundation

// DDC 读写协调：枚举外部显示器、切换输入源（带读回验证）、自动探测输入口。

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
}

final class DDCController {
    static let shared = DDCController()

    private(set) var displays: [DisplayInfo] = []

    @discardableResult
    func refreshDisplays() -> [DisplayInfo] {
        displays = DDC.listDisplays().map { DisplayInfo($0 as NSDictionary) }
        return displays
    }

    /// 读当前输入源；失败返回 nil。
    func currentInput(_ rid: UInt64) -> Int? {
        var cur: UInt16 = 0
        return DDC.getVCP(0x60, registryID: rid, cur: &cur, max: nil) ? Int(cur) : nil
    }

    /// 切换输入源：写入 → 轮询读回确认；失败重试一次。
    /// 返回 true 表示显示器确认已切到目标码。
    @discardableResult
    func switchInput(_ rid: UInt64, to code: Int) -> Bool {
        for attempt in 0..<2 {
            guard DDC.setVCP(0x60, registryID: rid, value: UInt16(code)) else { continue }
            let deadline = Date().addingTimeInterval(3.5)
            var last: Int? = nil
            while Date() < deadline {
                let v = currentInput(rid)
                if v == code { return true }
                if let v = v, v != last { last = v }
                usleep(250_000)
            }
            if attempt == 0 { usleep(300_000) }
        }
        return false
    }

    /// 自动探测：对所有候选码写+读回。
    /// 返回 (accepted: 读回==写入, bounced: 读回变成别的码)
    func probeInputs(_ rid: UInt64, progress: (Double) -> Void) -> (accepted: [Int], bounced: [(wrote: Int, landed: Int)]) {
        let home = currentInput(rid)
        var accepted: [Int] = []
        var bounced: [(Int, Int)] = []
        let candidates = Array(1...36)
        for (idx, code) in candidates.enumerated() {
            if code == home { continue }
            _ = DDC.setVCP(0x60, registryID: rid, value: UInt16(code))
            let deadline = Date().addingTimeInterval(2.6)
            var r: Int? = nil
            while Date() < deadline {
                if let v = currentInput(rid) { r = v; break }
                usleep(120_000)
            }
            if let v = r {
                if v == code { accepted.append(code) }
                else if v != home { bounced.append((code, v)) }
            }
            progress(Double(idx + 1) / Double(candidates.count))
        }
        if let h = home, h != currentInput(rid) {
            _ = DDC.setVCP(0x60, registryID: rid, value: UInt16(h))
        }
        return (accepted, bounced)
    }
}

import Foundation

// 配置模型：一台显示器 → 若干个输入口（每口可接一台电脑）

struct InputEntry: Codable, Equatable {
    var code: Int            // VCP 0x60 输入源编号
    var label: String        // 接口名，如 "USB-C"、"HDMI 2"
    var computer: String?    // 用户给接在这个口上的电脑起的名字，如 "MacBook"
    var inCycle: Bool?       // 是否参与热键循环；切换成功过的口自动加入

    init(code: Int, label: String, computer: String? = nil, inCycle: Bool? = nil) {
        self.code = code; self.label = label; self.computer = computer; self.inCycle = inCycle
    }

    var title: String {
        if let c = computer, !c.isEmpty { return "\(label) — \(c)" }
        return label
    }
}

struct DisplayConfig: Codable, Equatable {
    var id: String       // EDID 字母序列为首选标识；无序列号时 "VENDOR:MODEL"
    var name: String     // 展示名，如 "AOC U32U3D"
    var inputs: [InputEntry]
}

struct AppConfig: Codable, Equatable {
    var version: Int = 2
    var displays: [DisplayConfig] = []
}

final class ConfigStore {
    static let shared = ConfigStore()
    private(set) var config = AppConfig()

    var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("显示器切换", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var url: URL { dir.appendingPathComponent("config.json") }

    func load() {
        if let data = try? Data(contentsOf: url),
           let c = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = c
            return
        }
        migrateLegacyIfNeeded()
    }

    func save() {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // 首次运行：读取旧版内置 config.txt（编号,名称）作为第一台显示器的机器清单
    private func migrateLegacyIfNeeded() {
        var entries: [InputEntry] = []
        if let url = Bundle.main.url(forResource: "config", withExtension: "txt"),
           let s = try? String(contentsOf: url, encoding: .utf8) {
            for raw in s.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let p = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if p.count == 2, let code = Int(p[0]), code > 0 {
                    entries.append(InputEntry(code: code, label: p[1]))
                }
            }
        }
        guard !entries.isEmpty else { return }
        if let d = DDC.listDisplays().first {
            let info = DisplayInfo(d as NSDictionary)
            config.displays = [DisplayConfig(id: info.configID, name: info.displayName, inputs: entries)]
            save()
        }
    }

    func displayConfig(for info: DisplayInfo) -> DisplayConfig? {
        config.displays.first(where: { $0.id == info.configID })
    }

    func upsert(_ dc: DisplayConfig) {
        if let i = config.displays.firstIndex(where: { $0.id == dc.id }) {
            config.displays[i] = dc
        } else {
            config.displays.append(dc)
        }
        save()
    }
}

// MARK: - 接口目录

/// VCP 0x60 输入源编号 → 接口类型名。
/// 标准值来自 VESA MCCS；另收录几家厂商的非标准编号（如 AOC 的 USB-C 用 21）。
/// 识别不出的编号显示为「输入 N」，用户可改名。
func guessInputName(_ code: Int, manufacturer: String = "") -> String {
    let m = manufacturer.uppercased()
    if m == "AOC" {
        switch code {
        case 21: return "USB-C"
        case 22: return "USB-C 2"
        default: break
        }
    }
    if m == "GSM" { // LG
        switch code {
        case 0x90: return "HDMI 1"
        case 0x91: return "HDMI 2"
        case 0x92: return "HDMI 3"
        case 0xD0: return "DisplayPort"
        case 0xD1: return "USB-C"
        default: break
        }
    }
    switch code {
    case 1: return "VGA 1"
    case 2: return "VGA 2"
    case 3: return "DVI 1"
    case 4: return "DVI 2"
    case 15: return "DisplayPort 1"
    case 16: return "DisplayPort 2"
    case 17: return "HDMI 1"
    case 18: return "HDMI 2"
    case 19: return "HDMI 3"
    case 20: return "HDMI 4"
    case 21: return "USB-C"
    case 22: return "USB-C 2"
    case 27: return "USB-C"
    case 28: return "USB-C 2"
    default: return "输入 \(code)"
    }
}

/// 识别接口时尝试的编号：MCCS 标准范围 + 常见厂商扩展。
let probeCandidates: [Int] = Array(1...32) + [0x90, 0x91, 0x92, 0xD0, 0xD1]

/// 接口类型排序：USB-C → HDMI → DP → 其他。
func portSortKey(_ label: String) -> Int {
    let l = label.uppercased()
    if l.contains("USB-C") || l.contains("TYPE-C") { return 0 }
    if l.contains("HDMI") { return 1 }
    if l.contains("DISPLAYPORT") || l.contains("DP") { return 2 }
    return 3
}

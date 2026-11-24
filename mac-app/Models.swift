import Foundation

// 配置模型：一台显示器 → 若干个输入口（每口对应一台机器）

struct InputEntry: Codable, Equatable {
    var code: Int        // VCP 0x60 输入源编号
    var label: String    // 机器名，如 "MacBook (USB-C)"
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

    private var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("显示器切换", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

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
            let serial = d["alphaSerial"] as? String ?? ""
            let vendor = (d["vendor"] as? NSNumber)?.uint32Value ?? 0
            let model = (d["model"] as? NSNumber)?.uint32Value ?? 0
            let mfg = d["manufacturer"] as? String ?? ""
            let name = d["productName"] as? String ?? ""
            let id = serial.isEmpty ? "\(vendor):\(model)" : serial
            config.displays = [DisplayConfig(id: id, name: "\(mfg) \(name)", inputs: entries)]
            save()
        }
    }

    func displayConfig(for info: DisplayInfo) -> DisplayConfig? {
        let id = info.alphaSerial.isEmpty ? "\(info.vendor):\(info.model)" : info.alphaSerial
        return config.displays.first(where: { $0.id == id })
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

// 标准 VCP 0x60 常用码 → 猜名（各家不完全一致，自动探测后用作用户可改的默认名）
func guessInputName(_ code: Int) -> String {
    switch code {
    case 1: return "VGA"
    case 3, 4: return "DVI-\(code - 2)"
    case 15: return "DisplayPort 1"
    case 16: return "DisplayPort 2"
    case 17: return "HDMI 1"
    case 18: return "HDMI 2"
    case 19: return "HDMI 3"
    case 20: return "HDMI 4"
    case 27: return "USB-C"
    case 33, 34, 35: return "USB-C\(code - 32)"
    default: return "输入 \(code)"
    }
}

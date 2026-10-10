// MonitorSwitch — 显示器输入源一键切换（macOS 菜单栏 App，自包含 m1ddc）
// 菜单里直接选「切到 A机 / 切到 B机」，当前谁在屏幕上会打 ✓；
// 左键点 ⇄ = 切到"不在屏幕上的那一台"。
// 机器清单写在 App 内部 Contents/Resources/config.txt（每行: 编号,名称），
// 编号是显示器内部的门牌号，用户永远不需要看到。
import AppKit
import ServiceManagement

// Draw at menu-bar resolution so the two screens remain recognizable in both
// light and dark menu bars. The template mask lets macOS choose the ink color.
func menuBarScreensIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 25, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()

        let left = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 5.5, width: 9, height: 8),
                                xRadius: 1.2, yRadius: 1.2)
        left.lineWidth = 1.45
        left.stroke()
        let right = NSBezierPath(roundedRect: NSRect(x: 14.5, y: 5.5, width: 9, height: 8),
                                 xRadius: 1.2, yRadius: 1.2)
        right.lineWidth = 1.45
        right.stroke()

        let feet = NSBezierPath()
        feet.lineWidth = 1.4
        for center in [6.0, 19.0] {
            feet.move(to: NSPoint(x: center, y: 5.3))
            feet.line(to: NSPoint(x: center, y: 3.2))
            feet.move(to: NSPoint(x: center - 2.8, y: 3.1))
            feet.line(to: NSPoint(x: center + 2.8, y: 3.1))
        }
        feet.stroke()

        // The diagonal divider echoes the blue application icon.
        let divider = NSBezierPath()
        divider.lineWidth = 1.6
        divider.lineCapStyle = .round
        divider.move(to: NSPoint(x: 11.5, y: 3.1))
        divider.line(to: NSPoint(x: 13.5, y: 15.0))
        divider.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

struct MachineEntry {
    let code: Int
    let label: String
}

func bundledMachines() -> [MachineEntry] {
    guard let url = Bundle.main.url(forResource: "config", withExtension: "txt"),
          let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var out: [MachineEntry] = []
    for raw in s.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let p = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        if p.count == 2, let code = Int(p[0]), code > 0 { out.append(MachineEntry(code: code, label: p[1])) }
    }
    return out
}

func m1ddcURL() -> URL? {
    let fm = FileManager.default
    if let exe = Bundle.main.executableURL {
        let bundled = exe.deletingLastPathComponent().appendingPathComponent("m1ddc")
        if fm.fileExists(atPath: bundled.path) { return bundled }
    }
    for p in ["/opt/homebrew/bin/m1ddc", "/usr/local/bin/m1ddc"] where fm.fileExists(atPath: p) {
        return URL(fileURLWithPath: p)
    }
    return nil
}

@discardableResult
func runM1ddc(_ args: [String]) -> (ok: Bool, out: String) {
    guard let url = m1ddcURL() else {
        return (false, "未找到 m1ddc（App 应已自带，请重新安装本 App）")
    }
    let p = Process()
    p.executableURL = url
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (false, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    return (p.terminationStatus == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let defaults = UserDefaults.standard
    var item: NSStatusItem!
    let menu = NSMenu()
    var lastKnownInput: Int?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.title = ""
            b.image = menuBarScreensIcon()
            b.imagePosition = .imageOnly
            b.toolTip = "显示器切换（左键=切到另一台，右键=菜单）"
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        menu.autoenablesItems = false
    }

    // MARK: - 机器清单

    func machines() -> [MachineEntry] {
        let bundled = bundledMachines()
        if !bundled.isEmpty { return bundled }
        // 兜底：旧的单目标配置
        var code = defaults.integer(forKey: "otherInput")
        if code <= 0, let url = Bundle.main.url(forResource: "target", withExtension: "txt"),
           let s = try? String(contentsOf: url, encoding: .utf8), let c = Int(s.trimmingCharacters(in: .whitespaces)) {
            code = c
        }
        if code > 0 { return [MachineEntry(code: code, label: "另一台")] }
        return []
    }

    func currentInput() -> Int? {
        var (ok, out) = runM1ddc(["get", "input"])
        if !ok { (ok, out) = runM1ddc(["get", "vcp", "96"]) }
        guard ok, let n = Int(out) else { return nil }
        lastKnownInput = n
        return n
    }

    // MARK: - 行为

    @objc func statusClicked() {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.option) {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        // 左键：切到"不在屏幕上"的那一台。用缓存判断、立即发指令，不做任何前置读取，
        // 把切换延迟压到最低（只有 App 刚启动后的第一次点击才需要读一次当前状态）。
        let ms = machines()
        guard !ms.isEmpty else { promptTargetFallback(); return }
        let target: MachineEntry
        if ms.count == 1 {
            target = ms[0]
        } else if let last = lastKnownInput, let other = ms.first(where: { $0.code != last }) {
            target = other
        } else if let c = currentInput(), let other = ms.first(where: { $0.code != c }) {
            target = other
        } else {
            target = ms.count > 1 ? ms[1] : ms[0]
        }
        doSwitch(code: target.code)
    }

    func doSwitch(code: Int) {
        lastKnownInput = code
        let (ok, out) = runM1ddc(["set", "input", String(code)])
        if !ok {
            alert("切换失败",
                  "显示器没有接受切换指令。\n\nm1ddc 输出：\(out)\n\n请检查：\n① 显示器 OSD 菜单里 DDC/CI 是否已开启；\n② 显示器线缆是否直连（部分扩展坞不透传）。")
        }
        // 成功时屏幕会直接切走，无需弹窗。
    }

    @objc func switchToMenuItem(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? Int { doSwitch(code: code) }
    }

    func alert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.runModal()
    }

    @discardableResult
    func promptTargetFallback() -> Bool {
        let a = NSAlert()
        a.messageText = "缺少机器清单"
        a.informativeText = "本 App 需要内置机器清单（config.txt，含每台机器的输入源编号）。请重新安装完整打包版，或联系帮你打包的人重新生成。"
        a.addButton(withTitle: "好")
        a.runModal()
        return false
    }

    @objc func showCurrent() {
        if let c = currentInput() {
            let name = machines().first(where: { $0.code == c })?.label ?? "未知输入口"
            alert("当前在屏幕上的", "编号 \(c) — \(name)")
        } else {
            alert("读取失败", "显示器暂时不支持读取，稍后再试。")
        }
    }

    func refreshAutoStartState() -> NSControl.StateValue {
        SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleAutoStart() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("设置失败", "\(error.localizedDescription)\n\n也可以手动设置：系统设置 → 通用 → 登录项，添加 MonitorSwitch。")
        }
    }

    @objc func sleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        try? p.run()
    }

    // MARK: - 菜单（每次打开时重建，保证 ✓ 是最新的）

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let ms = machines()
        let cur = currentInput()
        for m in ms {
            let it = NSMenuItem(title: "切到 \(m.label)", action: #selector(switchToMenuItem(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = m.code as NSNumber
            if cur == m.code { it.state = .on }
            menu.addItem(it)
        }
        menu.addItem(.separator())
        let curItem = NSMenuItem(title: "查看当前在哪台", action: #selector(showCurrent), keyEquivalent: "")
        curItem.target = self
        menu.addItem(curItem)

        let auto = NSMenuItem(title: "开机自启", action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        auto.state = refreshAutoStartState()
        menu.addItem(auto)

        let sleep = NSMenuItem(title: "睡眠本机（显示器开了自动信号源时会自动让屏）", action: #selector(sleepNow), keyEquivalent: "")
        sleep.target = self
        menu.addItem(sleep)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

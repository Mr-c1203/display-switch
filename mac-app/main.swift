// 显示器切换 v2 — 多输入源 KVM 切换（macOS 菜单栏 App）
// - 自研 DDC 通道（内嵌 m1ddc 传输层，MIT），不再依赖外部二进制，利于上架
// - 机器清单最多 4 台，存 ~/Library/Application Support/显示器切换/config.json
// - 自动探测输入口（写+读回）；探测不到的口用「学习当前输入」手动加
import AppKit
import Carbon.HIToolbox
import ServiceManagement

func menuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 25, height: 18), flipped: false) { _ in
        NSColor.black.setStroke()
        for x in [1.5, 14.5] {
            let r = NSBezierPath(roundedRect: NSRect(x: x, y: 5.5, width: 9, height: 8), xRadius: 1.2, yRadius: 1.2)
            r.lineWidth = 1.45; r.stroke()
        }
        let feet = NSBezierPath()
        feet.lineWidth = 1.4
        for c in [6.0, 19.0] {
            feet.move(to: NSPoint(x: c, y: 5.3)); feet.line(to: NSPoint(x: c, y: 3.2))
            feet.move(to: NSPoint(x: c - 2.8, y: 3.1)); feet.line(to: NSPoint(x: c + 2.8, y: 3.1))
        }
        feet.stroke()
        let div = NSBezierPath(); div.lineWidth = 1.6; div.lineCapStyle = .round
        div.move(to: NSPoint(x: 11.5, y: 3.1)); div.line(to: NSPoint(x: 13.5, y: 15.0)); div.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let ddc = DDCController.shared
    let store = ConfigStore.shared
    var item: NSStatusItem!
    let menu = NSMenu()
    var lastKnown: [UInt64: Int] = [:]   // registryID -> input code

    func applicationDidFinishLaunching(_ n: Notification) {
        store.load()
        _ = ddc.refreshDisplays()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = menuBarIcon()
            b.imagePosition = .imageOnly
            b.toolTip = "显示器切换（左键=切到下一台，右键=菜单）"
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        menu.delegate = self
        menu.autoenablesItems = false
        HotkeyManager.shared.onFire = { [weak self] in self?.cycleToNext() }
        if UserDefaults.standard.bool(forKey: "hotkeyEnabled") { HotkeyManager.shared.register() }
    }

    // MARK: - 快捷数据

    /// 主显示器：取配置里第一台还在线的；否则第一台在线的。
    func primary() -> (info: DisplayInfo, cfg: DisplayConfig?)? {
        let live = ddc.displays
        guard !live.isEmpty else { return nil }
        for d in live {
            if let c = store.displayConfig(for: d) { return (d, c) }
        }
        return (live[0], nil)
    }

    // MARK: - 点击

    @objc func statusClicked() {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.option) {
            item.menu = menu
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        cycleToNext()
    }

    /// 左键：切到清单里的下一台（两台之间即来回切）。
    func cycleToNext() {
        _ = ddc.refreshDisplays()
        guard let (info, cfg) = primary(), let c = cfg, !c.inputs.isEmpty else {
            alert("还没有机器清单", "请从右键菜单用「自动探测输入口」或「学习当前输入」添加。")
            return
        }
        let rid = info.registryID
        let cur = lastKnown[rid] ?? ddc.currentInput(rid)
        let next: InputEntry
        if let cur = cur, let i = c.inputs.firstIndex(where: { $0.code == cur }) {
            next = c.inputs[(i + 1) % c.inputs.count]
        } else {
            next = c.inputs[0]
        }
        doSwitch(rid: rid, entry: next)
    }

    func doSwitch(rid: UInt64, entry: InputEntry) {
        lastKnown[rid] = entry.code
        let ok = ddc.switchInput(rid, to: entry.code)
        if !ok {
            lastKnown[rid] = nil
            alert("切换未确认",
                  "显示器没有明确回复已切到「\(entry.label)」。\n\n可能原因：目标输入上没有信号源、显示器弹回了，或 DDC/CI 被关闭。\n显示器实际画面请自行确认。")
        }
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        _ = ddc.refreshDisplays()

        if ddc.displays.isEmpty {
            let it = NSMenuItem(title: "没有检测到外部显示器", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
        }

        for info in ddc.displays {
            let rid = info.registryID
            let cfg = store.displayConfig(for: info)
            let title = NSMenuItem(title: "🖥 \(info.productName)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            let cur = lastKnown[rid] ?? ddc.currentInput(rid)
            if let c = cfg {
                for e in c.inputs {
                    let it = NSMenuItem(title: "  切到 \(e.label)", action: #selector(switchToMenuItem(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = SwitchRef(rid: rid, code: e.code)
                    if cur == e.code { it.state = .on }
                    menu.addItem(it)
                }
                if c.inputs.isEmpty {
                    let it = NSMenuItem(title: "  （还没有输入口，先添加）", action: nil, keyEquivalent: "")
                    it.isEnabled = false
                    menu.addItem(it)
                }
            } else {
                let it = NSMenuItem(title: "  （未配置机器清单）", action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }

            let sub = NSMenuItem(title: "  管理这台显示器", action: nil, keyEquivalent: "")
            let sm = NSMenu()
            func add(_ t: String, _ sel: Selector, _ ref: Any) {
                let m = NSMenuItem(title: t, action: sel, keyEquivalent: "")
                m.target = self; m.representedObject = ref; sm.addItem(m)
            }
            add("自动探测输入口…", #selector(probe(_:)), ProbeRef(info: info))
            add("学习当前输入（先手动切换再点）…", #selector(learn(_:)), ProbeRef(info: info))
            add("手动添加输入口…", #selector(addManual(_:)), ProbeRef(info: info))
            add("重命名/删除输入口…", #selector(editInputs(_:)), ProbeRef(info: info))
            sub.submenu = sm
            menu.addItem(sub)
            menu.addItem(.separator())
        }

        let cur = NSMenuItem(title: "查看当前在哪台", action: #selector(showCurrent), keyEquivalent: "")
        cur.target = self
        menu.addItem(cur)

        let hot = NSMenuItem(title: "热键 ⌃⌥` 循环切换", action: #selector(toggleHotkey), keyEquivalent: "")
        hot.target = self
        hot.state = UserDefaults.standard.bool(forKey: "hotkeyEnabled") ? .on : .off
        menu.addItem(hot)

        let auto = NSMenuItem(title: "开机自启", action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        auto.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(auto)

        let sleep = NSMenuItem(title: "睡眠本机", action: #selector(sleepNow), keyEquivalent: "")
        sleep.target = self
        menu.addItem(sleep)

        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    final class SwitchRef: NSObject { let rid: UInt64, code: Int
        init(rid: UInt64, code: Int) { self.rid = rid; self.code = code } }
    final class ProbeRef: NSObject { let info: DisplayInfo
        init(info: DisplayInfo) { self.info = info } }

    @objc func switchToMenuItem(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? SwitchRef else { return }
        let label = sender.title.replacingOccurrences(of: "  切到 ", with: "")
        doSwitch(rid: r.rid, entry: InputEntry(code: r.code, label: label))
    }

    @objc func showCurrent() {
        guard let (info, _) = primary() else { alert("无显示器", "没有检测到外部显示器"); return }
        let rid = info.registryID
        if let c = ddc.currentInput(rid) {
            lastKnown[rid] = c
            let name = store.displayConfig(for: info)?.inputs.first(where: { $0.code == c })?.label ?? "未命名输入口"
            alert("当前输入", "编号 \(c) — \(name)")
        } else {
            alert("读取失败", "显示器暂时不支持读取，稍后再试。")
        }
    }

    // MARK: - 输入口管理

    @objc func probe(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef else { return }
        let rid = ref.info.registryID
        let a = NSAlert()
        a.messageText = "自动探测输入口"
        a.informativeText = "接下来约 90 秒，屏幕会多次切换输入源（会闪），结束后自动切回来。\n\n探测期间请保存手头工作、不要操作电脑。探测到「读回一致」的口才会列出；有信号但没有对应设备的口可能探测不到，可用「学习当前输入」补加。"
        a.addButton(withTitle: "开始探测")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        var result: (accepted: [Int], bounced: [(wrote: Int, landed: Int)])? = nil
        let spinner = NSAlert()
        spinner.messageText = "正在探测输入口…"
        spinner.informativeText = "屏幕会切换，请稍候。"
        spinner.addButton(withTitle: "")
        spinner.buttons.first?.isHidden = true
        // 异步跑探测，同时弹出无按钮的进度框
        Thread.detachNewThread {
            let r = self.ddc.probeInputs(rid) { _ in }
            DispatchQueue.main.async {
                NSApp.stopModal()
                result = r
                self.showProbeResult(ref.info, r)
            }
        }
        spinner.runModal()
        if result == nil { /* 用户无法取消（无按钮），保底 */ }
    }

    func showProbeResult(_ info: DisplayInfo, _ r: (accepted: [Int], bounced: [(wrote: Int, landed: Int)])) {
        if r.accepted.isEmpty && r.bounced.isEmpty {
            alert("探测完成", "没有探测到可用的输入口。这台显示器可能不响应 DDC 探测，请改用「学习当前输入」。")
            return
        }
        var lines: [String] = []
        var entries: [InputEntry] = []
        for code in r.accepted {
            let name = guessInputName(code)
            entries.append(InputEntry(code: code, label: name))
            lines.append("  ✓ \(name)（编号 \(code)）")
        }
        if !r.bounced.isEmpty {
            lines.append("")
            lines.append("以下编号写进去后跳到了别的口，可作为候选（请自行核实）：")
            for b in r.bounced { lines.append("  ? 写 \(b.wrote) → 落到 \(b.landed)") }
        }
        let a = NSAlert()
        a.messageText = "探测结果（将并入机器清单）"
        a.informativeText = lines.joined(separator: "\n") + "\n\n这些名字是猜测，可在「重命名/删除输入口」里改。"
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "不保存")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        var cfg = store.displayConfig(for: info) ?? DisplayConfig(
            id: info.alphaSerial.isEmpty ? "\(info.vendor):\(info.model)" : info.alphaSerial,
            name: "\(info.manufacturer) \(info.productName)", inputs: [])
        for e in entries where !cfg.inputs.contains(where: { $0.code == e.code }) {
            cfg.inputs.append(e)
        }
        cfg.inputs.sort { $0.code < $1.code }
        store.upsert(cfg)
    }

    @objc func learn(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef else { return }
        let rid = ref.info.registryID
        let a = NSAlert()
        a.messageText = "学习当前输入"
        a.informativeText = "先用显示器按钮/摇杆，把画面切到这台显示器当前正在显示的那个输入口（也就是本机现在用的口），然后点「读取」。\n\n用途：给探测不到的口编号、命名。"
        a.addButton(withTitle: "读取")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let code = ddc.currentInput(rid) else {
            alert("读取失败", "显示器暂时不支持读取。")
            return
        }
        promptInputName(default: guessInputName(code)) { name in
            var cfg = self.store.displayConfig(for: ref.info) ?? DisplayConfig(
                id: ref.info.alphaSerial.isEmpty ? "\(ref.info.vendor):\(ref.info.model)" : ref.info.alphaSerial,
                name: "\(ref.info.manufacturer) \(ref.info.productName)", inputs: [])
            if let i = cfg.inputs.firstIndex(where: { $0.code == code }) {
                cfg.inputs[i].label = name
            } else {
                cfg.inputs.append(InputEntry(code: code, label: name))
            }
            cfg.inputs.sort { $0.code < $1.code }
            self.store.upsert(cfg)
        }
    }

    @objc func addManual(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef else { return }
        let a = NSAlert()
        a.messageText = "手动添加输入口"
        a.informativeText = "填显示器内部的输入源编号（常见：15=DP1、17=HDMI1、18=HDMI2、27=USB-C，各家不同）。"
        a.addButton(withTitle: "下一步")
        a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        tf.placeholderString = "编号，如 18"
        a.accessoryView = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let code = Int(tf.stringValue.trimmingCharacters(in: .whitespaces)), code > 0 else {
            alert("编号无效", "请输入正整数。")
            return
        }
        promptInputName(default: guessInputName(code)) { name in
            var cfg = self.store.displayConfig(for: ref.info) ?? DisplayConfig(
                id: ref.info.alphaSerial.isEmpty ? "\(ref.info.vendor):\(ref.info.model)" : ref.info.alphaSerial,
                name: "\(ref.info.manufacturer) \(ref.info.productName)", inputs: [])
            if let i = cfg.inputs.firstIndex(where: { $0.code == code }) {
                cfg.inputs[i].label = name
            } else {
                cfg.inputs.append(InputEntry(code: code, label: name))
            }
            cfg.inputs.sort { $0.code < $1.code }
            self.store.upsert(cfg)
        }
    }

    @objc func editInputs(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef else { return }
        guard var cfg = store.displayConfig(for: ref.info), !cfg.inputs.isEmpty else {
            alert("没有输入口", "这台显示器还没有机器清单。")
            return
        }
        let a = NSAlert()
        a.messageText = "输入口管理（\(cfg.inputs.count) 个）"
        let list = cfg.inputs.enumerated().map { "\($0.offset + 1). \($0.element.label)（编号 \($0.element.code)）" }.joined(separator: "\n")
        a.informativeText = list + "\n\n输入要删除的序号；要改名请输入「序号 新名字」。留空则关闭。"
        a.addButton(withTitle: "执行")
        a.addButton(withTitle: "关闭")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.placeholderString = "如：2  或  2 Mac mini"
        a.accessoryView = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let parts = tf.stringValue.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1).map(String.init)
        guard let idx = Int(parts.first ?? ""), idx >= 1, idx <= cfg.inputs.count else { return }
        if parts.count == 1 {
            cfg.inputs.remove(at: idx - 1)
        } else {
            cfg.inputs[idx - 1].label = parts[1]
        }
        store.upsert(cfg)
    }

    func promptInputName(default name: String, save: @escaping (String) -> Void) {
        let a = NSAlert()
        a.messageText = "给这个输入口起个名字"
        a.informativeText = "会显示在菜单里，例如「MacBook (USB-C)」。"
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = name
        a.accessoryView = tf
        if a.runModal() == .alertFirstButtonReturn {
            let n = tf.stringValue.trimmingCharacters(in: .whitespaces)
            save(n.isEmpty ? name : n)
        }
    }

    // MARK: - 其他

    @objc func toggleHotkey() {
        let on = !UserDefaults.standard.bool(forKey: "hotkeyEnabled")
        UserDefaults.standard.set(on, forKey: "hotkeyEnabled")
        if on { HotkeyManager.shared.register() } else { HotkeyManager.shared.unregister() }
    }

    @objc func toggleAutoStart() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("设置失败", "\(error.localizedDescription)\n\n也可以手动设置：系统设置 → 通用 → 登录项。")
        }
    }

    @objc func sleepNow() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["sleepnow"]
        try? p.run()
    }

    func alert(_ title: String, _ msg: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.runModal()
    }
}

// MARK: - 全局热键 ⌃⌥`（Carbon，无需辅助功能权限）

final class HotkeyManager {
    static let shared = HotkeyManager()
    var onFire: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handler: EventHandlerRef?

    func register() {
        if hotKeyRef != nil { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, userData) -> OSStatus in
            guard let ud = userData else { return noErr }
            Unmanaged<HotkeyManager>.fromOpaque(ud).takeUnretainedValue().onFire?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        var id = EventHotKeyID(signature: OSType(0x4D535749), id: 1) // 'MSWI'
        RegisterEventHotKey(UInt32(kVK_ANSI_Grave), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    func unregister() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let h = handler { RemoveEventHandler(h); handler = nil }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

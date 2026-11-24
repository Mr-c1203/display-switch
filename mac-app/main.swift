// 显示器切换 — 多台电脑共用一台显示器的输入源切换（macOS 菜单栏 App）
// - 点图标弹出菜单，从菜单选接口切换；快捷键可自定义（循环切换 / 直达某个接口）
// - 新显示器自动识别全部接口（USB-C / HDMI / DP …），没接电脑的口也能识别
// - 切换后守住输入，防止显示器的自动信号源跳回
// - 「关于」里检查更新，从 GitHub Releases 下载新版并替换自身
import AppKit
import Carbon.HIToolbox
import ServiceManagement

let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
let repoSlug = "Mr-c1203/display-switch"

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
    let hotkeys = HotkeyManager.shared
    var item: NSStatusItem!
    let menu = NSMenu()
    var busy = false
    var noSignal: Set<Int> = []          // 本次运行中切过去没信号的口，循环切换时跳过
    var promptedDisplays: Set<String> = []
    var availableUpdate: UpdateInfo?

    func applicationDidFinishLaunching(_ n: Notification) {
        store.load()
        _ = ddc.refreshDisplays()
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = menuBarIcon()
            b.imagePosition = .imageOnly
            b.toolTip = "显示器切换"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu   // 左键、右键都只弹菜单，不直接切换

        hotkeys.onFire = { [weak self] action in self?.runHotkey(action) }
        hotkeys.loadAndRegister()

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.offerProbeForNewDisplays() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.checkUpdateQuietly() }
    }

    // MARK: - 新显示器自动识别

    @objc func screensChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.offerProbeForNewDisplays() }
    }

    func offerProbeForNewDisplays() {
        guard !busy else { return }
        _ = ddc.refreshDisplays()
        for info in ddc.displays where store.displayConfig(for: info) == nil && !promptedDisplays.contains(info.configID) {
            promptedDisplays.insert(info.configID)
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "发现显示器「\(info.displayName)」"
            a.informativeText = "要自动识别它有哪些接口吗（USB-C、HDMI、DP 等，没接电脑的口也能识别）？\n\n识别约 1–2 分钟，期间屏幕会多次切换、闪烁，结束后自动切回本机。"
            a.addButton(withTitle: "现在识别")
            a.addButton(withTitle: "以后再说")
            if a.runModal() == .alertFirstButtonReturn { startProbe(info) }
            return
        }
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        _ = ddc.refreshDisplays()

        if busy {
            let it = NSMenuItem(title: "正在切换/识别，请稍候…", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            menu.addItem(.separator())
        }

        if ddc.displays.isEmpty {
            let it = NSMenuItem(title: "没有检测到支持 DDC/CI 的外接显示器", action: nil, keyEquivalent: "")
            it.isEnabled = false
            menu.addItem(it)
            menu.addItem(.separator())
        }

        for info in ddc.displays {
            let rid = info.registryID
            let cfg = store.displayConfig(for: info)
            let title = NSMenuItem(title: "🖥 \(info.displayName)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            let cur = ddc.currentInput(rid)
            if let c = cfg, !c.inputs.isEmpty {
                for e in c.inputs {
                    let it = NSMenuItem(title: "  " + e.title, action: #selector(switchToMenuItem(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = SwitchRef(info: info, entry: e)
                    it.isEnabled = !busy
                    if cur == e.code { it.state = .on }
                    if let hk = hotkeys.binding(for: .port(info.configID, e.code)) {
                        it.title += "    \(hk.display)"
                    }
                    menu.addItem(it)
                }
            } else {
                let it = NSMenuItem(title: "  识别这台显示器的接口…", action: #selector(probe(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = ProbeRef(info: info)
                it.isEnabled = !busy
                menu.addItem(it)
            }

            let sub = NSMenuItem(title: "  管理这台显示器", action: nil, keyEquivalent: "")
            let sm = NSMenu()
            sm.autoenablesItems = false
            func add(_ t: String, _ sel: Selector, _ ref: Any, enabled: Bool = true) {
                let m = NSMenuItem(title: t, action: sel, keyEquivalent: "")
                m.target = self; m.representedObject = ref; m.isEnabled = enabled && !busy; sm.addItem(m)
            }
            let ref = ProbeRef(info: info)
            add("重新识别接口…", #selector(probe(_:)), ref)
            add("给接口填电脑名字…", #selector(nameComputer(_:)), ref, enabled: !(cfg?.inputs.isEmpty ?? true))
            add("设置接口快捷键…", #selector(setPortHotkey(_:)), ref, enabled: !(cfg?.inputs.isEmpty ?? true))
            add("循环切换包含哪些接口…", #selector(editCycle(_:)), ref, enabled: !(cfg?.inputs.isEmpty ?? true))
            sm.addItem(.separator())
            add("学习当前输入（识别不到的口用）…", #selector(learn(_:)), ref)
            add("手动添加编号…", #selector(addManual(_:)), ref)
            add("删除接口…", #selector(deleteInput(_:)), ref, enabled: !(cfg?.inputs.isEmpty ?? true))
            sub.submenu = sm
            menu.addItem(sub)
            menu.addItem(.separator())
        }

        let hk = NSMenuItem(title: "快捷键", action: nil, keyEquivalent: "")
        let hm = NSMenu()
        hm.autoenablesItems = false
        let cycle = hotkeys.binding(for: .cycle)
        let c1 = NSMenuItem(title: "循环切换：\(cycle?.display ?? "未设置")", action: nil, keyEquivalent: "")
        c1.isEnabled = false
        hm.addItem(c1)
        let c2 = NSMenuItem(title: "设置循环切换快捷键…", action: #selector(setCycleHotkey), keyEquivalent: "")
        c2.target = self
        hm.addItem(c2)
        if cycle != nil {
            let c3 = NSMenuItem(title: "关闭循环切换快捷键", action: #selector(clearCycleHotkey), keyEquivalent: "")
            c3.target = self
            hm.addItem(c3)
        }
        hm.addItem(.separator())
        let c4 = NSMenuItem(title: "接口直达快捷键在「管理这台显示器」里设置", action: nil, keyEquivalent: "")
        c4.isEnabled = false
        hm.addItem(c4)
        hk.submenu = hm
        menu.addItem(hk)

        let auto = NSMenuItem(title: "开机自启", action: #selector(toggleAutoStart), keyEquivalent: "")
        auto.target = self
        auto.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        if let u = availableUpdate {
            let up = NSMenuItem(title: "⬆︎ 升级到新版本 \(u.version)", action: #selector(installUpdateFromMenu), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
        }
        let about = NSMenuItem(title: "关于显示器切换（\(appVersion)）/ 检查更新…", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    final class SwitchRef: NSObject { let info: DisplayInfo, entry: InputEntry
        init(info: DisplayInfo, entry: InputEntry) { self.info = info; self.entry = entry } }
    final class ProbeRef: NSObject { let info: DisplayInfo
        init(info: DisplayInfo) { self.info = info } }

    // MARK: - 切换

    @objc func switchToMenuItem(_ sender: NSMenuItem) {
        guard let r = sender.representedObject as? SwitchRef else { return }
        doSwitch(info: r.info, candidates: [r.entry])
    }

    func runHotkey(_ action: HotkeyAction) {
        _ = ddc.refreshDisplays()
        switch action {
        case .cycle:
            cycleToNext()
        case .port(let displayID, let code):
            guard let info = ddc.displays.first(where: { $0.configID == displayID }),
                  let e = store.displayConfig(for: info)?.inputs.first(where: { $0.code == code }) else {
                NSSound.beep(); return
            }
            doSwitch(info: info, candidates: [e])
        }
    }

    /// 主显示器：取配置里第一台还在线的。
    func primary() -> (info: DisplayInfo, cfg: DisplayConfig)? {
        for d in ddc.displays {
            if let c = store.displayConfig(for: d), !c.inputs.isEmpty { return (d, c) }
        }
        return nil
    }

    /// 循环切换：只在「参与循环」的接口之间轮换（切换成功过的口会自动加入），没信号的口跳过。
    func cycleToNext() {
        guard let (info, c) = primary() else {
            NSSound.beep()
            offerProbeForNewDisplays()
            return
        }
        var pool = c.inputs.filter { $0.inCycle == true }
        if pool.count < 2 { pool = c.inputs }
        let cur = ddc.currentInput(info.registryID)
        let start = cur.flatMap { code in pool.firstIndex(where: { $0.code == code }) }.map { $0 + 1 } ?? 0
        var order: [InputEntry] = []
        for k in 0..<pool.count {
            let e = pool[(start + k) % pool.count]
            if e.code != cur { order.append(e) }
        }
        let live = order.filter { !noSignal.contains($0.code) }
        if !live.isEmpty { order = live }
        guard !order.isEmpty else { return }
        doSwitch(info: info, candidates: order)
    }

    /// 切换在后台线程做（含防弹回观察），不卡菜单栏；结果以显示器读回为准。
    func doSwitch(info: DisplayInfo, candidates: [InputEntry]) {
        if busy { return }
        busy = true
        item.button?.appearsDisabled = true
        ddc.cancelGuard()
        let rid = info.registryID
        DispatchQueue.global(qos: .userInitiated).async {
            var entry = candidates[0]
            var r = DDCController.SwitchResult.noReply
            for e in candidates {
                entry = e
                r = self.ddc.switchInput(rid, to: e.code)
                if case .bounced = r {
                    DispatchQueue.main.async { self.noSignal.insert(e.code) }
                    continue
                }
                break
            }
            DispatchQueue.main.async {
                self.busy = false
                self.item.button?.appearsDisabled = false
                switch r {
                case .ok, .unverified:
                    self.noSignal.remove(entry.code)
                    self.markInCycle(info, entry.code)
                    if case .ok = r { self.ddc.guardInput(rid, code: entry.code) }
                case .bounced(let landed):
                    let back = self.store.displayConfig(for: info)?.inputs.first(where: { $0.code == landed })?.title
                        ?? guessInputName(landed, manufacturer: info.manufacturer)
                    self.alert("没切过去：显示器跳回了「\(back)」",
                               "显示器收到了切到「\(entry.title)」的指令，但那个口没有画面信号，所以自己跳回了有信号的口。\n\n请检查那台电脑：\n• 是否接在这个口上、是否开机\n• 是否在睡眠/锁屏黑屏（按一下它的键盘唤醒）\n• 笔记本合盖使用时是否接着电源\n• 视频线是否插紧")
                case .noReply:
                    self.alert("显示器没有回应",
                               "读写显示器失败。请确认显示器菜单里 DDC/CI 已开启；经过扩展坞/转接头时可能不透传 DDC/CI，可换直连线再试。")
                }
            }
        }
    }

    func markInCycle(_ info: DisplayInfo, _ code: Int) {
        guard var cfg = store.displayConfig(for: info),
              let i = cfg.inputs.firstIndex(where: { $0.code == code }),
              cfg.inputs[i].inCycle != true else { return }
        cfg.inputs[i].inCycle = true
        store.upsert(cfg)
    }

    // MARK: - 接口识别与管理

    @objc func probe(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef else { return }
        let a = NSAlert()
        a.messageText = "识别「\(ref.info.displayName)」的接口"
        a.informativeText = "接下来约 1–2 分钟，屏幕会多次切换输入源（会闪），结束后自动切回本机。\n\n请先保存手头工作，期间不要操作电脑。已填的电脑名字和快捷键会保留。"
        a.addButton(withTitle: "开始识别")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        startProbe(ref.info)
    }

    func startProbe(_ info: DisplayInfo) {
        if busy { return }
        busy = true
        item.button?.appearsDisabled = true
        let rid = info.registryID
        DispatchQueue.global(qos: .userInitiated).async {
            let r = self.ddc.probeInputs(rid) { _ in }
            DispatchQueue.main.async {
                self.busy = false
                self.item.button?.appearsDisabled = false
                self.applyProbe(info, r)
            }
        }
    }

    func applyProbe(_ info: DisplayInfo, _ r: DDCController.ProbeResult) {
        NSApp.activate(ignoringOtherApps: true)
        switch r {
        case .unreadable:
            // 不支持读回的显示器：给一份常见接口清单，用户可删改
            let defaults = [27, 17, 18, 15].map { InputEntry(code: $0, label: guessInputName($0, manufacturer: info.manufacturer)) }
            var cfg = store.displayConfig(for: info) ?? DisplayConfig(id: info.configID, name: info.displayName, inputs: [])
            if cfg.inputs.isEmpty { cfg.inputs = defaults; store.upsert(cfg) }
            alert("这台显示器不支持读取当前输入",
                  "无法自动识别，已先放入常见接口（USB-C、HDMI 1、HDMI 2、DisplayPort 1），可以直接试切换。\n切不过去的口可在「管理这台显示器」里删除，或用「手动添加编号」补充。")
        case .found(let home, let ports):
            var cfg = store.displayConfig(for: info) ?? DisplayConfig(id: info.configID, name: info.displayName, inputs: [])
            var merged: [InputEntry] = []
            var usedNames: [String: Int] = [:]
            for code in ports {
                if let old = cfg.inputs.first(where: { $0.code == code }) { merged.append(old); continue }
                var name = guessInputName(code, manufacturer: info.manufacturer)
                usedNames[name, default: 0] += 1
                if usedNames[name]! > 1 { name += " \(usedNames[name]!)" }
                var e = InputEntry(code: code, label: name)
                if code == home {
                    e.computer = Host.current().localizedName ?? "本机"
                    e.inCycle = true
                }
                merged.append(e)
            }
            // 识别不到但用户手动加过的口保留
            for old in cfg.inputs where !merged.contains(where: { $0.code == old.code }) { merged.append(old) }
            merged.sort { (portSortKey($0.label), $0.code) < (portSortKey($1.label), $1.code) }
            cfg.inputs = merged
            store.upsert(cfg)
            let list = merged.map { "  • \($0.title)" }.joined(separator: "\n")
            alert("识别完成：\(merged.count) 个接口",
                  "\(list)\n\n现在点菜单栏图标就能从菜单里选择切换。\n建议在「管理这台显示器 → 给接口填电脑名字」里写上每个口接的是哪台电脑。")
        }
    }

    @objc func learn(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef else { return }
        let a = NSAlert()
        a.messageText = "学习当前输入"
        a.informativeText = "用于自动识别漏掉的口：先用显示器按钮把画面切到那个口，然后（在那台电脑或本机）点「读取」。"
        a.addButton(withTitle: "读取")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        guard let code = ddc.currentInput(ref.info.registryID) else {
            alert("读取失败", "这台显示器不支持读取当前输入。")
            return
        }
        addEntry(ref.info, code: code)
    }

    @objc func addManual(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef else { return }
        guard let s = prompt("手动添加编号",
                             "填显示器内部的输入源编号（常见：15=DP1、16=DP2、17=HDMI1、18=HDMI2、27=USB-C，各家不同）。",
                             placeholder: "编号，如 18"),
              let code = Int(s), code > 0, code < 256 else { return }
        addEntry(ref.info, code: code)
    }

    func addEntry(_ info: DisplayInfo, code: Int) {
        var cfg = store.displayConfig(for: info) ?? DisplayConfig(id: info.configID, name: info.displayName, inputs: [])
        guard let label = prompt("接口名称", "会显示在菜单里。", initial: guessInputName(code, manufacturer: info.manufacturer)),
              !label.isEmpty else { return }
        if let i = cfg.inputs.firstIndex(where: { $0.code == code }) {
            cfg.inputs[i].label = label
        } else {
            cfg.inputs.append(InputEntry(code: code, label: label))
            cfg.inputs.sort { (portSortKey($0.label), $0.code) < (portSortKey($1.label), $1.code) }
        }
        store.upsert(cfg)
    }

    /// 弹出接口选择框，返回选中的接口下标。
    func choosePort(_ cfg: DisplayConfig, title: String, info text: String) -> Int? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        pop.addItems(withTitles: cfg.inputs.map { "\($0.title)（编号 \($0.code)）" })
        a.accessoryView = pop
        a.addButton(withTitle: "下一步")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return pop.indexOfSelectedItem
    }

    @objc func nameComputer(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef,
              var cfg = store.displayConfig(for: ref.info),
              let i = choosePort(cfg, title: "给接口填电脑名字", info: "选择接口：") else { return }
        guard let name = prompt("这个口接的是哪台电脑？", "例如 MacBook、Mac mini、公司 Windows。留空则清除。",
                                initial: cfg.inputs[i].computer ?? "") else { return }
        cfg.inputs[i].computer = name.isEmpty ? nil : name
        if !name.isEmpty { cfg.inputs[i].inCycle = true }
        store.upsert(cfg)
    }

    @objc func editCycle(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef,
              var cfg = store.displayConfig(for: ref.info) else { return }
        let a = NSAlert()
        a.messageText = "循环切换包含哪些接口"
        a.informativeText = "按循环切换快捷键时，只在勾选的接口之间轮换。切换成功过或填了电脑名字的口会自动勾上。"
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: CGFloat(cfg.inputs.count) * 24))
        stack.orientation = .vertical
        stack.alignment = .leading
        var boxes: [NSButton] = []
        for e in cfg.inputs {
            let b = NSButton(checkboxWithTitle: e.title, target: nil, action: nil)
            b.state = e.inCycle == true ? .on : .off
            boxes.append(b)
            stack.addArrangedSubview(b)
        }
        a.accessoryView = stack
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for (i, b) in boxes.enumerated() { cfg.inputs[i].inCycle = b.state == .on }
        store.upsert(cfg)
    }

    @objc func deleteInput(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef,
              var cfg = store.displayConfig(for: ref.info),
              let i = choosePort(cfg, title: "删除接口", info: "选择要从菜单里删掉的接口：") else { return }
        hotkeys.set(nil, for: .port(cfg.id, cfg.inputs[i].code))
        cfg.inputs.remove(at: i)
        store.upsert(cfg)
    }

    // MARK: - 快捷键

    @objc func setCycleHotkey() {
        if let hk = HotkeyRecorder.record(title: "设置循环切换快捷键", current: hotkeys.binding(for: .cycle)) {
            if !hotkeys.set(hk, for: .cycle) { alert("快捷键被占用", "\(hk.display) 已被别的程序使用，请换一个。") }
        }
    }

    @objc func clearCycleHotkey() { hotkeys.set(nil, for: .cycle) }

    @objc func setPortHotkey(_ sender: NSMenuItem) {
        guard let ref = sender.representedObject as? ProbeRef,
              let cfg = store.displayConfig(for: ref.info),
              let i = choosePort(cfg, title: "设置接口快捷键", info: "按下快捷键会直接切到这个接口。选择接口：") else { return }
        let action = HotkeyAction.port(cfg.id, cfg.inputs[i].code)
        let r = HotkeyRecorder.record(title: "「\(cfg.inputs[i].title)」的快捷键", current: hotkeys.binding(for: action), allowClear: true)
        switch r {
        case .none: return
        case .some(let hk) where hk.keyCode == HotkeyRecorder.clearSentinel: hotkeys.set(nil, for: action)
        case .some(let hk):
            if !hotkeys.set(hk, for: action) { alert("快捷键被占用", "\(hk.display) 已被别的程序使用，请换一个。") }
        }
    }

    // MARK: - 关于 / 更新

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let header = "多台电脑共用一台显示器时切换输入源。\n开源仓库：github.com/\(repoSlug)"
        // 先弹「正在检查」，结果回来后换成结果框
        let wait = NSAlert()
        wait.messageText = "显示器切换 \(appVersion)"
        wait.informativeText = header + "\n\n正在检查更新…"
        wait.addButton(withTitle: "关闭")
        var result: (UpdateInfo?, String?)? = nil
        Updater.fetchLatest { info, err in
            DispatchQueue.main.async {
                result = (info, err)
                if wait.window.isVisible { NSApp.stopModal(withCode: .OK) }
            }
        }
        let r0 = wait.runModal()
        wait.window.orderOut(nil)
        guard r0 == .OK, let (info, err) = result else { return }

        let a = NSAlert()
        a.messageText = "显示器切换 \(appVersion)"
        if let info = info, Updater.isNewer(info.version, than: appVersion) {
            availableUpdate = info
            let notes = info.notes.isEmpty ? "" : "\n\n更新内容：\n\(info.notes.prefix(500))"
            a.informativeText = header + "\n\n发现新版本 \(info.version)。" + notes
            a.addButton(withTitle: "升级到 \(info.version)")
            a.addButton(withTitle: "以后再说")
            if a.runModal() == .alertFirstButtonReturn { installUpdate(info) }
            return
        }
        a.informativeText = header + (info != nil ? "\n\n已是最新版本。" : "\n\n检查更新失败：\(err ?? "网络错误")")
        a.addButton(withTitle: "好")
        a.addButton(withTitle: "打开 GitHub")
        if a.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "https://github.com/\(repoSlug)/releases")!)
        }
    }

    func checkUpdateQuietly() {
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        if Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        Updater.fetchLatest { info, _ in
            DispatchQueue.main.async {
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
                if let info = info, Updater.isNewer(info.version, than: appVersion) { self.availableUpdate = info }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6 * 3600) { self.checkUpdateQuietly() }
    }

    @objc func installUpdateFromMenu() {
        guard let u = availableUpdate else { return }
        installUpdate(u)
    }

    func installUpdate(_ u: UpdateInfo) {
        if busy { return }
        busy = true
        item.button?.appearsDisabled = true
        Updater.install(u) { err in
            DispatchQueue.main.async {
                self.busy = false
                self.item.button?.appearsDisabled = false
                if let err = err {
                    self.alert("升级失败", "\(err)\n\n可以到 GitHub 发布页手动下载：github.com/\(repoSlug)/releases")
                } else {
                    NSApp.terminate(nil)   // 安装脚本等本进程退出后替换并重新打开
                }
            }
        }
    }

    // MARK: - 其他

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

    func prompt(_ title: String, _ msg: String, initial: String = "", placeholder: String = "") -> String? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = initial
        tf.placeholderString = placeholder
        a.accessoryView = tf
        NSApp.activate(ignoringOtherApps: true)
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        return tf.stringValue.trimmingCharacters(in: .whitespaces)
    }

    func alert(_ title: String, _ msg: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = msg
        a.runModal()
    }
}

// MARK: - 快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）

enum HotkeyAction: Hashable {
    case cycle
    case port(String, Int)   // 显示器 configID, 输入编号

    var key: String {
        switch self {
        case .cycle: return "cycle"
        case .port(let d, let c): return "port|\(d)|\(c)"
        }
    }

    init?(key: String) {
        if key == "cycle" { self = .cycle; return }
        let p = key.split(separator: "|", omittingEmptySubsequences: false)
        guard p.count == 3, p[0] == "port", let c = Int(p[2]) else { return nil }
        self = .port(String(p[1]), c)
    }
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon 修饰键
    var display: String
}

final class HotkeyManager {
    static let shared = HotkeyManager()
    var onFire: ((HotkeyAction) -> Void)?
    private var bindings: [String: Hotkey] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var idToAction: [UInt32: HotkeyAction] = [:]
    private var handler: EventHandlerRef?
    private let defaultsKey = "hotkeys.v2"

    func loadAndRegister() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let b = try? JSONDecoder().decode([String: Hotkey].self, from: data) {
            bindings = b
        } else {
            // 首次运行：默认循环切换 ⌃⌥`
            bindings = ["cycle": Hotkey(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey | optionKey), display: "⌃⌥`")]
            persist()
        }
        installHandler()
        reregister()
    }

    func binding(for a: HotkeyAction) -> Hotkey? { bindings[a.key] }

    /// 设置/清除快捷键。返回 false 表示系统里已被占用。
    @discardableResult
    func set(_ hk: Hotkey?, for a: HotkeyAction) -> Bool {
        let old = bindings[a.key]
        if let hk = hk {
            // 同一组合只保留一个动作
            for (k, v) in bindings where v.keyCode == hk.keyCode && v.modifiers == hk.modifiers { bindings[k] = nil }
            bindings[a.key] = hk
        } else {
            bindings[a.key] = nil
        }
        let ok = reregister(check: a)
        if !ok { bindings[a.key] = old; reregister() }
        persist()
        return ok
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(bindings) { UserDefaults.standard.set(d, forKey: defaultsKey) }
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, userData) -> OSStatus in
            guard let ud = userData, let event = event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let me = Unmanaged<HotkeyManager>.fromOpaque(ud).takeUnretainedValue()
            if let a = me.idToAction[hkID.id] { DispatchQueue.main.async { me.onFire?(a) } }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    private func reregister(check: HotkeyAction? = nil) -> Bool {
        for (_, r) in refs { UnregisterEventHotKey(r) }
        refs.removeAll(); idToAction.removeAll()
        var ok = true
        var nextID: UInt32 = 1
        for (k, hk) in bindings.sorted(by: { $0.key < $1.key }) {
            guard let action = HotkeyAction(key: k) else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4D535749), id: nextID) // 'MSWI'
            let st = RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref = ref {
                refs[nextID] = ref
                idToAction[nextID] = action
            } else if action == check {
                ok = false
            }
            nextID += 1
        }
        return ok
    }
}

/// 录制快捷键：弹框后直接按组合键。
enum HotkeyRecorder {
    static let clearSentinel: UInt32 = 0xFFFF

    static func record(title: String, current: Hotkey?, allowClear: Bool = false) -> Hotkey? {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "现在按下想用的组合键（至少带 ⌃ ⌥ ⌘ 其中一个；F1–F12 可单独用）。\n当前：\(current?.display ?? "未设置")"
        let label = NSTextField(labelWithString: "等待按键…")
        label.font = .systemFont(ofSize: 20, weight: .medium)
        label.frame = NSRect(x: 0, y: 0, width: 260, height: 30)
        a.accessoryView = label
        a.addButton(withTitle: "保存")
        a.addButton(withTitle: "取消")
        if allowClear { a.addButton(withTitle: "清除") }
        a.buttons[0].isEnabled = false
        var captured: Hotkey?
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if let hk = make(e) {
                captured = hk
                label.stringValue = hk.display
                a.buttons[0].isEnabled = true
                return nil
            }
            if e.keyCode == UInt16(kVK_Escape) { return e }
            label.stringValue = "需要带 ⌃ ⌥ ⌘ 修饰键"
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)
        let r = a.runModal()
        if let m = monitor { NSEvent.removeMonitor(m) }
        if r == .alertFirstButtonReturn { return captured }
        if allowClear && r == .alertThirdButtonReturn { return Hotkey(keyCode: clearSentinel, modifiers: 0, display: "") }
        return nil
    }

    static func make(_ e: NSEvent) -> Hotkey? {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        var s = ""
        if f.contains(.control) { mods |= UInt32(controlKey); s += "⌃" }
        if f.contains(.option) { mods |= UInt32(optionKey); s += "⌥" }
        if f.contains(.shift) { mods |= UInt32(shiftKey); s += "⇧" }
        if f.contains(.command) { mods |= UInt32(cmdKey); s += "⌘" }
        let fkeys: [Int: String] = [kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
                                    kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12"]
        let code = Int(e.keyCode)
        let keyName: String
        if let fk = fkeys[code] { keyName = fk }
        else if code == kVK_Space { keyName = "Space" }
        else if code == kVK_ANSI_Grave { keyName = "`" }
        else { keyName = (e.charactersIgnoringModifiers ?? "").uppercased() }
        if keyName.isEmpty { return nil }
        let hasMod = mods & UInt32(controlKey | optionKey | cmdKey) != 0
        if !hasMod && fkeys[code] == nil { return nil }
        return Hotkey(keyCode: UInt32(code), modifiers: mods, display: s + keyName)
    }
}

// MARK: - 自动更新（GitHub Releases）

struct UpdateInfo {
    let version: String
    let notes: String
    let assetURL: URL
}

enum Updater {
    static func fetchLatest(_ done: @escaping (UpdateInfo?, String?) -> Void) {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("DisplaySwitch/\(appVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { done(nil, err.localizedDescription); return }
            guard let data = data,
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = j["tag_name"] as? String else {
                done(nil, "GitHub 返回异常（\((resp as? HTTPURLResponse)?.statusCode ?? 0)）"); return
            }
            let assets = j["assets"] as? [[String: Any]] ?? []
            let mac = assets.first { (($0["name"] as? String) ?? "").lowercased().contains("macos") }
            guard let urlStr = mac?["browser_download_url"] as? String, let url = URL(string: urlStr) else {
                done(nil, "最新发布 \(tag) 里没有 Mac 安装包"); return
            }
            let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            done(UpdateInfo(version: v, notes: j["body"] as? String ?? "", assetURL: url), nil)
        }.resume()
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 下载 zip → 解压 → 校验包标识 → 写一个安装脚本，等本进程退出后替换自身并重新打开。
    static func install(_ u: UpdateInfo, done: @escaping (String?) -> Void) {
        URLSession.shared.downloadTask(with: u.assetURL) { tmp, _, err in
            if let err = err { done("下载失败：\(err.localizedDescription)"); return }
            guard let tmp = tmp else { done("下载失败"); return }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("DisplaySwitch-update-\(u.version)")
            try? fm.removeItem(at: work)
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            do { try fm.moveItem(at: tmp, to: zip) } catch { done("保存下载失败"); return }
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", zip.path, work.path]
            do { try unzip.run(); unzip.waitUntilExit() } catch { done("解压失败"); return }
            guard unzip.terminationStatus == 0 else { done("解压失败"); return }
            guard let newApp = findApp(in: work) else { done("安装包里没有找到 .app"); return }
            let newID = Bundle(url: newApp)?.bundleIdentifier
            guard newID == Bundle.main.bundleIdentifier else { done("安装包标识不匹配，已停止升级"); return }

            let target = Bundle.main.bundlePath
            let backup = work.appendingPathComponent("previous.app").path
            let script = """
            #!/bin/bash
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done
            /usr/bin/xattr -dr com.apple.quarantine "\(newApp.path)" 2>/dev/null
            /bin/mv "\(target)" "\(backup)" || exit 1
            if /usr/bin/ditto "\(newApp.path)" "\(target)"; then
              /usr/bin/open "\(target)"
            else
              /bin/rm -rf "\(target)"; /bin/mv "\(backup)" "\(target)"; /usr/bin/open "\(target)"
            fi
            """
            let sp = work.appendingPathComponent("install.sh")
            do {
                try script.write(to: sp, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sp.path)
            } catch { done("写安装脚本失败"); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", "nohup \"\(sp.path)\" >/dev/null 2>&1 &"]
            do { try p.run(); p.waitUntilExit() } catch { done("启动安装失败"); return }
            done(nil)
        }.resume()
    }

    private static func findApp(in dir: URL) -> URL? {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        while let u = e?.nextObject() as? URL {
            if u.pathExtension == "app" { return u }
        }
        return nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

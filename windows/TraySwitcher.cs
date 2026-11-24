// TraySwitcher.cs — Windows 版 显示器切换 v2（多台电脑共用一台显示器）
// 对齐 Mac 版 2.0：
//   - 多机清单（JSON 存 %LocalAppData%\显示器切换\config.json）
//   - 切换带读回验证
//   - 自动探测输入口 / 学习当前输入 / 手动添加 / 改名删除
//   - 热键 Ctrl+Alt+` 循环切换
// 只用 .NET 自带组件（Windows 自带 csc 可编）。
//
// 编译：
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe ^
//     /out:TraySwitcher.exe /r:System.Windows.Forms.dll /r:System.Drawing.dll TraySwitcher.cs

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace MonitorSwitch
{
    public class InputEntry { public int Code; public string Label; }

    public class DisplayConfig
    {
        public string Id = "";
        public string Name = "";
        public List<InputEntry> Inputs = new List<InputEntry>();
    }

    // ---------- 配置（简单 JSON 手写解析，避免依赖 .NET 4 外的库） ----------
    static class ConfigStore
    {
        static string Dir => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "显示器切换");
        static string Path => System.IO.Path.Combine(Dir, "config.json");
        public static List<DisplayConfig> Displays = new List<DisplayConfig>();

        public static void Load()
        {
            try
            {
                if (File.Exists(Path))
                {
                    Displays = ParseJson(File.ReadAllText(Path, Encoding.UTF8));
                    if (Displays.Count > 0) return;
                }
            }
            catch { }
            MigrateIni();
        }

        public static void Save()
        {
            try
            {
                Directory.CreateDirectory(Dir);
                File.WriteAllText(Path, ToJson(), Encoding.UTF8);
            }
            catch { }
        }

        static void MigrateIni()
        {
            // 读 exe 同目录的 TraySwitcher.ini（旧版格式：编号,名称）
            string ini = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "TraySwitcher.ini");
            if (!File.Exists(ini)) return;
            var inputs = new List<InputEntry>();
            foreach (string raw in File.ReadAllLines(ini))
            {
                string line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                int comma = line.IndexOf(',');
                int code;
                if (comma > 0 && int.TryParse(line.Substring(0, comma).Trim(), out code) && code > 0)
                    inputs.Add(new InputEntry { Code = code, Label = line.Substring(comma + 1).Trim() });
                else if (int.TryParse(line, out code) && code > 0)
                    inputs.Add(new InputEntry { Code = code, Label = "input " + code });
            }
            if (inputs.Count == 0) return;
            Displays.Add(new DisplayConfig { Id = "*", Name = "显示器", Inputs = inputs });
            Save();
        }

        static string Esc(string s) => s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");

        static string ToJson()
        {
            var sb = new StringBuilder("{\"version\":2,\"displays\":[");
            for (int i = 0; i < Displays.Count; i++)
            {
                var d = Displays[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"id\":\"").Append(Esc(d.Id)).Append("\",\"name\":\"").Append(Esc(d.Name)).Append("\",\"inputs\":[");
                for (int j = 0; j < d.Inputs.Count; j++)
                {
                    if (j > 0) sb.Append(',');
                    sb.Append("{\"code\":").Append(d.Inputs[j].Code).Append(",\"label\":\"").Append(Esc(d.Inputs[j].Label)).Append("\"}");
                }
                sb.Append("]}");
            }
            sb.Append("]}");
            return sb.ToString();
        }

        static List<DisplayConfig> ParseJson(string s)
        {
            // 极简解析：只认本程序自己写的格式
            var list = new List<DisplayConfig>();
            int di = 0;
            while ((di = s.IndexOf("\"id\":\"", di)) >= 0)
            {
                var d = new DisplayConfig();
                d.Id = ReadString(s, di + 6, out int end);
                di = end;
                int ni = s.IndexOf("\"name\":\"", di); if (ni < 0) break;
                d.Name = ReadString(s, ni + 8, out end); di = end;
                int ii = s.IndexOf("\"inputs\":[", di); if (ii < 0) break;
                int close = s.IndexOf(']', ii); if (close < 0) break;
                string arr = s.Substring(ii + 10, close - ii - 10);
                int ci = 0;
                while ((ci = arr.IndexOf("\"code\":", ci)) >= 0)
                {
                    int v = 0, k = ci + 7;
                    while (k < arr.Length && char.IsDigit(arr[k])) { v = v * 10 + arr[k] - '0'; k++; }
                    int li = arr.IndexOf("\"label\":\"", k); if (li < 0) break;
                    string label = ReadString(arr, li + 9, out int lend);
                    list.Count.ToString(); // noop
                    d.Inputs.Add(new InputEntry { Code = v, Label = label });
                    ci = lend;
                }
                list.Add(d);
            }
            return list;
        }

        static string ReadString(string s, int start, out int end)
        {
            var sb = new StringBuilder();
            int i = start;
            while (i < s.Length && s[i] != '"')
            {
                if (s[i] == '\\' && i + 1 < s.Length) { sb.Append(s[i + 1]); i += 2; continue; }
                sb.Append(s[i++]);
            }
            end = i + 1;
            return sb.ToString();
        }
    }

    // ---------- DDC/CI（dxva2） ----------
    static class Ddc
    {
        delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct PHYSICAL_MONITOR
        {
            public IntPtr hPhysicalMonitor;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        }

        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);
        [DllImport("dxva2.dll", CharSet = CharSet.Unicode)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);
        [DllImport("dxva2.dll")] static extern bool GetVCPFeatureandVCPFeatureReply(IntPtr hMonitor, byte code, ref uint vcpType, ref uint current, ref uint maximum);
        [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr hMonitor, byte code, uint value);
        [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);
        [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        const uint MOD_CONTROL = 0x0002, MOD_ALT = 0x0001, VK_OEM_3 = 0xC0;
        const int HOTKEY_ID = 1;

        public class MonitorHandle { public IntPtr H; public string Desc; }
        static List<MonitorHandle> _monitors;

        public static List<MonitorHandle> PhysicalMonitors()
        {
            var hs = new List<IntPtr>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
                (IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) => { hs.Add(h); return true; }, IntPtr.Zero);
            var result = new List<MonitorHandle>();
            foreach (var hm in hs)
            {
                uint n = 0;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, ref n) || n == 0) continue;
                var arr = new PHYSICAL_MONITOR[n];
                if (!GetPhysicalMonitorsFromHMONITOR(hm, n, arr)) continue;
                foreach (var m in arr)
                    result.Add(new MonitorHandle { H = m.hPhysicalMonitor, Desc = m.Description ?? "" });
            }
            _monitors = result;
            return result;
        }

        public static bool GetInput(IntPtr h, out int code)
        {
            uint t = 0, cur = 0, max = 0;
            if (GetVCPFeatureandVCPFeatureReply(h, 0x60, ref t, ref cur, ref max)) { code = (int)cur; return true; }
            code = -1; return false;
        }

        public static bool SetInput(IntPtr h, int code) => SetVCPFeature(h, 0x60, (uint)code);

        public static bool SwitchToVerify(IntPtr h, int code)
        {
            if (!SetInput(h, code)) return false;
            var deadline = DateTime.Now.AddSeconds(3.5);
            while (DateTime.Now < deadline)
            {
                int cur;
                if (GetInput(h, out cur) && cur == code) return true;
                Thread.Sleep(250);
            }
            return false;
        }

        public static (List<int> accepted, List<int> bounced) Probe(IntPtr h, Action<double> progress)
        {
            var accepted = new List<int>();
            var bounced = new List<int>();
            int home;
            GetInput(h, out home);
            for (int c = 1; c <= 36; c++)
            {
                if (c == home) { progress(c / 36.0); continue; }
                SetInput(h, c);
                int r = -1;
                var dl = DateTime.Now.AddSeconds(2.6);
                while (DateTime.Now < dl)
                {
                    if (GetInput(h, out r)) break;
                    Thread.Sleep(120);
                }
                if (r == c) accepted.Add(c);
                else if (r >= 0 && r != home) bounced.Add(c);
                progress(c / 36.0);
            }
            if (home >= 0) { int cur; GetInput(h, out cur); if (cur != home) SetInput(h, home); }
            return (accepted, bounced);
        }

        // 热键
        public static bool RegisterHotkey(IntPtr hwnd) => RegisterHotKey(hwnd, HOTKEY_ID, MOD_CONTROL | MOD_ALT, VK_OEM_3);
        public static void UnregisterHotkey(IntPtr hwnd) => UnregisterHotKey(hwnd, HOTKEY_ID);
        public const int WM_HOTKEY = 0x0312;
    }

    // ---------- 简单输入框 ----------
    static class InputBox
    {
        public static string Show(string title, string prompt, string def = "")
        {
            var f = new Form { Text = title, Width = 380, Height = 170, StartPosition = FormStartPosition.CenterScreen, TopMost = true };
            var lbl = new Label { Left = 12, Top = 10, Width = 350, Height = 40, Text = prompt };
            var tb = new TextBox { Left = 12, Top = 55, Width = 340, Text = def };
            var ok = new Button { Text = "保存", Left = 190, Width = 75, Top = 95, DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "取消", Left = 275, Width = 75, Top = 95, DialogResult = DialogResult.Cancel };
            f.Controls.AddRange(new Control[] { lbl, tb, ok, cancel });
            f.AcceptButton = ok; f.CancelButton = cancel;
            return f.ShowDialog() == DialogResult.OK ? tb.Text.Trim() : null;
        }
    }

    // ---------- 主程序 ----------
    public class TrayApp : Form
    {
        NotifyIcon icon;
        ContextMenu menu;
        Ddc.MonitorHandle primary;
        int lastKnown = -1;
        bool hotkeyOn;

        [STAThread]
        static void Main() { Application.Run(new TrayApp()); }

        public TrayApp()
        {
            ConfigStore.Load();
            ShowInTaskbar = false;
            WindowState = FormWindowState.Minimized;
            FormBorderStyle = FormBorderStyle.FixedToolWindow;
            Opacity = 0;
            Show();

            icon = new NotifyIcon
            {
                Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
                Text = "显示器切换 (左键切换，右键选机器)",
                Visible = true
            };
            menu = new ContextMenu();
            menu.Popup += (s, e) => BuildMenu();
            icon.ContextMenu = menu;
            icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) CycleNext(); };
            Application.ApplicationExit += (s, e) => icon.Visible = false;
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Ddc.WM_HOTKEY) CycleNext();
            base.WndProc(ref m);
        }

        Ddc.MonitorHandle Primary()
        {
            var ms = Ddc.PhysicalMonitors();
            if (ms.Count == 0) return null;
            if (primary == null || !ms.Exists(x => x.H == primary.H)) primary = ms[0];
            return primary;
        }

        DisplayConfig Cfg()
        {
            if (ConfigStore.Displays.Count == 0)
                ConfigStore.Displays.Add(new DisplayConfig { Id = "*", Name = "显示器" });
            return ConfigStore.Displays[0];
        }

        int? CurrentInput(IntPtr h) { int c; return Ddc.GetInput(h, out c) ? c : (int?)null; }

        void BuildMenu()
        {
            menu.MenuItems.Clear();
            var h = Primary();
            if (h == null)
            {
                var it = new MenuItem("没有检测到外接显示器") { Enabled = false };
                menu.MenuItems.Add(it);
            }
            else
            {
                var cfg = Cfg();
                int? cur = lastKnown >= 0 ? lastKnown : CurrentInput(h.H);
                if (cfg.Inputs.Count == 0)
                    menu.MenuItems.Add(new MenuItem("（还没有输入口，先添加）") { Enabled = false });
                foreach (var e in cfg.Inputs)
                {
                    var entry = e;
                    var mi = new MenuItem("切到 " + e.Label, (s, a) => DoSwitch(h.H, entry));
                    mi.Checked = cur == e.Code;
                    menu.MenuItems.Add(mi);
                }
                menu.MenuItems.Add("-");
                var probe = new MenuItem("自动探测输入口…", (s, a) => ProbeRun(h.H));
                var learn = new MenuItem("学习当前输入…", (s, a) => Learn(h.H));
                var manual = new MenuItem("手动添加输入口…", (s, a) => AddManual());
                var edit = new MenuItem("重命名/删除输入口…", (s, a) => EditInputs());
                menu.MenuItems.Add(probe); menu.MenuItems.Add(learn); menu.MenuItems.Add(manual); menu.MenuItems.Add(edit);
                menu.MenuItems.Add("-");
            }
            menu.MenuItems.Add(new MenuItem("查看当前在哪台", (s, a) => ShowCurrent()));
            var hot = new MenuItem("热键 Ctrl+Alt+` 循环切换", (s, a) => ToggleHotkey());
            hot.Checked = hotkeyOn;
            menu.MenuItems.Add(hot);
            menu.MenuItems.Add("-");
            menu.MenuItems.Add(new MenuItem("退出", (s, a) => Application.Exit()));
        }

        void CycleNext()
        {
            var h = Primary();
            var cfg = Cfg();
            if (h == null || cfg.Inputs.Count == 0)
            {
                Balloon("还没有机器清单", "请从右键菜单用「自动探测」或「学习当前输入」添加。", ToolTipIcon.Warning);
                return;
            }
            int? cur = lastKnown >= 0 ? lastKnown : CurrentInput(h.H);
            InputEntry next;
            if (cur.HasValue)
            {
                int i = cfg.Inputs.FindIndex(x => x.Code == cur.Value);
                next = cfg.Inputs[(i + 1) % cfg.Inputs.Count];
            }
            else next = cfg.Inputs[0];
            DoSwitch(h.H, next);
        }

        void DoSwitch(IntPtr h, InputEntry e)
        {
            lastKnown = e.Code;
            bool ok = Ddc.SwitchToVerify(h, e.Code);
            if (!ok)
            {
                lastKnown = -1;
                Balloon("切换未确认", "显示器没有确认已切到「" + e.Label + "」。\n可能是目标输入没信号源、显示器弹回，或 DDC/CI 关闭。", ToolTipIcon.Warning);
            }
            else
            {
                Balloon("显示器切换", "已切到 " + e.Label, ToolTipIcon.Info);
            }
        }

        void ShowCurrent()
        {
            var h = Primary();
            if (h == null) { Balloon("无显示器", "没有检测到外接显示器", ToolTipIcon.Warning); return; }
            int c;
            if (Ddc.GetInput(h.H, out c))
            {
                lastKnown = c;
                var name = Cfg().Inputs.Find(x => x.Code == c)?.Label ?? "未命名输入口";
                Balloon("当前输入", "编号 " + c + " — " + name, ToolTipIcon.Info);
            }
            else Balloon("读取失败", "显示器暂时不支持读取", ToolTipIcon.Warning);
        }

        void Learn(IntPtr h)
        {
            var r = MessageBox.Show(
                "先用显示器按钮/摇杆把画面切到这台显示器当前正在显示的那个输入口（也就是本机现在用的口），然后点「确定」读码。", 
                "学习当前输入", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (r != DialogResult.OK) return;
            int code;
            if (!Ddc.GetInput(h, out code)) { Balloon("读取失败", "显示器暂时不支持读取", ToolTipIcon.Warning); return; }
            var name = InputBox.Show("给这个输入口起名", "会显示在菜单里，例如「MacBook (USB-C)」", GuessName(code));
            if (name == null) return;
            var cfg = Cfg();
            var ex = cfg.Inputs.Find(x => x.Code == code);
            if (ex != null) ex.Label = name; else cfg.Inputs.Add(new InputEntry { Code = code, Label = name });
            cfg.Inputs.Sort((a, b) => a.Code.CompareTo(b.Code));
            ConfigStore.Save();
        }

        void AddManual()
        {
            var s = InputBox.Show("手动添加输入口", "填显示器内部的输入源编号（常见：15=DP1、17=HDMI1、18=HDMI2、27=USB-C）", "");
            if (s == null) return;
            int code;
            if (!int.TryParse(s, out code) || code <= 0) { Balloon("编号无效", "请输入正整数", ToolTipIcon.Warning); return; }
            var name = InputBox.Show("给这个输入口起名", "会显示在菜单里", GuessName(code));
            if (name == null) return;
            var cfg = Cfg();
            var ex = cfg.Inputs.Find(x => x.Code == code);
            if (ex != null) ex.Label = name; else cfg.Inputs.Add(new InputEntry { Code = code, Label = name });
            cfg.Inputs.Sort((a, b) => a.Code.CompareTo(b.Code));
            ConfigStore.Save();
        }

        void EditInputs()
        {
            var cfg = Cfg();
            if (cfg.Inputs.Count == 0) { Balloon("没有输入口", "这台显示器还没有机器清单", ToolTipIcon.Warning); return; }
            var list = new StringBuilder();
            for (int i = 0; i < cfg.Inputs.Count; i++)
                list.Append((i + 1)).Append(". ").Append(cfg.Inputs[i].Label).Append("（编号 ").Append(cfg.Inputs[i].Code).Append("）\n");
            var s = InputBox.Show("输入口管理（" + cfg.Inputs.Count + " 个）",
                list + "\n输入要删除的序号；要改名请输入「序号 新名字」。留空则关闭。", "");
            if (string.IsNullOrEmpty(s)) return;
            var parts = s.Split(new[] { ' ' }, 2, StringSplitOptions.RemoveEmptyEntries);
            int idx;
            if (!int.TryParse(parts[0], out idx) || idx < 1 || idx > cfg.Inputs.Count) return;
            if (parts.Length == 1) cfg.Inputs.RemoveAt(idx - 1);
            else cfg.Inputs[idx - 1].Label = parts[1];
            ConfigStore.Save();
        }

        void ProbeRun(IntPtr h)
        {
            var r = MessageBox.Show(
                "接下来约 90 秒，屏幕会多次切换输入源（会闪），结束后自动切回来。\n探测期间请保存手头工作、不要操作电脑。",
                "自动探测输入口", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (r != DialogResult.OK) return;
            Balloon("正在探测…", "屏幕会切换，请稍候", ToolTipIcon.Info);
            var res = Ddc.Probe(h, p => { });
            var lines = new StringBuilder();
            foreach (var c in res.accepted) lines.Append("  ✓ " + GuessName(c) + "（编号 " + c + "）\n");
            if (res.bounced.Count > 0)
            {
                lines.Append("\n以下编号写进去后跳到别的口（可候选）：\n");
                foreach (var b in res.bounced) lines.Append("  ? 写 " + b + "\n");
            }
            var ask = MessageBox.Show(lines + "\n保存这些结果？", "探测结果", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (ask != DialogResult.OK) return;
            var cfg = Cfg();
            foreach (var c in res.accepted)
                if (!cfg.Inputs.Exists(x => x.Code == c)) cfg.Inputs.Add(new InputEntry { Code = c, Label = GuessName(c) });
            cfg.Inputs.Sort((a, b) => a.Code.CompareTo(b.Code));
            ConfigStore.Save();
        }

        void ToggleHotkey()
        {
            hotkeyOn = !hotkeyOn;
            if (hotkeyOn) Ddc.RegisterHotkey(Handle); else Ddc.UnregisterHotkey(Handle);
        }

        string GuessName(int code)
        {
            switch (code)
            {
                case 1: return "VGA";
                case 3: return "DVI-1"; case 4: return "DVI-2";
                case 15: return "DisplayPort 1"; case 16: return "DisplayPort 2";
                case 17: return "HDMI 1"; case 18: return "HDMI 2"; case 19: return "HDMI 3"; case 20: return "HDMI 4";
                case 27: return "USB-C";
                case 33: case 34: case 35: return "USB-C" + (code - 32);
                default: return "输入 " + code;
            }
        }

        void Balloon(string t, string m, ToolTipIcon ic) =>
            icon.ShowBalloonTip(2000, t, m, ic);
    }
}

// TraySwitcher.cs — Windows 版 显示器切换（多台电脑共用一台显示器）
// 与 Mac 版对齐：
//   - 点托盘图标弹出菜单，从菜单选接口切换（点图标本身不切换）
//   - 快捷键可自定义：循环切换 + 每个接口的直达快捷键
//   - 新显示器自动识别全部接口（USB-C / HDMI / DP …），没接电脑的口也能识别
//   - 切换后守住输入，防止显示器的自动信号源跳回
//   - 「关于」里检查更新，从 GitHub Releases 下载新版并替换
// 只用 .NET Framework 自带组件，按 C# 5 语法写，Windows 自带 csc 可编译：
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /codepage:65001 /target:winexe ^
//     /out:TraySwitcher.exe /r:System.Windows.Forms.dll /r:System.Drawing.dll TraySwitcher.cs

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace MonitorSwitch
{
    public static class AppInfo
    {
        public const string Version = "2.1.0";
        public const string Repo = "Mr-c1203/display-switch";
    }

    public class InputEntry
    {
        public int Code;
        public string Label = "";
        public string Computer = "";
        public bool InCycle;
        public string Title { get { return string.IsNullOrEmpty(Computer) ? Label : Label + " — " + Computer; } }
    }

    public class DisplayConfig
    {
        public string Id = "";
        public string Name = "";
        public List<InputEntry> Inputs = new List<InputEntry>();
    }

    public class HotkeyBinding
    {
        public string Action = "";   // "cycle" 或 "port|显示器Id|编号"
        public uint Mods;
        public uint Vk;
        public string Display = "";
    }

    // ---------- 配置（手写 JSON，避免依赖额外库） ----------
    static class ConfigStore
    {
        public static List<DisplayConfig> Displays = new List<DisplayConfig>();
        public static List<HotkeyBinding> Hotkeys = new List<HotkeyBinding>();
        static bool hotkeysLoaded;

        static string Dir
        {
            get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "显示器切换"); }
        }
        static string FilePath { get { return Path.Combine(Dir, "config.json"); } }

        public static void Load()
        {
            try
            {
                if (File.Exists(FilePath)) Parse(File.ReadAllText(FilePath, Encoding.UTF8));
            }
            catch { }
            if (!hotkeysLoaded)
                Hotkeys.Add(new HotkeyBinding { Action = "cycle", Mods = Ddc.MOD_CONTROL | Ddc.MOD_ALT, Vk = 0xC0, Display = "Ctrl+Alt+`" });
        }

        public static void Save()
        {
            try
            {
                Directory.CreateDirectory(Dir);
                File.WriteAllText(FilePath, ToJson(), new UTF8Encoding(false));
            }
            catch { }
        }

        public static DisplayConfig Find(string id)
        {
            return Displays.Find(delegate(DisplayConfig d) { return d.Id == id; });
        }

        public static void Upsert(DisplayConfig dc)
        {
            int i = Displays.FindIndex(delegate(DisplayConfig d) { return d.Id == dc.Id; });
            if (i >= 0) Displays[i] = dc; else Displays.Add(dc);
            Save();
        }

        static string Esc(string s)
        {
            if (s == null) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n");
        }

        static string ToJson()
        {
            var sb = new StringBuilder("{\n  \"version\": 3,\n  \"displays\": [");
            for (int i = 0; i < Displays.Count; i++)
            {
                var d = Displays[i];
                if (i > 0) sb.Append(',');
                sb.Append("\n    {\"id\": \"").Append(Esc(d.Id)).Append("\", \"name\": \"").Append(Esc(d.Name)).Append("\", \"inputs\": [");
                for (int j = 0; j < d.Inputs.Count; j++)
                {
                    var e = d.Inputs[j];
                    if (j > 0) sb.Append(',');
                    sb.Append("\n      {\"code\": ").Append(e.Code)
                      .Append(", \"label\": \"").Append(Esc(e.Label))
                      .Append("\", \"computer\": \"").Append(Esc(e.Computer))
                      .Append("\", \"inCycle\": ").Append(e.InCycle ? "true" : "false").Append('}');
                }
                sb.Append("]}");
            }
            sb.Append("\n  ],\n  \"hotkeys\": [");
            for (int i = 0; i < Hotkeys.Count; i++)
            {
                var h = Hotkeys[i];
                if (i > 0) sb.Append(',');
                sb.Append("\n    {\"action\": \"").Append(Esc(h.Action)).Append("\", \"mods\": ").Append(h.Mods)
                  .Append(", \"vk\": ").Append(h.Vk).Append(", \"display\": \"").Append(Esc(h.Display)).Append("\"}");
            }
            sb.Append("\n  ]\n}\n");
            return sb.ToString();
        }

        // 极简解析：只认本程序自己写的格式（也兼容 2.0 版没有 computer/inCycle/hotkeys 的文件）
        static void Parse(string s)
        {
            Displays.Clear();
            int hk = s.IndexOf("\"hotkeys\"");
            string disp = hk >= 0 ? s.Substring(0, hk) : s;
            foreach (Match dm in Regex.Matches(disp, "\\{\\s*\"id\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*\"name\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*\"inputs\"\\s*:\\s*\\[(.*?)\\]\\s*\\}", RegexOptions.Singleline))
            {
                var d = new DisplayConfig { Id = Unesc(dm.Groups[1].Value), Name = Unesc(dm.Groups[2].Value) };
                foreach (Match im in Regex.Matches(dm.Groups[3].Value, "\\{[^{}]*\\}"))
                {
                    string o = im.Value;
                    var e = new InputEntry();
                    Match m = Regex.Match(o, "\"code\"\\s*:\\s*(\\d+)");
                    if (!m.Success) continue;
                    e.Code = int.Parse(m.Groups[1].Value);
                    m = Regex.Match(o, "\"label\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
                    e.Label = m.Success ? Unesc(m.Groups[1].Value) : "输入 " + e.Code;
                    m = Regex.Match(o, "\"computer\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
                    if (m.Success) e.Computer = Unesc(m.Groups[1].Value);
                    e.InCycle = Regex.IsMatch(o, "\"inCycle\"\\s*:\\s*true");
                    d.Inputs.Add(e);
                }
                Displays.Add(d);
            }
            if (hk >= 0)
            {
                hotkeysLoaded = true;
                Hotkeys.Clear();
                foreach (Match m in Regex.Matches(s.Substring(hk), "\\{\\s*\"action\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*,\\s*\"mods\"\\s*:\\s*(\\d+)\\s*,\\s*\"vk\"\\s*:\\s*(\\d+)\\s*,\\s*\"display\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"\\s*\\}"))
                {
                    Hotkeys.Add(new HotkeyBinding
                    {
                        Action = Unesc(m.Groups[1].Value),
                        Mods = uint.Parse(m.Groups[2].Value),
                        Vk = uint.Parse(m.Groups[3].Value),
                        Display = Unesc(m.Groups[4].Value)
                    });
                }
            }
        }

        static string Unesc(string s)
        {
            return Regex.Replace(s, "\\\\(.)", delegate(Match m) { return m.Groups[1].Value == "n" ? "\n" : m.Groups[1].Value; });
        }
    }

    // ---------- 接口目录 ----------
    static class Ports
    {
        public static readonly int[] Candidates = BuildCandidates();

        static int[] BuildCandidates()
        {
            var l = new List<int>();
            for (int i = 1; i <= 32; i++) l.Add(i);
            l.AddRange(new int[] { 0x90, 0x91, 0x92, 0xD0, 0xD1 });
            return l.ToArray();
        }

        public static string Guess(int code, string monitorDesc)
        {
            string m = (monitorDesc ?? "").ToUpperInvariant();
            if (m.Contains("LG"))
            {
                switch (code)
                {
                    case 0x90: return "HDMI 1";
                    case 0x91: return "HDMI 2";
                    case 0x92: return "HDMI 3";
                    case 0xD0: return "DisplayPort";
                    case 0xD1: return "USB-C";
                }
            }
            switch (code)
            {
                case 1: return "VGA 1";
                case 2: return "VGA 2";
                case 3: return "DVI 1";
                case 4: return "DVI 2";
                case 15: return "DisplayPort 1";
                case 16: return "DisplayPort 2";
                case 17: return "HDMI 1";
                case 18: return "HDMI 2";
                case 19: return "HDMI 3";
                case 20: return "HDMI 4";
                case 21: return "USB-C";
                case 22: return "USB-C 2";
                case 27: return "USB-C";
                case 28: return "USB-C 2";
                default: return "输入 " + code;
            }
        }

        public static int SortKey(string label)
        {
            string l = (label ?? "").ToUpperInvariant();
            if (l.Contains("USB-C") || l.Contains("TYPE-C")) return 0;
            if (l.Contains("HDMI")) return 1;
            if (l.Contains("DISPLAYPORT") || l.Contains("DP")) return 2;
            return 3;
        }

        public static void Sort(List<InputEntry> list)
        {
            list.Sort(delegate(InputEntry a, InputEntry b)
            {
                int c = SortKey(a.Label).CompareTo(SortKey(b.Label));
                return c != 0 ? c : a.Code.CompareTo(b.Code);
            });
        }
    }

    // ---------- DDC/CI（dxva2） ----------
    static class Ddc
    {
        delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PHYSICAL_MONITOR
        {
            public IntPtr hPhysicalMonitor;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
        }

        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);
        [DllImport("dxva2.dll", CharSet = CharSet.Unicode)] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);
        [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr hMonitor, byte code, IntPtr vcpType, ref uint current, ref uint maximum);
        [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr hMonitor, byte code, uint value);
        [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        public const uint MOD_ALT = 0x0001, MOD_CONTROL = 0x0002, MOD_SHIFT = 0x0004, MOD_WIN = 0x0008, MOD_NOREPEAT = 0x4000;
        public const int WM_HOTKEY = 0x0312;

        public class Monitor
        {
            public IntPtr H;
            public string Desc;
            public string Id;   // 描述 + 序号，区分同型号多台
        }

        static List<Monitor> current = new List<Monitor>();
        static readonly object sync = new object();

        public static List<Monitor> Refresh()
        {
            lock (sync)
            {
                foreach (var m in current) DestroyPhysicalMonitor(m.H);
                var hs = new List<IntPtr>();
                EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
                    delegate(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) { hs.Add(h); return true; }, IntPtr.Zero);
                var result = new List<Monitor>();
                var seen = new Dictionary<string, int>();
                foreach (var hm in hs)
                {
                    uint n = 0;
                    if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, ref n) || n == 0) continue;
                    var arr = new PHYSICAL_MONITOR[n];
                    if (!GetPhysicalMonitorsFromHMONITOR(hm, n, arr)) continue;
                    foreach (var pm in arr)
                    {
                        uint cur = 0, max = 0;
                        // 只保留支持读输入源的（内置屏、不支持 DDC 的屏跳过）
                        bool ok = GetVCPFeatureAndVCPFeatureReply(pm.hPhysicalMonitor, 0x60, IntPtr.Zero, ref cur, ref max)
                               || SetVCPProbeable(pm.hPhysicalMonitor);
                        if (!ok) { DestroyPhysicalMonitor(pm.hPhysicalMonitor); continue; }
                        string desc = string.IsNullOrEmpty(pm.Description) ? "显示器" : pm.Description;
                        int k;
                        seen.TryGetValue(desc, out k);
                        seen[desc] = k + 1;
                        result.Add(new Monitor { H = pm.hPhysicalMonitor, Desc = desc, Id = k == 0 ? desc : desc + " #" + (k + 1) });
                    }
                }
                current = result;
                return new List<Monitor>(result);
            }
        }

        static bool SetVCPProbeable(IntPtr h)
        {
            uint cur = 0, max = 0;
            return GetVCPFeatureAndVCPFeatureReply(h, 0x10, IntPtr.Zero, ref cur, ref max);
        }

        public static bool ReadOnce(IntPtr h, out int code)
        {
            uint cur = 0, max = 0;
            if (GetVCPFeatureAndVCPFeatureReply(h, 0x60, IntPtr.Zero, ref cur, ref max)) { code = (int)(cur & 0xFFFF); return true; }
            code = -1;
            return false;
        }

        public static bool GetInput(IntPtr h, out int code)
        {
            for (int i = 0; i < 4; i++)
            {
                if (ReadOnce(h, out code)) return true;
                if (i < 3) Thread.Sleep(200);
            }
            code = -1;
            return false;
        }

        public static bool SetInput(IntPtr h, int code) { return SetVCPFeature(h, 0x60, (uint)code); }

        public enum SwitchResult { Ok, Unverified, Bounced, NoReply }

        // 切换并「守住」：目标电脑画面接通要几秒，显示器的自动信号源会在这段时间跳回有信号的口。
        // 写入后观察，被跳走就补发，连续稳定 4 秒才算成功。
        public static SwitchResult SwitchAndHold(IntPtr h, int code, out int landed)
        {
            landed = -1;
            int writes = 0, failedReads = 0;
            bool anyReply = false;
            DateTime? stableSince = null;
            SetInput(h, code); writes++;
            DateTime lastWrite = DateTime.Now;
            DateTime deadline = DateTime.Now.AddSeconds(14);
            while (DateTime.Now < deadline)
            {
                Thread.Sleep(400);
                int cur;
                if (!ReadOnce(h, out cur))
                {
                    failedReads++;
                    if (!anyReply && failedReads >= 10) return SwitchResult.Unverified;
                    continue;
                }
                anyReply = true;
                if (cur == code)
                {
                    if (stableSince == null) stableSince = DateTime.Now;
                    if ((DateTime.Now - stableSince.Value).TotalSeconds >= 4 &&
                        (DateTime.Now - lastWrite).TotalSeconds >= 6) return SwitchResult.Ok;
                }
                else
                {
                    landed = cur;
                    stableSince = null;
                    if (writes < 6 && (DateTime.Now - lastWrite).TotalSeconds >= 1.2)
                    {
                        SetInput(h, code); writes++; lastWrite = DateTime.Now;
                    }
                }
            }
            if (stableSince != null && (DateTime.Now - stableSince.Value).TotalSeconds >= 2) return SwitchResult.Ok;
            if (landed >= 0) return SwitchResult.Bounced;
            return anyReply ? SwitchResult.Ok : SwitchResult.NoReply;
        }

        static int guardGen;

        public static void CancelGuard() { Interlocked.Increment(ref guardGen); }

        // 切换成功后的后台守护：画面重新握手时显示器可能跳回别的口，守护 30 秒内补发，最多 4 次。
        public static void Guard(IntPtr h, int code)
        {
            int gen = Interlocked.Increment(ref guardGen);
            var t = new Thread(delegate()
            {
                int rewrites = 0;
                DateTime lastWrite = DateTime.Now, end = DateTime.Now.AddSeconds(30);
                while (DateTime.Now < end)
                {
                    Thread.Sleep(700);
                    if (gen != guardGen) return;
                    int cur;
                    if (!ReadOnce(h, out cur)) continue;
                    if (cur != code && rewrites < 4 && (DateTime.Now - lastWrite).TotalSeconds >= 1.5)
                    {
                        SetInput(h, code); rewrites++; lastWrite = DateTime.Now;
                    }
                }
            });
            t.IsBackground = true;
            t.Start();
        }

        static int WaitStable(IntPtr h, double timeout)
        {
            int last = -1, same = 0;
            DateTime t0 = DateTime.Now;
            while ((DateTime.Now - t0).TotalSeconds < timeout)
            {
                Thread.Sleep(250);
                int v;
                if (!ReadOnce(h, out v)) { same = 0; continue; }
                if (v == last) { same++; if (same >= 2) return v; } else { last = v; same = 0; }
            }
            return last;
        }

        static void ReturnHome(IntPtr h, int home)
        {
            for (int i = 0; i < 3; i++)
            {
                SetInput(h, home);
                if (WaitStable(h, 8) == home) return;
            }
        }

        // 写一个编号：读回离开本机的口（该编号本身或显示器自己扫描到的口）→ 有这个口；一直是本机的口 → 没有
        static bool TryCode(IntPtr h, int code, int home)
        {
            SetInput(h, code);
            int homeReads = 0;
            DateTime t0 = DateTime.Now;
            while ((DateTime.Now - t0).TotalSeconds < 4.5)
            {
                Thread.Sleep(150);
                int v;
                if (!ReadOnce(h, out v)) continue;
                if (v != home) return true;
                homeReads++;
                if (homeReads >= 4 && (DateTime.Now - t0).TotalSeconds > 1.5) return false;
            }
            return false;
        }

        // 自动识别接口。返回 null 表示显示器不支持读取当前输入。第一个元素是本机所在的口。
        public static List<int> Probe(IntPtr h)
        {
            CancelGuard();
            int home = WaitStable(h, 8);
            if (home < 0 && !GetInput(h, out home)) return null;
            var hits = new List<int>();
            foreach (int code in Ports.Candidates)
            {
                if (code == home) continue;
                if (TryCode(h, code, home)) { hits.Add(code); ReturnHome(h, home); }
            }
            var found = new List<int> { home };
            foreach (int code in hits)
            {
                if (TryCode(h, code, home)) found.Add(code);
                ReturnHome(h, home);
            }
            int ignored;
            SwitchAndHold(h, home, out ignored);
            return found;
        }
    }

    // ---------- 自动更新（GitHub Releases） ----------
    static class Updater
    {
        public class Info { public string Version; public string Notes; public string Url; }

        public static Info FetchLatest(out string error)
        {
            error = null;
            try
            {
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072; // TLS 1.2
                using (var wc = new WebClient())
                {
                    wc.Headers.Add("User-Agent", "DisplaySwitch/" + AppInfo.Version);
                    wc.Headers.Add("Accept", "application/vnd.github+json");
                    wc.Encoding = Encoding.UTF8;
                    string json = wc.DownloadString("https://api.github.com/repos/" + AppInfo.Repo + "/releases/latest");
                    Match tag = Regex.Match(json, "\"tag_name\"\\s*:\\s*\"([^\"]+)\"");
                    if (!tag.Success) { error = "GitHub 返回异常"; return null; }
                    string url = null;
                    foreach (Match m in Regex.Matches(json, "\"browser_download_url\"\\s*:\\s*\"([^\"]+)\""))
                        if (m.Groups[1].Value.ToLowerInvariant().Contains("windows")) { url = m.Groups[1].Value; break; }
                    if (url == null) { error = "最新发布里没有 Windows 安装包"; return null; }
                    Match body = Regex.Match(json, "\"body\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
                    string notes = body.Success ? Regex.Unescape(body.Groups[1].Value) : "";
                    string v = tag.Groups[1].Value.TrimStart('v', 'V');
                    return new Info { Version = v, Notes = notes, Url = url };
                }
            }
            catch (Exception ex) { error = ex.Message; return null; }
        }

        public static bool IsNewer(string a, string b)
        {
            string[] pa = a.Split('.'), pb = b.Split('.');
            for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
            {
                int x = 0, y = 0;
                if (i < pa.Length) int.TryParse(pa[i], out x);
                if (i < pb.Length) int.TryParse(pb[i], out y);
                if (x != y) return x > y;
            }
            return false;
        }

        // 下载 zip，写一个 PowerShell 脚本：等本进程退出 → 解压覆盖程序目录 → 重新启动。
        public static string Install(Info u)
        {
            try
            {
                string work = Path.Combine(Path.GetTempPath(), "DisplaySwitch-update-" + u.Version);
                Directory.CreateDirectory(work);
                string zip = Path.Combine(work, "update.zip");
                ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
                using (var wc = new WebClient())
                {
                    wc.Headers.Add("User-Agent", "DisplaySwitch/" + AppInfo.Version);
                    wc.DownloadFile(u.Url, zip);
                }
                string exe = Application.ExecutablePath;
                string dir = Path.GetDirectoryName(exe);
                string ps1 = Path.Combine(work, "install.ps1");
                string script =
                    "$ErrorActionPreference = 'Stop'\r\n" +
                    "try { Wait-Process -Id " + Process.GetCurrentProcess().Id + " -Timeout 30 } catch {}\r\n" +
                    "$x = Join-Path '" + work.Replace("'", "''") + "' 'x'\r\n" +
                    "if (Test-Path $x) { Remove-Item $x -Recurse -Force }\r\n" +
                    "Expand-Archive -Path '" + zip.Replace("'", "''") + "' -DestinationPath $x -Force\r\n" +
                    "$src = Get-ChildItem $x -Recurse -Filter TraySwitcher.exe | Select-Object -First 1\r\n" +
                    "if (-not $src) { throw 'no exe' }\r\n" +
                    "$dst = '" + dir.Replace("'", "''") + "'\r\n" +
                    "Copy-Item '" + exe.Replace("'", "''") + "' (Join-Path $dst 'TraySwitcher.exe.previous') -Force\r\n" +
                    "Copy-Item (Join-Path $src.DirectoryName '*') $dst -Recurse -Force\r\n" +
                    "Start-Process '" + exe.Replace("'", "''") + "'\r\n";
                File.WriteAllText(ps1, script, new UTF8Encoding(true));
                var psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + ps1 + "\"");
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                Process.Start(psi);
                return null;
            }
            catch (Exception ex) { return ex.Message; }
        }
    }

    // ---------- 小对话框 ----------
    static class Dialogs
    {
        public static string Input(string title, string prompt, string def)
        {
            var f = new Form { Text = title, Width = 420, Height = 180, StartPosition = FormStartPosition.CenterScreen, TopMost = true, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
            var lbl = new Label { Left = 12, Top = 10, Width = 380, Height = 48, Text = prompt };
            var tb = new TextBox { Left = 12, Top = 62, Width = 380, Text = def ?? "" };
            var ok = new Button { Text = "确定", Left = 230, Width = 75, Top = 100, DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "取消", Left = 315, Width = 75, Top = 100, DialogResult = DialogResult.Cancel };
            f.Controls.AddRange(new Control[] { lbl, tb, ok, cancel });
            f.AcceptButton = ok; f.CancelButton = cancel;
            return f.ShowDialog() == DialogResult.OK ? tb.Text.Trim() : null;
        }

        public static int ChoosePort(string title, string prompt, DisplayConfig cfg)
        {
            var f = new Form { Text = title, Width = 420, Height = 170, StartPosition = FormStartPosition.CenterScreen, TopMost = true, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
            var lbl = new Label { Left = 12, Top = 10, Width = 380, Height = 22, Text = prompt };
            var cb = new ComboBox { Left = 12, Top = 38, Width = 380, DropDownStyle = ComboBoxStyle.DropDownList };
            foreach (var e in cfg.Inputs) cb.Items.Add(e.Title + "（编号 " + e.Code + "）");
            if (cb.Items.Count > 0) cb.SelectedIndex = 0;
            var ok = new Button { Text = "下一步", Left = 230, Width = 75, Top = 85, DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "取消", Left = 315, Width = 75, Top = 85, DialogResult = DialogResult.Cancel };
            f.Controls.AddRange(new Control[] { lbl, cb, ok, cancel });
            f.AcceptButton = ok; f.CancelButton = cancel;
            return f.ShowDialog() == DialogResult.OK ? cb.SelectedIndex : -1;
        }

        public static bool EditCycle(DisplayConfig cfg)
        {
            var f = new Form { Text = "循环切换包含哪些接口", Width = 420, Height = 120 + cfg.Inputs.Count * 24, StartPosition = FormStartPosition.CenterScreen, TopMost = true, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
            var lbl = new Label { Left = 12, Top = 8, Width = 380, Height = 22, Text = "按循环切换快捷键时，只在勾选的接口之间轮换：" };
            f.Controls.Add(lbl);
            var boxes = new List<CheckBox>();
            for (int i = 0; i < cfg.Inputs.Count; i++)
            {
                var b = new CheckBox { Left = 16, Top = 34 + i * 24, Width = 370, Text = cfg.Inputs[i].Title, Checked = cfg.Inputs[i].InCycle };
                boxes.Add(b); f.Controls.Add(b);
            }
            int y = 40 + cfg.Inputs.Count * 24;
            var ok = new Button { Text = "保存", Left = 230, Width = 75, Top = y, DialogResult = DialogResult.OK };
            var cancel = new Button { Text = "取消", Left = 315, Width = 75, Top = y, DialogResult = DialogResult.Cancel };
            f.Controls.AddRange(new Control[] { ok, cancel });
            f.AcceptButton = ok; f.CancelButton = cancel;
            if (f.ShowDialog() != DialogResult.OK) return false;
            for (int i = 0; i < boxes.Count; i++) cfg.Inputs[i].InCycle = boxes[i].Checked;
            return true;
        }

        // 录制快捷键。返回 null=取消；Vk=0 的绑定=清除。
        public static HotkeyBinding RecordHotkey(string title, string current, bool allowClear)
        {
            HotkeyBinding captured = null;
            var f = new Form { Text = title, Width = 420, Height = 190, StartPosition = FormStartPosition.CenterScreen, TopMost = true, KeyPreview = true, FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false };
            var lbl = new Label { Left = 12, Top = 10, Width = 380, Height = 36, Text = "现在按下想用的组合键（至少带 Ctrl / Alt / Win 之一；F1–F12 可单独用）。\n当前：" + (string.IsNullOrEmpty(current) ? "未设置" : current) };
            var show = new Label { Left = 12, Top = 54, Width = 380, Height = 30, Text = "等待按键…", Font = new Font(SystemFonts.DefaultFont.FontFamily, 14f) };
            var ok = new Button { Text = "保存", Left = 150, Width = 75, Top = 105, DialogResult = DialogResult.OK, Enabled = false };
            var clear = new Button { Text = "清除", Left = 232, Width = 75, Top = 105, Visible = allowClear };
            var cancel = new Button { Text = "取消", Left = 315, Width = 75, Top = 105, DialogResult = DialogResult.Cancel };
            clear.Click += delegate { captured = new HotkeyBinding { Vk = 0 }; f.DialogResult = DialogResult.OK; };
            f.Controls.AddRange(new Control[] { lbl, show, ok, clear, cancel });
            f.CancelButton = cancel;
            f.KeyDown += delegate(object s, KeyEventArgs e)
            {
                Keys k = e.KeyCode;
                if (k == Keys.ControlKey || k == Keys.Menu || k == Keys.ShiftKey || k == Keys.LWin || k == Keys.RWin) { e.Handled = true; return; }
                if (k == Keys.Escape && !e.Control && !e.Alt) return;
                uint mods = 0; string disp = "";
                bool win = (Control.ModifierKeys & Keys.LWin) == Keys.LWin || IsWinDown();
                if (e.Control) { mods |= Ddc.MOD_CONTROL; disp += "Ctrl+"; }
                if (e.Alt) { mods |= Ddc.MOD_ALT; disp += "Alt+"; }
                if (e.Shift) { mods |= Ddc.MOD_SHIFT; disp += "Shift+"; }
                if (win) { mods |= Ddc.MOD_WIN; disp += "Win+"; }
                bool fkey = k >= Keys.F1 && k <= Keys.F12;
                if ((mods & (Ddc.MOD_CONTROL | Ddc.MOD_ALT | Ddc.MOD_WIN)) == 0 && !fkey)
                {
                    show.Text = "需要带 Ctrl / Alt / Win";
                    e.Handled = true; e.SuppressKeyPress = true;
                    return;
                }
                string name = k == Keys.Oemtilde ? "`" : k.ToString();
                if (name.StartsWith("D") && name.Length == 2 && char.IsDigit(name[1])) name = name.Substring(1);
                captured = new HotkeyBinding { Mods = mods, Vk = (uint)k, Display = disp + name };
                show.Text = captured.Display;
                ok.Enabled = true;
                e.Handled = true; e.SuppressKeyPress = true;
            };
            return f.ShowDialog() == DialogResult.OK ? captured : null;
        }

        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
        static bool IsWinDown() { return (GetAsyncKeyState(0x5B) & 0x8000) != 0 || (GetAsyncKeyState(0x5C) & 0x8000) != 0; }
    }

    // ---------- 主程序 ----------
    public class TrayApp : Form
    {
        NotifyIcon icon;
        ContextMenu menu;
        volatile bool busy;
        readonly HashSet<int> noSignal = new HashSet<int>();
        readonly HashSet<string> prompted = new HashSet<string>();
        readonly Dictionary<int, string> hotkeyIds = new Dictionary<int, string>();
        Updater.Info availableUpdate;

        [STAThread]
        static void Main()
        {
            bool created;
            using (new Mutex(true, "MonitorSwitch.TraySwitcher", out created))
            {
                if (!created) return;
                Application.EnableVisualStyles();
                Application.Run(new TrayApp());
            }
        }

        public TrayApp()
        {
            ConfigStore.Load();
            ShowInTaskbar = false;
            WindowState = FormWindowState.Minimized;
            FormBorderStyle = FormBorderStyle.FixedToolWindow;
            Opacity = 0;
            Show();
            Hide();

            Icon ico = null;
            try { ico = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }
            icon = new NotifyIcon { Icon = ico ?? SystemIcons.Application, Text = "显示器切换", Visible = true };
            menu = new ContextMenu();
            menu.Popup += delegate { BuildMenu(); };
            icon.ContextMenu = menu;
            // 左键也只弹菜单，不直接切换
            icon.MouseUp += delegate(object s, MouseEventArgs e)
            {
                if (e.Button != MouseButtons.Left) return;
                MethodInfo mi = typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic);
                if (mi != null) mi.Invoke(icon, null);
            };
            Application.ApplicationExit += delegate { icon.Visible = false; };

            RegisterHotkeys();
            SystemEvents.DisplaySettingsChanged += delegate
            {
                var t = new System.Windows.Forms.Timer { Interval = 3000 };
                t.Tick += delegate { t.Stop(); t.Dispose(); OfferProbeForNewDisplays(); };
                t.Start();
            };
            var t1 = new System.Windows.Forms.Timer { Interval = 1500 };
            t1.Tick += delegate { t1.Stop(); OfferProbeForNewDisplays(); };
            t1.Start();
            var t2 = new System.Windows.Forms.Timer { Interval = 8000 };
            t2.Tick += delegate { t2.Interval = 6 * 3600 * 1000; CheckUpdateQuietly(); };
            t2.Start();
        }

        protected override void SetVisibleCore(bool value) { base.SetVisibleCore(false); }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == Ddc.WM_HOTKEY)
            {
                string action;
                if (hotkeyIds.TryGetValue(m.WParam.ToInt32(), out action)) RunHotkey(action);
            }
            base.WndProc(ref m);
        }

        // ---- 快捷键 ----

        void RegisterHotkeys()
        {
            foreach (int id in hotkeyIds.Keys) Ddc.UnregisterHotKey(Handle, id);
            hotkeyIds.Clear();
            int next = 1;
            foreach (var h in ConfigStore.Hotkeys)
            {
                if (h.Vk == 0) continue;
                if (Ddc.RegisterHotKey(Handle, next, h.Mods | Ddc.MOD_NOREPEAT, h.Vk)) hotkeyIds[next] = h.Action;
                next++;
            }
        }

        HotkeyBinding BindingFor(string action)
        {
            return ConfigStore.Hotkeys.Find(delegate(HotkeyBinding h) { return h.Action == action; });
        }

        bool SetHotkey(string action, HotkeyBinding hk)
        {
            ConfigStore.Hotkeys.RemoveAll(delegate(HotkeyBinding h) { return h.Action == action || (hk != null && hk.Vk != 0 && h.Vk == hk.Vk && h.Mods == hk.Mods); });
            bool ok = true;
            if (hk != null && hk.Vk != 0)
            {
                hk.Action = action;
                // 先试注册，确认没被别的程序占用
                if (Ddc.RegisterHotKey(Handle, 9999, hk.Mods | Ddc.MOD_NOREPEAT, hk.Vk)) Ddc.UnregisterHotKey(Handle, 9999);
                else ok = false;
                if (ok) ConfigStore.Hotkeys.Add(hk);
            }
            ConfigStore.Save();
            RegisterHotkeys();
            return ok;
        }

        static string PortAction(DisplayConfig cfg, int code) { return "port|" + cfg.Id + "|" + code; }

        void RunHotkey(string action)
        {
            if (action == "cycle") { CycleNext(); return; }
            string[] p = action.Split('|');
            if (p.Length != 3) return;
            int code;
            if (!int.TryParse(p[2], out code)) return;
            var mon = Ddc.Refresh().Find(delegate(Ddc.Monitor m) { return m.Id == p[1]; });
            var cfg = ConfigStore.Find(p[1]);
            if (mon == null || cfg == null) { System.Media.SystemSounds.Beep.Play(); return; }
            var e = cfg.Inputs.Find(delegate(InputEntry x) { return x.Code == code; });
            if (e == null) return;
            DoSwitch(mon, new List<InputEntry> { e });
        }

        // ---- 菜单 ----

        void BuildMenu()
        {
            menu.MenuItems.Clear();
            var mons = Ddc.Refresh();
            if (busy)
            {
                menu.MenuItems.Add(new MenuItem("正在切换/识别，请稍候…") { Enabled = false });
                menu.MenuItems.Add("-");
            }
            if (mons.Count == 0)
            {
                menu.MenuItems.Add(new MenuItem("没有检测到支持 DDC/CI 的显示器") { Enabled = false });
                menu.MenuItems.Add("-");
            }
            foreach (var mon in mons)
            {
                var m = mon;
                var cfg = ConfigStore.Find(m.Id);
                menu.MenuItems.Add(new MenuItem("🖥 " + m.Desc) { Enabled = false });
                int cur;
                bool hasCur = Ddc.GetInput(m.H, out cur);
                if (cfg != null && cfg.Inputs.Count > 0)
                {
                    foreach (var e in cfg.Inputs)
                    {
                        var entry = e;
                        string t = "    " + e.Title;
                        var hk = BindingFor(PortAction(cfg, e.Code));
                        if (hk != null) t += "\t" + hk.Display;
                        var mi = new MenuItem(t, delegate { DoSwitch(m, new List<InputEntry> { entry }); });
                        mi.Checked = hasCur && cur == e.Code;
                        mi.Enabled = !busy;
                        menu.MenuItems.Add(mi);
                    }
                }
                else
                {
                    menu.MenuItems.Add(new MenuItem("    识别这台显示器的接口…", delegate { ConfirmProbe(m); }) { Enabled = !busy });
                }
                var sub = new MenuItem("    管理这台显示器");
                bool has = cfg != null && cfg.Inputs.Count > 0;
                sub.MenuItems.Add(new MenuItem("重新识别接口…", delegate { ConfirmProbe(m); }) { Enabled = !busy });
                sub.MenuItems.Add(new MenuItem("给接口填电脑名字…", delegate { NameComputer(m); }) { Enabled = has && !busy });
                sub.MenuItems.Add(new MenuItem("设置接口快捷键…", delegate { SetPortHotkey(m); }) { Enabled = has && !busy });
                sub.MenuItems.Add(new MenuItem("循环切换包含哪些接口…", delegate { EditCycle(m); }) { Enabled = has && !busy });
                sub.MenuItems.Add("-");
                sub.MenuItems.Add(new MenuItem("学习当前输入（识别不到的口用）…", delegate { Learn(m); }) { Enabled = !busy });
                sub.MenuItems.Add(new MenuItem("手动添加编号…", delegate { AddManual(m); }) { Enabled = !busy });
                sub.MenuItems.Add(new MenuItem("删除接口…", delegate { DeleteInput(m); }) { Enabled = has && !busy });
                menu.MenuItems.Add(sub);
                menu.MenuItems.Add("-");
            }

            var hkMenu = new MenuItem("快捷键");
            var cyc = BindingFor("cycle");
            hkMenu.MenuItems.Add(new MenuItem("循环切换：" + (cyc != null ? cyc.Display : "未设置")) { Enabled = false });
            hkMenu.MenuItems.Add(new MenuItem("设置循环切换快捷键…", delegate
            {
                var c = BindingFor("cycle");
                var hk = Dialogs.RecordHotkey("设置循环切换快捷键", c != null ? c.Display : "", false);
                if (hk != null && !SetHotkey("cycle", hk)) Warn("快捷键被占用", hk.Display + " 已被别的程序使用，请换一个。");
            }));
            if (cyc != null) hkMenu.MenuItems.Add(new MenuItem("关闭循环切换快捷键", delegate { SetHotkey("cycle", null); }));
            hkMenu.MenuItems.Add("-");
            hkMenu.MenuItems.Add(new MenuItem("接口直达快捷键在「管理这台显示器」里设置") { Enabled = false });
            menu.MenuItems.Add(hkMenu);

            var auto = new MenuItem("开机自启", delegate { ToggleAutoStart(); });
            auto.Checked = AutoStartEnabled();
            menu.MenuItems.Add(auto);
            menu.MenuItems.Add("-");
            if (availableUpdate != null)
            {
                var u = availableUpdate;
                menu.MenuItems.Add(new MenuItem("⬆ 升级到新版本 " + u.Version, delegate { InstallUpdate(u); }));
            }
            menu.MenuItems.Add(new MenuItem("关于显示器切换（" + AppInfo.Version + "）/ 检查更新…", delegate { ShowAbout(); }));
            menu.MenuItems.Add(new MenuItem("退出", delegate { Application.Exit(); }));
        }

        // ---- 切换 ----

        void CycleNext()
        {
            Ddc.Monitor mon = null; DisplayConfig cfg = null;
            foreach (var m in Ddc.Refresh())
            {
                var c = ConfigStore.Find(m.Id);
                if (c != null && c.Inputs.Count > 0) { mon = m; cfg = c; break; }
            }
            if (mon == null) { System.Media.SystemSounds.Beep.Play(); OfferProbeForNewDisplays(); return; }
            var pool = cfg.Inputs.FindAll(delegate(InputEntry e) { return e.InCycle; });
            if (pool.Count < 2) pool = cfg.Inputs;
            int cur;
            bool hasCur = Ddc.GetInput(mon.H, out cur);
            int start = 0;
            if (hasCur) { int i = pool.FindIndex(delegate(InputEntry e) { return e.Code == cur; }); if (i >= 0) start = i + 1; }
            var order = new List<InputEntry>();
            for (int k = 0; k < pool.Count; k++)
            {
                var e = pool[(start + k) % pool.Count];
                if (!hasCur || e.Code != cur) order.Add(e);
            }
            var live = order.FindAll(delegate(InputEntry e) { return !noSignal.Contains(e.Code); });
            if (live.Count > 0) order = live;
            if (order.Count > 0) DoSwitch(mon, order);
        }

        // 后台线程切换（含防弹回观察），不卡托盘；结果以显示器读回为准
        void DoSwitch(Ddc.Monitor mon, List<InputEntry> candidates)
        {
            if (busy) return;
            busy = true;
            Ddc.CancelGuard();
            var th = new Thread(delegate()
            {
                var r = Ddc.SwitchResult.NoReply;
                int landed = -1;
                InputEntry entry = candidates[0];
                var bounced = new List<int>();
                foreach (var e in candidates)
                {
                    entry = e;
                    r = Ddc.SwitchAndHold(mon.H, e.Code, out landed);
                    if (r != Ddc.SwitchResult.Bounced) break;
                    bounced.Add(e.Code);
                }
                BeginInvoke((Action)delegate
                {
                    busy = false;
                    foreach (int b in bounced) noSignal.Add(b);
                    if (r == Ddc.SwitchResult.Ok || r == Ddc.SwitchResult.Unverified)
                    {
                        noSignal.Remove(entry.Code);
                        MarkInCycle(mon, entry.Code);
                        if (r == Ddc.SwitchResult.Ok) Ddc.Guard(mon.H, entry.Code);
                    }
                    else if (r == Ddc.SwitchResult.Bounced)
                    {
                        var cfg = ConfigStore.Find(mon.Id);
                        var back = cfg != null ? cfg.Inputs.Find(delegate(InputEntry x) { return x.Code == landed; }) : null;
                        string backName = back != null ? back.Title : Ports.Guess(landed, mon.Desc);
                        Warn("没切过去：显示器跳回了「" + backName + "」",
                             "显示器收到了切到「" + entry.Title + "」的指令，但那个口没有画面信号，所以自己跳回了有信号的口。\n\n" +
                             "请检查那台电脑：\n• 是否接在这个口上、是否开机\n• 是否在睡眠/锁屏黑屏（按一下它的键盘唤醒）\n• 笔记本合盖使用时是否接着电源\n• 视频线是否插紧");
                    }
                    else
                    {
                        Warn("显示器没有回应", "读写显示器失败。请确认显示器菜单里 DDC/CI 已开启；经过扩展坞/转接头时可能不透传 DDC/CI，可换直连线再试。");
                    }
                });
            });
            th.IsBackground = true;
            th.Start();
        }

        void MarkInCycle(Ddc.Monitor mon, int code)
        {
            var cfg = ConfigStore.Find(mon.Id);
            if (cfg == null) return;
            var e = cfg.Inputs.Find(delegate(InputEntry x) { return x.Code == code; });
            if (e == null || e.InCycle) return;
            e.InCycle = true;
            ConfigStore.Save();
        }

        // ---- 接口识别与管理 ----

        void OfferProbeForNewDisplays()
        {
            if (busy) return;
            foreach (var m in Ddc.Refresh())
            {
                if (ConfigStore.Find(m.Id) != null || prompted.Contains(m.Id)) continue;
                prompted.Add(m.Id);
                var r = MessageBox.Show("发现显示器「" + m.Desc + "」。\n\n要自动识别它有哪些接口吗（USB-C、HDMI、DP 等，没接电脑的口也能识别）？\n识别约 1–3 分钟，期间屏幕会多次切换、闪烁，结束后自动切回本机。",
                    "显示器切换", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button1, MessageBoxOptions.DefaultDesktopOnly);
                if (r == DialogResult.Yes) StartProbe(m);
                return;
            }
        }

        void ConfirmProbe(Ddc.Monitor m)
        {
            var r = MessageBox.Show("接下来约 1–3 分钟，屏幕会多次切换输入源（会闪），结束后自动切回本机。\n请先保存手头工作，期间不要操作电脑。已填的电脑名字和快捷键会保留。",
                "识别「" + m.Desc + "」的接口", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (r == DialogResult.OK) StartProbe(m);
        }

        void StartProbe(Ddc.Monitor m)
        {
            if (busy) return;
            busy = true;
            icon.ShowBalloonTip(3000, "正在识别接口…", "屏幕会切换几次，请稍候", ToolTipIcon.Info);
            var th = new Thread(delegate()
            {
                List<int> found = Ddc.Probe(m.H);
                BeginInvoke((Action)delegate { busy = false; ApplyProbe(m, found); });
            });
            th.IsBackground = true;
            th.Start();
        }

        void ApplyProbe(Ddc.Monitor m, List<int> found)
        {
            var cfg = ConfigStore.Find(m.Id) ?? new DisplayConfig { Id = m.Id, Name = m.Desc };
            if (found == null)
            {
                if (cfg.Inputs.Count == 0)
                {
                    foreach (int c in new int[] { 27, 17, 18, 15 }) cfg.Inputs.Add(new InputEntry { Code = c, Label = Ports.Guess(c, m.Desc) });
                    ConfigStore.Upsert(cfg);
                }
                Warn("这台显示器不支持读取当前输入",
                     "无法自动识别，已先放入常见接口（USB-C、HDMI 1、HDMI 2、DisplayPort 1），可以直接试切换。\n切不过去的口可在「管理这台显示器」里删除，或用「手动添加编号」补充。");
                return;
            }
            var merged = new List<InputEntry>();
            var names = new Dictionary<string, int>();
            for (int i = 0; i < found.Count; i++)
            {
                int code = found[i];
                var old = cfg.Inputs.Find(delegate(InputEntry x) { return x.Code == code; });
                if (old != null) { merged.Add(old); continue; }
                string name = Ports.Guess(code, m.Desc);
                int n;
                names.TryGetValue(name, out n);
                names[name] = n + 1;
                if (n > 0) name += " " + (n + 1);
                var e = new InputEntry { Code = code, Label = name };
                if (i == 0) { e.Computer = Environment.MachineName; e.InCycle = true; }
                merged.Add(e);
            }
            foreach (var old in cfg.Inputs)
                if (!merged.Exists(delegate(InputEntry x) { return x.Code == old.Code; })) merged.Add(old);
            Ports.Sort(merged);
            cfg.Inputs = merged;
            ConfigStore.Upsert(cfg);
            var sb = new StringBuilder();
            foreach (var e in merged) sb.Append("  • ").Append(e.Title).Append('\n');
            MessageBox.Show("识别到 " + merged.Count + " 个接口：\n\n" + sb +
                "\n现在点托盘图标就能从菜单里选择切换。\n建议在「管理这台显示器 → 给接口填电脑名字」里写上每个口接的是哪台电脑。",
                "识别完成", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        void Learn(Ddc.Monitor m)
        {
            var r = MessageBox.Show("用于自动识别漏掉的口：先用显示器按钮把画面切到那个口，然后点「确定」读取。",
                "学习当前输入", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (r != DialogResult.OK) return;
            int code;
            if (!Ddc.GetInput(m.H, out code)) { Warn("读取失败", "这台显示器不支持读取当前输入。"); return; }
            AddEntry(m, code);
        }

        void AddManual(Ddc.Monitor m)
        {
            string s = Dialogs.Input("手动添加编号", "填显示器内部的输入源编号（常见：15=DP1、16=DP2、17=HDMI1、18=HDMI2、27=USB-C，各家不同）。", "");
            int code;
            if (s == null || !int.TryParse(s, out code) || code <= 0 || code > 255) return;
            AddEntry(m, code);
        }

        void AddEntry(Ddc.Monitor m, int code)
        {
            var cfg = ConfigStore.Find(m.Id) ?? new DisplayConfig { Id = m.Id, Name = m.Desc };
            string label = Dialogs.Input("接口名称", "会显示在菜单里。", Ports.Guess(code, m.Desc));
            if (string.IsNullOrEmpty(label)) return;
            var ex = cfg.Inputs.Find(delegate(InputEntry x) { return x.Code == code; });
            if (ex != null) ex.Label = label;
            else { cfg.Inputs.Add(new InputEntry { Code = code, Label = label }); Ports.Sort(cfg.Inputs); }
            ConfigStore.Upsert(cfg);
        }

        void NameComputer(Ddc.Monitor m)
        {
            var cfg = ConfigStore.Find(m.Id);
            if (cfg == null) return;
            int i = Dialogs.ChoosePort("给接口填电脑名字", "选择接口：", cfg);
            if (i < 0) return;
            string name = Dialogs.Input("这个口接的是哪台电脑？", "例如 MacBook、Mac mini、公司 Windows。留空则清除。", cfg.Inputs[i].Computer);
            if (name == null) return;
            cfg.Inputs[i].Computer = name;
            if (name.Length > 0) cfg.Inputs[i].InCycle = true;
            ConfigStore.Save();
        }

        void SetPortHotkey(Ddc.Monitor m)
        {
            var cfg = ConfigStore.Find(m.Id);
            if (cfg == null) return;
            int i = Dialogs.ChoosePort("设置接口快捷键", "按下快捷键会直接切到这个接口。选择接口：", cfg);
            if (i < 0) return;
            string action = PortAction(cfg, cfg.Inputs[i].Code);
            var cur = BindingFor(action);
            var hk = Dialogs.RecordHotkey("「" + cfg.Inputs[i].Title + "」的快捷键", cur != null ? cur.Display : "", true);
            if (hk == null) return;
            if (!SetHotkey(action, hk.Vk == 0 ? null : hk)) Warn("快捷键被占用", hk.Display + " 已被别的程序使用，请换一个。");
        }

        void EditCycle(Ddc.Monitor m)
        {
            var cfg = ConfigStore.Find(m.Id);
            if (cfg != null && Dialogs.EditCycle(cfg)) ConfigStore.Save();
        }

        void DeleteInput(Ddc.Monitor m)
        {
            var cfg = ConfigStore.Find(m.Id);
            if (cfg == null) return;
            int i = Dialogs.ChoosePort("删除接口", "选择要从菜单里删掉的接口：", cfg);
            if (i < 0) return;
            SetHotkey(PortAction(cfg, cfg.Inputs[i].Code), null);
            cfg.Inputs.RemoveAt(i);
            ConfigStore.Save();
        }

        // ---- 关于 / 更新 ----

        void ShowAbout()
        {
            string header = "显示器切换 " + AppInfo.Version + "\n多台电脑共用一台显示器时切换输入源。\n开源仓库：github.com/" + AppInfo.Repo;
            Cursor.Current = Cursors.WaitCursor;
            string err;
            var info = Updater.FetchLatest(out err);
            Cursor.Current = Cursors.Default;
            if (info != null && Updater.IsNewer(info.Version, AppInfo.Version))
            {
                availableUpdate = info;
                string notes = string.IsNullOrEmpty(info.Notes) ? "" : "\n\n更新内容：\n" + (info.Notes.Length > 500 ? info.Notes.Substring(0, 500) : info.Notes);
                var r = MessageBox.Show(header + "\n\n发现新版本 " + info.Version + "，现在升级吗？" + notes, "关于", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
                if (r == DialogResult.Yes) InstallUpdate(info);
                return;
            }
            string tail = info != null ? "\n\n已是最新版本。" : "\n\n检查更新失败：" + (err ?? "网络错误");
            var r2 = MessageBox.Show(header + tail + "\n\n要打开 GitHub 发布页吗？", "关于", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
            if (r2 == DialogResult.Yes) Process.Start("https://github.com/" + AppInfo.Repo + "/releases");
        }

        void CheckUpdateQuietly()
        {
            var th = new Thread(delegate()
            {
                string err;
                var info = Updater.FetchLatest(out err);
                if (info != null && Updater.IsNewer(info.Version, AppInfo.Version))
                    BeginInvoke((Action)delegate
                    {
                        availableUpdate = info;
                        icon.ShowBalloonTip(5000, "显示器切换有新版本 " + info.Version, "点托盘图标，在菜单里选「升级到新版本」。", ToolTipIcon.Info);
                    });
            });
            th.IsBackground = true;
            th.Start();
        }

        void InstallUpdate(Updater.Info u)
        {
            if (busy) return;
            busy = true;
            icon.ShowBalloonTip(3000, "正在下载新版本 " + u.Version, "完成后会自动重启程序", ToolTipIcon.Info);
            var th = new Thread(delegate()
            {
                string err = Updater.Install(u);
                BeginInvoke((Action)delegate
                {
                    busy = false;
                    if (err != null) Warn("升级失败", err + "\n\n可以到 GitHub 发布页手动下载：github.com/" + AppInfo.Repo + "/releases");
                    else Application.Exit();
                });
            });
            th.IsBackground = true;
            th.Start();
        }

        // ---- 其他 ----

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        bool AutoStartEnabled()
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
                return k != null && k.GetValue("MonitorSwitch") != null;
        }

        void ToggleAutoStart()
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (k.GetValue("MonitorSwitch") != null) k.DeleteValue("MonitorSwitch", false);
                else k.SetValue("MonitorSwitch", "\"" + Application.ExecutablePath + "\"");
            }
        }

        void Warn(string title, string msg)
        {
            MessageBox.Show(msg, title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }
}

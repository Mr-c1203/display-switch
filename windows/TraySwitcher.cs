// TraySwitcher.cs - Windows tray tool for monitor input switching via DDC/CI.
// Same experience as the Mac menu bar app:
//   - Right-click tray icon: menu "Switch to <machine>" with a checkmark on the
//     machine currently shown on the screen.
//   - Left-click tray icon: instantly switch to the machine NOT on screen.
// No third-party dependencies (uses dxva2.dll shipped with Windows).
//
// Machine list is read from TraySwitcher.ini next to the exe, one machine per
// line:  <input code>,<label>     e.g.  21, Mac (USB-C)
// A legacy single-line number also works (label defaults to "other").
//
// Build (compiler shipped with Windows):
//   %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe ^
//     /out:TraySwitcher.exe /r:System.Windows.Forms.dll /r:System.Drawing.dll TraySwitcher.cs

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Collections.Generic;
using System.Windows.Forms;

namespace MonitorSwitch
{
    public class MachineEntry
    {
        public int Code;
        public string Label;
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.Run(new TrayApp());
        }
    }

    public class TrayApp : ApplicationContext
    {
        NotifyIcon icon;
        List<MachineEntry> machines = new List<MachineEntry>();
        int lastKnown = -1;

        public TrayApp()
        {
            LoadConfig();

            icon = new NotifyIcon();
            // The installer embeds the same dual-screen icon as the Mac app.
            icon.Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath)
                        ?? System.Drawing.SystemIcons.Application;
            icon.Text = "显示器切换 (左键切换，右键选机器)";
            icon.Visible = true;

            ContextMenu menu = new ContextMenu();
            menu.Popup += Menu_Popup;
            icon.ContextMenu = menu;
            icon.MouseClick += new MouseEventHandler(Icon_Click);
        }

        void LoadConfig()
        {
            try
            {
                string ini = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "TraySwitcher.ini");
                foreach (string raw in File.ReadAllLines(ini))
                {
                    string line = raw.Trim();
                    if (line.Length == 0 || line.StartsWith("#")) continue;
                    int comma = line.IndexOf(',');
                    if (comma > 0)
                    {
                        int code;
                        string label = line.Substring(comma + 1).Trim();
                        if (int.TryParse(line.Substring(0, comma).Trim(), out code) && code > 0)
                        {
                            if (label.Length == 0) label = "input " + code;
                            machines.Add(new MachineEntry());
                            machines[machines.Count - 1].Code = code;
                            machines[machines.Count - 1].Label = label;
                        }
                    }
                    else
                    {
                        int code;
                        if (int.TryParse(line, out code) && code > 0)
                        {
                            machines.Add(new MachineEntry());
                            machines[machines.Count - 1].Code = code;
                            machines[machines.Count - 1].Label = "other (" + code + ")";
                        }
                    }
                }
            }
            catch { }
            if (machines.Count == 0)
                throw new InvalidOperationException("未配置显示器输入源编号，请先运行安装脚本。");
        }

        int? GetCurrent()
        {
            int v;
            if (Ddc.GetCurrent(0x60, out v)) { lastKnown = v; return v; }
            return null;
        }

        void Icon_Click(object sender, MouseEventArgs e)
        {
            if (e.Button != MouseButtons.Left) return;
            // Left-click: switch to the machine NOT on screen. Fresh read when
            // possible (fast), fall back to the cached value otherwise.
            MachineEntry target;
            if (machines.Count == 1)
            {
                target = machines[0];
            }
            else
            {
                int? cur = GetCurrent();
                if (cur.HasValue) target = FindOther(cur.Value);
                else if (lastKnown >= 0) target = FindOther(lastKnown);
                else target = machines[machines.Count - 1];
            }
            SwitchTo(target);
        }

        MachineEntry FindOther(int code)
        {
            foreach (MachineEntry m in machines)
                if (m.Code != code) return m;
            return machines[0];
        }

        void SwitchTo(MachineEntry m)
        {
            lastKnown = m.Code;
            string msg;
            bool ok = Ddc.SwitchTo(m.Code, out msg);
            string text = ok ? ("已切到 " + m.Label) : (msg + "（请检查显示器的 DDC/CI 设置）");
            icon.ShowBalloonTip(1500, "显示器切换", text,
                ok ? ToolTipIcon.Info : ToolTipIcon.Warning);
        }

        void Menu_Popup(object sender, EventArgs e)
        {
            ContextMenu menu = (ContextMenu)sender;
            menu.MenuItems.Clear();
            int? cur = GetCurrent();
            foreach (MachineEntry m in machines)
            {
                MachineEntry entry = m;
                MenuItem it = new MenuItem("切到 " + m.Label,
                    delegate { SwitchTo(entry); });
                it.Checked = cur.HasValue && cur.Value == m.Code;
                menu.MenuItems.Add(it);
            }
            menu.MenuItems.Add("-");
            MenuItem quit = new MenuItem("退出", delegate
            {
                icon.Visible = false;
                Application.Exit();
            });
            menu.MenuItems.Add(quit);
        }
    }

    public static class Ddc
    {
        delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PHYSICAL_MONITOR
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

        static List<IntPtr> _handles;
        static bool Callback(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) { _handles.Add(h); return true; }

        delegate void MonitorVisitor(IntPtr hPhysical, string description);

        static void ForEachPhysical(MonitorVisitor visit)
        {
            _handles = new List<IntPtr>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
            foreach (IntPtr hm in _handles)
            {
                uint n = 0;
                if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, ref n) || n == 0) continue;
                PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
                if (!GetPhysicalMonitorsFromHMONITOR(hm, n, arr)) continue;
                for (int i = 0; i < n; i++)
                {
                    visit(arr[i].hPhysicalMonitor, arr[i].Description);
                    DestroyPhysicalMonitor(arr[i].hPhysicalMonitor);
                }
            }
        }

        public static bool GetCurrent(int vcpCode, out int current)
        {
            int observed = -1;
            bool found = false;
            ForEachPhysical(delegate(IntPtr h, string desc)
            {
                if (found) return;
                uint t = 0, cur = 0, max = 0;
                if (GetVCPFeatureandVCPFeatureReply(h, (byte)vcpCode, ref t, ref cur, ref max))
                {
                    observed = (int)cur;
                    found = true;
                }
            });
            current = observed;
            return found;
        }

        public static bool SwitchTo(int target, out string message)
        {
            int total = 0, okCount = 0;
            ForEachPhysical(delegate(IntPtr h, string desc)
            {
                total++;
                if (SetVCPFeature(h, 0x60, (uint)target)) okCount++;
            });
            if (total == 0) { message = "No monitor found"; return false; }
            if (okCount == 0) { message = "Switch failed"; return false; }
            message = "Switch command sent";
            return true;
        }
    }
}

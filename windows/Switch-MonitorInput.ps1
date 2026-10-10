<#
Switch-MonitorInput.ps1 - Switch the monitor's input source via DDC/CI.
Uses only Windows built-in APIs (dxva2.dll). No third-party software needed.

Usage (in PowerShell):
  .\Switch-MonitorInput.ps1 -ShowCurrent       # list monitors + current input source code (VCP 0x60)
  .\Switch-MonitorInput.ps1 -Target 15         # switch to input source code 15 (decimal)

Common codes (decimal): 1=VGA, 3/4=DVI, 15=DP1, 16/17=DP2/DP3,
17/18=HDMI1/HDMI2 (Dell, AOC), 33/34=HDMI1/HDMI2 (Samsung), 144/145=HDMI1/HDMI2 (LG),
27=USB-C (varies by model). Always verify with -ShowCurrent.

If switching fails: enable DDC/CI in the monitor's OSD menu.
#>
param(
    [int]$Target = -1,
    [switch]$ShowCurrent,
    [int]$VcpCode = 96   # 0x60 = Input Source
)

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public static class DdcTool
{
    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rect, IntPtr data);
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR
    {
        public IntPtr hPhysicalMonitor;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    }
    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
    [DllImport("dxva2.dll")] public static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, ref uint count);
    [DllImport("dxva2.dll", CharSet = CharSet.Unicode)] public static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMonitor, uint count, [Out] PHYSICAL_MONITOR[] monitors);
    [DllImport("dxva2.dll")] public static extern bool GetVCPFeatureandVCPFeatureReply(IntPtr hMonitor, byte code, ref uint vcpType, ref uint current, ref uint maximum);
    [DllImport("dxva2.dll")] public static extern bool SetVCPFeature(IntPtr hMonitor, byte code, uint value);
    [DllImport("dxva2.dll")] public static extern bool DestroyPhysicalMonitor(IntPtr hMonitor);

    static List<IntPtr> _handles = new List<IntPtr>();
    static bool Callback(IntPtr h, IntPtr hdc, ref RECT r, IntPtr d) { _handles.Add(h); return true; }

    public static void Run(int target, int vcpCode)
    {
        _handles.Clear();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
        int total = 0, okCount = 0;
        foreach (IntPtr hm in _handles)
        {
            uint n = 0;
            if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hm, ref n) || n == 0) continue;
            PHYSICAL_MONITOR[] arr = new PHYSICAL_MONITOR[n];
            if (!GetPhysicalMonitorsFromHMONITOR(hm, n, arr)) continue;
            for (int i = 0; i < n; i++)
            {
                total++;
                string name = arr[i].Description;
                if (string.IsNullOrEmpty(name)) name = "(monitor)";
                if (target < 0)
                {
                    uint t = 0, cur = 0, max = 0;
                    if (GetVCPFeatureandVCPFeatureReply(arr[i].h, (byte)vcpCode, ref t, ref cur, ref max))
                        Console.WriteLine("[OK]   " + name + "  current input code = " + cur + " (max " + max + ")");
                    else
                        Console.WriteLine("[FAIL] " + name + "  cannot read VCP " + vcpCode + " (enable DDC/CI in monitor OSD)");
                }
                else
                {
                    if (SetVCPFeature(arr[i].h, (byte)vcpCode, (uint)target))
                    { okCount++; Console.WriteLine("[OK]   " + name + "  switch command sent -> " + target); }
                    else
                        Console.WriteLine("[FAIL] " + name + "  SetVCPFeature failed (enable DDC/CI in monitor OSD)");
                }
                DestroyPhysicalMonitor(arr[i].h);
            }
        }
        if (total == 0)
            Console.WriteLine("No monitor found. Note: only the machine currently shown on the screen can control it - that is normal.");
        if (target >= 0 && total > 0 && okCount == 0) Environment.ExitCode = 1;
    }
}
"@

if ($Target -ge 0) {
    [DdcTool]::Run($Target, $VcpCode)
} else {
    if (-not $ShowCurrent) {
        Write-Host "Usage: .\Switch-MonitorInput.ps1 -ShowCurrent | -Target <code>"
        Write-Host ""
    }
    [DdcTool]::Run(-1, $VcpCode)
}

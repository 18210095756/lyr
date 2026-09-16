@echo off
setlocal
chcp 65001 >nul
rem ================================================================
rem  WeChat Special Alert - single file build
rem  The whole PowerShell program is embedded in this file.
rem  Double-click to start. Data is kept in %APPDATA%\WeChatSpecialAlert.
rem  (Keep this header ASCII-only: cmd reads batch files in the OEM codepage.)
rem ================================================================
set "WXSELF=%~f0"
set "WXPS=%TEMP%\WeChatSpecialAlert_run.ps1"
set "WXDATA=%APPDATA%\WeChatSpecialAlert"
set "WXARGS=%*"
if "%~1"=="" set "WXARGS=-Menu"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:WXSELF,[Text.Encoding]::UTF8); $m='#WXPS'+'BODY'+'#'; $i=$t.IndexOf($m); if ($i -lt 0) { exit 2 }; [IO.File]::WriteAllText($env:WXPS,$t.Substring($i+$m.Length),(New-Object Text.UTF8Encoding($true)))"
if errorlevel 1 (
    echo.
    echo [ERROR] Failed to prepare the script. Please make sure PowerShell is available.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%WXPS%" -DataDir "%WXDATA%" %WXARGS%
set "EC=%ERRORLEVEL%"
del "%WXPS%" >nul 2>&1
echo.
echo [WeChatSpecialAlert closed] Press any key to close this window.
pause >nul
exit /b %EC%
#WXPSBODY#<#
  微信特别提醒 (WeChat Special Alert)  v1.0
  ------------------------------------------------------------------
  作用：当指定的微信联系人给你发来新消息时，用「专属铃声 + 语音播报 +
        全屏置顶大弹窗 + 任务栏闪烁」的方式进行特别提醒。

  原理：轮询截取微信窗口左侧会话列表 → 用 Windows 自带中文 OCR 识别
        联系人名字 → 检查该行右侧是否有红色未读角标。
        另外会监控微信右下角的"新消息弹窗"，双重触发。

  运行环境：Windows 10/11 + Windows PowerShell 5.1（系统自带，无需安装任何东西）

  用法见同目录 README.md
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = '',
    [string]$DataDir = '',        # 配置/头像/日志存放目录（留空=脚本所在目录）
    [switch]$Menu,                # 显示控制台菜单
    [switch]$StartHidden,         # 后台静默启动（不打印启动横幅）
    [switch]$Diagnose,            # 诊断：输出窗口信息、截图、OCR 结果，不启动提醒
    [switch]$Calibrate,           # 校准：只打印会话列表里识别到的名字
    [switch]$TeachAvatar,         # 校准头像：点一下目标联系人所在行，记住他的头像
    [switch]$SelectContacts,      # 打开"选择提醒联系人"界面
    [string]$SetContacts = '',    # 直接设置联系人（用逗号分隔），配合脚本/批处理使用
    [string]$ContactName = '',    # 配合 -TeachAvatar 指定要校准的联系人
    [string]$CalibrationPoint = '', # 调试用：直接指定校准点击的屏幕坐标 "x,y"
    [switch]$TestAlert,           # 预览提醒效果（铃声+弹窗+语音）
    [int]$Seconds = 0,            # 预览提醒 N 秒后自动关闭（0=一直显示到手动关闭）
    [switch]$Once,                # 只检测一次后退出（配合 -NoAlert 可用于验证）
    [switch]$NoAlert,             # 检测到也不弹窗，只写日志（试运行）
    [switch]$Trace,               # 打印详细检测过程（排错用）
    [int]$DurationSeconds = 0,    # 运行 N 秒后自动退出
    [int]$ForceMainWindowHwnd = 0 # 指定主窗口句柄（调试用）
)

$ErrorActionPreference = 'Stop'

# 注意：不能在 param() 默认值里用 $PSScriptRoot（某些启动方式下它是空的），这里兜底
if (-not $PSScriptRoot) { $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $DataDir) { $DataDir = $PSScriptRoot }
if (-not (Test-Path -LiteralPath $DataDir)) {
    try {
        New-Item -ItemType Directory -Path $DataDir -Force -ErrorAction Stop | Out-Null
    } catch {
        # 个别环境下 %APPDATA% 不可写，退回到临时目录
        $fallback = Join-Path $env:TEMP 'WeChatSpecialAlert'
        New-Item -ItemType Directory -Path $fallback -Force -ErrorAction SilentlyContinue | Out-Null
        Write-Host ("注意：无法写入 {0}，改用 {1}" -f $DataDir, $fallback) -ForegroundColor Yellow
        $DataDir = $fallback
        $script:DataDir = $fallback
    }
}
if (-not $ConfigFile) { $ConfigFile = Join-Path $DataDir 'config.json' }
$script:DataDir = $DataDir

# ==================================================================
# 基础环境
# ==================================================================
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public class WxWin {
    public IntPtr Handle;
    public uint Pid;
    public string Title = "";
    public string Class = "";
    public bool Visible;
    public bool Minimized;
    public int X, Y, W, H;
    public override string ToString() {
        return string.Format("0x{0:X8} pid={1,-6} {2,5}x{3,-5} at {4},{5} visible={6,-5} min={7,-5} class={8} title={9}",
            (long)Handle, Pid, W, H, X, Y, Visible, Minimized, Class, Title);
    }
}

public class CaptureResult {
    public Bitmap Image;
    public bool Blank;
    public int X, Y, W, H;
}

public class ScanResult {
    public int Red;
    public int Gray;
    public int MinX = int.MaxValue, MinY = int.MaxValue, MaxX = -1, MaxY = -1;
    public int RedW { get { return MaxX < 0 ? 0 : MaxX - MinX + 1; } }
    public int RedH { get { return MaxY < 0 ? 0 : MaxY - MinY + 1; } }
}

public class Blob {
    public int X, Y, W, H, Count, SumX, SumY;
    public double CenterX { get { return SumX / (double)Count; } }
    public double CenterY { get { return SumY / (double)Count; } }
    public override string ToString() {
        return string.Format("{0}x{1} @ {2},{3} ({4}px)", W, H, X, Y, Count);
    }
}

public class MatchResult {
    public double Score;
    public int X, Y;
    public override string ToString() { return string.Format("score={0:0.000} at {1},{2}", Score, X, Y); }
}

public static class WxNative {
    public delegate bool EnumProc(IntPtr h, IntPtr l);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO {
        public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout;
    }

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern int GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO fwi);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);

    const uint PW_RENDERFULLCONTENT = 2;

    public static void EnableDpiAwareness() {
        try { SetProcessDpiAwareness(2); } catch { }
        try { SetProcessDPIAware(); } catch { }
    }

    public static List<WxWin> EnumTopLevel() {
        var list = new List<WxWin>();
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid; GetWindowThreadProcessId(h, out pid);
            var t = new StringBuilder(512); GetWindowTextW(h, t, 512);
            var c = new StringBuilder(512); GetClassNameW(h, c, 512);
            RECT r; GetWindowRect(h, out r);
            list.Add(new WxWin {
                Handle = h, Pid = pid, Title = t.ToString(), Class = c.ToString(),
                Visible = IsWindowVisible(h), Minimized = IsIconic(h),
                X = r.Left, Y = r.Top, W = r.Right - r.Left, H = r.Bottom - r.Top
            });
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static double GetScale(IntPtr h) {
        try {
            int dpi = GetDpiForWindow(h);
            if (dpi <= 0) dpi = 96;
            return dpi / 96.0;
        } catch { return 1.0; }
    }

    // 用 PrintWindow 抓取窗口内容（即使被其它窗口遮挡也能抓到）
    public static CaptureResult Capture(IntPtr h) {
        var res = new CaptureResult();
        RECT r;
        if (!GetWindowRect(h, out r)) return res;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0 || w > 8000 || ht > 8000) return res;
        var bmp = new Bitmap(w, ht);
        try {
            using (var g = Graphics.FromImage(bmp)) {
                IntPtr hdc = g.GetHdc();
                try { PrintWindow(h, hdc, PW_RENDERFULLCONTENT); }
                finally { g.ReleaseHdc(hdc); }
            }
        } catch { return res; }
        res.Image = bmp; res.X = r.Left; res.Y = r.Top; res.W = w; res.H = ht;
        res.Blank = IsBlank(bmp);
        if (res.Blank) {
            // 退化方案：直接从屏幕上抓（窗口必须没被完全遮挡）
            try {
                var bmp2 = new Bitmap(w, ht);
                using (var g = Graphics.FromImage(bmp2)) {
                    g.CopyFromScreen(r.Left, r.Top, 0, 0, new Size(w, ht), CopyPixelOperation.SourceCopy);
                }
                if (!IsBlank(bmp2)) { bmp.Dispose(); res.Image = bmp2; res.Blank = false; }
                else bmp2.Dispose();
            } catch { }
        }
        return res;
    }

    public static bool IsBlank(Bitmap bmp) {
        if (bmp == null) return true;
        int step = Math.Max(1, Math.Min(bmp.Width, bmp.Height) / 64);
        var seen = new HashSet<int>();
        int minLum = 255, maxLum = 0;
        for (int y = 0; y < bmp.Height; y += step) {
            for (int x = 0; x < bmp.Width; x += step) {
                Color c = bmp.GetPixel(x, y);
                seen.Add((c.R << 16) | (c.G << 8) | c.B);
                int lum = (c.R * 299 + c.G * 587 + c.B * 114) / 1000;
                if (lum < minLum) minLum = lum;
                if (lum > maxLum) maxLum = lum;
                if (seen.Count > 40) return false;
            }
        }
        return seen.Count <= 3 && (maxLum - minLum) < 12;
    }

    public static Bitmap Crop(Bitmap src, int x, int y, int w, int h) {
        if (x < 0) { w += x; x = 0; }
        if (y < 0) { h += y; y = 0; }
        if (x + w > src.Width) w = src.Width - x;
        if (y + h > src.Height) h = src.Height - y;
        if (w <= 0 || h <= 0) return null;
        var dst = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(dst)) {
            g.DrawImage(src, new Rectangle(0, 0, w, h), new Rectangle(x, y, w, h), GraphicsUnit.Pixel);
        }
        return dst;
    }

    public static Bitmap Scale(Bitmap src, double scale) {
        if (Math.Abs(scale - 1.0) < 0.01) {
            return (Bitmap)src.Clone();
        }
        int w = (int)Math.Round(src.Width * scale);
        int h = (int)Math.Round(src.Height * scale);
        if (w < 1) w = 1;
        if (h < 1) h = 1;
        var dst = new Bitmap(w, h, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(dst)) {
            g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            g.DrawImage(src, 0, 0, w, h);
        }
        return dst;
    }

    public static void SavePng(Bitmap bmp, string path) {
        string dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
        bmp.Save(path, ImageFormat.Png);
    }

    public static void SaveBmp(Bitmap bmp, string path) {
        string dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
        bmp.Save(path, ImageFormat.Bmp);
    }

    // 逐像素比较两张同尺寸位图，返回"不同像素"的比例（每 2 像素抽样一次）
    public static double DiffRatio(Bitmap a, Bitmap b) {
        if (a == null || b == null) return 1.0;
        if (a.Width != b.Width || a.Height != b.Height) return 1.0;
        var da = a.LockBits(new Rectangle(0, 0, a.Width, a.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        var db = b.LockBits(new Rectangle(0, 0, b.Width, b.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            byte[] ba = new byte[da.Stride * a.Height];
            byte[] bb = new byte[db.Stride * b.Height];
            Marshal.Copy(da.Scan0, ba, 0, ba.Length);
            Marshal.Copy(db.Scan0, bb, 0, bb.Length);
            long diff = 0, total = 0;
            for (int y = 0; y < a.Height; y += 2) {
                int rowA = y * da.Stride, rowB = y * db.Stride;
                for (int x = 0; x < a.Width; x += 2) {
                    int i = rowA + x * 4, j = rowB + x * 4;
                    total++;
                    if (Math.Abs(ba[i] - bb[j]) > 12 || Math.Abs(ba[i + 1] - bb[j + 1]) > 12 || Math.Abs(ba[i + 2] - bb[j + 2]) > 12) diff++;
                }
            }
            if (total == 0) return 0;
            return (double)diff / total;
        } finally { a.UnlockBits(da); b.UnlockBits(db); }
    }

    // 在指定区域内统计"红色未读角标"和"灰色静音圆点"的像素
    public static ScanResult ScanUnread(Bitmap bmp, int x, int y, int w, int h) {
        var res = new ScanResult();
        int x2 = Math.Min(bmp.Width, x + w);
        int y2 = Math.Min(bmp.Height, y + h);
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            int stride = data.Stride;
            byte[] buf = new byte[stride * bmp.Height];
            Marshal.Copy(data.Scan0, buf, 0, buf.Length);
            for (int yy = y; yy < y2; yy++) {
                int row = yy * stride;
                for (int xx = x; xx < x2; xx++) {
                    int i = row + xx * 4;
                    int b = buf[i], g = buf[i + 1], r = buf[i + 2];
                    bool isRed = r > 170 && g < 100 && b < 100 && (r - g) > 70 && (r - b) > 60;
                    if (isRed) {
                        res.Red++;
                        if (xx < res.MinX) res.MinX = xx;
                        if (xx > res.MaxX) res.MaxX = xx;
                        if (yy < res.MinY) res.MinY = yy;
                        if (yy > res.MaxY) res.MaxY = yy;
                    } else {
                        int mx = Math.Max(r, Math.Max(g, b));
                        int mn = Math.Min(r, Math.Min(g, b));
                        if (mx - mn < 22 && r > 105 && r < 205) res.Gray++;
                    }
                }
            }
        } finally { bmp.UnlockBits(data); }
        return res;
    }

    // 找出区域内所有"红色小圆点/圆角矩形"（未读角标），返回连通块的坐标和大小
    public static List<Blob> FindRedBlobs(Bitmap bmp, int x, int y, int w, int h, int minPixels, int maxW, int maxH) {
        var result = new List<Blob>();
        int x2 = Math.Min(bmp.Width, x + w);
        int y2 = Math.Min(bmp.Height, y + h);
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x2 <= x || y2 <= y) return result;

        int rw = x2 - x, rh = y2 - y;
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        bool[] mask;
        try {
            int stride = data.Stride;
            byte[] buf = new byte[stride * bmp.Height];
            Marshal.Copy(data.Scan0, buf, 0, buf.Length);
            mask = new bool[rw * rh];
            for (int yy = 0; yy < rh; yy++) {
                int row = (y + yy) * stride;
                for (int xx = 0; xx < rw; xx++) {
                    int i = row + (x + xx) * 4;
                    int b = buf[i], g = buf[i + 1], r = buf[i + 2];
                    if (r > 165 && g < 110 && b < 110 && (r - g) > 60 && (r - b) > 50) mask[yy * rw + xx] = true;
                }
            }
        } finally { bmp.UnlockBits(data); }

        var visited = new bool[mask.Length];
        var stack = new Stack<int>();
        for (int start = 0; start < mask.Length; start++) {
            if (!mask[start] || visited[start]) continue;
            stack.Clear();
            stack.Push(start);
            visited[start] = true;
            int count = 0, minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1, sumX = 0, sumY = 0;
            while (stack.Count > 0) {
                int idx = stack.Pop();
                int px = idx % rw, py = idx / rw;
                count++; sumX += px; sumY += py;
                if (px < minX) minX = px;
                if (px > maxX) maxX = px;
                if (py < minY) minY = py;
                if (py > maxY) maxY = py;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        int nx = px + dx, ny = py + dy;
                        if (nx < 0 || ny < 0 || nx >= rw || ny >= rh) continue;
                        int nidx = ny * rw + nx;
                        if (mask[nidx] && !visited[nidx]) { visited[nidx] = true; stack.Push(nidx); }
                    }
                }
            }
            int bw = maxX - minX + 1, bh = maxY - minY + 1;
            if (count >= minPixels && bw <= maxW && bh <= maxH && bw >= 4 && bh >= 4) {
                result.Add(new Blob {
                    X = minX + x, Y = minY + y, W = bw, H = bh, Count = count, SumX = sumX + x * count, SumY = sumY + y * count
                });
            }
        }
        return result;
    }

    // 在给定区域内找出"内容块"（用来精确框出联系人头像）：返回最大的连通块
    public static Blob FindAvatarBox(Bitmap bmp, int x, int y, int w, int h) {
        int x2 = Math.Min(bmp.Width, x + w);
        int y2 = Math.Min(bmp.Height, y + h);
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x2 <= x || y2 <= y) return null;
        int rw = x2 - x, rh = y2 - y;

        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] buf;
        int stride;
        try {
            stride = data.Stride;
            buf = new byte[stride * bmp.Height];
            Marshal.Copy(data.Scan0, buf, 0, buf.Length);
        } finally { bmp.UnlockBits(data); }

        // 用区域四边像素估计背景色
        long sr = 0, sg = 0, sb = 0; int n = 0;
        for (int xx = 0; xx < rw; xx++) {
            int i = y * stride + (x + xx) * 4;
            sr += buf[i + 2]; sg += buf[i + 1]; sb += buf[i]; n++;
            int j = (y2 - 1) * stride + (x + xx) * 4;
            sr += buf[j + 2]; sg += buf[j + 1]; sb += buf[j]; n++;
        }
        for (int yy = 0; yy < rh; yy++) {
            int i = (y + yy) * stride + x * 4;
            sr += buf[i + 2]; sg += buf[i + 1]; sb += buf[i]; n++;
            int j = (y + yy) * stride + (x2 - 1) * 4;
            sr += buf[j + 2]; sg += buf[j + 1]; sb += buf[j]; n++;
        }
        int bgR = (int)(sr / n), bgG = (int)(sg / n), bgB = (int)(sb / n);

        var mask = new bool[rw * rh];
        for (int yy = 0; yy < rh; yy++) {
            int row = (y + yy) * stride;
            for (int xx = 0; xx < rw; xx++) {
                int i = row + (x + xx) * 4;
                int b = buf[i], g = buf[i + 1], r = buf[i + 2];
                int d = Math.Abs(r - bgR) + Math.Abs(g - bgG) + Math.Abs(b - bgB);
                if (d > 60) mask[yy * rw + xx] = true;
            }
        }

        var visited = new bool[mask.Length];
        var stack = new Stack<int>();
        Blob best = null;
        for (int start = 0; start < mask.Length; start++) {
            if (!mask[start] || visited[start]) continue;
            stack.Clear(); stack.Push(start); visited[start] = true;
            int count = 0, minX = int.MaxValue, minY = int.MaxValue, maxX = -1, maxY = -1;
            while (stack.Count > 0) {
                int idx = stack.Pop();
                int px = idx % rw, py = idx / rw;
                count++;
                if (px < minX) minX = px;
                if (px > maxX) maxX = px;
                if (py < minY) minY = py;
                if (py > maxY) maxY = py;
                for (int dy = -1; dy <= 1; dy++) {
                    for (int dx = -1; dx <= 1; dx++) {
                        int nx = px + dx, ny = py + dy;
                        if (nx < 0 || ny < 0 || nx >= rw || ny >= rh) continue;
                        int nidx = ny * rw + nx;
                        if (mask[nidx] && !visited[nidx]) { visited[nidx] = true; stack.Push(nidx); }
                    }
                }
            }
            int bw = maxX - minX + 1, bh = maxY - minY + 1;
            if (bw < 16 || bh < 16) continue;
            if (best == null || count > best.Count) {
                best = new Blob { X = minX + x, Y = minY + y, W = bw, H = bh, Count = count };
            }
        }
        return best;
    }

    // 灰度模板匹配（平均绝对差），在给定范围内搜索最相似的位置
    public static MatchResult MatchTemplate(Bitmap hay, Bitmap needle, int x0, int x1, int y0, int y1) {
        var res = new MatchResult();
        if (hay == null || needle == null) return res;
        int tw = needle.Width, th = needle.Height;
        if (tw < 8 || th < 8) return res;
        if (x1 > hay.Width - tw) x1 = hay.Width - tw;
        if (y1 > hay.Height - th) y1 = hay.Height - th;
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 < x0 || y1 < y0) return res;

        byte[] tg = ToGray(needle);
        var hd = hay.LockBits(new Rectangle(0, 0, hay.Width, hay.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] hb;
        int stride;
        try {
            stride = hd.Stride;
            hb = new byte[stride * hay.Height];
            Marshal.Copy(hd.Scan0, hb, 0, hb.Length);
        } finally { hay.UnlockBits(hd); }

        double best = -1; int bestX = x0, bestY = y0;
        for (int oy = y0; oy <= y1; oy++) {
            for (int ox = x0; ox <= x1; ox++) {
                long sum = 0; int cnt = 0;
                for (int ty = 0; ty < th; ty += 2) {
                    int row = (oy + ty) * stride;
                    for (int tx = 0; tx < tw; tx += 2) {
                        int i = row + (ox + tx) * 4;
                        int g = (hb[i + 2] * 299 + hb[i + 1] * 587 + hb[i] * 114) / 1000;
                        sum += Math.Abs(g - tg[ty * tw + tx]);
                        cnt++;
                    }
                }
                double score = 1.0 - (sum / (double)cnt) / 255.0;
                if (score > best) { best = score; bestX = ox; bestY = oy; }
            }
        }
        res.Score = best < 0 ? 0 : best;
        res.X = bestX; res.Y = bestY;
        return res;
    }

    static byte[] ToGray(Bitmap bmp) {
        var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        try {
            byte[] buf = new byte[data.Stride * bmp.Height];
            Marshal.Copy(data.Scan0, buf, 0, buf.Length);
            byte[] gray = new byte[bmp.Width * bmp.Height];
            for (int y = 0; y < bmp.Height; y++) {
                int row = y * data.Stride;
                for (int x = 0; x < bmp.Width; x++) {
                    int i = row + x * 4;
                    gray[y * bmp.Width + x] = (byte)((buf[i + 2] * 299 + buf[i + 1] * 587 + buf[i] * 114) / 1000);
                }
            }
            return gray;
        } finally { bmp.UnlockBits(data); }
    }

    // 把 needle 缩放到 (w,h) 后与 hay 的 (x,y) 区域比较，返回相似度（0~1）
    public static double CompareScaled(Bitmap hay, Bitmap needle, int x, int y, int w, int h) {
        if (hay == null || needle == null || w < 8 || h < 8) return 0;
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x + w > hay.Width || y + h > hay.Height) return 0;
        Bitmap scaled;
        using (var tmp = new Bitmap(w, h, PixelFormat.Format32bppArgb)) {
            using (var g = Graphics.FromImage(tmp)) {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(needle, 0, 0, w, h);
            }
            scaled = (Bitmap)tmp.Clone();
        }
        try {
            byte[] tg = ToGray(scaled);
            var hd = hay.LockBits(new Rectangle(0, 0, hay.Width, hay.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            byte[] hb;
            int stride;
            try {
                stride = hd.Stride;
                hb = new byte[stride * hay.Height];
                Marshal.Copy(hd.Scan0, hb, 0, hb.Length);
            } finally { hay.UnlockBits(hd); }
            long sum = 0; int cnt = 0;
            for (int ty = 0; ty < h; ty += 2) {
                int row = (y + ty) * stride;
                for (int tx = 0; tx < w; tx += 2) {
                    int i = row + (x + tx) * 4;
                    int g = (hb[i + 2] * 299 + hb[i + 1] * 587 + hb[i] * 114) / 1000;
                    sum += Math.Abs(g - tg[ty * w + tx]);
                    cnt++;
                }
            }
            return 1.0 - (sum / (double)cnt) / 255.0;
        } finally { scaled.Dispose(); }
    }

    public static void FlashTaskbar(IntPtr h, uint count) {
        if (h == IntPtr.Zero) return;
        var fwi = new FLASHWINFO();
        fwi.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        fwi.hwnd = h;
        fwi.dwFlags = 0x00000003 | 0x00000004; // FLASHW_ALL | FLASHW_TIMERNOFG
        fwi.uCount = count;
        fwi.dwTimeout = 0;
        try { FlashWindowEx(ref fwi); } catch { }
    }

    // 生成一个专属提示音（三段上行音，第一次运行自动创建）
    public static void WriteChime(string path) {
        int rate = 44100;
        double[] freqs = new double[] { 784.0, 1046.5, 1318.5 };
        int noteMs = 210, gapMs = 55;
        int total = freqs.Length * (noteMs + gapMs) + 120;
        int samples = rate * total / 1000;
        short[] pcm = new short[samples];
        int pos = 0;
        foreach (double f in freqs) {
            int n = rate * noteMs / 1000;
            for (int i = 0; i < n && pos < samples; i++, pos++) {
                double t = (double)i / rate;
                double env = Math.Min(1.0, Math.Min(i / (rate * 0.02), (n - i) / (rate * 0.05)));
                double v = 0.45 * env * (Math.Sin(2 * Math.PI * f * t) + 0.25 * Math.Sin(4 * Math.PI * f * t));
                pcm[pos] = (short)Math.Max(short.MinValue, Math.Min(short.MaxValue, v * 32767));
            }
            pos += rate * gapMs / 1000;
            if (pos >= samples) pos = samples - 1;
        }
        string dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
        using (var fs = new FileStream(path, FileMode.Create, FileAccess.Write)) {
            using (var bw = new BinaryWriter(fs)) {
                int dataBytes = samples * 2;
                bw.Write(new char[] { 'R', 'I', 'F', 'F' });
                bw.Write(36 + dataBytes);
                bw.Write(new char[] { 'W', 'A', 'V', 'E' });
                bw.Write(new char[] { 'f', 'm', 't', ' ' });
                bw.Write(16);
                bw.Write((short)1);
                bw.Write((short)1);
                bw.Write(rate);
                bw.Write(rate * 2);
                bw.Write((short)2);
                bw.Write((short)16);
                bw.Write(new char[] { 'd', 'a', 't', 'a' });
                bw.Write(dataBytes);
                foreach (short s in pcm) bw.Write(s);
            }
        }
    }
}
'@

if (-not ('WxNative' -as [type])) {
    Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies 'System.dll', 'System.Drawing.dll'
}
[WxNative]::EnableDpiAwareness()

# WinRT OCR 环境
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]

$script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    })[0]

function Await-WinRT($op, $resultType) {
    $netTask = $script:AsTaskGeneric.MakeGenericMethod($resultType).Invoke($null, @($op))
    $netTask.Wait(-1) | Out-Null
    $netTask.Result
}

# ==================================================================
# 配置
# ==================================================================
$defaultConfig = [ordered]@{
    # 要特别提醒的联系人（微信里显示的备注名/昵称）
    contacts                = @()
    # 微信进程名（4.x 是 Weixin，3.x 是 WeChat）
    processNames            = @('Weixin', 'WeChat')
    # 检测间隔（毫秒）
    pollIntervalMs          = 2000
    # OCR 放大倍率列表：会用每个倍率各识别一次并合并结果（单倍率容易漏字，多倍率互补）
    ocrScales               = @(2.5, 4.0)
    # 每次 OCR 输入图的像素上限（越大越准但越耗 CPU）
    maxOcrPixels            = 6000000
    ocrLanguage             = 'zh-Hans-CN'
    # 同一块画面最长多少秒重新识别一次（未读角标一直存在时）
    reOcrSeconds            = 3
    # 名字相似度阈值（0~1），识别不准可下调到 0.65
    matchThreshold          = 0.75
    # 会话列表裁剪范围（单位：逻辑像素，会按屏幕缩放自动换算）
    stripLeftDip            = 40
    stripRightDip           = 470
    stripRightRatio         = 0.55
    topOffsetDip            = 36
    # 未读角标（红色小圆点）的识别参数
    badgeMinPixels          = 25
    badgeMinXDip            = 60
    badgeMaxWidthDip        = 46
    badgeMaxHeightDip       = 32
    # 会话列表里"文字"区域的左边界（用它排除左侧头像和导航栏）
    nameAreaLeftDip         = 70
    # 头像模板匹配：搜索范围（相对窗口左上角）和匹配阈值
    avatarSearchXFromDip    = 30
    avatarSearchXToDip      = 150
    avatarSearchYAboveDip   = 46
    avatarSearchYBelowDip   = 24
    avatarMatchThreshold    = 0.90
    # 是否监控微信右下角的新消息弹窗（微信主窗口关到托盘时也能提醒）
    watchPopupWindow        = $true
    popupMinWidth           = 120
    popupMaxWidth           = 760
    popupMinHeight          = 50
    popupMaxHeight          = 460
    # 提醒效果
    soundFile               = ''          # 留空则使用自动生成的专属提示音 chime.wav
    soundLoopSeconds        = 15          # 铃声持续几秒（0=一直响到手动关闭）
    speakEnabled            = $true       # 语音播报
    speakTemplate           = '微信，{0}给你发消息了'
    popupEnabled            = $true       # 大弹窗
    popupTopMost            = $true
    alertAutoCloseSeconds   = 0           # 弹窗自动关闭秒数（0=不自动关闭）
    bringWeChatToFront      = $false      # 点"打开微信"时是否把微信窗口调到最前
    # 同一联系人两次提醒的最小间隔（秒）
    cooldownSeconds         = 12
    # 日志
    logEnabled              = $true
    logFile                 = 'alerts.log'
}

function Merge-Config($defaults, $user) {
    $out = @{}
    foreach ($k in $defaults.Keys) { $out[$k] = $defaults[$k] }
    if ($user) {
        foreach ($p in $user.PSObject.Properties) { $out[$p.Name] = $p.Value }
    }
    return $out
}

function Get-ContactList($raw) {
    $list = @()
    foreach ($c in @($raw)) {
        if ($null -eq $c) { continue }
        if ($c -is [string]) {
            if ($c.Trim()) { $list += , @{ name = $c.Trim(); aliases = @(); sound = ''; speak = '' } }
        } else {
            $name = [string]$c.name
            if (-not $name.Trim()) { continue }
            $aliases = @()
            if ($c.aliases) { $aliases = @($c.aliases | ForEach-Object { [string]$_ }) }
            $list += , @{
                name    = $name.Trim()
                aliases = $aliases
                sound   = [string]$c.sound
                speak   = [string]$c.speak
            }
        }
    }
    return $list
}

$script:Cfg = $null
$script:Contacts = @()
$script:LogPath = ''

function Load-AppConfig {
    $userCfg = $null
    if (Test-Path -LiteralPath $ConfigFile) {
        $raw = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8)
        $raw = $raw -replace '^\uFEFF', ''
        if ($raw.Trim()) {
            try { $userCfg = $raw | ConvertFrom-Json } catch { throw "配置文件格式有误: $($_.Exception.Message)" }
        }
    }
    $script:Cfg = Merge-Config $defaultConfig $userCfg
    $script:Contacts = Get-ContactList $script:Cfg['contacts']
    if ($script:Cfg['logEnabled']) {
        $logName = [string]$script:Cfg['logFile']
        if (-not [System.IO.Path]::IsPathRooted($logName)) { $logName = Join-Path $script:DataDir $logName }
        $script:LogPath = $logName
    }
}

function Write-Log([string]$message, [string]$level = 'INFO') {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $level, $message
    if ($script:LogPath) {
        try { [System.IO.File]::AppendAllText($script:LogPath, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }
    if ($script:VerboseConsole) { Write-Host $line }
}

$script:VerboseConsole = $true

# ==================================================================
# 文本匹配
# ==================================================================
function ConvertTo-NormalizedText([string]$text) {
    if (-not $text) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 0x3000 -or $code -eq 0x00A0) { continue }
        if ($code -ge 0xFF01 -and $code -le 0xFF5E) { $code = $code - 0xFEE0 }
        $c2 = [char]$code
        if ([char]::IsWhiteSpace($c2)) { continue }
        if ([char]::IsPunctuation($c2)) { continue }
        if ([char]::IsSymbol($c2)) { continue }
        [void]$sb.Append([char]::ToLowerInvariant($c2))
    }
    return $sb.ToString()
}

function Get-Levenshtein([string]$a, [string]$b) {
    $n = $a.Length; $m = $b.Length
    if ($n -eq 0) { return $m }
    if ($m -eq 0) { return $n }
    $prev = New-Object 'int[]' ($m + 1)
    $cur = New-Object 'int[]' ($m + 1)
    for ($j = 0; $j -le $m; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $n; $i++) {
        $cur[0] = $i
        $ca = $a[$i - 1]
        for ($j = 1; $j -le $m; $j++) {
            $cost = 1
            if ($ca -eq $b[$j - 1]) { $cost = 0 }
            $best = $prev[$j] + 1
            if (($cur[$j - 1] + 1) -lt $best) { $best = $cur[$j - 1] + 1 }
            if (($prev[$j - 1] + $cost) -lt $best) { $best = $prev[$j - 1] + $cost }
            $cur[$j] = $best
        }
        $tmp = $prev; $prev = $cur; $cur = $tmp
    }
    return $prev[$m]
}

# 返回 0~1 的相似度
function Get-MatchScore([string]$lineNorm, [string]$nameNorm) {
    if (-not $lineNorm -or -not $nameNorm) { return 0 }
    if ($lineNorm -eq $nameNorm) { return 1.0 }
    $maxLen = [Math]::Max($lineNorm.Length, $nameNorm.Length)
    $sim = 1.0 - ((Get-Levenshtein $lineNorm $nameNorm) / [double]$maxLen)
    if ($lineNorm.Contains($nameNorm) -and ($lineNorm.Length - $nameNorm.Length) -le 3) {
        if ($sim -lt 0.9) { $sim = 0.9 }
    }
    return $sim
}

function Get-ContactScore($contact, [string]$lineNorm) {
    $best = Get-MatchScore $lineNorm (ConvertTo-NormalizedText $contact.name)
    foreach ($alias in @($contact.aliases)) {
        if (-not $alias) { continue }
        $aliasNorm = ConvertTo-NormalizedText $alias
        if ($aliasNorm -and $lineNorm -eq $aliasNorm) { return 1.0 }
        $s = Get-MatchScore $lineNorm $aliasNorm
        if ($s -gt $best) { $best = $s }
    }
    return $best
}

# 用于"名字出现在一长段文字开头"的场景（例如微信弹窗里的"张三：xxx"）
function Get-ContactScoreLoose($contact, [string]$lineNorm) {
    $base = Get-ContactScore $contact $lineNorm
    if ($base -ge 0.75) { return $base }
    $nameNorm = ConvertTo-NormalizedText $contact.name
    if (-not $nameNorm) { return $base }
    if ($lineNorm.StartsWith($nameNorm) -and $lineNorm.Length -gt $nameNorm.Length) {
        if ($base -lt 0.92) { $base = 0.92 }
    } elseif ($lineNorm.Contains($nameNorm) -and $nameNorm.Length -ge 3) {
        if ($base -lt 0.85) { $base = 0.85 }
    }
    return $base
}

# ==================================================================
# OCR
# ==================================================================
function Initialize-Ocr {
    $tag = [string]$script:Cfg['ocrLanguage']
    $engine = $null
    if ($tag) {
        try { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage((New-Object Windows.Globalization.Language $tag)) } catch { $engine = $null }
    }
    if (-not $engine) { $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    if (-not $engine) {
        $avail = ([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag }) -join ', '
        throw "系统没有可用的 OCR 语言包（已安装: $avail）。请在 设置→时间和语言→语言 中安装中文(简体)的'光学字符识别'功能。"
    }
    return $engine
}

function Invoke-OcrOnFile([string]$path, [double]$scale) {
    $engine = $script:OcrEngine
    $file = Await-WinRT ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
    $stream = Await-WinRT ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Await-WinRT ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $software = Await-WinRT ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Await-WinRT ($engine.RecognizeAsync($software)) ([Windows.Media.Ocr.OcrResult])
        $lines = @()
        foreach ($line in $result.Lines) {
            $xs = @($line.Words | ForEach-Object { $_.BoundingRect })
            if (-not $xs) { continue }
            $minX = ($xs | Measure-Object X -Minimum).Minimum
            $minY = ($xs | Measure-Object Y -Minimum).Minimum
            $maxR = ($xs | ForEach-Object { $_.X + $_.Width } | Measure-Object -Maximum).Maximum
            $maxB = ($xs | ForEach-Object { $_.Y + $_.Height } | Measure-Object -Maximum).Maximum
            $lines += [pscustomobject]@{
                Text   = $line.Text
                X      = $minX / $scale
                Y      = $minY / $scale
                Right  = $maxR / $scale
                Bottom = $maxB / $scale
            }
        }
        return , $lines
    } finally { $stream.Dispose() }
}

# 按像素上限自动收敛放大倍率：图太大时降低倍率，控制单次识别耗时
function Get-EffectiveScale([System.Drawing.Bitmap]$bitmap, [double]$wanted) {
    $scale = $wanted
    $maxPixels = [double]$script:Cfg['maxOcrPixels']
    $pixels = [double]$bitmap.Width * [double]$bitmap.Height
    if ($pixels -gt 0 -and $maxPixels -gt 0) {
        $limit = [Math]::Sqrt($maxPixels / $pixels)
        if ($scale -gt $limit) { $scale = $limit }
    }
    if ($scale -lt 1.0) { $scale = 1.0 }
    return $scale
}

# 放大 → 存盘 → OCR，返回裁剪坐标系下的识别结果
function Invoke-OcrOnBitmap([System.Drawing.Bitmap]$bitmap, [double]$scale, [string]$tmpPath) {
    $scaled = [WxNative]::Scale($bitmap, $scale)
    try {
        if ($tmpPath -like '*.bmp') { [WxNative]::SaveBmp($scaled, $tmpPath) }
        else { [WxNative]::SavePng($scaled, $tmpPath) }
    } finally { $scaled.Dispose() }
    return Invoke-OcrOnFile $tmpPath $scale
}

# ==================================================================
# 窗口
# ==================================================================
$script:WeChatPids = @()
$script:PidRefreshTick = 0

function Update-WeChatPids {
    $names = @($script:Cfg['processNames'])
    $pids = @()
    foreach ($n in $names) {
        foreach ($p in (Get-Process -Name $n -ErrorAction SilentlyContinue)) {
            $pids += [uint32]$p.Id
        }
    }
    $script:WeChatPids = $pids
    if ($Trace) { Write-Host ("    [进程] 匹配到 {0} 个 {1} 进程: {2}" -f $pids.Count, ($names -join '/'), ($pids -join ',')) }
}

function Get-WeChatWindows {
    Update-WeChatPids
    $all = [WxNative]::EnumTopLevel()
    return , @($all | Where-Object { $script:WeChatPids -contains $_.Pid })
}

function Select-MainWindow($wins, $exclude) {
    $cands = @($wins | Where-Object {
            $_.W -ge 420 -and $_.H -ge 320 -and
            ([uint32]$_.Pid -ne [uint32]$PID) -and
            ($_.Class -notlike 'WindowsForms*') -and
            ($_.Class -ne '#32768') -and
            ($_.Class -notlike '*tooltips_class*') -and
            ($exclude -notcontains $_.Handle)
        })
    if (-not $cands) { return $null }
    $visible = @($cands | Where-Object { $_.Visible })
    $pool = $cands
    if ($visible) { $pool = $visible }
    return ($pool | Sort-Object -Property @{ Expression = { $_.W * $_.H } } -Descending)[0]
}

# ==================================================================
# 提醒
# ==================================================================
$script:AlertForm = $null
$script:AlertNames = New-Object System.Collections.ArrayList
$script:SoundPlayer = $null
$script:SoundStopTimer = $null
$script:SpeakSynth = $null
$script:SpeakReady = $false
$script:MainWindowHandle = [IntPtr]::Zero

function Get-SoundFile($contact) {
    if ($contact -and $contact.sound) {
        if (Test-Path -LiteralPath $contact.sound) { return $contact.sound }
    }
    $cfgSound = [string]$script:Cfg['soundFile']
    if ($cfgSound -and (Test-Path -LiteralPath $cfgSound)) { return $cfgSound }
    $chime = Join-Path $script:DataDir 'chime.wav'
    if (-not (Test-Path -LiteralPath $chime)) {
        try { [WxNative]::WriteChime($chime) } catch { Write-Log "生成提示音失败: $($_.Exception.Message)" 'WARN' }
    }
    if (Test-Path -LiteralPath $chime) { return $chime }
    return ''
}

function Stop-AlertSound {
    if ($script:SoundPlayer) { try { $script:SoundPlayer.Stop() } catch { } }
    if ($script:SoundStopTimer) { $script:SoundStopTimer.Stop() }
}

function Start-AlertSound([string]$wavPath, [int]$seconds) {
    Stop-AlertSound
    if (-not $wavPath) {
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
        return
    }
    try {
        if (-not $script:SoundPlayer) { $script:SoundPlayer = New-Object System.Media.SoundPlayer }
        $script:SoundPlayer.SoundLocation = $wavPath
        $script:SoundPlayer.Load()
        $script:SoundPlayer.PlayLooping()
        if ($seconds -gt 0) {
            if (-not $script:SoundStopTimer) {
                $script:SoundStopTimer = New-Object System.Windows.Forms.Timer
                $script:SoundStopTimer.Add_Tick({ Stop-AlertSound })
            }
            $script:SoundStopTimer.Interval = $seconds * 1000
            $script:SoundStopTimer.Stop()
            $script:SoundStopTimer.Start()
        }
    } catch {
        Write-Log "播放提示音失败: $($_.Exception.Message)" 'WARN'
        try { [System.Media.SystemSounds]::Exclamation.Play() } catch { }
    }
}

function Start-Speak([string]$text) {
    if (-not $script:Cfg['speakEnabled'] -or -not $text) { return }
    if (-not $script:SpeakReady) {
        try {
            Add-Type -AssemblyName System.Speech
            $script:SpeakSynth = New-Object System.Speech.Synthesis.SpeechSynthesizer
            try { $script:SpeakSynth.Rate = 0 } catch { }
            try { $script:SpeakSynth.Volume = 100 } catch { }
            $script:SpeakReady = $true
        } catch {
            $script:SpeakReady = $false
            Write-Log "语音播报不可用: $($_.Exception.Message)" 'WARN'
            return
        }
    }
    try { $script:SpeakSynth.SpeakAsync($text) | Out-Null } catch { }
}

function Open-WeChatWindow {
    $h = $script:MainWindowHandle
    if ($h -eq [IntPtr]::Zero -or -not [WxNative]::IsWindow($h)) {
        foreach ($w in (Get-WeChatWindows)) {
            $m = Select-MainWindow @($w) @()
            if ($m) { $h = $m.Handle; break }
        }
    }
    if ($h -ne [IntPtr]::Zero) {
        try {
            [WxNative]::ShowWindow($h, 9) | Out-Null   # SW_RESTORE
            [WxNative]::SetForegroundWindow($h) | Out-Null
        } catch { }
    }
}

function Show-AlertWindow($names, [string]$detail, [string]$wav) {
    if (-not $script:Cfg['popupEnabled']) { return }
    $title = ($names -join '、') + ' 给你发消息了'

    if ($script:AlertForm -and -not $script:AlertForm.IsDisposed) {
        foreach ($n in $names) { if (-not $script:AlertNames.Contains($n)) { [void]$script:AlertNames.Add($n) } }
        $script:AlertForm.Controls['lblTitle'].Text = (($script:AlertNames) -join '、') + ' 给你发消息了'
        $script:AlertForm.Controls['lblDetail'].Text = $detail
        $script:AlertForm.Activate()
        try { [WxNative]::FlashTaskbar($script:AlertForm.Handle, 6) } catch { }
        return
    }

    foreach ($n in $names) { if (-not $script:AlertNames.Contains($n)) { [void]$script:AlertNames.Add($n) } }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '微信特别提醒'
    $form.ClientSize = New-Object System.Drawing.Size 480, 210
    $form.FormBorderStyle = 'FixedToolWindow'
    $form.StartPosition = 'Manual'
    $form.TopMost = [bool]$script:Cfg['popupTopMost']
    $form.ShowInTaskbar = $true
    $form.BackColor = [System.Drawing.Color]::White

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = 'Top'
    $header.Height = 40
    $header.BackColor = [System.Drawing.Color]::FromArgb(200, 30, 30)
    $lblHeaderText = New-Object System.Windows.Forms.Label
    $lblHeaderText.Text = '  微信特别提醒'
    $lblHeaderText.ForeColor = [System.Drawing.Color]::White
    $lblHeaderText.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei', 12, ([System.Drawing.FontStyle]::Bold)
    $lblHeaderText.Dock = 'Fill'
    $lblHeaderText.TextAlign = 'MiddleLeft'
    $header.Controls.Add($lblHeaderText)
    $form.Controls.Add($header)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Name = 'lblTitle'
    $lblTitle.Text = $title
    $lblTitle.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei', 20, ([System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(180, 20, 20)
    $lblTitle.TextAlign = 'MiddleCenter'
    $lblTitle.SetBounds(10, 52, 460, 46)
    $form.Controls.Add($lblTitle)

    $lblDetail = New-Object System.Windows.Forms.Label
    $lblDetail.Name = 'lblDetail'
    $lblDetail.Text = $detail
    $lblDetail.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei', 10
    $lblDetail.ForeColor = [System.Drawing.Color]::DimGray
    $lblDetail.TextAlign = 'MiddleCenter'
    $lblDetail.SetBounds(10, 100, 460, 44)
    $form.Controls.Add($lblDetail)

    $btnOpen = New-Object System.Windows.Forms.Button
    $btnOpen.Text = '打开微信'
    $btnOpen.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei', 10
    $btnOpen.SetBounds(96, 152, 130, 40)
    $btnOpen.Add_Click({
            Open-WeChatWindow
            $script:AlertForm.Close()
        })
    $form.Controls.Add($btnOpen)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = '知道了'
    $btnOk.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei', 10
    $btnOk.SetBounds(254, 152, 130, 40)
    $btnOk.Add_Click({ $script:AlertForm.Close() })
    $form.Controls.Add($btnOk)

    $form.Add_FormClosed({
            Stop-AlertSound
            $script:AlertForm = $null
            $script:AlertNames = New-Object System.Collections.ArrayList
        })

    # 屏幕中上方
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Left = $screen.Left + [int](($screen.Width - $form.Width) / 2)
    $form.Top = $screen.Top + 60

    $script:AlertForm = $form
    $form.Show()
    $form.Activate()
    try { [WxNative]::FlashTaskbar($form.Handle, 8) } catch { }

    if ([int]$script:Cfg['alertAutoCloseSeconds'] -gt 0) {
        $auto = New-Object System.Windows.Forms.Timer
        $auto.Interval = [int]$script:Cfg['alertAutoCloseSeconds'] * 1000
        $auto.Add_Tick({ $auto.Stop(); if ($script:AlertForm) { $script:AlertForm.Close() } })
        $auto.Start()
    }
    Start-AlertSound $wav ([int]$script:Cfg['soundLoopSeconds'])
    $speakText = ''
    foreach ($n in $names) {
        $contact = $script:Contacts | Where-Object { $_.name -eq $n } | Select-Object -First 1
        if ($contact -and $contact.speak) { $speakText = $contact.speak } else { $speakText = ([string]$script:Cfg['speakTemplate']) -f $n }
        break
    }
    Start-Speak $speakText
}

function Invoke-Alert($matchedContacts, [string]$detail, [string]$source) {
    $names = @($matchedContacts | ForEach-Object { $_.name })
    $timeText = (Get-Date -Format 'HH:mm:ss')
    $desc = "$timeText  来源:$source" + $(if ($detail) { "  $detail" } else { '' })
    Write-Log "【提醒】$($names -join '、') 有新消息 ($source) $detail" 'ALERT'
    if ($NoAlert) { return }
    $wav = ''
    foreach ($c in $matchedContacts) {
        $wav = Get-SoundFile $c
        if ($wav) { break }
    }
    Show-AlertWindow $names $desc $wav
}

function Test-AlertPreview([int]$seconds) {
    $demo = @{ name = '测试联系人'; aliases = @(); sound = ''; speak = '' }
    Invoke-Alert @($demo) '这是一条测试提醒（-TestAlert）' '测试'
    $form = $script:AlertForm
    if ($form) {
        $end = (Get-Date).AddSeconds($(if ($seconds -gt 0) { $seconds } else { 3600 }))
        while ((Get-Date) -lt $end -and $script:AlertForm -and -not $script:AlertForm.IsDisposed) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        if ($script:AlertForm) { $script:AlertForm.Close() }
    }
}

# ==================================================================
# 检测
# ==================================================================
$script:ContactState = @{}

# ==================================================================
# 头像模板（校准数据）
# ==================================================================
$script:AvatarTemplates = @()   # @( @{ name=..; bitmap=Bitmap; file=..; dpi=.. } )

function Get-AvatarIndexPath { Join-Path $script:DataDir 'avatars.json' }

function Load-AvatarTemplates {
    $script:AvatarTemplates = @()
    $indexPath = Get-AvatarIndexPath
    if (-not (Test-Path -LiteralPath $indexPath)) { return }
    try {
        $raw = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8) -replace '^\uFEFF', ''
        if (-not $raw.Trim()) { return }
        foreach ($item in @($raw | ConvertFrom-Json)) {
            if (-not $item.name -or -not $item.file) { continue }
            $file = [string]$item.file
            if (-not [System.IO.Path]::IsPathRooted($file)) { $file = Join-Path $script:DataDir $file }
            if (-not (Test-Path -LiteralPath $file)) { continue }
            $bmp = $null
            try { $bmp = New-Object System.Drawing.Bitmap $file } catch { continue }
            $dpi = 1.0
            if ($item.dpi) { $dpi = [double]$item.dpi }
            $script:AvatarTemplates += , @{ name = [string]$item.name; bitmap = $bmp; file = $file; dpi = $dpi }
        }
    } catch {
        Write-Log "读取 avatars.json 失败: $($_.Exception.Message)" 'WARN'
    }
}

function Save-AvatarTemplate([string]$name, [System.Drawing.Bitmap]$bitmap, [double]$dpi) {
    $indexPath = Get-AvatarIndexPath
    $items = @()
    if (Test-Path -LiteralPath $indexPath) {
        try {
            $raw = [System.IO.File]::ReadAllText($indexPath, [System.Text.Encoding]::UTF8) -replace '^\uFEFF', ''
            if ($raw.Trim()) { $items += @($raw | ConvertFrom-Json) }
        } catch { }
    }
    $fileName = 'avatar_' + ($name -replace '[\\/:*?"<>|]', '_') + '.png'
    $fullPath = Join-Path $script:DataDir $fileName
    [WxNative]::SavePng($bitmap, $fullPath)
    $items = @($items | Where-Object { $_.name -ne $name })
    $items += [pscustomobject]@{ name = $name; file = $fileName; dpi = [Math]::Round($dpi, 3) }
    $json = ConvertTo-Json -InputObject @($items) -Depth 6
    [System.IO.File]::WriteAllText($indexPath, $json, (New-Object System.Text.UTF8Encoding($true)))
    return $fullPath
}

# 把联系人列表写回 config.json（保留其它配置项，以及原有的别名写法）
function Save-ContactConfig([string[]]$names) {
    $names = @($names | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique)
    $obj = $null
    if (Test-Path -LiteralPath $ConfigFile) {
        $raw = [System.IO.File]::ReadAllText($ConfigFile, [System.Text.Encoding]::UTF8) -replace '^\uFEFF', ''
        if ($raw.Trim()) { try { $obj = $raw | ConvertFrom-Json } catch { $obj = $null } }
    }
    if (-not $obj) { $obj = New-Object psobject }

    $keep = @{}
    if ($obj.PSObject.Properties.Name -contains 'contacts') {
        foreach ($c in @($obj.contacts)) {
            if ($c -isnot [string] -and $c.name) { $keep[[string]$c.name] = $c }
        }
    }
    $out = @()
    foreach ($n in $names) {
        if ($keep.ContainsKey($n)) { $out += $keep[$n] } else { $out += $n }
    }
    if ($obj.PSObject.Properties.Name -contains 'contacts') { $obj.contacts = @($out) }
    else { $obj | Add-Member -NotePropertyName contacts -NotePropertyValue @($out) -Force }

    $json = $obj | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ConfigFile, $json, (New-Object System.Text.UTF8Encoding($true)))
    Write-Log ("联系人配置已保存: {0}" -f ($names -join '、')) 'INFO'
}

function Update-AvatarTemplatesFromConfig { Load-AvatarTemplates }

function Test-AvatarMatch([System.Drawing.Bitmap]$strip, $blob, [double]$dpi) {
    if (-not $script:AvatarTemplates.Count) { return $null }
    $best = $null
    foreach ($tpl in $script:AvatarTemplates) {
        $needle = $tpl.bitmap
        if ([Math]::Abs($dpi - $tpl.dpi) -gt 0.05) {
            $factor = $dpi / $tpl.dpi
            $needle = [WxNative]::Scale($tpl.bitmap, $factor)
        }
        try {
            # 配置里是"相对微信窗口左上角"的坐标，裁剪图已经右移了 stripLeftDip，这里要换算
            $stripLeft = [double]$script:Cfg['stripLeftDip'] * $dpi
            $x0 = [int]([double]$script:Cfg['avatarSearchXFromDip'] * $dpi - $stripLeft)
            $x1 = [int]([double]$script:Cfg['avatarSearchXToDip'] * $dpi - $stripLeft)
            $y0 = [int]($blob.Y - [double]$script:Cfg['avatarSearchYAboveDip'] * $dpi)
            $y1 = [int]($blob.Y + $blob.H + [double]$script:Cfg['avatarSearchYBelowDip'] * $dpi)
            $m = [WxNative]::MatchTemplate($strip, $needle, $x0, $x1, $y0, $y1)
            if ($Calibrate -or $Diagnose) { Write-Host ("    头像匹配【{0}】{1}" -f $tpl.name, $m.ToString()) }
            if ($m.Score -ge [double]$script:Cfg['avatarMatchThreshold']) {
                if (-not $best -or $m.Score -gt $best.Score) {
                    $best = [pscustomobject]@{ name = $tpl.name; Score = $m.Score; Match = $m }
                }
            }
        } finally {
            if ($needle -ne $tpl.bitmap) { $needle.Dispose() }
        }
    }
    return $best
}

function Find-ContactByName([string]$name) {
    foreach ($c in $script:Contacts) { if ($c.name -eq $name) { return $c } }
    return $null
}

# 校准：让用户点一下微信会话列表里目标联系人的那一行，自动截取头像作为模板
function Invoke-AvatarCalibration {
    $win = $null
    if ($ForceMainWindowHwnd -gt 0) {
        $win = [WxNative]::EnumTopLevel() | Where-Object { $_.Handle -eq [IntPtr]$ForceMainWindowHwnd } | Select-Object -First 1
    }
    if (-not $win) {
        Update-WeChatPids
        $win = Select-MainWindow (Get-WeChatWindows) @()
    }
    if (-not $win) {
        Write-Host '没找到微信主窗口，请先登录微信并打开主界面。' -ForegroundColor Yellow
        return
    }

    $v = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $overlay = New-Object System.Windows.Forms.Form
    $overlay.FormBorderStyle = 'None'
    $overlay.StartPosition = 'Manual'
    $overlay.Bounds = New-Object System.Drawing.Rectangle $v.X, $v.Y, $v.Width, $v.Height
    $overlay.TopMost = $true
    $overlay.ShowInTaskbar = $false
    $overlay.BackColor = [System.Drawing.Color]::Black
    $overlay.Opacity = 0.25
    $overlay.Cursor = [System.Windows.Forms.Cursors]::Cross

    $tip = New-Object System.Windows.Forms.Label
    $tip.Text = '请点击微信会话列表中【目标联系人】所在的那一行（按 Esc 取消）'
    $tip.ForeColor = [System.Drawing.Color]::White
    $tip.BackColor = [System.Drawing.Color]::FromArgb(200, 30, 30)
    $tip.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei', 16, ([System.Drawing.FontStyle]::Bold)
    $tip.TextAlign = 'MiddleCenter'
    $tip.SetBounds(($v.Width - 900) / 2, 40, 900, 56)
    $overlay.Controls.Add($tip)

    $script:CalibrationClick = $null
    if ($CalibrationPoint -and $CalibrationPoint -match '^\s*(-?\d+)\s*,\s*(-?\d+)\s*$') {
        $screenX = [int]$Matches[1]
        $screenY = [int]$Matches[2]
        Write-Host ("使用指定坐标校准: {0},{1}" -f $screenX, $screenY)
    } else {
        $overlay.Add_MouseClick({
                if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $script:CalibrationClick = $null }
                else { $script:CalibrationClick = $_.Location }
                $overlay.Close()
            })
        $overlay.Add_KeyDown({ if ($_.KeyCode -eq 'Escape') { $overlay.Close() } })
        $overlay.Add_Shown({ $overlay.Activate() })

        [System.Windows.Forms.Application]::Run($overlay)
        if (-not $script:CalibrationClick) { Write-Host '已取消校准。'; return $null }

        $screenX = $v.X + $script:CalibrationClick.X
        $screenY = $v.Y + $script:CalibrationClick.Y
    }

    $cap = [WxNative]::Capture($win.Handle)
    if (-not $cap.Image -or $cap.Blank) {
        if ($cap.Image) { $cap.Image.Dispose() }
        Write-Host '微信窗口截图失败（窗口可能被最小化/关到托盘）。请把微信主窗口打开后重试。' -ForegroundColor Yellow
        return $null
    }
    try {
        $dpi = [WxNative]::GetScale($win.Handle)
        try { [WxNative]::SavePng($cap.Image, (Join-Path $script:DataDir '校准用截图.png')) } catch { }
        $localX = $screenX - $cap.X
        $localY = $screenY - $cap.Y
        Write-Host ("点击位置（相对微信窗口）: {0},{1}  窗口 {2}x{3}  缩放 {4:0.##}x" -f $localX, $localY, $cap.W, $cap.H, $dpi)
        if ($localX -lt 0 -or $localY -lt 0 -or $localX -gt $cap.W -or $localY -gt $cap.H) {
            Write-Host '点击的位置不在微信窗口内，请重新校准。' -ForegroundColor Yellow
            return $null
        }
        # 在点击行的高度上，往左侧找头像
        $searchX = [int](30 * $dpi)
        $searchW = [int](120 * $dpi)
        $searchY = [int][Math]::Max(0, $localY - 34 * $dpi)
        $searchH = [int][Math]::Min($cap.H - $searchY, 68 * $dpi)
        $box = [WxNative]::FindAvatarBox($cap.Image, $searchX, $searchY, $searchW, $searchH)
        if (-not $box) {
            Write-Host '没有在点击位置附近找到头像，请点在那一行的中间位置重试。' -ForegroundColor Yellow
            return $null
        }
        Write-Host ("找到头像区域: {0}x{1} @ {2},{3}" -f $box.W, $box.H, $box.X, $box.Y)
        $tpl = [WxNative]::Crop($cap.Image, $box.X, $box.Y, $box.W, $box.H)

        # 顺手猜一下这一行的名字（只用于界面上预填，猜错可以改）
        $nameGuess = ''
        try {
            $nx = [int](118 * $dpi)
            $nw = [int]((390 - 118) * $dpi)
            $ny = [int][Math]::Max(0, $localY - 30 * $dpi)
            $nh = [int][Math]::Min($cap.H - $ny, 58 * $dpi)
            if ($nw -gt 20 -and $nh -gt 10) {
                $nameBmp = [WxNative]::Crop($cap.Image, $nx, $ny, $nw, $nh)
                if ($nameBmp) {
                    try {
                        $guessLines = @()
                        foreach ($sc in @($script:Cfg['ocrScales'])) {
                            $s = Get-EffectiveScale $nameBmp ([double]$sc)
                            $pass = Invoke-OcrOnBitmap $nameBmp $s $script:OcrTmpFile
                            if ($pass) { $guessLines += $pass }
                        }
                        if ($guessLines.Count) {
                            $first = $guessLines | Sort-Object Y | Select-Object -First 1
                            $nameGuess = ($first.Text -replace '\s', '')
                        }
                    } finally { $nameBmp.Dispose() }
                }
            }
        } catch { }
        Write-Host ("这一行识别到的文字（仅供参考）: '{0}'" -f $nameGuess)
        return [pscustomobject]@{ Bitmap = $tpl; Dpi = $dpi; Box = $box; NameGuess = $nameGuess }
    } finally { $cap.Image.Dispose() }
}

# ==================================================================
# 界面：选择提醒联系人
# ==================================================================
$script:ManagerForm = $null
$script:ManagerNames = New-Object System.Collections.ArrayList
$script:ManagerImages = $null

function Show-NamePrompt([string]$title, [string]$defaultValue) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title
    $f.ClientSize = New-Object System.Drawing.Size 380, 130
    $f.FormBorderStyle = 'FixedDialog'
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = '联系人名字（和微信里显示的备注名一致）：'
    $lbl.SetBounds(14, 12, 350, 20)
    $f.Controls.Add($lbl)

    $tb = New-Object System.Windows.Forms.TextBox
    $tb.SetBounds(14, 36, 350, 26)
    $tb.Text = $defaultValue
    $f.Controls.Add($tb)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'
    $ok.SetBounds(190, 78, 80, 30)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.Controls.Add($ok)
    $f.AcceptButton = $ok

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'
    $cancel.SetBounds(284, 78, 80, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.Add($cancel)
    $f.CancelButton = $cancel

    $f.Add_Shown({ $tb.Focus(); $tb.SelectAll() })
    $result = $f.ShowDialog()
    $value = $tb.Text
    $f.Dispose()
    if ($result -eq [System.Windows.Forms.DialogResult]::OK -and $value.Trim()) { return $value.Trim() }
    return $null
}

function New-PlaceholderThumb([string]$name, [int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::White)
    $seed = 0
    foreach ($ch in $name.ToCharArray()) { $seed = ($seed + [int]$ch) % 200 }
    $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, (90 + $seed), (120 + ($seed % 90)), (170 - ($seed % 70))))
    $g.FillEllipse($brush, 0, 0, ($size - 1), ($size - 1))
    $brush.Dispose()
    $text = ''
    if ($name.Length -gt 0) { $text = $name.Substring(0, 1) }
    $font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei', ($size * 0.42), ([System.Drawing.FontStyle]::Bold)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'
    $sf.LineAlignment = 'Center'
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, $size, $size), $sf)
    $g.Dispose()
    return $bmp
}

function Get-AvatarTemplate([string]$name) {
    foreach ($t in $script:AvatarTemplates) { if ($t.name -eq $name) { return $t } }
    return $null
}

function Get-ContactNameSuggestions {
    $result = New-Object System.Collections.ArrayList
    foreach ($c in $script:Contacts) { if (-not $result.Contains($c.name)) { [void]$result.Add($c.name) } }

    $win = $null
    if ($ForceMainWindowHwnd -gt 0) {
        $win = [WxNative]::EnumTopLevel() | Where-Object { $_.Handle -eq [IntPtr]$ForceMainWindowHwnd } | Select-Object -First 1
    }
    if (-not $win) {
        Update-WeChatPids
        $win = Select-MainWindow (Get-WeChatWindows) @()
    }
    if (-not $win) { return $result.ToArray() }

    $cap = [WxNative]::Capture($win.Handle)
    if (-not $cap.Image -or $cap.Blank) { if ($cap.Image) { $cap.Image.Dispose() }; return $result.ToArray() }
    try {
        $dpi = [WxNative]::GetScale($win.Handle)
        $left = [int]([double]$script:Cfg['stripLeftDip'] * $dpi)
        $right = [int][Math]::Min(([double]$script:Cfg['stripRightDip'] * $dpi), $cap.Image.Width * [double]$script:Cfg['stripRightRatio'])
        $top = [int]([double]$script:Cfg['topOffsetDip'] * $dpi)
        $strip = [WxNative]::Crop($cap.Image, $left, $top, ($right - $left), ($cap.Image.Height - $top))
        if ($strip) {
            try {
                $lines = @()
                foreach ($sc in @($script:Cfg['ocrScales'])) {
                    $s = Get-EffectiveScale $strip ([double]$sc)
                    $pass = Invoke-OcrOnBitmap $strip $s $script:OcrTmpFile
                    if ($pass) { $lines += $pass }
                }
                $minX = [double]$script:Cfg['nameAreaLeftDip'] * $dpi
                foreach ($line in ($lines | Sort-Object Y)) {
                    if ($line.X -lt $minX) { continue }
                    if ($line.X -gt (300 * $dpi)) { continue }
                    $text = ($line.Text -replace '\s', '')
                    if ($text.Length -lt 2) { continue }
                    if (-not $result.Contains($text)) { [void]$result.Add($text) }
                }
            } finally { $strip.Dispose() }
        }
    } finally { $cap.Image.Dispose() }
    return $result.ToArray()
}

function Show-ContactManager {
    param([switch]$RunLoop)
    if ($script:ManagerForm -and -not $script:ManagerForm.IsDisposed) {
        $script:ManagerForm.Activate()
        return
    }

    $script:ManagerNames = New-Object System.Collections.ArrayList
    foreach ($c in $script:Contacts) { [void]$script:ManagerNames.Add($c.name) }
    $script:ManagerImages = New-Object System.Windows.Forms.ImageList
    $script:ManagerImages.ImageSize = New-Object System.Drawing.Size 32, 32
    $script:ManagerImages.ColorDepth = [System.Windows.Forms.ColorDepth]::Depth32Bit

    $form = New-Object System.Windows.Forms.Form
    $form.Text = '微信特别提醒 - 选择提醒联系人'
    $form.ClientSize = New-Object System.Drawing.Size 664, 548
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.TopMost = $true
    $form.Font = New-Object System.Drawing.Font -ArgumentList 'Microsoft YaHei', 9

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = '要特别提醒的联系人（微信里显示的备注名）：'
    $lblTitle.SetBounds(12, 10, 500, 20)
    $form.Controls.Add($lblTitle)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.SetBounds(12, 34, 640, 186)
    $lv.View = 'Details'
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $false
    $lv.HideSelection = $false
    $lv.SmallImageList = $script:ManagerImages
    [void]$lv.Columns.Add('联系人', 200)
    [void]$lv.Columns.Add('头像', 90)
    [void]$lv.Columns.Add('说明', 330)
    $form.Controls.Add($lv)

    $lblManual = New-Object System.Windows.Forms.Label
    $lblManual.Text = '手动添加：'
    $lblManual.SetBounds(12, 232, 80, 22)
    $form.Controls.Add($lblManual)

    $txtName = New-Object System.Windows.Forms.TextBox
    $txtName.SetBounds(96, 229, 196, 26)
    $form.Controls.Add($txtName)

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = '添加'
    $btnAdd.SetBounds(300, 228, 70, 28)
    $form.Controls.Add($btnAdd)

    $btnDel = New-Object System.Windows.Forms.Button
    $btnDel.Text = '删除选中'
    $btnDel.SetBounds(378, 228, 100, 28)
    $form.Controls.Add($btnDel)

    $btnCalib = New-Object System.Windows.Forms.Button
    $btnCalib.Text = '校准所选头像'
    $btnCalib.SetBounds(486, 228, 166, 28)
    $form.Controls.Add($btnCalib)

    $btnPick = New-Object System.Windows.Forms.Button
    $btnPick.Text = '从微信会话列表中选取…'
    $btnPick.SetBounds(12, 264, 210, 32)
    $form.Controls.Add($btnPick)

    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Text = '扫描会话列表'
    $btnScan.SetBounds(230, 264, 140, 32)
    $form.Controls.Add($btnScan)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.SetBounds(380, 264, 272, 32)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblStatus)

    $lblScanned = New-Object System.Windows.Forms.Label
    $lblScanned.Text = '会话列表里识别到的文字（选中后点右侧按钮添加）：'
    $lblScanned.SetBounds(12, 306, 500, 20)
    $form.Controls.Add($lblScanned)

    $lb = New-Object System.Windows.Forms.ListBox
    $lb.SetBounds(12, 328, 500, 146)
    $form.Controls.Add($lb)

    $btnAddScanned = New-Object System.Windows.Forms.Button
    $btnAddScanned.Text = '添加为联系人'
    $btnAddScanned.SetBounds(520, 328, 132, 30)
    $form.Controls.Add($btnAddScanned)

    $lblHint = New-Object System.Windows.Forms.Label
    $lblHint.Text = '提示：微信里"两个字"的短名字识别率不高，建议用「校准所选头像」，之后靠头像识别最稳。'
    $lblHint.SetBounds(520, 364, 132, 110)
    $lblHint.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($lblHint)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = '保存并关闭'
    $btnSave.SetBounds(526, 490, 126, 34)
    $form.Controls.Add($btnSave)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.SetBounds(396, 490, 120, 34)
    $form.Controls.Add($btnCancel)

    $script:RefreshManager = {
        $script:ManagerImages.Images.Clear()
        $lv.Items.Clear()
        foreach ($name in $script:ManagerNames) {
            $tpl = Get-AvatarTemplate $name
            $index = $script:ManagerImages.Images.Count
            if ($tpl) {
                $factor = 32.0 / [double][Math]::Max($tpl.bitmap.Width, $tpl.bitmap.Height)
                $thumb = [WxNative]::Scale($tpl.bitmap, $factor)
                $canvas = New-Object System.Drawing.Bitmap 32, 32
                $g2 = [System.Drawing.Graphics]::FromImage($canvas)
                $g2.Clear([System.Drawing.Color]::White)
                $g2.DrawImage($thumb, [int]((32 - $thumb.Width) / 2), [int]((32 - $thumb.Height) / 2))
                $g2.Dispose()
                $thumb.Dispose()
                [void]$script:ManagerImages.Images.Add($canvas)
            } else {
                [void]$script:ManagerImages.Images.Add((New-PlaceholderThumb $name 32))
            }
            $state = '未校准（建议校准，识别更准）'
            if ($tpl) { $state = '已校准头像' }
            $item = New-Object System.Windows.Forms.ListViewItem $name
            $item.ImageIndex = $index
            [void]$item.SubItems.Add($(if ($tpl) { '已保存' } else { '—' }))
            [void]$item.SubItems.Add($state)
            [void]$lv.Items.Add($item)
        }
    }

    $btnAdd.Add_Click({
            try {
                $n = $txtName.Text.Trim()
                if (-not $n) { $lblStatus.Text = '请先输入联系人名字'; return }
                if (-not $script:ManagerNames.Contains($n)) { [void]$script:ManagerNames.Add($n) }
                $txtName.Text = ''
                $lblStatus.Text = "已添加 $n（记得点「保存并关闭」）"
                & $script:RefreshManager
            } catch { $lblStatus.Text = "出错: $($_.Exception.Message)" }
        })

    $btnDel.Add_Click({
            try {
                if ($lv.SelectedItems.Count -eq 0) { $lblStatus.Text = '请先在上面的列表里选一个'; return }
                $n = $lv.SelectedItems[0].Text
                [void]$script:ManagerNames.Remove($n)
                $lblStatus.Text = "已移除 $n（记得点「保存并关闭」）"
                & $script:RefreshManager
            } catch { $lblStatus.Text = "出错: $($_.Exception.Message)" }
        })

    $btnPick.Add_Click({
            try {
                $lblStatus.Text = '请点击微信会话列表里的那一行…'
                [System.Windows.Forms.Application]::DoEvents()
                $res = Invoke-AvatarCalibration
                if (-not $res) { $lblStatus.Text = '没有选取到，可以重试'; return }
                $guess = ''
                if ($res.NameGuess) { $guess = $res.NameGuess }
                $name = Show-NamePrompt '确认联系人名字' $guess
                if (-not $name) { $res.Bitmap.Dispose(); $lblStatus.Text = '已取消'; return }
                if (-not $script:ManagerNames.Contains($name)) { [void]$script:ManagerNames.Add($name) }
                $null = Save-AvatarTemplate $name $res.Bitmap $res.Dpi
                $res.Bitmap.Dispose()
                Load-AvatarTemplates
                $lblStatus.Text = "已添加 $name 并保存头像"
                & $script:RefreshManager
            } catch { $lblStatus.Text = "出错: $($_.Exception.Message)" }
        })

    $btnCalib.Add_Click({
            try {
                if ($lv.SelectedItems.Count -eq 0) { $lblStatus.Text = '请先在上面的列表里选一个联系人'; return }
                $n = $lv.SelectedItems[0].Text
                $lblStatus.Text = "请点击微信里【$n】所在的那一行…"
                [System.Windows.Forms.Application]::DoEvents()
                $res = Invoke-AvatarCalibration
                if (-not $res) { $lblStatus.Text = '没有选取到，可以重试'; return }
                $null = Save-AvatarTemplate $n $res.Bitmap $res.Dpi
                $res.Bitmap.Dispose()
                Load-AvatarTemplates
                $lblStatus.Text = "【$n】的头像已保存"
                & $script:RefreshManager
            } catch { $lblStatus.Text = "出错: $($_.Exception.Message)" }
        })

    $btnScan.Add_Click({
            try {
                $lblStatus.Text = '正在识别会话列表…'
                [System.Windows.Forms.Application]::DoEvents()
                $names = @(Get-ContactNameSuggestions)
                $lb.Items.Clear()
                foreach ($n in $names) { [void]$lb.Items.Add($n) }
                $lblStatus.Text = ("识别到 {0} 条文字，选中后点右边按钮添加" -f $names.Count)
            } catch { $lblStatus.Text = "出错: $($_.Exception.Message)" }
        })

    $btnAddScanned.Add_Click({
            try {
                if ($null -eq $lb.SelectedItem) { $lblStatus.Text = '请先在下面选一条文字'; return }
                $n = [string]$lb.SelectedItem
                if (-not $script:ManagerNames.Contains($n)) { [void]$script:ManagerNames.Add($n) }
                $lblStatus.Text = "已添加 $n（记得点「保存并关闭」）"
                & $script:RefreshManager
            } catch { $lblStatus.Text = "出错: $($_.Exception.Message)" }
        })

    $btnSave.Add_Click({
            try {
                Save-ContactConfig @($script:ManagerNames)
                Load-AppConfig
                Reset-ContactState
                $names = (@($script:Contacts | ForEach-Object { $_.name }) -join '、')
                if (-not $names) { $names = '(空)' }
                [System.Windows.Forms.MessageBox]::Show("已保存。当前监听的联系人：$names", '微信特别提醒', 'OK', 'Information') | Out-Null
                $form.Close()
            } catch { $lblStatus.Text = "保存失败: $($_.Exception.Message)" }
        })

    $btnCancel.Add_Click({ $form.Close() })
    $form.Add_FormClosed({ $script:ManagerForm = $null })

    & $script:RefreshManager
    $script:ManagerForm = $form
    if ($RunLoop) {
        [System.Windows.Forms.Application]::Run($form)
    } else {
        $form.Show()
        $form.Activate()
    }
}

function Reset-ContactState {
    $script:ContactState = @{}
    foreach ($c in $script:Contacts) {
        $script:ContactState[$c.name] = @{ Unread = $false; Missing = 0; LastAlert = [datetime]::MinValue }
    }
}

function Test-Cooldown($contact) {
    $state = $script:ContactState[$contact.name]
    if (-not $state) { return $true }
    $cd = [int]$script:Cfg['cooldownSeconds']
    if ($cd -le 0) { return $true }
    return ((Get-Date) - $state.LastAlert).TotalSeconds -ge $cd
}

function Invoke-DetectionTick {
    if (-not $script:Contacts.Count) { return }
    $dpiScale = 1.0
    $wins = Get-WeChatWindows
    $main = $null
    if ($ForceMainWindowHwnd -gt 0) {
        $main = [WxNative]::EnumTopLevel() | Where-Object { $_.Handle -eq [IntPtr]$ForceMainWindowHwnd } | Select-Object -First 1
        if (-not $main) {
            $winsAll = [WxNative]::EnumTopLevel()
            $main = $winsAll | Where-Object { $_.Handle -eq [IntPtr]$ForceMainWindowHwnd } | Select-Object -First 1
        }
    } else {
        $main = Select-MainWindow $wins @($script:PopupSeen.Values)
    }

    if (-not $main) {
        $script:NoMainWindowTicks++
        if ($script:NoMainWindowTicks -eq 1 -or ($script:NoMainWindowTicks % 30) -eq 0) {
            Write-Log '没有找到微信主窗口（可能未登录、已退出或窗口被隐藏）。' 'WARN'
        }
    } else {
        $script:NoMainWindowTicks = 0
        $script:MainWindowHandle = $main.Handle
        if (-not $main.Visible) {
            if (($script:HiddenWarnTick++ % 60) -eq 0) { Write-Log '微信主窗口不可见（关到托盘了）。会话列表检测需要窗口处于打开状态。' 'WARN' }
        } elseif ($main.Minimized) {
            if (($script:HiddenWarnTick++ % 60) -eq 0) { Write-Log '微信主窗口被最小化了，识别可能失败（建议保持窗口打开，放在其它窗口后面即可）。' 'WARN' }
        }

        $dpiScale = [WxNative]::GetScale($main.Handle)
        $cap = [WxNative]::Capture($main.Handle)
        if ($cap.Image) {
            try {
                if ($cap.Blank) {
                    if (($script:BlankWarnTick++ % 30) -eq 0) {
                        Write-Log '截图内容是空白的。常见原因：微信被最小化/关到托盘，或微信以管理员身份运行（请同样以管理员身份运行本程序）。' 'WARN'
                    }
                } else {
                    Invoke-SessionListScan $cap.Image $dpiScale $main
                }
            } finally { if ($cap.Image) { $cap.Image.Dispose() } }
        }
    }

    if ($script:Cfg['watchPopupWindow']) { Invoke-PopupScan $wins }
}

function Invoke-SessionListScan([System.Drawing.Bitmap]$windowBitmap, [double]$dpi, $main) {
    $left = [int]([double]$script:Cfg['stripLeftDip'] * $dpi)
    $rightDip = [double]$script:Cfg['stripRightDip'] * $dpi
    $ratioRight = $windowBitmap.Width * [double]$script:Cfg['stripRightRatio']
    $right = [int][Math]::Min($rightDip, $ratioRight)
    $top = [int]([double]$script:Cfg['topOffsetDip'] * $dpi)
    $w = $right - $left
    $h = $windowBitmap.Height - $top
    if ($w -lt 60 -or $h -lt 60) { return }

    $strip = [WxNative]::Crop($windowBitmap, $left, $top, $w, $h)
    if (-not $strip) { return }
    try {
        # 第一步：找出所有红色未读角标（没有角标时几乎不耗 CPU，也不用做 OCR）
        $maxW = [int]([double]$script:Cfg['badgeMaxWidthDip'] * $dpi)
        $maxH = [int]([double]$script:Cfg['badgeMaxHeightDip'] * $dpi)
        $blobs = [WxNative]::FindRedBlobs($strip, 0, 0, $strip.Width, $strip.Height,
            [int]$script:Cfg['badgeMinPixels'], $maxW, $maxH)
        $badgeMinX = [double]$script:Cfg['badgeMinXDip'] * $dpi
        $blobs = @($blobs | Where-Object { $_.X -ge $badgeMinX })
        $script:LastBlobCount = $blobs.Count
        if ($Calibrate) { Write-Host ("--- 检测到 {0} 个未读角标 ---" -f $blobs.Count) }
        if (-not $blobs.Count) {
            # 没有未读角标：把状态机推进到"已读"
            foreach ($contact in $script:Contacts) {
                $state = $script:ContactState[$contact.name]
                $state.Missing++
                if ($state.Missing -ge 2 -and $state.Unread) { $state.Unread = $false }
            }
            return
        }

        # 角标位置发生变化，或距上次识别超过 reOcrSeconds，就重新做一次 OCR
        $signature = ($blobs | Sort-Object Y | ForEach-Object { "$($_.X),$($_.Y),$($_.W),$($_.H)" }) -join ';'
        $sinceOcr = 9999.0
        if ($script:LastStripOcrTime) { $sinceOcr = ((Get-Date) - $script:LastStripOcrTime).TotalSeconds }
        $needOcr = ($signature -ne $script:LastBlobSignature) -or ($sinceOcr -ge [double]$script:Cfg['reOcrSeconds'])
        if ($needOcr) {
            $script:LastBlobSignature = $signature
            $script:LastStripOcrTime = Get-Date
            # 多倍率识别，结果合并（不同倍率互补，能显著减少漏字）
            $lines = @()
            foreach ($scaleWanted in @($script:Cfg['ocrScales'])) {
                $scale = Get-EffectiveScale $strip ([double]$scaleWanted)
                if ($scale -lt 1.05) { continue }
                $pass = Invoke-OcrOnBitmap $strip $scale $script:OcrTmpFile
                if ($pass) { $lines += $pass }
                # 如果这一轮已经能找到目标联系人的名字，就不必再跑下一个倍率
                $early = $false
                foreach ($line in $pass) {
                    $norm = ConvertTo-NormalizedText $line.Text
                    if (-not $norm) { continue }
                    foreach ($contact in $script:Contacts) {
                        if ((Get-ContactScore $contact $norm) -ge [double]$script:Cfg['matchThreshold']) { $early = $true; break }
                    }
                    if ($early) { break }
                }
                if ($early) { break }
            }
            $script:CachedStripLines = $lines
            if ($Calibrate) {
                Write-Host ("--- OCR 识别到的行（{0} 倍率合并，共 {1} 行）---" -f (@($script:Cfg['ocrScales']) -join '/'), $lines.Count)
                foreach ($line in $lines) { Write-Host ('  {0,-28} x={1,4:0} y={2,4:0}' -f $line.Text, $line.X, $line.Y) }
            }
        }
        $lines = $script:CachedStripLines
        if (-not $lines) { return }

        # 第二步：把"名字行"和"角标行"按纵向位置配对
        $hits = @{}
        foreach ($blob in $blobs) {
            # 方式一：头像模板匹配（最可靠，需要先做一次校准）
            $avatarHit = Test-AvatarMatch $strip $blob $dpi
            if ($avatarHit) {
                $contact = Find-ContactByName $avatarHit.name
                if ($contact) {
                    $prev = $hits[$contact.name]
                    if (-not $prev -or $avatarHit.Score -gt $prev.Score) {
                        $hits[$contact.name] = [pscustomobject]@{
                            Score = $avatarHit.Score; Text = '(头像匹配)'; Blob = $blob; Kind = '头像'
                        }
                    }
                }
            }

            # 方式二：名字文字匹配（OCR，长一点的备注名更可靠）
            $top = $blob.Y - 6 * $dpi
            $bottom = $blob.Y + $blob.H + 6 * $dpi
            foreach ($line in $lines) {
                if ($line.X -lt [double]$script:Cfg['nameAreaLeftDip'] * $dpi) { continue }
                if ($line.X -gt ($blob.X - 20 * $dpi)) { continue }   # 排除聊天区/其它文字
                if ($line.Y -gt $bottom -or $line.Bottom -lt $top) { continue }
                $norm = ConvertTo-NormalizedText $line.Text
                if (-not $norm) { continue }
                foreach ($contact in $script:Contacts) {
                    $score = Get-ContactScore $contact $norm
                    if ($score -ge [double]$script:Cfg['matchThreshold']) {
                        $prev = $hits[$contact.name]
                        if (-not $prev -or $score -gt $prev.Score) {
                            $hits[$contact.name] = [pscustomobject]@{ Score = $score; Text = $line.Text; Blob = $blob; Kind = '名字' }
                        }
                    }
                }
            }
        }

        # 第三步：状态机（未读期间只提醒一次，读数清零后可再次提醒）
        foreach ($contact in $script:Contacts) {
            $state = $script:ContactState[$contact.name]
            $hit = $hits[$contact.name]
            if ($hit) {
                $state.Missing = 0
                if (-not $state.Unread) {
                    $state.Unread = $true
                    if (Test-Cooldown $contact) {
                        $state.LastAlert = Get-Date
                        $detail = "$($hit.Kind)匹配 $($hit.Score.ToString('0.00'))，未读角标 $($hit.Blob.ToString())，该行文字 '$($hit.Text)'"
                        Invoke-Alert @($contact) $detail '会话列表'
                    } else {
                        Write-Log "跳过提醒（冷却中）: $($contact.name)" 'INFO'
                    }
                }
            } else {
                $state.Missing++
                if ($state.Missing -ge 2 -and $state.Unread) { $state.Unread = $false }
            }
        }
    } finally { $strip.Dispose() }
}

$script:PopupSeen = @{}
$script:PopupBaselineDone = $false
$script:NoMainWindowTicks = 0
$script:HiddenWarnTick = 0
$script:BlankWarnTick = 0
$script:PrevCrop = $null
$script:LastOcrTime = $null
$script:LastBlobCount = 0
$script:LastBlobSignature = ''
$script:LastStripOcrTime = $null
$script:CachedStripLines = @()

function Invoke-PopupScan($wins) {
    $excludeClasses = @('#32768', 'tooltips_class32', 'SysShadow', 'TaskListThumbnailWnd',
        'ConsoleWindowClass', 'IME', 'MSCTFIME UI', 'GDI+ Hook Window Class',
        'Shell_TrayWnd', 'Progman', 'WorkerW', 'Static', 'Button')
    $excludePrefixes = @('.NET-BroadcastEventWindow')
    $minW = [int]$script:Cfg['popupMinWidth']; $maxW = [int]$script:Cfg['popupMaxWidth']
    $minH = [int]$script:Cfg['popupMinHeight']; $maxH = [int]$script:Cfg['popupMaxHeight']
    if ($Trace) { Write-Host ("    [弹窗扫描] 传入窗口数 {0}" -f @($wins).Count) }

    if ($Trace) {
        foreach ($tw in @($wins)) {
            Write-Host ("      - {0}" -f $tw.ToString())
        }
    }

    $current = @{}
    foreach ($w in $wins) {
        if (-not $w.Visible) { continue }
        if ($w.Class -in $excludeClasses) { continue }
        $skip = $false
        foreach ($prefix in $excludePrefixes) { if ($w.Class.StartsWith($prefix)) { $skip = $true; break } }
        if ($skip) { continue }
        if ($w.Minimized) { continue }
        if ([uint32]$w.Pid -eq [uint32]$PID) { continue }   # 排除本程序自己的窗口
        if ($w.W -lt $minW -or $w.W -gt $maxW -or $w.H -lt $minH -or $w.H -gt $maxH) { continue }
        if ($script:MainWindowHandle -ne [IntPtr]::Zero -and $w.Handle -eq $script:MainWindowHandle) { continue }
        $current["$($w.Handle)"] = $w
        if ($Trace) { Write-Host ("    [弹窗候选] " + $w.ToString()) }
    }

    if (-not $script:PopupBaselineDone) {
        $script:PopupSeen = $current
        $script:PopupBaselineDone = $true
        return
    }

    foreach ($key in $current.Keys) {
        if ($script:PopupSeen.ContainsKey($key)) { continue }
        $w = $current[$key]
        $script:PopupSeen[$key] = $w
        if ($Trace) { Write-Host ("    [新弹窗] " + $w.ToString()) }
        try {
            $cap = [WxNative]::Capture($w.Handle)
            if (-not $cap.Image -or $cap.Blank) { if ($cap.Image) { $cap.Image.Dispose() }; continue }
            try {
                $scale = Get-EffectiveScale $cap.Image ([double](@($script:Cfg['ocrScales'])[0]))
                $lines = Invoke-OcrOnBitmap $cap.Image $scale $script:OcrTmpFile
                $matched = @()
                $texts = @()
                $headerHeight = $cap.Image.Height * 0.5
                $headerRight = $cap.Image.Width * 0.9
                foreach ($line in $lines) {
                    $norm = ConvertTo-NormalizedText $line.Text
                    if ($norm) { $texts += $line.Text }
                    # 只在弹窗的"表头区域"里找发件人名字，避免消息正文里出现同名造成误报
                    if ($line.Y -gt $headerHeight -or $line.X -gt $headerRight) { continue }
                    foreach ($contact in $script:Contacts) {
                        if ($matched -contains $contact) { continue }
                        if ((Get-ContactScoreLoose $contact $norm) -ge [double]$script:Cfg['matchThreshold']) { $matched += $contact }
                    }
                }
                $dpiNow = [WxNative]::GetScale($w.Handle)
                if ($matched.Count -gt 0) {
                    $preview = ($texts -join ' ').Trim()
                    if ($preview.Length -gt 90) { $preview = $preview.Substring(0, 90) + '…' }
                    Invoke-Alert $matched $preview '新消息弹窗'
                    continue
                }
                # 名字文字没认出来时，改用头像比对（弹窗左上角就是发件人头像）
                if ($script:AvatarTemplates.Count) {
                    $box = [WxNative]::FindAvatarBox($cap.Image, 0, 0, [int](140 * $dpiNow), $cap.Image.Height)
                    if ($box) {
                        foreach ($tpl in $script:AvatarTemplates) {
                            $contact = Find-ContactByName $tpl.name
                            if (-not $contact) { continue }
                            $score = [WxNative]::CompareScaled($cap.Image, $tpl.bitmap, $box.X, $box.Y, $box.W, $box.H)
                            if ($Calibrate -or $Diagnose) { Write-Host ("    弹窗头像比对【{0}】score={1:0.000}" -f $tpl.name, $score) }
                            if ($score -ge [double]$script:Cfg['avatarMatchThreshold']) {
                                Invoke-Alert @($contact) ("弹窗头像比对 " + $score.ToString('0.00')) '新消息弹窗'
                                break
                            }
                        }
                    }
                }
            } finally { $cap.Image.Dispose() }
        } catch { Write-Log "处理弹窗失败: $($_.Exception.Message)" 'WARN' }
    }

    # 清理已经消失的窗口记录
    foreach ($key in @($script:PopupSeen.Keys)) {
        if (-not $current.ContainsKey($key)) { $script:PopupSeen.Remove($key) }
    }
}

# ==================================================================
# 诊断 / 校准
# ==================================================================
function Invoke-Diagnostics {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $dir = Join-Path $script:DataDir "诊断_$stamp"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    Write-Host ''
    Write-Host '================ 微信特别提醒 · 诊断 ================'
    Write-Host ("时间        : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Write-Host ("系统        : {0}" -f ([System.Environment]::OSVersion.VersionString))
    Write-Host ("PowerShell  : {0}" -f $PSVersionTable.PSVersion)
    Write-Host ("配置文件    : {0} ({1})" -f $ConfigFile, $(if (Test-Path -LiteralPath $ConfigFile) { '存在' } else { '不存在，使用默认值' }))

    $langs = ([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages | ForEach-Object { $_.LanguageTag }) -join ', '
    Write-Host ("OCR 语言包  : {0}" -f $langs)
    if (-not $script:OcrEngine) {
        Write-Host 'OCR 引擎     : 初始化失败！'
    } else {
        Write-Host ("OCR 引擎    : {0}" -f $script:OcrEngine.RecognizerLanguage.DisplayName)
    }

    Write-Host ("提醒联系人  : {0}" -f (($script:Contacts | ForEach-Object { $_.name }) -join '、'))
    if ($script:AvatarTemplates.Count) {
        Write-Host ("头像模板    : {0}" -f (($script:AvatarTemplates | ForEach-Object { $_.name }) -join '、'))
    } else {
        Write-Host '头像模板    : 无（建议先运行"校准联系人头像.bat"，识别会更可靠）'
    }
    Write-Host ''

    Update-WeChatPids
    Write-Host '--- 微信进程 ---'
    if (-not $script:WeChatPids.Count) {
        Write-Host '未发现微信进程（进程名: ' + ($script:Cfg['processNames'] -join ', ') + '）'
    } else {
        foreach ($procId in $script:WeChatPids) {
            $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
            if ($p) { Write-Host ("  pid={0,-7} {1}" -f $p.Id, $p.ProcessName) }
        }
    }
    Write-Host ''

    $all = [WxNative]::EnumTopLevel()
    Write-Host '--- 微信相关窗口 ---'
    $wxWins = @($all | Where-Object { $script:WeChatPids -contains $_.Pid })
    if (-not $wxWins) { Write-Host '  没有找到微信窗口。' }
    foreach ($w in ($wxWins | Sort-Object -Property @{ Expression = { $_.W * $_.H } } -Descending)) {
        Write-Host ("  {0}" -f $w.ToString())
    }
    Write-Host ''

    $main = $null
    if ($ForceMainWindowHwnd -gt 0) {
        $main = $all | Where-Object { $_.Handle -eq [IntPtr]$ForceMainWindowHwnd } | Select-Object -First 1
    } else {
        $main = Select-MainWindow $wxWins @()
    }
    if (-not $main) {
        Write-Host '未找到微信主窗口，无法生成截图。请先登录微信并保持窗口打开后重试。'
        Write-Host ''
        Write-Host ("诊断文件目录: {0}" -f $dir)
        return
    }

    $dpi = [WxNative]::GetScale($main.Handle)
    Write-Host '--- 主窗口 ---'
    Write-Host ("  {0}" -f $main.ToString())
    Write-Host ("  屏幕缩放    : {0:0.##}x (DPI {1})" -f $dpi, ($dpi * 96))

    $cap = [WxNative]::Capture($main.Handle)
    if (-not $cap.Image) {
        Write-Host '截图失败。'
        Write-Host ("诊断文件目录: {0}" -f $dir)
        return
    }
    $capPath = Join-Path $dir 'capture.png'
    [WxNative]::SavePng($cap.Image, $capPath)
    Write-Host ("  截图        : {0}x{1}，空白={2}" -f $cap.W, $cap.H, $cap.Blank)

    if ($cap.Blank) {
        Write-Host '  截图是空白的：微信可能被最小化/关到托盘，或以管理员权限运行（本程序也需要管理员权限）。'
        $cap.Image.Dispose()
        Write-Host ''
        Write-Host ("诊断文件目录: {0}" -f $dir)
        return
    }

    $left = [int]([double]$script:Cfg['stripLeftDip'] * $dpi)
    $right = [int][Math]::Min(([double]$script:Cfg['stripRightDip'] * $dpi), $cap.Image.Width * [double]$script:Cfg['stripRightRatio'])
    $top = [int]([double]$script:Cfg['topOffsetDip'] * $dpi)
    Write-Host ("  会话列表区域: x={0}..{1}, y={2}..{3}" -f $left, $right, $top, $cap.H)

    $crop = [WxNative]::Crop($cap.Image, $left, $top, ($right - $left), ($cap.H - $top))
    if ($crop) {
        [WxNative]::SavePng($crop, (Join-Path $dir 'session_list.png'))

        # 第一步：红色角标检测
        $maxW = [int]([double]$script:Cfg['badgeMaxWidthDip'] * $dpi)
        $maxH = [int]([double]$script:Cfg['badgeMaxHeightDip'] * $dpi)
        $blobs = [WxNative]::FindRedBlobs($crop, 0, 0, $crop.Width, $crop.Height,
            [int]$script:Cfg['badgeMinPixels'], $maxW, $maxH)
        $badgeMinX = [double]$script:Cfg['badgeMinXDip'] * $dpi
        $kept = @($blobs | Where-Object { $_.X -ge $badgeMinX })

        Write-Host ("  红色角标    : 找到 {0} 个（过滤掉左侧头像区域后剩 {1} 个）" -f $blobs.Count, $kept.Count)

        # 标注图：画出裁剪区域和识别到的角标
        try {
            $annotated = [WxNative]::Crop($cap.Image, 0, 0, $cap.Image.Width, $cap.Image.Height)
            $g = [System.Drawing.Graphics]::FromImage($annotated)
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0, 160, 255)), 3
            $g.DrawRectangle($pen, $left, $top, ($right - $left), ($cap.H - $top))
            $pen.Dispose()
            $pen2 = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0, 200, 0)), 2
            foreach ($b in $kept) {
                $g.DrawRectangle($pen2, ($left + $b.X - 3), ($top + $b.Y - 3), ($b.W + 6), ($b.H + 6))
            }
            $pen2.Dispose(); $g.Dispose()
            [WxNative]::SavePng($annotated, (Join-Path $dir 'annotated.png'))
            $annotated.Dispose()
        } catch { }

        # 第二步：多倍率 OCR（和实际运行时的判断逻辑一致）
        $threshold = [double]$script:Cfg['matchThreshold']
        $allLines = @()
        foreach ($scaleWanted in @($script:Cfg['ocrScales'])) {
            $scale = Get-EffectiveScale $crop ([double]$scaleWanted)
            if ($scale -lt 1.05) { continue }
            Write-Host ("  识别倍率 {0:0.00}x → 输入图 {1}x{2}" -f $scale, [int]($crop.Width * $scale), [int]($crop.Height * $scale))
            $pass = Invoke-OcrOnBitmap $crop $scale $script:OcrTmpFile
            if ($pass) { $allLines += $pass }
        }
        Write-Host ''
        Write-Host ("--- OCR 识别结果（{0} 倍率合并，共 {1} 行）---" -f (@($script:Cfg['ocrScales']) -join '/'), $allLines.Count)
        foreach ($line in $allLines) {
            Write-Host ('  {0,-28} x={1,4:0} y={2,4:0} 下={3:0}' -f $line.Text, $line.X, $line.Y, $line.Bottom)
        }

        Write-Host ''
        Write-Host '--- 未读角标 → 名字 的配对结果 ---'
        if (-not $kept) {
            Write-Host '  当前会话列表里没有红色未读角标（说明：没有未读消息，或微信窗口不在会话列表页）。'
        }
        $idx = 0
        foreach ($blob in $kept) {
            $idx++
            Write-Host ("  #{0} 角标 {1}" -f $idx, $blob.ToString())
            if ($script:AvatarTemplates.Count) {
                $avatarHit = Test-AvatarMatch $crop $blob $dpi
                if ($avatarHit) {
                    Write-Host ("     → 头像匹配成功：【{0}】相似度 {1:0.00}" -f $avatarHit.name, $avatarHit.Score) -ForegroundColor Green
                } else {
                    Write-Host '     → 头像匹配：未匹配到任何已校准的联系人'
                }
            }
            $bandTop = $blob.Y - 6 * $dpi
            $bandBottom = $blob.Y + $blob.H + 6 * $dpi
            $found = $false
            foreach ($line in $allLines) {
                if ($line.X -lt [double]$script:Cfg['nameAreaLeftDip'] * $dpi) { continue }
                if ($line.X -gt ($blob.X - 20 * $dpi)) { continue }
                if ($line.Y -gt $bandBottom -or $line.Bottom -lt $bandTop) { continue }
                $found = $true
                $bestScore = 0.0; $bestName = ''
                foreach ($contact in $script:Contacts) {
                    $s = Get-ContactScore $contact (ConvertTo-NormalizedText $line.Text)
                    if ($s -gt $bestScore) { $bestScore = $s; $bestName = $contact.name }
                }
                $mark = ''
                if ($bestScore -ge $threshold) { $mark = "  → 匹配【$bestName】" }
                Write-Host ("     同行文本='{0}' 相似度={1:0.00}{2}" -f $line.Text, $bestScore, $mark)
            }
            if (-not $found) { Write-Host '     未能把识别到的文字和这个角标对应上（该行名字可能没被识别出来）' }
        }
        $crop.Dispose()
    }

    Write-Host ''
    Write-Host ("诊断文件目录: {0}" -f $dir)
    Write-Host '（capture.png = 截到的微信窗口；session_list.png = 用于识别的区域；annotated.png = 识别区域标注）'
    $cap.Image.Dispose()
}

# ==================================================================
# 主流程
# ==================================================================
$script:OcrTmpFile = Join-Path $env:TEMP ("wechat_alert_ocr_{0}.bmp" -f $PID)
# ==================================================================
# 开机自启 / 后台运行 / 校准流程 / 监听主循环
# ==================================================================
function Find-SelfScriptPath {
    # 返回一个"可以长期使用"的脚本路径：单文件版会把内部脚本释放到数据目录
    $selfBat = $env:WXSELF
    if ($selfBat -and (Test-Path -LiteralPath $selfBat)) {
        $target = Join-Path $script:DataDir 'WeChatSpecialAlert.ps1'
        try {
            $t = [System.IO.File]::ReadAllText($selfBat, [System.Text.Encoding]::UTF8)
            $marker = '#WXPS' + 'BODY' + '#'
            $i = $t.IndexOf($marker)
            if ($i -ge 0) {
                [System.IO.File]::WriteAllText($target, $t.Substring($i + $marker.Length), (New-Object System.Text.UTF8Encoding($true)))
                return $target
            }
        } catch { }
    }
    $ps1 = Join-Path $PSScriptRoot 'WeChatSpecialAlert.ps1'
    if (Test-Path -LiteralPath $ps1) { return $ps1 }
    return ''
}

function Set-Autostart {
    param([switch]$Remove)
    $startup = [Environment]::GetFolderPath('Startup')
    $link = Join-Path $startup '微信特别提醒.lnk'
    if ($Remove) {
        if (Test-Path -LiteralPath $link) {
            Remove-Item -LiteralPath $link -Force
            Write-Host '已取消开机自启。' -ForegroundColor Green
        } else {
            Write-Host '当前没有设置开机自启。' -ForegroundColor Yellow
        }
        return
    }
    $ps1 = Find-SelfScriptPath
    if (-not $ps1) { Write-Host '找不到脚本本体，无法设置开机自启。' -ForegroundColor Yellow; return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($link)
    $shortcut.TargetPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '" -DataDir "' + $script:DataDir + '" -StartHidden'
    $shortcut.WorkingDirectory = $script:DataDir
    $shortcut.WindowStyle = 7
    $shortcut.Description = '微信特别提醒（后台运行）'
    $shortcut.Save()
    Write-Host ("已设置开机自启: {0}" -f $link) -ForegroundColor Green
}

function Test-AutostartInstalled {
    $link = Join-Path ([Environment]::GetFolderPath('Startup')) '微信特别提醒.lnk'
    return (Test-Path -LiteralPath $link)
}

function Start-BackgroundRun {
    $ps1 = Find-SelfScriptPath
    if (-not $ps1) { Write-Host '找不到脚本本体。' -ForegroundColor Yellow; return }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $ps1, '-DataDir', $script:DataDir, '-StartHidden') -WindowStyle Hidden
    Start-Sleep -Seconds 1
    Write-Host '已在后台启动（右下角托盘图标可以打开设置或退出）。' -ForegroundColor Green
}

function Invoke-TeachAvatarFlow {
    $names = @()
    if ($ContactName) { $names = @($ContactName) }
    elseif ($script:Contacts.Count) { $names = @($script:Contacts | ForEach-Object { $_.name }) }
    if (-not $names) {
        $typed = Read-Host '请输入要校准的联系人名字（和 config.json 里的 contacts 保持一致）'
        if ($typed -and $typed.Trim()) { $names = @($typed.Trim()) }
    }
    if (-not $names) { Write-Host '没有指定联系人，已退出。' -ForegroundColor Yellow; return }
    Write-Host ''
    Write-Host '================ 校准联系人头像 ================' -ForegroundColor Green
    Write-Host '用途：记住该联系人的头像，之后识别会更准（尤其是两个字的短名字）。'
    Write-Host '步骤：'
    Write-Host '  1) 先确认微信主窗口已经打开，并且会话列表里能看到这个联系人'
    Write-Host '  2) 稍后屏幕会整体变暗，这时用鼠标点击该联系人所在的那一行'
    Write-Host '  3) 点击后自动保存，按 Esc 可以取消'
    Write-Host ''
    foreach ($n in $names) {
        Write-Host ("--- 校准【{0}】---" -f $n) -ForegroundColor Cyan
        $res = Invoke-AvatarCalibration
        if (-not $res) {
            Write-Host ("【{0}】没有校准成功，可以重新运行本程序再试。" -f $n) -ForegroundColor Yellow
            continue
        }
        $file = Save-AvatarTemplate $n $res.Bitmap $res.Dpi
        $res.Bitmap.Dispose()
        Write-Host ("已保存头像模板: {0}" -f $file) -ForegroundColor Green
        if (-not (Find-ContactByName $n)) {
            Write-Host ("注意：config.json 的 contacts 里没有【{0}】，请把它加进去，否则不会提醒。" -f $n) -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host '校准结束。'
}

function Start-Watcher {
    if (-not $script:Contacts.Count) {
        Write-Host '还没有设置要特别提醒的联系人。请先在菜单里选「3. 选择要特别提醒的联系人…」。' -ForegroundColor Yellow
        return
    }
    $mutex = New-Object System.Threading.Mutex $false, 'WeChatSpecialAlert_SingleInstance'
    $hasLock = $mutex.WaitOne(0)
    if (-not $hasLock -and -not $Once -and $DurationSeconds -le 0) {
        Write-Host '已经有一个"微信特别提醒"在运行了（托盘图标里可以退出）。' -ForegroundColor Yellow
        return
    }

    if (-not $StartHidden) {
        Write-Host ''
        Write-Host '================ 微信特别提醒 已启动 ================' -ForegroundColor Green
        Write-Host ("监听联系人: {0}" -f (($script:Contacts | ForEach-Object { $_.name }) -join '、'))
        Write-Host ("检测间隔  : {0} ms" -f $script:Cfg['pollIntervalMs'])
        Write-Host ("提示音    : {0}" -f (Get-SoundFile $null))
        Write-Host ("监控进程  : {0}" -f (@($script:Cfg['processNames']) -join ', '))
        Write-Host '保持微信窗口打开（可以被其它窗口挡住，但不要最小化/关闭到托盘）效果最好。'
        Write-Host '按 Ctrl+C 结束，或右键托盘图标退出。'
        Write-Host ("配置文件: {0}" -f $ConfigFile)
        Write-Host ''
    }

    if ($Once) {
        Invoke-DetectionTick
        Write-Host '单次检测完成。'
        if ($hasLock) { try { $mutex.ReleaseMutex() } catch { } }
        return
    }

    # 托盘图标
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = [System.Drawing.SystemIcons]::Information
    $tray.Text = '微信特别提醒'
    $tray.Visible = $true
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $itemPick = $menu.Items.Add('选择提醒联系人…')
    $itemTest = $menu.Items.Add('测试提醒效果')
    $itemLog = $menu.Items.Add('打开日志')
    $itemCfg = $menu.Items.Add('打开配置文件')
    $itemExit = $menu.Items.Add('退出')
    $itemPick.Add_Click({ Show-ContactManager })
    $itemTest.Add_Click({ Test-AlertPreview 0 })
    $itemLog.Add_Click({ if ($script:LogPath -and (Test-Path -LiteralPath $script:LogPath)) { Start-Process notepad.exe $script:LogPath } })
    $itemCfg.Add_Click({ Start-Process notepad.exe $ConfigFile })
    $itemExit.Add_Click({ $tray.ContextMenuStrip = $null; $tray.Visible = $false; $script:AlertForm = $null; [System.Windows.Forms.Application]::ExitThread() })
    $tray.ContextMenuStrip = $menu
    $tray.Add_DoubleClick({ Test-AlertPreview 0 })

    # 隐藏的宿主窗口 + 定时器
    $hostForm = New-Object System.Windows.Forms.Form
    $hostForm.Text = 'WeChatSpecialAlert'
    $hostForm.ShowInTaskbar = $false
    $hostForm.WindowState = 'Minimized'
    $hostForm.Opacity = 0
    $hostForm.FormBorderStyle = 'None'
    $hostForm.ClientSize = New-Object System.Drawing.Size 1, 1

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(500, [int]$script:Cfg['pollIntervalMs'])
    $timer.Add_Tick({
            try { Invoke-DetectionTick }
            catch { Write-Log "检测出错: $($_.Exception.Message)" 'ERROR' }
        })
    $hostForm.Add_FormClosed({
            $timer.Stop()
            $tray.Visible = $false
            try { $timer.Dispose() } catch { }
        })

    if ($DurationSeconds -gt 0) {
        $stopTimer = New-Object System.Windows.Forms.Timer
        $stopTimer.Interval = $DurationSeconds * 1000
        $stopTimer.Add_Tick({
                $stopTimer.Stop()
                if (-not $StartHidden) { Write-Host '到达指定运行时长，退出。' }
                $hostForm.Close()
                [System.Windows.Forms.Application]::ExitThread()
            })
        $stopTimer.Start()
    }

    try {
        # 先做一次检测，再进入消息循环（托盘图标和弹窗都需要消息循环）
        try { Invoke-DetectionTick } catch { Write-Log "首次检测出错: $($_.Exception.Message)" 'ERROR' }
        $timer.Start()
        [System.Windows.Forms.Application]::Run($hostForm)
    } finally {
        if ($script:SoundPlayer) { try { $script:SoundPlayer.Stop() } catch { } }
        if ($tray) { $tray.Visible = $false; $tray.Dispose() }
        if ($script:OcrTmpFile -and (Test-Path -LiteralPath $script:OcrTmpFile)) { Remove-Item -LiteralPath $script:OcrTmpFile -Force -ErrorAction SilentlyContinue }
        if ($hasLock) { try { $mutex.ReleaseMutex() } catch { } }
        if (-not $StartHidden) { Write-Host '微信特别提醒已退出。' }
    }
}

function Show-MainMenu {
    $emptyCount = 0
    while ($true) {
        $names = (@($script:Contacts | ForEach-Object { $_.name }) -join '、')
        if (-not $names) { $names = '（还没设置）' }
        Write-Host ''
        Write-Host '================ 微信特别提醒 ================' -ForegroundColor Green
        Write-Host ("监听联系人: {0}" -f $names)
        Write-Host ("配置文件  : {0}" -f $ConfigFile)
        Write-Host ("开机自启  : {0}" -f $(if (Test-AutostartInstalled) { '已设置' } else { '未设置' }))
        Write-Host ''
        Write-Host '  1. 开始监听（本窗口保持打开，关掉窗口就停止监听）'
        Write-Host '  2. 后台运行（关掉本窗口也继续运行，从托盘图标退出）'
        Write-Host '  3. 选择要特别提醒的联系人…'
        Write-Host '  4. 校准某个联系人的头像…'
        Write-Host '  5. 预览提醒效果'
        Write-Host '  6. 诊断（识别不准时用，会保存截图）'
        Write-Host '  7. 设置 / 取消开机自启'
        Write-Host '  0. 退出'
        $choice = Read-Host '请输入序号'
        $text = ($choice -as [string])
        if (-not $text) { $text = '' }
        $text = $text.Trim()
        if (-not $text) {
            $emptyCount++
            if ($emptyCount -ge 3) { return }
        } else {
            $emptyCount = 0
        }
        switch ($text) {
            '1' { Start-Watcher }
            '2' { Start-BackgroundRun }
            '3' { Show-ContactManager -RunLoop; Load-AppConfig; Reset-ContactState }
            '4' { Invoke-TeachAvatarFlow; Load-AppConfig }
            '5' { Test-AlertPreview 0 }
            '6' { Invoke-Diagnostics }
            '7' {
                if (Test-AutostartInstalled) { Set-Autostart -Remove } else { Set-Autostart }
            }
            '0' { return }
            default { Write-Host '请输入 0-7 之间的数字。' -ForegroundColor Yellow }
        }
    }
}

$script:OcrEngine = $null

Load-AppConfig
Load-AvatarTemplates
$script:OcrEngine = Initialize-Ocr
Reset-ContactState

if ($Diagnose -or $Calibrate) {
    Invoke-Diagnostics
    return
}

if ($SetContacts) {
    $names = @($SetContacts -split '[,，;；]' | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    Save-ContactConfig $names
    Load-AppConfig
    Write-Host ("已保存联系人: {0}" -f ((@($script:Contacts | ForEach-Object { $_.name }) -join '、')))
    Write-Host ("配置文件: {0}" -f $ConfigFile)
    return
}

if ($SelectContacts) {
    Write-Host ''
    Write-Host '================ 选择提醒联系人 ================' -ForegroundColor Green
    Write-Host '在打开的窗口里选择/添加要特别提醒的联系人，保存后即可。'
    Write-Host '（窗口里可以：从微信会话列表中直接点选、校准头像、手动输入名字）'
    Write-Host ''
    Show-ContactManager -RunLoop
    Write-Host ("当前监听的联系人: {0}" -f ((@($script:Contacts | ForEach-Object { $_.name }) -join '、')))
    Write-Host '如果这是你要的联系人，双击「启动特别提醒.bat」即可开始监听。'
    return
}

if ($TeachAvatar) {
    Invoke-TeachAvatarFlow
    return
}

if ($TestAlert) {
    Test-AlertPreview $Seconds
    return
}

if (-not $script:Contacts.Count) {
    Write-Host ''
    Write-Host '【提示】config.json 里还没有设置要特别提醒的联系人。' -ForegroundColor Yellow
    Write-Host ("请编辑: {0}" -f $ConfigFile) -ForegroundColor Yellow
    Write-Host '把联系人的微信备注名填到 contacts 里，例如: "contacts": ["张三"]' -ForegroundColor Yellow
    Write-Host ''
    if (-not $Once -and $DurationSeconds -le 0 -and -not $Menu) { exit 1 }
}


# 入口：显示菜单 或 直接开始监听
if ($Menu) { Show-MainMenu; return }
Start-Watcher

param(
    [string]$Shell = "cmd",
    [string]$ExePath = "",
    [string]$WorkingDirectory = "",
    [string]$OutDir = "",
    [int]$WindowX = 80,
    [int]$WindowY = 80,
    [int]$WindowWidth = 1200,
    [int]$WindowHeight = 760,
    [int]$ExplorerCropWidth = 430,
    [switch]$KeepOpen
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
if ($ExePath.Length -eq 0) {
    $ExePath = Join-Path $repoRoot "zig-out\bin\phantty.exe"
}
if ($WorkingDirectory.Length -eq 0) {
    $WorkingDirectory = $repoRoot
}
if ($OutDir.Length -eq 0) {
    $OutDir = Join-Path $repoRoot "zig-out\ui-test"
}

if (!(Test-Path -LiteralPath $ExePath)) {
    throw "Phantty executable not found: $ExePath. Run zig build first."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class PhanttyUiAutomation {
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT {
    public int Left;
    public int Top;
    public int Right;
    public int Bottom;
  }

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, UIntPtr extra);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@

[PhanttyUiAutomation]::SetProcessDPIAware() | Out-Null

function Get-WindowRectValue([IntPtr]$Hwnd) {
    [PhanttyUiAutomation+RECT]$rect = New-Object PhanttyUiAutomation+RECT
    [PhanttyUiAutomation]::GetWindowRect($Hwnd, [ref]$rect) | Out-Null
    return $rect
}

function Capture-Window([IntPtr]$Hwnd, [string]$Path) {
    $rect = Get-WindowRectValue $Hwnd
    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) {
        throw "Invalid window bounds: $width x $height"
    }

    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, [System.Drawing.Size]::new($width, $height))
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }

    return @{ Width = $width; Height = $height; Left = $rect.Left; Top = $rect.Top }
}

function Crop-RightPanel([string]$SourcePath, [string]$DestPath, [int]$CropWidth) {
    $bitmap = [System.Drawing.Bitmap]::FromFile($SourcePath)
    try {
        $width = [Math]::Min($CropWidth, $bitmap.Width)
        $rect = [System.Drawing.Rectangle]::new($bitmap.Width - $width, 0, $width, $bitmap.Height)
        $crop = $bitmap.Clone($rect, $bitmap.PixelFormat)
        try {
            $crop.Save($DestPath, [System.Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $crop.Dispose()
        }
        return @{ Width = $width; Height = $bitmap.Height }
    } finally {
        $bitmap.Dispose()
    }
}

function Analyze-ExplorerCrop([string]$BeforePath, [string]$AfterPath) {
    $before = [System.Drawing.Bitmap]::FromFile($BeforePath)
    $after = [System.Drawing.Bitmap]::FromFile($AfterPath)
    try {
        $width = [Math]::Min($before.Width, $after.Width)
        $height = [Math]::Min($before.Height, $after.Height)

        $headerBright = 0
        $bodyBright = 0
        $changed = 0
        $samples = 0

        for ($y = 45; $y -lt [Math]::Min(110, $height); $y += 2) {
            for ($x = 0; $x -lt $width; $x += 2) {
                $color = $after.GetPixel($x, $y)
                if ($color.R -gt 115 -and $color.G -gt 115 -and $color.B -gt 115) {
                    $headerBright++
                }
            }
        }

        for ($y = 115; $y -lt ($height - 35); $y += 2) {
            for ($x = 8; $x -lt ($width - 8); $x += 2) {
                $color = $after.GetPixel($x, $y)
                if ($color.R -gt 125 -and $color.G -gt 125 -and $color.B -gt 125) {
                    $bodyBright++
                }
            }
        }

        for ($y = 40; $y -lt ($height - 20); $y += 4) {
            for ($x = 0; $x -lt $width; $x += 4) {
                $a = $after.GetPixel($x, $y)
                $b = $before.GetPixel($x, $y)
                $delta = [Math]::Abs($a.R - $b.R) + [Math]::Abs($a.G - $b.G) + [Math]::Abs($a.B - $b.B)
                if ($delta -gt 55) {
                    $changed++
                }
                $samples++
            }
        }

        $ratio = 0.0
        if ($samples -gt 0) {
            $ratio = $changed / $samples
        }

        return @{
            HeaderBright = $headerBright
            BodyBright = $bodyBright
            Changed = $changed
            Samples = $samples
            ChangedRatio = $ratio
            Pass = ($headerBright -gt 40 -and $bodyBright -gt 120 -and $changed -gt 400)
        }
    } finally {
        $before.Dispose()
        $after.Dispose()
    }
}

function Click-WindowCenter([IntPtr]$Hwnd) {
    $rect = Get-WindowRectValue $Hwnd
    $x = [int](($rect.Left + $rect.Right) / 2)
    $y = [int](($rect.Top + $rect.Bottom) / 2)
    [PhanttyUiAutomation]::SetCursorPos($x, $y) | Out-Null
    [PhanttyUiAutomation]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [PhanttyUiAutomation]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Send-CtrlShiftE() {
    $keyUp = 0x0002
    [PhanttyUiAutomation]::keybd_event(0x11, 0, 0, [UIntPtr]::Zero) # Ctrl
    Start-Sleep -Milliseconds 80
    [PhanttyUiAutomation]::keybd_event(0x10, 0, 0, [UIntPtr]::Zero) # Shift
    Start-Sleep -Milliseconds 80
    [PhanttyUiAutomation]::keybd_event(0x45, 0, 0, [UIntPtr]::Zero) # E
    Start-Sleep -Milliseconds 120
    [PhanttyUiAutomation]::keybd_event(0x45, 0, $keyUp, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    [PhanttyUiAutomation]::keybd_event(0x10, 0, $keyUp, [UIntPtr]::Zero)
    [PhanttyUiAutomation]::keybd_event(0x11, 0, $keyUp, [UIntPtr]::Zero)
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$beforeFull = Join-Path $OutDir "file-explorer-before-$timestamp.png"
$beforeCrop = Join-Path $OutDir "file-explorer-before-crop-$timestamp.png"
$afterFull = Join-Path $OutDir "file-explorer-after-$timestamp.png"
$afterCrop = Join-Path $OutDir "file-explorer-after-crop-$timestamp.png"

$proc = Start-Process -FilePath $ExePath -ArgumentList @("--shell", $Shell) -WorkingDirectory $WorkingDirectory -PassThru

try {
    $deadline = (Get-Date).AddSeconds(12)
    do {
        Start-Sleep -Milliseconds 250
        $proc.Refresh()
    } while ($proc.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline)

    if ($proc.MainWindowHandle -eq 0) {
        throw "Phantty window did not appear"
    }

    [PhanttyUiAutomation]::ShowWindow($proc.MainWindowHandle, 5) | Out-Null
    [PhanttyUiAutomation]::SetWindowPos($proc.MainWindowHandle, [IntPtr]::Zero, $WindowX, $WindowY, $WindowWidth, $WindowHeight, 0x0040) | Out-Null
    [PhanttyUiAutomation]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 900
    Click-WindowCenter $proc.MainWindowHandle
    Start-Sleep -Milliseconds 500

    $beforeSize = Capture-Window $proc.MainWindowHandle $beforeFull
    Crop-RightPanel $beforeFull $beforeCrop $ExplorerCropWidth | Out-Null

    Send-CtrlShiftE
    Start-Sleep -Milliseconds 1800

    $afterSize = Capture-Window $proc.MainWindowHandle $afterFull
    Crop-RightPanel $afterFull $afterCrop $ExplorerCropWidth | Out-Null
    $metrics = Analyze-ExplorerCrop $beforeCrop $afterCrop

    $result = [ordered]@{
        pass = [bool]$metrics.Pass
        shell = $Shell
        window = "$($afterSize.Width)x$($afterSize.Height)"
        before = $beforeFull
        before_crop = $beforeCrop
        after = $afterFull
        after_crop = $afterCrop
        header_bright = $metrics.HeaderBright
        body_bright = $metrics.BodyBright
        changed = $metrics.Changed
        samples = $metrics.Samples
        changed_ratio = [Math]::Round($metrics.ChangedRatio, 5)
    }

    $result | ConvertTo-Json -Depth 3

    if (!$metrics.Pass) {
        throw "File Explorer UI check failed. Inspect after_crop=$afterCrop"
    }
} finally {
    if (!$KeepOpen) {
        if (!$proc.HasExited) {
            $proc.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 500
        }
        if (!$proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

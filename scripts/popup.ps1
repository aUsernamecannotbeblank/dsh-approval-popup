# dsh-approval-popup: compact always-on-top approval card.
# Launched per approval by the host half. The decision is written to stdout
# as one JSON object.
#
# Exit codes:
#   0 = decision (stdout JSON: {"decision":"allow"|"deny"})
#   2 = DSH is focused / popup no longer needed (delegate to the Web UI)
#   3 = invalid payload
#   4 = window could not be created
#
# All user-visible strings arrive in the payload: PowerShell 5.1 reads .ps1
# files as ANSI, so this file itself stays ASCII.

$ErrorActionPreference = 'Stop'

$logFile = [string]$env:DSH_APPROVAL_LOG
function Write-PopupLog([string]$Message) {
  if (-not $logFile) { return }
  try {
    $item = Get-Item -LiteralPath $logFile -ErrorAction SilentlyContinue
    if ($item -and $item.Length -gt 262144) {
      Remove-Item -LiteralPath $logFile -Force -ErrorAction SilentlyContinue
    }
    "[$([DateTime]::Now.ToString('HH:mm:ss.fff'))] $Message" |
      Add-Content -LiteralPath $logFile -ErrorAction SilentlyContinue
  } catch { }
}

# ---------------------------------------------------------------------------
# Payload
# ---------------------------------------------------------------------------
try {
  $raw = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String([string]$env:DSH_APPROVAL_PAYLOAD))
  $data = $raw | ConvertFrom-Json
} catch {
  Write-PopupLog "bad payload: $($_.Exception.Message)"
  exit 3
}

$toolName = ([string]$data.tool).Trim()
if (-not $toolName) { $toolName = 'tool' }
if ($toolName.Length -gt 80) { $toolName = $toolName.Substring(0, 80) }

$reason = ([string]$data.reason).Trim()
if ($reason.Length -gt 220) { $reason = $reason.Substring(0, 220) + [char]0x2026 }

$timeoutSec = 0
try { $timeoutSec = [int]$data.timeoutSec } catch { $timeoutSec = 0 }
if ($timeoutSec -lt 0) { $timeoutSec = 0 }

$playSound = $data.sound -eq $true
$focusWindow = $data.focusWindow -eq $true
$onlyWhenUnfocused = $data.onlyWhenUnfocused -ne $false

# The focus watchdog is only meaningful when the card is a substitute for a
# focused DSH window. Tests can opt out explicitly with watchFocus=false.
$watchFocus = $onlyWhenUnfocused
if ($null -ne $data.watchFocus) { $watchFocus = ($data.watchFocus -eq $true) }

$script:playSound = $playSound
$script:focusWindow = $focusWindow
$script:timeoutSec = $timeoutSec
$script:onlyWhenUnfocused = $onlyWhenUnfocused
$script:watchFocus = $watchFocus

# ---------------------------------------------------------------------------
# Foreground detection (UI Automation; no native compile required)
# ---------------------------------------------------------------------------
function Get-ForegroundApp {
  try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes -ErrorAction Stop
    $element = [System.Windows.Automation.AutomationElement]::FocusedElement
    if ($null -eq $element) {
      return @{ title = ''; className = ''; pid = 0; processName = '' }
    }
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $node = $element
    for ($i = 0; $i -lt 12; $i++) {
      $parent = $walker.GetParent($node)
      if ($null -eq $parent) { break }
      $parentClass = [string]$parent.Current.ClassName
      $parentHandle = [int]$parent.Current.NativeWindowHandle
      if ($parentClass -eq '#32769' -or $parentHandle -eq 0) { break }
      $node = $parent
    }
    $procId = 0
    try { $procId = [int]$node.Current.ProcessId } catch { }
    $procName = ''
    if ($procId -gt 0) {
      try {
        $procName = [string]([System.Diagnostics.Process]::GetProcessById($procId).ProcessName)
      } catch { }
    }
    return @{
      title = [string]$node.Current.Name
      className = [string]$node.Current.ClassName
      pid = $procId
      processName = $procName
    }
  } catch {
    Write-PopupLog "focus detection failed: $($_.Exception.Message)"
    return @{ title = ''; className = ''; pid = 0; processName = '' }
  }
}

function Test-DshForeground {
  $foreground = Get-ForegroundApp
  if ($foreground.processName) {
    return ($foreground.processName -eq 'DeepSeek Harness')
  }
  # Process lookup can fail under a restricted token; fall back to the
  # Electron window class + title.
  return ($foreground.className -eq 'Chrome_WidgetWin_1' -and
    $foreground.title -match 'DeepSeek Harness')
}

if ($onlyWhenUnfocused) {
  if (Test-DshForeground) {
    Write-PopupLog 'skip: DSH is focused'
    exit 2
  }
  Write-PopupLog 'unfocused: showing card'
}

# ---------------------------------------------------------------------------
# Per-monitor DPI awareness. The helper assembly is cached so a popup does
# not pay the Add-Type compile cost on every launch.
# ---------------------------------------------------------------------------
function Enable-DpiAwareness {
  $cacheRoot = [string]$env:DSH_APPROVAL_CACHE
  if (-not $cacheRoot) { $cacheRoot = Join-Path $env:LOCALAPPDATA 'DSH\approval-popup' }
  $tag = if ([string]$PSVersionTable.PSEdition -eq 'Core') { 'core' } else { 'desktop' }
  $dll = Join-Path $cacheRoot ("DshApprovalDpi-v1-$tag.dll")
  $source = @'
using System.Runtime.InteropServices;
public static class DshApprovalDpi {
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
}
'@

  if (Test-Path -LiteralPath $dll) {
    try {
      Add-Type -Path $dll -ErrorAction Stop
      [void][DshApprovalDpi]::SetProcessDpiAwareness(2)
      Write-PopupLog 'dpi=cache'
      return
    } catch { }
  }

  try {
    [void][System.IO.Directory]::CreateDirectory($cacheRoot)
    $tmp = $dll + '.' + $PID + '.tmp'
    Add-Type -TypeDefinition $source -OutputAssembly $tmp -OutputType Library -ErrorAction Stop
    [System.IO.File]::Copy($tmp, $dll, $true)
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Add-Type -Path $dll -ErrorAction Stop
    [void][DshApprovalDpi]::SetProcessDpiAwareness(2)
    Write-PopupLog 'dpi=compiled'
    return
  } catch {
    Write-PopupLog "dpi-cache failed: $($_.Exception.Message)"
  }

  try {
    Add-Type -TypeDefinition $source -ErrorAction Stop
    [void][DshApprovalDpi]::SetProcessDpiAwareness(2)
    Write-PopupLog 'dpi=memory'
  } catch {
    Write-PopupLog "dpi=unavailable $($_.Exception.Message)"
  }
}

Enable-DpiAwareness

# ---------------------------------------------------------------------------
# WPF
# ---------------------------------------------------------------------------
try {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
} catch {
  Write-PopupLog "WPF load failed: $($_.Exception.Message)"
  exit 4
}

$lang = if ([string]$data.lang -eq 'en') { 'en' } else { 'zh' }
$labels = $data.labels
$pack = if ($lang -eq 'en') { $labels.en } else { $labels.zh }
$labelHeading = [string]$pack.heading
$labelAllow = [string]$pack.allow
$labelDeny = [string]$pack.deny
if (-not $labelHeading) { $labelHeading = 'Approval required' }
if (-not $labelAllow) { $labelAllow = 'Allow' }
if (-not $labelDeny) { $labelDeny = 'Deny' }

function New-Brush([int]$a, [int]$r, [int]$g, [int]$b) {
  $brush = New-Object System.Windows.Media.SolidColorBrush (
    [System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
  $brush.Freeze()
  return $brush
}

$brCard = New-Brush 246 24 24 28
$brLine = New-Brush 38 255 255 255
$brText = New-Brush 255 242 242 247
$brMuted = New-Brush 255 158 158 168
$brAccent = New-Brush 255 77 107 254
$brAccentHover = New-Brush 255 99 126 255
$brGhost = New-Brush 22 255 255 255
$brGhostHover = New-Brush 40 255 255 255
$brGhostLine = New-Brush 30 255 255 255
$brAmber = New-Brush 255 245 165 36
$brTrack = New-Brush 30 255 255 255
$brClose = New-Brush 255 128 128 138
$brCloseHover = New-Brush 255 236 236 242

$window = New-Object System.Windows.Window
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.ShowInTaskbar = $false
$window.Topmost = $true
$window.ResizeMode = 'NoResize'
$window.SizeToContent = 'Height'
$window.Width = 376
$window.WindowStartupLocation = 'Manual'
$window.Left = 0
$window.Top = 0
$window.Opacity = 1
$window.ShowActivated = $focusWindow
$window.Focusable = $true
$window.Title = $labelHeading
$window.FontFamily = New-Object System.Windows.Media.FontFamily 'Segoe UI, Microsoft YaHei UI, Microsoft YaHei'
$window.UseLayoutRounding = $true

$outer = New-Object System.Windows.Controls.Grid
$outer.Margin = New-Object System.Windows.Thickness 18
$translate = New-Object System.Windows.Media.TranslateTransform 0, 14
$outer.RenderTransform = $translate

$card = New-Object System.Windows.Controls.Border
$card.CornerRadius = New-Object System.Windows.CornerRadius 14
$card.Background = $brCard
$card.BorderBrush = $brLine
$card.BorderThickness = 1
$card.Padding = New-Object System.Windows.Thickness 16, 13, 16, 14
$shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$shadow.BlurRadius = 26
$shadow.ShadowDepth = 2
$shadow.Direction = 270
$shadow.Opacity = 0.42
$shadow.Color = [System.Windows.Media.Colors]::Black
$card.Effect = $shadow
[void]$outer.Children.Add($card)
$window.Content = $outer

$stack = New-Object System.Windows.Controls.StackPanel
$card.Child = $stack

# Header: dot + label on the left, close on the right.
$header = New-Object System.Windows.Controls.DockPanel
$header.LastChildFill = $true

$close = New-Object System.Windows.Controls.TextBlock
$close.Text = [char]0x2715
$close.FontSize = 11
$close.Foreground = $brClose
$close.Cursor = [System.Windows.Input.Cursors]::Hand
$close.Padding = New-Object System.Windows.Thickness 5, 2, 0, 2
$close.VerticalAlignment = 'Center'
[System.Windows.Controls.DockPanel]::SetDock($close, 'Right')
$close.Add_MouseEnter({ $this.Foreground = $brCloseHover })
$close.Add_MouseLeave({ $this.Foreground = $brClose })
$close.Add_MouseLeftButtonUp({ Set-Decision 'deny' })
[void]$header.Children.Add($close)

$mark = New-Object System.Windows.Controls.StackPanel
$mark.Orientation = 'Horizontal'
$mark.VerticalAlignment = 'Center'
$dot = New-Object System.Windows.Shapes.Ellipse
$dot.Width = 7
$dot.Height = 7
$dot.Fill = $brAmber
$dot.Margin = New-Object System.Windows.Thickness 0, 0, 7, 0
$dot.VerticalAlignment = 'Center'
[void]$mark.Children.Add($dot)
$heading = New-Object System.Windows.Controls.TextBlock
$heading.Text = $labelHeading
$heading.FontSize = 11.5
$heading.Foreground = $brMuted
$heading.VerticalAlignment = 'Center'
[void]$mark.Children.Add($heading)
[void]$header.Children.Add($mark)
[void]$stack.Children.Add($header)

# Tool name.
$title = New-Object System.Windows.Controls.TextBlock
$title.Text = $toolName
$title.FontSize = 16.5
$title.FontWeight = [System.Windows.FontWeights]::SemiBold
$title.Foreground = $brText
$title.TextTrimming = 'CharacterEllipsis'
$title.Margin = New-Object System.Windows.Thickness 0, 10, 0, 0
[void]$stack.Children.Add($title)

# Reason (up to two lines; the full text stays available to the Web UI).
if ($reason) {
  $detail = New-Object System.Windows.Controls.TextBlock
  $detail.Text = $reason
  $detail.FontSize = 12.2
  $detail.Foreground = $brMuted
  $detail.TextWrapping = 'Wrap'
  $detail.LineHeight = 18
  $detail.LineStackingStrategy = 'BlockLineHeight'
  $detail.MaxHeight = 37
  $detail.Margin = New-Object System.Windows.Thickness 0, 4, 0, 0
  [void]$stack.Children.Add($detail)
}

function New-CardButton {
  param(
    [string]$Text,
    $Background,
    $Foreground,
    $Hover,
    $BorderBrush,
    [string]$Action
  )
  $button = New-Object System.Windows.Controls.Border
  $button.CornerRadius = New-Object System.Windows.CornerRadius 8
  $button.Background = $Background
  $button.BorderBrush = $BorderBrush
  $button.BorderThickness = if ($null -eq $BorderBrush) { 0 } else { 1 }
  $button.Padding = New-Object System.Windows.Thickness 15, 6, 15, 7
  $button.Margin = New-Object System.Windows.Thickness 8, 0, 0, 0
  $button.Cursor = [System.Windows.Input.Cursors]::Hand
  $button.Tag = @{ normal = $Background; hover = $Hover; action = $Action }
  $label = New-Object System.Windows.Controls.TextBlock
  $label.Text = $Text
  $label.FontSize = 12.5
  $label.FontWeight = [System.Windows.FontWeights]::Medium
  $label.Foreground = $Foreground
  $button.Child = $label
  $button.Add_MouseEnter({ $this.Background = $this.Tag.hover })
  $button.Add_MouseLeave({ $this.Background = $this.Tag.normal })
  $button.Add_MouseLeftButtonUp({
    Write-PopupLog "click action=$($this.Tag.action)"
    Set-Decision $this.Tag.action
  })
  return $button
}

$actions = New-Object System.Windows.Controls.StackPanel
$actions.Orientation = 'Horizontal'
$actions.HorizontalAlignment = 'Right'
$actions.Margin = New-Object System.Windows.Thickness 0, 14, 0, 0
$deny = New-CardButton -Text $labelDeny -Background $brGhost -Foreground $brText `
  -Hover $brGhostHover -BorderBrush $brGhostLine -Action 'deny'
$allow = New-CardButton -Text $labelAllow -Background $brAccent -Foreground $brText `
  -Hover $brAccentHover -BorderBrush $null -Action 'allow'
[void]$actions.Children.Add($deny)
[void]$actions.Children.Add($allow)
[void]$stack.Children.Add($actions)

# Optional timeout strip.
$timerHost = $null
$timerFill = $null
if ($timeoutSec -gt 0) {
  $timerHost = New-Object System.Windows.Controls.Grid
  $timerHost.Height = 3
  $timerHost.Margin = New-Object System.Windows.Thickness 16, 12, 16, 0
  $track = New-Object System.Windows.Shapes.Rectangle
  $track.RadiusX = 1.5
  $track.RadiusY = 1.5
  $track.Fill = $brTrack
  $timerFill = New-Object System.Windows.Shapes.Rectangle
  $timerFill.RadiusX = 1.5
  $timerFill.RadiusY = 1.5
  $timerFill.HorizontalAlignment = 'Left'
  $timerFill.Fill = $brAccent
  [void]$timerHost.Children.Add($track)
  [void]$timerHost.Children.Add($timerFill)
  [void]$stack.Children.Add($timerHost)
}

# ---------------------------------------------------------------------------
# Behaviour
# ---------------------------------------------------------------------------
$script:decision = $null

function Place-BottomRight {
  try {
    $work = [System.Windows.SystemParameters]::WorkArea
    $w = if ($script:window.ActualWidth -gt 0) { $script:window.ActualWidth } else { $script:window.Width }
    $h = if ($script:window.ActualHeight -gt 0) { $script:window.ActualHeight } else { 156 }
    $script:window.Left = $work.Right - $w - 12
    $script:window.Top = $work.Bottom - $h - 12
  } catch { }
}

function Set-Decision([string]$Decision) {
  if ($script:decision) { return }
  $script:decision = $Decision
  Write-PopupLog "decision=$Decision"
  try { $script:window.Close() } catch { }
}

$window.Add_KeyDown({
  if ($_.Key -eq [System.Windows.Input.Key]::Escape) { Set-Decision 'deny' }
})

$window.Add_ContentRendered({
  Place-BottomRight
  Write-PopupLog ("shown at {0},{1} size={2}x{3} work={4}x{5} visible={6} opacity={7}" -f `
    [int]$script:window.Left, [int]$script:window.Top,
    [int]$script:window.ActualWidth, [int]$script:window.ActualHeight,
    [int][System.Windows.SystemParameters]::WorkArea.Width,
    [int][System.Windows.SystemParameters]::WorkArea.Height,
    $script:window.IsVisible, $script:window.Opacity)
  try {
    $ease = New-Object System.Windows.Media.Animation.QuadraticEase
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $rise = New-Object System.Windows.Media.Animation.DoubleAnimation
    $rise.From = 14.0
    $rise.To = 0.0
    $rise.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromMilliseconds(180))
    $rise.EasingFunction = $ease
    $script:translate.BeginAnimation(
      [System.Windows.Media.TranslateTransform]::YProperty, $rise)
  } catch { }
  if ($script:focusWindow) {
    try { $script:window.Activate() | Out-Null } catch { }
  }
  if ($script:playSound) {
    try { [System.Media.SystemSounds]::Asterisk.Play() } catch { }
  }
  if ($script:timeoutSec -gt 0) {
    $script:remaining = [double]$script:timeoutSec
    $script:timeoutTimer.Start()
  }
  if ($script:watchFocus) { $script:focusTimer.Start() }
})

$window.Add_Closed({
  try { $script:timeoutTimer.Stop() } catch { }
  try { $script:focusTimer.Stop() } catch { }
})

$script:focusTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:focusTimer.Interval = [TimeSpan]::FromMilliseconds(1200)
$script:focusTimer.Add_Tick({
  if ($script:decision) { return }
  if (Test-DshForeground) {
    $script:decision = 'skip'
    Write-PopupLog 'focus returned: delegating to Web UI'
    try { $script:window.Close() } catch { }
  }
})

$script:timeoutTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:timeoutTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:timeoutTimer.Add_Tick({
  if ($script:decision) { return }
  $script:remaining -= 0.1
  if ($script:remaining -le 0) {
    $script:timeoutTimer.Stop()
    Write-PopupLog 'timeout'
    $script:decision = 'timeout'
    try { $script:window.Close() } catch { }
    return
  }
  if ($timeoutSec -gt 0 -and $timerHost) {
    $hostWidth = $timerHost.ActualWidth
    if ($hostWidth -gt 0) {
      $timerFill.Width = [double]$hostWidth * ($script:remaining / $timeoutSec)
    }
  }
})

$window.Add_SizeChanged({ Place-BottomRight })

try {
  [void]$window.ShowDialog()
} catch {
  Write-PopupLog "window error: $($_.Exception.Message)"
  exit 4
}

if ($script:decision -eq 'skip') { exit 2 }
if (-not $script:decision) { $script:decision = 'deny' }
Write-PopupLog "exit decision=$($script:decision)"
@{ decision = $script:decision } | ConvertTo-Json -Compress | Write-Output
exit 0

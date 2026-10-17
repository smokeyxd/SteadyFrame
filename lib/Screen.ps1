# Menus are drawn as one frame that is redrawn in place from the top of the window, instead of
# printing a fresh copy under the old one on every key. VT escape codes make that flicker-free;
# consoles without them get Clear-Host, and piped input keeps the old line-by-line prompts.

$script:SFVT = $null

function Initialize-SFScreen {
    if ($null -ne $script:SFVT) { return $script:SFVT }
    $script:SFVT = $false
    try {
        if (-not ('SFConsoleMode' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SFConsoleMode {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
    [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out uint m);
    [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, uint m);
    public static bool EnableVT() {
        IntPtr h = GetStdHandle(-11);
        uint m;
        if (!GetConsoleMode(h, out m)) return false;
        return (m & 4) != 0 || SetConsoleMode(h, m | 4);
    }
}
'@
        }
        $script:SFVT = [SFConsoleMode]::EnableVT()
    } catch { $script:SFVT = $false }
    return $script:SFVT
}

function Test-SFKeyConsole {
    try {
        return ($Host.Name -eq 'ConsoleHost' -and -not [Console]::IsInputRedirected -and -not [Console]::IsOutputRedirected -and
            [Console]::WindowHeight -ge 16 -and [Console]::WindowWidth -ge 60)
    } catch { return $false }
}

function New-SFSeg {
    param([string]$Text = '', [string]$Color = 'Gray', [string]$Back = '')
    return [pscustomobject]@{ Text = $Text; Color = $Color; Back = $Back }
}

function Split-SFWrapped {
    param([string]$Text, [int]$Width)
    $out = @()
    foreach ($para in ("$Text" -split "`n")) {
        $line = ''
        foreach ($word in ($para -split ' ')) {
            if ($line -and ($line.Length + 1 + $word.Length) -gt $Width) { $out += $line; $line = $word }
            elseif ($line) { $line += ' ' + $word }
            else { $line = $word }
        }
        $out += $line
    }
    return $out
}

# Lines are cut to the window width: a wrapped line would push everything below it down and the
# next redraw would no longer line up.
function Write-SFFrame {
    param([Parameter(Mandatory)]$Lines, [switch]$Fresh)
    $w = [math]::Max(20, [Console]::WindowWidth - 1)
    $h = [math]::Max(5, [Console]::WindowHeight - 1)
    $esc = [char]27
    if ($Fresh -or -not $script:SFVT) { Clear-Host } else { [Console]::Write("$esc[H") }
    $lines = @($Lines)
    $n = [math]::Min($lines.Count, $h)
    for ($i = 0; $i -lt $n; $i++) {
        $left = $w
        foreach ($s in @($lines[$i])) {
            if ($left -le 0 -or $null -eq $s) { continue }
            $t = [string]$s.Text
            if ($t.Length -gt $left) { $t = $t.Substring(0, $left) }
            $left -= $t.Length
            if ($s.Back) { Write-Host $t -NoNewline -ForegroundColor $s.Color -BackgroundColor $s.Back }
            elseif ($t) { Write-Host $t -NoNewline -ForegroundColor $s.Color }
        }
        if ($script:SFVT) { [Console]::Write("$esc[K") }
        # no newline after the last line: writing one on the bottom row scrolls the whole frame
        if ($i -lt $n - 1) { Write-Host '' }
    }
    if ($script:SFVT) { [Console]::Write("$esc[J") }
}

function Read-SFKey {
    $k = [Console]::ReadKey($true)
    switch ($k.Key) {
        'UpArrow' { return 'Up' }
        'DownArrow' { return 'Down' }
        'PageUp' { return 'PageUp' }
        'PageDown' { return 'PageDown' }
        'Home' { return 'Home' }
        'End' { return 'End' }
        'Enter' { return 'Enter' }
        'Escape' { return 'Escape' }
        'Spacebar' { return 'Space' }
    }
    if ($k.KeyChar -ne [char]0) { return ([string]$k.KeyChar).ToLowerInvariant() }
    return ''
}

function Enter-SFFrameMode {
    [void](Initialize-SFScreen)
    try { [Console]::CursorVisible = $false } catch { }
}

function Exit-SFFrameMode {
    try { [Console]::CursorVisible = $true } catch { }
    Clear-Host
}

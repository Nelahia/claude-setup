#requires -Version 5.1
<#
.SYNOPSIS
  Install the Caveman output style and/or RTK for Claude Code on Windows.
.LINK
  https://github.com/Nelahia/claude-setup

  irm .../install.ps1 | iex                                                   # both
  & ([scriptblock]::Create((irm .../install.ps1))) caveman
  & ([scriptblock]::Create((irm .../install.ps1))) rtk
  & ([scriptblock]::Create((irm .../install.ps1))) all -Uninstall
#>
[CmdletBinding()]
param(
    [ValidateSet('all', 'caveman', 'rtk')]
    [string]$Component = 'all',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoRaw = if ($env:CLAUDE_SETUP_RAW) { $env:CLAUDE_SETUP_RAW }
           else { 'https://raw.githubusercontent.com/Nelahia/claude-setup/main' }
$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
$Settings  = Join-Path $ClaudeDir 'settings.json'
$ClaudeMd  = Join-Path $ClaudeDir 'CLAUDE.md'
$StyleName = 'caveman'
$BeginMark = '<!-- BEGIN claude-setup -->'
$EndMark   = '<!-- END claude-setup -->'

function Say  { param([string]$Message) Write-Host $Message }
function Warn { param([string]$Message) Write-Warning $Message }

# npm/pnpm install Claude Code as a claude.cmd shim on Windows. Node's
# child_process can't spawn a .cmd/.bat safely (it needs cmd.exe /c with
# shell:true — a known Windows arg-injection surface), so anything that
# launches a nested `claude` process (background agents, local-session
# spawning) refuses with "cannot safely launch non-Node Windows command
# shim". The native installer ships a real claude.exe and sidesteps this
# entirely, so just flag it — this repo doesn't touch how Claude Code itself
# is installed.
function Test-ClaudeShim {
    $cmd = Get-Command claude -All -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd -or $cmd.Source -notmatch '\.(cmd|bat|ps1)$') { return }
    Warn "claude resolves to a Windows command shim ($($cmd.Source)), not a native .exe."
    Warn "Nested/background Claude Code launches will fail with 'cannot safely launch non-Node Windows command shim'."
    Warn "Fix: irm https://claude.ai/install.ps1 | iex, then 'npm uninstall -g @anthropic-ai/claude-code' (and/or 'pnpm remove -g @anthropic-ai/claude-code')."
}

# Fetch a repo-relative asset as text. CLAUDE_SETUP_SRC reads from a local checkout instead.
function Get-Asset {
    param([Parameter(Mandatory)][string]$Path)
    if ($env:CLAUDE_SETUP_SRC) {
        return [IO.File]::ReadAllText((Join-Path $env:CLAUDE_SETUP_SRC $Path))
    }
    return (Invoke-RestMethod -Uri "$RepoRaw/$Path" -Headers @{ 'User-Agent' = 'claude-setup' })
}

function Backup-File {
    param([Parameter(Mandatory)][string]$Path)
    Copy-Item $Path "$Path.bak.$(Get-Date -Format 'yyyyMMddHHmmss')" -Force
}

# Write $Content to $Path only when it differs. Backs up first unless $Fresh.
function Write-IfChanged {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)][string]$Label,
        [switch]$Fresh
    )
    if (Test-Path -LiteralPath $Path) {
        if ([IO.File]::ReadAllText($Path) -eq $Content) {
            Say "  = ${Label}: already up to date"
            return
        }
        if (-not $Fresh) { Backup-File $Path }
    }
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content)
    Say "  + ${Label}: written"
}

# --- settings.json ----------------------------------------------------------

# Set or remove outputStyle. Never string-edit this file: it also holds
# apiKeyHelper, env, statusLine and the RTK hook. The up-to-date check is on the
# parsed value rather than the file bytes, because RTK rewrites settings.json
# with its own formatting and a byte comparison would never converge.
function Set-OutputStyleSetting {
    param([ValidateSet('set', 'del')][string]$Operation)

    if (-not (Test-Path -LiteralPath $ClaudeDir)) {
        New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
    }

    $fresh = -not (Test-Path -LiteralPath $Settings)
    $data = $null
    if (-not $fresh) {
        $raw = [IO.File]::ReadAllText($Settings)
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try { $data = $raw | ConvertFrom-Json }
            catch { throw "could not parse $Settings — fix the JSON first" }
        }
    }
    if ($null -eq $data) { $data = [pscustomobject]@{} }

    $prop = $data.PSObject.Properties['outputStyle']
    $current = if ($prop) { [string]$prop.Value } else { '' }

    if ($Operation -eq 'set' -and $current -eq $StyleName) {
        Say "  = settings.json: outputStyle already `"$StyleName`""
        return
    }
    if ($Operation -eq 'del' -and $current -eq '') {
        Say '  = settings.json: no outputStyle to remove'
        return
    }

    if ($Operation -eq 'set') {
        $data | Add-Member -NotePropertyName outputStyle -NotePropertyValue $StyleName -Force
    }
    else {
        $data.PSObject.Properties.Remove('outputStyle')
    }

    $json = ($data | ConvertTo-Json -Depth 20) + "`n"
    Write-IfChanged -Path $Settings -Content $json -Label 'settings.json' -Fresh:$fresh
}

# --- CLAUDE.md managed block ------------------------------------------------

# Everything in CLAUDE.md except our block, with trailing blank lines dropped.
# Trimming matters: without it every run appends another blank separator.
function Get-ClaudeMdBody {
    if (-not (Test-Path -LiteralPath $ClaudeMd)) { return '' }
    $kept = New-Object 'System.Collections.Generic.List[string]'
    $skip = $false
    foreach ($line in [IO.File]::ReadAllLines($ClaudeMd)) {
        if ($line -eq $BeginMark) { $skip = $true; continue }
        if ($line -eq $EndMark)   { $skip = $false; continue }
        if (-not $skip) { $kept.Add($line) }
    }
    while ($kept.Count -gt 0 -and [string]::IsNullOrWhiteSpace($kept[$kept.Count - 1])) {
        $kept.RemoveAt($kept.Count - 1)
    }
    return ($kept -join "`n")
}

function Sync-ManagedBlock {
    param([ValidateSet('install', 'remove')][string]$Action)

    $body = Get-ClaudeMdBody

    if ($Action -eq 'remove') {
        if ($body -eq '') {
            if (Test-Path -LiteralPath $ClaudeMd) {
                Backup-File $ClaudeMd
                Remove-Item -LiteralPath $ClaudeMd -Force
                Say '  - CLAUDE.md: removed (nothing left in it)'
            }
            return
        }
        Write-IfChanged -Path $ClaudeMd -Content ($body + "`n") -Label 'CLAUDE.md managed block'
        return
    }

    $block = (Get-Asset 'claude/tools-block.md').Replace("`r`n", "`n").TrimEnd("`n")
    $new = ''
    if ($body -ne '') { $new = $body + "`n`n" }
    $new += "$BeginMark`n$block`n$EndMark`n"
    Write-IfChanged -Path $ClaudeMd -Content $new -Label 'CLAUDE.md managed block'
}

# --- caveman ----------------------------------------------------------------

function Install-Caveman {
    Say 'caveman:'
    $stylePath = Join-Path $ClaudeDir "output-styles\$StyleName.md"

    if ($Uninstall) {
        if (Test-Path -LiteralPath $stylePath) {
            Remove-Item -LiteralPath $stylePath -Force
            Say "  - output-styles/$StyleName.md: removed"
        }
        else {
            Say "  = output-styles/$StyleName.md: not present"
        }
        Set-OutputStyleSetting -Operation del
        return
    }

    $style = (Get-Asset "styles/$StyleName.md").Replace("`r`n", "`n")
    Write-IfChanged -Path $stylePath -Content $style -Label "output-styles/$StyleName.md"
    Set-OutputStyleSetting -Operation set
}

# --- rtk --------------------------------------------------------------------

function Install-RtkBinary {
    # Upstream publishes no Windows ARM64 asset. Windows 11 on ARM emulates x64,
    # so install the x64 build rather than refusing outright — but say so.
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {
        Warn 'no native Windows ARM64 build of rtk exists; installing the x64 build (runs under emulation)'
    }

    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/rtk-ai/rtk/releases/latest' `
        -Headers @{ 'User-Agent' = 'claude-setup' }
    $assetName = 'rtk-x86_64-pc-windows-msvc.zip'
    $asset = $release.assets | Where-Object { $_.name -eq $assetName } | Select-Object -First 1
    if (-not $asset) { throw "asset $assetName not found in rtk release $($release.tag_name)" }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('claude-setup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $zip = Join-Path $work 'rtk.zip'
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
        $exe = Get-ChildItem -Path $work -Recurse -Filter 'rtk.exe' | Select-Object -First 1
        if (-not $exe) { throw 'rtk.exe not found in the downloaded archive' }

        $binDir = Join-Path $HOME '.local\bin'
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
        Copy-Item $exe.FullName (Join-Path $binDir 'rtk.exe') -Force

        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($null -eq $userPath) { $userPath = '' }
        if ($userPath -split ';' -notcontains $binDir) {
            [Environment]::SetEnvironmentVariable(
                'Path', (($userPath.TrimEnd(';') + ';' + $binDir).TrimStart(';')), 'User')
            Say "  i PATH: added $binDir (new terminals only)"
        }
        $env:Path = "$env:Path;$binDir"
        Say "  + binary: installed to $binDir ($($release.tag_name))"
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-Rtk {
    Say 'rtk:'
    $rtk = Get-Command rtk -ErrorAction SilentlyContinue

    if ($Uninstall) {
        if ($rtk) {
            & rtk init -g --uninstall | Out-Null
            Say '  - hook, RTK.md and settings.json entry removed'
            Say '  i binary kept — delete ~\.local\bin\rtk.exe if you want it gone'
        }
        else {
            Say '  = rtk not installed'
        }
        return
    }

    if ($rtk) {
        Say "  = binary: already installed ($(& rtk --version))"
    }
    else {
        Install-RtkBinary
    }

    if (-not (Get-Command rtk -ErrorAction SilentlyContinue)) {
        throw 'rtk installed but not on PATH'
    }
    # --auto-patch keeps it non-interactive; the telemetry prompt would hang a piped install.
    & rtk init -g --auto-patch | Out-Null
    Say '  + hook: registered globally (rtk hook claude)'
}

# --- main -------------------------------------------------------------------

Say "claude-setup -> $ClaudeDir"
Say ''
Test-ClaudeShim

switch ($Component) {
    'caveman' { Install-Caveman }
    'rtk'     { Install-Rtk }
    'all'     { Install-Caveman; Say ''; Install-Rtk }
}

Say ''
if ($Uninstall) {
    # The managed block documents both tools, so only drop it on a full uninstall.
    if ($Component -eq 'all') { Sync-ManagedBlock -Action remove }
    else { Say '  i CLAUDE.md managed block kept (other component still installed)' }
    Say ''
    Say 'Done. Restart Claude Code.'
}
else {
    Sync-ManagedBlock -Action install
    Say ''
    Say 'Done. Restart Claude Code for the hook and output style to take effect.'
}

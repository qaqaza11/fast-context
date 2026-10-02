#Requires -Version 7.0
<#
.SYNOPSIS
Install fast-context for the current Windows user without changing default Python.
.PARAMETER CheckOnly
Print the installation plan without modifying files, PATH, or packages.
.PARAMETER Update
Back up and update an existing fast-context skill; never overwrite another skill.
.PARAMETER SkipDependencies
Reuse a prepared Python 3.12 runtime without installing packages. Useful for testing.
#>
[CmdletBinding()]
param(
    [string]$SkillDirectory,
    [string]$RuntimeRoot,
    [switch]$CheckOnly,
    [switch]$Update,
    [switch]$SkipOcr,
    [switch]$SkipAudio,
    [switch]$SkipDependencies,
    [switch]$NoPath,
    [switch]$NoVerify
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$fcSource = [IO.Path]::GetFullPath($PSScriptRoot)
$fcHomeDirectory = [Environment]::GetFolderPath('UserProfile')
if (-not $RuntimeRoot) {
    $RuntimeRoot = if ($env:FAST_CONTEXT_HOME) { $env:FAST_CONTEXT_HOME } else { Join-Path $fcHomeDirectory '.codex\tools\fast-context' }
}
$fcRuntime = [IO.Path]::GetFullPath($RuntimeRoot)
if (-not $SkillDirectory) {
    $fcModern = Join-Path $fcHomeDirectory '.agents\skills\fast-context'
    $fcLegacy = Join-Path $fcHomeDirectory '.codex\skills\fast-context'
    if ((Test-Path -LiteralPath $fcModern) -and (Test-Path -LiteralPath $fcLegacy)) {
        throw 'Both user skill locations exist. Choose one with -SkillDirectory to avoid duplicate discovery.'
    }
    $SkillDirectory = if (Test-Path -LiteralPath $fcLegacy) { $fcLegacy } else { $fcModern }
}
$fcSkill = [IO.Path]::GetFullPath($SkillDirectory)
$fcPackagePatterns = @{ rg='BurntSushi.ripgrep.MSVC*'; fd='sharkdp.fd*'; ffmpeg='Gyan.FFmpeg.Essentials*'; ffprobe='Gyan.FFmpeg.Essentials*'; uv='astral-sh.uv*' }
function Find-FcCommand([string]$Name) {
    $fcFound = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fcFound -and $fcFound.Source -and (Test-Path -LiteralPath $fcFound.Source)) { return $fcFound.Source }
    foreach ($fcDirectory in ([Environment]::GetEnvironmentVariable('Path','User') -split ';')) {
        if (-not $fcDirectory) { continue }
        foreach ($fcExtension in @('.exe','.cmd','.ps1')) {
            $fcCandidate = Join-Path $fcDirectory ($Name + $fcExtension)
            if (Test-Path -LiteralPath $fcCandidate) { return $fcCandidate }
        }
    }
    if ($fcPackagePatterns.ContainsKey($Name) -and $env:LOCALAPPDATA) {
        $fcPackages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        foreach ($fcPackage in (Get-ChildItem -Path (Join-Path $fcPackages $fcPackagePatterns[$Name]) -Directory -ErrorAction SilentlyContinue)) {
            $fcBinary = Get-ChildItem -LiteralPath $fcPackage.FullName -Filter ($Name+'.exe') -File -Recurse | Select-Object -First 1
            if ($fcBinary) { return $fcBinary.FullName }
        }
    }
    return $null
}
function Test-FcCommand([string]$Command, [string]$Name) {
    if (-not $Command) { return $false }
    $fcArgument = if ($Name -in @('ffmpeg','ffprobe')) { '-version' } else { '--version' }
    try {
        $fcOutput = & $Command $fcArgument 2>&1
        if ($LASTEXITCODE -ne 0) { return $false }
        if ($Name -in @('sg','ast-grep')) { return (($fcOutput -join ' ') -match 'ast-grep') }
        return $true
    } catch { return $false }
}
$fcNames = @('winget','git','uv','python','node','npm','rg','fd','ast-grep','sg','ffmpeg','ffprobe','markitdown')
$fcInventory = foreach ($fcName in $fcNames) {
    $fcCommand = Find-FcCommand $fcName
    [pscustomobject]@{tool=$fcName;present=[bool]$fcCommand;working=(Test-FcCommand $fcCommand $fcName);path=$fcCommand}
}
if ($CheckOnly) {
    [pscustomobject]@{mode='check-only';skill_directory=$fcSkill;runtime=$fcRuntime;tools=$fcInventory;
        python='3.12';ocr=(-not $SkipOcr);audio=(-not $SkipAudio);user_path=(-not $NoPath);
        models='downloaded only when OCR/transcription is first used'} | ConvertTo-Json -Depth 6
    exit 0
}
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
    throw 'This installer supports Windows x64. Other platforms may use the scripts with manually prepared dependencies.'
}
if ($fcRuntime -eq $fcSource -or $fcRuntime.StartsWith($fcSource+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Choose a runtime directory outside the source package so dependencies and caches stay out of the repository.'
}
$fcManagedFiles = @('SKILL.md','README.md','LICENSE','install.ps1','requirements-core.txt','requirements-ocr.txt','requirements-audio.txt')
$fcScriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $fcSource 'scripts') -File -Filter '*.py')
if ($fcSkill -ne $fcSource -and (Test-Path -LiteralPath (Join-Path $fcSkill 'SKILL.md'))) {
    $fcTargetManifest = Get-Content -LiteralPath (Join-Path $fcSkill 'SKILL.md') -Raw
    if ($fcTargetManifest -notmatch '(?m)^name:\s*fast-context\s*$') { throw 'Destination contains another skill. Choose a different -SkillDirectory.' }
    $fcDifferent = $false
    foreach ($fcRelative in ($fcManagedFiles + @($fcScriptFiles | ForEach-Object { 'scripts\'+$_.Name }))) {
        $fcFrom = Join-Path $fcSource $fcRelative
        $fcTo = Join-Path $fcSkill $fcRelative
        if ((Test-Path -LiteralPath $fcFrom) -and (Test-Path -LiteralPath $fcTo) -and
            (Get-FileHash -LiteralPath $fcFrom).Hash -ne (Get-FileHash -LiteralPath $fcTo).Hash) { $fcDifferent = $true }
    }
    if ($fcDifferent -and -not $Update) { throw 'Existing fast-context differs. Use -Update to back up and update it, or select another directory.' }
}
$fcLogs = Join-Path $fcRuntime 'logs'
New-Item -ItemType Directory -Path $fcLogs -Force | Out-Null
$fcBeforeFile = Join-Path $fcRuntime 'path-before-install.json'
if (-not (Test-Path -LiteralPath $fcBeforeFile)) {
    @{user_path=[Environment]::GetEnvironmentVariable('Path','User')} | ConvertTo-Json | Set-Content -LiteralPath $fcBeforeFile -Encoding utf8
}
$fcResults = [Collections.Generic.List[object]]::new()
$fcTools = @{}
function Invoke-FcStep([string]$Label,[string]$Command,[string[]]$Arguments) {
    $fcLog = Join-Path $fcLogs ($Label+'.log')
    & $Command @Arguments *> $fcLog
    if ($LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE); see $fcLog" }
}
function Ensure-FcTool([string]$Name,[string]$PackageId) {
    try {
        $fcCommand = Find-FcCommand $Name
        $fcStatus = 'reused'
        if (-not (Test-FcCommand $fcCommand $Name)) {
            $fcWinget = Find-FcCommand 'winget'
            if (-not $fcWinget) { throw "winget is required to install $Name" }
            Invoke-FcStep ('install-'+$Name) $fcWinget @('install','--id',$PackageId,'--exact','--source','winget','--scope','user','--accept-source-agreements','--accept-package-agreements','--disable-interactivity')
            $fcCommand = Find-FcCommand $Name
            if (-not (Test-FcCommand $fcCommand $Name)) { throw "$Name installed but could not run" }
            $fcStatus = 'installed'
        }
        $fcTools[$Name] = $fcCommand
        $fcResults.Add([pscustomobject]@{item=$Name;status=$fcStatus;detail=$fcCommand})
    } catch { $fcResults.Add([pscustomobject]@{item=$Name;status='failed';detail=$_.Exception.Message}) }
}
Ensure-FcTool 'rg' 'BurntSushi.ripgrep.MSVC'
Ensure-FcTool 'fd' 'sharkdp.fd'
Ensure-FcTool 'ffmpeg' 'Gyan.FFmpeg.Essentials'
$fcProbe = Find-FcCommand 'ffprobe'
if (Test-FcCommand $fcProbe 'ffprobe') { $fcTools.ffprobe=$fcProbe }
else { $fcResults.Add([pscustomobject]@{item='ffprobe';status='failed';detail='ffprobe could not run; check the FFmpeg installation'}) }
Ensure-FcTool 'uv' 'astral-sh.uv'
if (-not $fcTools.ContainsKey('uv')) { throw "Python runtime cannot be prepared. Review $fcLogs and rerun." }
$fcPython = Join-Path $fcRuntime '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $fcPython)) {
    if ($SkipDependencies) { throw '-SkipDependencies requires a prepared runtime with .venv\Scripts\python.exe' }
    Invoke-FcStep 'python' $fcTools.uv @('python','install','3.12','--no-bin','--no-registry')
    Invoke-FcStep 'venv' $fcTools.uv @('venv','--python','3.12',(Join-Path $fcRuntime '.venv'))
}
$fcPythonVersion = & $fcPython -c "import sys; print('%d.%d' % sys.version_info[:2])"
if ($LASTEXITCODE -ne 0 -or $fcPythonVersion.Trim() -ne '3.12') { throw 'An incompatible runtime already exists; preserve it and choose another -RuntimeRoot.' }
function Install-FcGroup([string]$Name,[string]$Requirements) {
    try {
        Invoke-FcStep ('pip-'+$Name) $fcTools.uv @('pip','install','--python',$fcPython,'-r',$Requirements)
        $fcResults.Add([pscustomobject]@{item=$Name;status='ready';detail='isolated Python dependencies resolved'})
    } catch { $fcResults.Add([pscustomobject]@{item=$Name;status='failed';detail=$_.Exception.Message}) }
}
if (-not $SkipDependencies) {
    Install-FcGroup 'documents' (Join-Path $fcSource 'requirements-core.txt')
    if (-not $SkipAudio) { Install-FcGroup 'audio' (Join-Path $fcSource 'requirements-audio.txt') }
    if (-not $SkipOcr) {
        try {
            Invoke-FcStep 'pip-paddle-cpu' $fcTools.uv @('pip','install','--python',$fcPython,'paddlepaddle==3.3.0','--index','https://www.paddlepaddle.org.cn/packages/stable/cpu/')
            Install-FcGroup 'ocr' (Join-Path $fcSource 'requirements-ocr.txt')
        } catch { $fcResults.Add([pscustomobject]@{item='ocr';status='failed';detail=$_.Exception.Message}) }
    }
}
try {
    # Prefer a native binary already in this runtime to avoid self-referencing shims.
    $fcAst = $null
    foreach ($fcNativeCandidate in @((Join-Path $fcRuntime 'npm\node_modules\@ast-grep\cli\ast-grep.exe'),(Join-Path $fcRuntime '.venv\Scripts\ast-grep.exe'),(Join-Path $fcRuntime '.venv\Scripts\sg.exe'))) {
        if (Test-FcCommand $fcNativeCandidate 'ast-grep') { $fcAst=$fcNativeCandidate; break }
    }
    if (-not $fcAst) { $fcAst = Find-FcCommand 'ast-grep' }
    if (-not (Test-FcCommand $fcAst 'ast-grep')) { $fcAst=Find-FcCommand 'sg' }
    $fcAstStatus = 'reused'
    if ($fcAst -and $fcAst.StartsWith((Join-Path $fcRuntime 'bin')+'\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'The runtime contains only an old ast-grep shim. Provide a native ast-grep installation before rerunning.'
    }
    if (-not (Test-FcCommand $fcAst 'sg')) {
        if ($SkipDependencies) { throw 'No working ast-grep available and dependency installation was skipped' }
        $fcNpm = Find-FcCommand 'npm'
        if ($fcNpm) {
            Invoke-FcStep 'ast-grep-npm' $fcNpm @('install','--global','--prefix',(Join-Path $fcRuntime 'npm'),'@ast-grep/cli')
            $fcAst = Join-Path $fcRuntime 'npm\node_modules\@ast-grep\cli\ast-grep.exe'
        } else {
            Invoke-FcStep 'ast-grep-pip' $fcTools.uv @('pip','install','--python',$fcPython,'ast-grep-cli')
            $fcAst = Join-Path $fcRuntime '.venv\Scripts\ast-grep.exe'
            if (-not (Test-Path -LiteralPath $fcAst)) { $fcAst=Join-Path $fcRuntime '.venv\Scripts\sg.exe' }
        }
        $fcAstStatus = 'installed'
    }
    if (-not (Test-FcCommand $fcAst 'ast-grep')) { throw 'ast-grep could not run' }
    $fcTools['ast-grep']=$fcAst
    $fcResults.Add([pscustomobject]@{item='ast-grep';status=$fcAstStatus;detail=$fcAst})
} catch { $fcResults.Add([pscustomobject]@{item='ast-grep';status='failed';detail=$_.Exception.Message}) }
if ($fcSkill -ne $fcSource) {
    $fcBackup = Join-Path $fcRuntime ('backups\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path (Join-Path $fcSkill 'scripts') -Force | Out-Null
    foreach ($fcRelative in ($fcManagedFiles + @($fcScriptFiles | ForEach-Object { 'scripts\'+$_.Name }))) {
        $fcFrom = Join-Path $fcSource $fcRelative
        $fcTo = Join-Path $fcSkill $fcRelative
        if (-not (Test-Path -LiteralPath $fcFrom)) { continue }
        if ((Test-Path -LiteralPath $fcTo) -and (Get-FileHash -LiteralPath $fcFrom).Hash -ne (Get-FileHash -LiteralPath $fcTo).Hash) {
            $fcBackupFile = Join-Path $fcBackup $fcRelative
            New-Item -ItemType Directory -Path (Split-Path -Parent $fcBackupFile) -Force | Out-Null
            Copy-Item -LiteralPath $fcTo -Destination $fcBackupFile
        }
        Copy-Item -LiteralPath $fcFrom -Destination $fcTo -Force
    }
}
$fcBin = Join-Path $fcRuntime 'bin'
New-Item -ItemType Directory -Path $fcBin -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $fcSkill 'scripts\entrypoint.py') -Destination (Join-Path $fcRuntime 'entrypoint.py') -Force
$fcState = @{version='0.1.0';skill_directory=$fcSkill;runtime=$fcRuntime;tools=$fcTools;results=$fcResults;
    optional_groups=@{ocr=(-not $SkipOcr);audio=(-not $SkipAudio)}}
$fcState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fcRuntime 'installation.json') -Encoding utf8
function Write-FcLauncher([string]$Name,[string]$Invocation) {
    $fcText = "@echo off`r`nsetlocal`r`nset PYTHONIOENCODING=utf-8`r`n"+$Invocation+" %*`r`n"
    [IO.File]::WriteAllText((Join-Path $fcBin ($Name+'.cmd')),$fcText,[Text.Encoding]::ASCII)
}
foreach ($fcHelper in @('inspect-media','extract-keyframes','contact-sheet','transcribe','batch-ocr','verify')) {
    Write-FcLauncher ('fc-'+$fcHelper) ('"%~dp0..\.venv\Scripts\python.exe" "%~dp0..\entrypoint.py" '+$fcHelper)
}
Write-FcLauncher 'markitdown' '"%~dp0..\.venv\Scripts\markitdown.exe"'
# Preserve existing rg.exe and create a stable hard link when reusing an app-bundled binary.
if ($fcTools.ContainsKey('rg') -and -not (Test-Path -LiteralPath (Join-Path $fcBin 'rg.exe'))) {
    try { New-Item -ItemType HardLink -Path (Join-Path $fcBin 'rg.exe') -Target $fcTools.rg | Out-Null } catch {
        $fcResults.Add([pscustomobject]@{item='rg launcher';status='notice';detail='Use the existing rg command; cross-volume hard link unavailable'})
    }
}
if ($fcTools.ContainsKey('ast-grep')) {
    $fcAstInvocation = '"%~dp0..\.venv\Scripts\python.exe" "%~dp0..\tool-entrypoint.py"'
    $fcToolEntry = @'
import json, subprocess, sys
from pathlib import Path
state = json.loads((Path(__file__).resolve().parent / 'installation.json').read_text(encoding='utf-8-sig'))
raise SystemExit(subprocess.call([state['tools']['ast-grep']] + sys.argv[1:]))
'@
    [IO.File]::WriteAllText((Join-Path $fcRuntime 'tool-entrypoint.py'),$fcToolEntry,[Text.UTF8Encoding]::new($false))
    if ($fcTools['ast-grep'].StartsWith($fcRuntime+'\',[StringComparison]::OrdinalIgnoreCase)) {
        $fcAstInvocation = '"%~dp0..\'+$fcTools['ast-grep'].Substring($fcRuntime.Length+1)+'"'
    }
    foreach ($fcAlias in @('sg','ast-grep')) { Write-FcLauncher $fcAlias $fcAstInvocation }
}
if (-not $NoPath) {
    $fcCurrentPaths = @([Environment]::GetEnvironmentVariable('Path','User') -split ';' | Where-Object { $_ })
    if ($fcCurrentPaths -notcontains $fcBin) {
        [Environment]::SetEnvironmentVariable('Path',(($fcCurrentPaths+$fcBin)-join ';'),'User')
        try {
            if (-not ('FastContext.EnvironmentBroadcast' -as [type])) {
                Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace FastContext {
    public static class EnvironmentBroadcast {
        [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        public static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr parameter,
            string value, uint flags, uint timeout, out UIntPtr result);
    }
}
'@
            }
            $fcBroadcastResult = [UIntPtr]::Zero
            [void][FastContext.EnvironmentBroadcast]::SendMessageTimeout([IntPtr]0xffff,0x1a,[UIntPtr]::Zero,
                'Environment',2,5000,[ref]$fcBroadcastResult)
        } catch {
            $fcResults.Add([pscustomobject]@{item='PATH notification';status='notice';detail='User PATH saved; sign out and back in if new terminals do not see it'})
        }
    }
    $env:Path=$fcBin+';'+[Environment]::GetEnvironmentVariable('Path','User')+';'+$env:Path
}
$env:FAST_CONTEXT_HOME=$fcRuntime
if (-not $NoVerify) {
    & $fcPython (Join-Path $fcSkill 'scripts\verify.py') --output (Join-Path $fcRuntime 'verification.json')
    if ($LASTEXITCODE -ne 0) { $fcResults.Add([pscustomobject]@{item='verification';status='failed';detail='See verification.json and logs; remaining tools may still work'}) }
}
$fcState.results=$fcResults
$fcState | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $fcRuntime 'installation.json') -Encoding utf8
$fcResults | Format-Table item,status,detail -Wrap
Write-Host "Skill: $fcSkill"
Write-Host "Runtime: $fcRuntime"
Write-Host 'Open a new terminal; restart Codex if it still uses the previous PATH.'
if (@($fcResults | Where-Object status -eq 'failed').Count) { exit 1 }
exit 0

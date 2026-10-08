# Windows counterpart of run.sh: launches a fresh, disposable claudecontainer scoped to
# the current directory, through Docker Desktop. Same flags as run.sh (see run.sh's
# header and README.md for what each one does and why) - parsed by hand from $args rather
# than a param() block, so `--continue`-style claude flags pass through untouched:
#
#   cd C:\path\to\project
#   C:\path\to\claudecontainer\run.ps1 [--allow-config] [--continue] ...
#
# Differences from run.sh, all forced by the host being Windows:
#
# - Paths can't be the same on both sides. C:\Users\me\proj is mounted at
#   /c/Users/me/proj, and dev's $HOME is %USERPROFILE% translated the same way. A
#   Claude Code that also runs natively on Windows records Windows paths (plugin
#   installLocation, per-project settings in ~/.claude.json), which won't match the
#   container's - plugins registered natively may need re-registering from inside.
# - No UID/GID remap by default: Windows has no UIDs, and Docker Desktop's bind mounts of
#   Windows folders accept writes from any container user and own the results by you.
#   CONTAINER_UID/CONTAINER_GID (environment or run.local.ps1) still force one.
# - No SSH agent forwarding: the Windows OpenSSH agent is a named pipe, which can't be
#   mounted into a Linux container. Use HTTPS remotes (gh auth) inside instead.
# - --sysbox is refused: sysbox can't be installed into Docker Desktop's VM.
# - --host-network shares the network of Docker Desktop's VM, not of Windows itself.
#
# A project that lives inside a WSL distro (\\wsl.localhost\...) is refused - open a WSL
# shell there and use run.sh instead; it's also much faster, since bind mounts of Windows
# drives go through a file-sharing layer that's slow on big trees (node_modules, .venv).
#
# Windows PowerShell 5.1 mangles embedded double quotes in arguments passed to native
# programs (docker.exe here), so a forwarded argument like `-p 'say "hi"'` may arrive
# altered. Plain arguments, including ones with spaces, are fine.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Captured first: dot-sourced helpers below get their own $args.
$cliArgs = @($args)

. (Join-Path $PSScriptRoot 'windows-common.ps1')
Assert-Windows

function Fail([string]$msg) {
  [Console]::Error.WriteLine("run.ps1: $msg")
  exit 1
}

# C:\Users\me\proj -> /c/Users/me/proj. Relative paths resolve against PowerShell's
# current location (not .NET's process cwd, which PowerShell doesn't keep in sync).
function Resolve-HostPath([string]$path) {
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
}
function ConvertTo-ContainerPath([string]$winPath) {
  if ($winPath -match '^([A-Za-z]):[\\/]?(.*)$') {
    $rest = ($Matches[2] -replace '\\', '/').TrimEnd('/')
    $drive = $Matches[1].ToLower()
    if ($rest) { return "/$drive/$rest" }
    return "/$drive"
  }
  Fail "can't map '$winPath' into the container - only drive-letter paths (C:\...) are supported, not UNC/network or WSL paths."
}

# One `docker run --mount` bind, from a Windows host path. --mount rather than -v: -v's
# colon-separated syntax collides with the drive letter's colon, and -v silently
# creates a missing source as an empty directory (the root-owned ~/.claude.json
# problem from README.md) where --mount refuses to start instead.
function Add-Bind([string]$hostPath, [string]$target, [switch]$ReadOnly) {
  if ($hostPath.Contains(',') -or $target.Contains(',')) {
    Fail "paths containing ',' can't be mounted (docker --mount syntax): $hostPath"
  }
  if (-not (Test-Path -LiteralPath $hostPath)) {
    Fail "mount source doesn't exist: $hostPath"
  }
  $spec = "type=bind,source=$hostPath,target=$target"
  if ($ReadOnly) { $spec += ',readonly' }
  $script:dockerArgs.Add('--mount')
  $script:dockerArgs.Add($spec)
}

# --mount / EXTRA_MOUNTS spec: host[:container][:ro|rw]. The drive letter's own colon
# is part of the host path, so this can't just split on ':' like run.sh. A bare path
# mounts at its translated container path, read-write. `C:\data:ro` (no container path)
# is accepted too, as same-path read-only.
function Add-MountSpec([string]$spec, [string]$origin) {
  if ($spec -notmatch '^(?<host>(?:[A-Za-z]:)?[^:]+)(?::(?<target>/[^:]*))?(?::(?<mode>ro|rw))?$') {
    Fail "invalid mount '$spec' ($origin) - expected host[:container][:ro], e.g. C:\data or C:\data:/data:ro"
  }
  $hostPath = Resolve-HostPath $Matches['host']
  $target = $Matches['target']
  $mode = $Matches['mode']
  if (-not $target) { $target = ConvertTo-ContainerPath $hostPath }
  Add-Bind $hostPath $target -ReadOnly:($mode -eq 'ro')
}

$hostNetwork = $false
$showHelp = $false
$allowList = ''
$allowInternet = $false
$allowContainer = $false
$allowConfig = $false
$sysbox = $false
$cliMounts = New-Object System.Collections.Generic.List[string]
$forward = New-Object System.Collections.Generic.List[string]

$i = 0
while ($i -lt $cliArgs.Count) {
  $a = [string]$cliArgs[$i]
  switch -CaseSensitive ($a) {
    '--host-network'    { $hostNetwork = $true; $i++; continue }
    { $_ -eq '-h' -or $_ -eq '--help' } { $showHelp = $true; $i++; continue }
    '--allow-internet'  { $allowInternet = $true; $i++; continue }
    '--allow-container' { $allowContainer = $true; $i++; continue }
    '--allow-config'    { $allowConfig = $true; $i++; continue }
    '--sysbox'          { $sysbox = $true; $i++; continue }
    '--allow-list' {
      if ($i + 1 -ge $cliArgs.Count) { Fail '--allow-list requires a path argument' }
      $allowList = [string]$cliArgs[$i + 1]; $i += 2; continue
    }
    '--mount' {
      if ($i + 1 -ge $cliArgs.Count) { Fail '--mount requires a host path, or host:container[:ro], argument' }
      $cliMounts.Add([string]$cliArgs[$i + 1]); $i += 2; continue
    }
    default { $forward.Add($a); $i++ }
  }
}

if ($allowList -and $allowInternet) { Fail '--allow-list and --allow-internet are mutually exclusive' }
if ($allowList) {
  $allowList = Resolve-HostPath $allowList
  if (-not (Test-Path -LiteralPath $allowList -PathType Leaf)) { Fail "--allow-list file not found: $allowList" }
}
if ($sysbox) {
  Fail '--sysbox is not available with Docker Desktop (sysbox-runc cannot be installed into its VM). Use run.sh on a Linux host for that.'
}

$location = Get-Location
if ($location.Provider.Name -ne 'FileSystem') { Fail "current location isn't a filesystem path: $location" }
$projectDir = $location.ProviderPath
if ($projectDir.StartsWith('\\')) {
  Fail ("$projectDir is a UNC/network path. If it's inside WSL (\\wsl.localhost\...), open a " +
    "WSL shell there and run claudecontainer/run.sh instead - same image, native paths, much faster.")
}
$projectTarget = ConvertTo-ContainerPath $projectDir

# Native Claude Code on Windows keeps its login/config under %USERPROFILE%, same layout
# as ~ on Linux/macOS.
$hostHome = $env:USERPROFILE
$homeTarget = ConvertTo-ContainerPath $hostHome
$claudeDir = Join-Path $hostHome '.claude'
$claudeJson = Join-Path $hostHome '.claude.json'

# See run.sh. Extendable from run.local.ps1: $CLAUDE_CONFIG_RO_PATHS += 'statusline.ps1'
$CLAUDE_CONFIG_RO_PATHS = @(
  'settings.json', 'settings.local.json', 'CLAUDE.md', 'keybindings.json',
  'agents', 'commands', 'skills', 'hooks', 'plugins', 'output-styles'
)
$EXTRA_MOUNTS = @()
$CONTAINER_UID = $env:CONTAINER_UID
$CONTAINER_GID = $env:CONTAINER_GID
$localConfig = Join-Path $PSScriptRoot 'run.local.ps1'
if (Test-Path $localConfig) { . $localConfig }

# See run.sh's remap block and the header comment above: off unless forced.
$remapUid = ''
$remapGid = ''
if ($CONTAINER_UID -and $CONTAINER_UID -ne 'off') {
  $remapUid = [string]$CONTAINER_UID
  $remapGid = [string]$CONTAINER_GID
  if (-not $remapGid) { $remapGid = $remapUid }
  if ($remapUid -notmatch '^[0-9]+$' -or $remapGid -notmatch '^[0-9]+$' -or [int64]$remapUid -eq 0 -or [int64]$remapGid -eq 0) {
    Fail "CONTAINER_UID/CONTAINER_GID must be non-zero numbers, or CONTAINER_UID=off (got '$remapUid'/'$remapGid')"
  }
  $remapDesc = "${remapUid}:${remapGid} (set by CONTAINER_UID/CONTAINER_GID)"
} else {
  $remapDesc = 'off (Windows host - dev stays 1000:1000)'
}

if ($showHelp) {
  if ($hostNetwork) { $netDesc = "host (--host-network passed - Docker Desktop VM's network, not Windows')" }
  else { $netDesc = 'bridge (default; pass --host-network to change)' }
  if ($allowInternet) { $listDesc = 'DISABLED (--allow-internet passed - any host reachable via the proxy)' }
  elseif ($allowList) { $listDesc = "$allowList (--allow-list passed, overrides image default)" }
  else { $listDesc = 'image default (allowed-domains.txt baked in at build; pass --allow-list to override)' }
  if ($allowContainer) { $sockDesc = "Docker Desktop's /var/run/docker.sock (--allow-container passed - root-equivalent access to its VM and every container in it)" }
  else { $sockDesc = 'sandboxed nested dockerd only (default; pass --allow-container to use the host daemon)' }
  if ($allowConfig) { $cfgDesc = 'WRITABLE (--allow-config passed - edits persist on the host)' }
  else { $cfgDesc = "read-only (default; pass --allow-config to let claude change it)" }

  @"
Usage: run.ps1 [--host-network] [--allow-list <path> | --allow-internet] [--allow-container]
               [--allow-config] [--mount <path|host:container[:ro]>]... [-h|--help] [claude-args... | command...]

Windows/Docker Desktop version of run.sh - same flags, see run.sh --help or README.md
for what each one does. --sysbox isn't available here. Mount specs take Windows host
paths: C:\data (-> /c/data, read-write), C:\data:/data, C:\data:/data:ro.

Anything else starting with '-' is forwarded to ``claude`` itself (e.g. --continue).
A bare command (e.g. ``run.ps1 bash``) overrides the default ``claude`` invocation.

Effective config on this machine:
  Image:          claudecontainer:latest
  Network:        $netDesc
  Runtime:        --privileged (sysbox not available on Docker Desktop)
  Allowlist:      $listDesc
  Docker socket:  $sockDesc
  Claude config:  $cfgDesc
  dev UID:GID:    $remapDesc
  Mounts:
    $projectDir -> $projectTarget
    $claudeDir -> $homeTarget/.claude (dev's `$HOME is $homeTarget)
"@ | Write-Host
  if ($allowConfig) {
    Write-Host "    $claudeJson -> $homeTarget/.claude.json"
  } else {
    foreach ($entry in $CLAUDE_CONFIG_RO_PATHS) {
      if (Test-Path -LiteralPath (Join-Path $claudeDir $entry)) {
        Write-Host "    $(Join-Path $claudeDir $entry) -> $homeTarget/.claude/$entry (ro)"
      }
    }
    Write-Host "    $claudeJson -> copied in from a ro mount (edits discarded on exit)"
  }
  Write-Host '    (no SSH agent forwarding on Windows - use HTTPS remotes / gh auth inside)'
  if (@($EXTRA_MOUNTS).Count -gt 0) {
    foreach ($m in $EXTRA_MOUNTS) { Write-Host "    $m (from run.local.ps1)" }
  } else {
    Write-Host '    (no run.local.ps1 extra mounts)'
  }
  foreach ($m in $cliMounts) { Write-Host "    $m (from --mount)" }
  exit 0
}

Assert-DockerCli
# No auto-start here (unlike build.ps1): a launcher silently spending a minute or two
# booting Docker Desktop is more confusing than a clear "start Docker Desktop" error.
try {
  Wait-DockerDaemon
  Assert-LinuxEngine
} catch {
  Fail $_.Exception.Message
}
if (-not (Invoke-NativeQuiet docker.exe @('image', 'inspect', 'claudecontainer:latest'))) {
  Fail "image claudecontainer:latest not found - run $(Join-Path $PSScriptRoot 'build.ps1') first."
}

# First run without Claude Code on the host (README.md): --mount would refuse to start
# on a missing source anyway, so create the two login paths up front instead of making
# the user do it by hand. '{}' is what an empty ~/.claude.json should contain.
if (-not (Test-Path -LiteralPath $claudeDir)) {
  Write-Host "Creating $claudeDir (first run - log in with --allow-config once, see README.md)"
  $null = New-Item -ItemType Directory -Path $claudeDir
}
if (Test-Path -LiteralPath $claudeJson -PathType Container) {
  Fail "$claudeJson is a directory (left over from a failed earlier mount?) - remove it and retry."
}
if (-not (Test-Path -LiteralPath $claudeJson)) {
  [IO.File]::WriteAllText($claudeJson, '{}')
}

$dockerArgs = New-Object System.Collections.Generic.List[string]
$dockerArgs.AddRange([string[]]@('--rm', '-it', '-w', $projectTarget, '-e', "HOST_HOME=$homeTarget"))
Add-Bind $projectDir $projectTarget
Add-Bind $claudeDir "$homeTarget/.claude"

if ($remapUid) {
  $dockerArgs.AddRange([string[]]@('-e', "HOST_UID=$remapUid", '-e', "HOST_GID=$remapGid"))
}

# See run.sh: per-entry ro mounts nest inside the rw ~/.claude mount; ~/.claude.json is
# staged ro and copied into the container's writable layer by entrypoint.sh.
if ($allowConfig) {
  Add-Bind $claudeJson "$homeTarget/.claude.json"
} else {
  foreach ($entry in $CLAUDE_CONFIG_RO_PATHS) {
    $p = Join-Path $claudeDir $entry
    if (Test-Path -LiteralPath $p) { Add-Bind $p "$homeTarget/.claude/$entry" -ReadOnly }
  }
  Add-Bind $claudeJson '/etc/claudecontainer/claude.json.host' -ReadOnly
}

# No sysbox on Docker Desktop (refused above), so always --privileged for the nested
# dockerd. Note this is privileged within Docker Desktop's VM, not over Windows itself.
$dockerArgs.Add('--privileged')

if ($hostNetwork) { $dockerArgs.AddRange([string[]]@('--network', 'host')) }

if ($allowList) {
  Add-Bind $allowList '/etc/squid/allowed-domains.override.txt' -ReadOnly
}
if ($allowInternet) { $dockerArgs.AddRange([string[]]@('-e', 'SQUID_ALLOW_INTERNET=1')) }

# Docker Desktop exposes its daemon socket at /var/run/docker.sock inside its VM, so the
# Linux-style path is right even from a Windows CLI. -v rather than Add-Bind: the source
# is a path inside the VM, not on Windows, so it can't be Test-Path'ed here.
if ($allowContainer) {
  $dockerArgs.AddRange([string[]]@('-v', '/var/run/docker.sock:/var/run/docker.sock', '-e', 'ALLOW_CONTAINER=1'))
}

foreach ($m in @($EXTRA_MOUNTS)) { Add-MountSpec ([string]$m) 'run.local.ps1' }
foreach ($m in $cliMounts) { Add-MountSpec $m '--mount' }

$dockerArgs.Add('claudecontainer:latest')
$dockerArgs.AddRange($forward)

$finalArgs = $dockerArgs.ToArray()
& docker.exe run @finalArgs
exit $LASTEXITCODE

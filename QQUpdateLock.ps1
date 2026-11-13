#Requires -Version 5.1
<#
    QQ 更新锁 / QQUpdateLock
    ---------------------------------------------------------------
    用途：让 QQNT 停在当前版本，关闭启动时的热更新自动下载与自动升级。

    设计要点（为了能在别人的机器上直接跑）：
      * 不硬编码任何版本号：安装位置、当前版本、要拦截的版本全部自动识别
      * 不硬编码安装路径：注册表卸载项 + 运行中进程 + 常见目录，自动定位 QQNT
      * 只改 QQ 自己的运行时状态文件 versions\config.json，不碰任何受签名
        保护的文件（application.asar / wrapper.node / major.node / QQNT.dll）
      * 需要时自动请求管理员权限，无需手动右键

    用法：
      QQUpdateLock.ps1 -Action off      关闭更新（锁定到当前版本）
      QQUpdateLock.ps1 -Action on       恢复更新
      QQUpdateLock.ps1 -Action status   查看状态

    可选参数：
      -InstallRoot <路径>   手动指定 QQNT 目录（自动识别失败时用）
      -PinVersion <版本>    手动指定要停留的版本，如 9.9.36-53644
      -Backstop acl         额外启用文件系统兜底（连将来新版本都下不下来）
      -Force                不询问，直接关闭正在运行的 QQ
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('off', 'on', 'status')]
    [string]$Action = 'off',

    [string]$InstallRoot,
    [string]$PinVersion,

    # 锁定层级：ask = 交互询问；none = 仅黑名单；acl = 黑名单 + 文件系统兜底
    [ValidateSet('ask', 'none', 'acl')]
    [string]$Backstop = 'ask',

    [switch]$Force,
    [switch]$FromElevated
)

$ErrorActionPreference = 'Stop'

$ScriptDir  = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$StateFile  = Join-Path $ScriptDir 'lock-state.json'
$Utf8NoBom  = New-Object System.Text.UTF8Encoding($false)
$VerPattern = '\d+\.\d+\.\d+-\d+'

# ============================================================ 基础工具

function Write-Step([string]$Text) { Write-Host "  $Text" }
function Write-Ok([string]$Text)   { Write-Host "  [OK] $Text" -ForegroundColor Green }
function Write-Warn2([string]$Text){ Write-Host "  [!]  $Text" -ForegroundColor Yellow }
function Write-Bad([string]$Text)  { Write-Host "  [X]  $Text" -ForegroundColor Red }
function Write-Head([string]$Text) { Write-Host "`n$Text" -ForegroundColor Cyan }

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $false }
}

function Test-CanWriteDir([string]$Dir) {
    # 优先用"打开已有 config.json 请求写权限"来判定。
    # 不用"新建文件"来探测——文件系统兜底(ACL)本身就会禁止新建，会造成误判。
    $cfg = Join-Path $Dir 'config.json'
    if (Test-Path $cfg) {
        try {
            $fs = New-Object System.IO.FileStream($cfg, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $fs.Dispose()
            return $true
        } catch { return $false }
    }
    try {
        $probe = Join-Path $Dir ('.~wlock_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [System.IO.File]::WriteAllText($probe, 'x', $Utf8NoBom)
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Read-TextShared([string]$Path) {
    # QQ 可能正持有这些文件，允许共享读取
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, $true)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function Read-Json([string]$Path) {
    $raw = Read-TextShared $Path
    if (-not $raw) { return $null }
    $raw = $raw.TrimStart([char]0xFEFF)
    if (-not $raw.Trim()) { return $null }
    try { return ($raw | ConvertFrom-Json) } catch { return $null }
}

function Write-JsonNoBom([string]$Path, $Object) {
    $json = $Object | ConvertTo-Json -Depth 10
    # PS 5.1 会把空数组/空对象输出成多行，压回 [] 和 {} 便于阅读
    $json = [regex]::Replace($json, '(?s)\[\s*\]', '[]')
    $json = [regex]::Replace($json, '(?s)\{\s*\}', '{}')
    [System.IO.File]::WriteAllText($Path, $json, $Utf8NoBom)
}

function Set-Prop($Obj, [string]$Name, $Value) {
    if ($null -eq $Obj) { return }
    if ($Obj.PSObject.Properties[$Name]) { $Obj.$Name = $Value }
    else { $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Remove-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return }
    if ($Obj.PSObject.Properties[$Name]) { $Obj.PSObject.Properties.Remove($Name) }
}

function Get-Prop($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties[$Name]) { return $Obj.$Name }
    return $null
}

function Get-AllVersions([string]$Text) {
    # 从一个名字/一行日志里提取所有 x.y.z-nnnn 形式的版本号
    if (-not $Text) { return @() }
    $m = [regex]::Matches($Text, $VerPattern)
    $out = @()
    foreach ($x in $m) { $out += $x.Value }
    return $out
}

# ============================================================ 定位 QQNT

function Get-QQRoots {
    $cand = New-Object System.Collections.Generic.List[string]

    if ($InstallRoot) {
        $cand.Add($InstallRoot.TrimEnd('\', '/'))
    }

    # 1) 正在运行的 QQ
    foreach ($p in (Get-Process -Name 'QQ', 'QQEX' -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path) {
                $cand.Add((Split-Path -Parent $p.Path).TrimEnd('\'))
            }
        } catch { }
    }

    # 2) 注册表卸载项里的安装位置
    $uninstallKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($k in $uninstallKeys) {
        try {
            Get-ItemProperty $k -ErrorAction SilentlyContinue |
                Where-Object { $_.PSObject.Properties['InstallLocation'] -and $_.InstallLocation -and $_.InstallLocation -match 'QQ' } |
                ForEach-Object { $cand.Add($_.InstallLocation.TrimEnd('\')) }
        } catch { }
    }

    # 3) 常见安装位置
    $bases = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:ProgramData)
    foreach ($b in $bases) {
        if (-not $b) { continue }
        $cand.Add((Join-Path $b 'Tencent\QQNT'))
        $cand.Add((Join-Path $b 'Tencent\QQ'))
    }
    $cand.Add('C:\Program Files\Tencent\QQNT')
    $cand.Add('C:\Program Files (x86)\Tencent\QQNT')

    # 4) 去重 + 校验（必须同时有 QQ.exe 和 versions 目录）
    $seen = @{}
    $roots = @()
    foreach ($c in $cand) {
        if (-not $c) { continue }
        $key = $c.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $hasExe = Test-Path (Join-Path $c 'QQ.exe')
        $hasVer = Test-Path (Join-Path $c 'versions')
        if ($hasExe -and $hasVer) { $roots += $c }
    }
    return $roots
}

function Get-VersionDirs([string]$Root) {
    $vdir = Join-Path $Root 'versions'
    if (-not (Test-Path $vdir)) { return @() }
    @(Get-ChildItem $vdir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match "^$VerPattern$" } |
        Select-Object -ExpandProperty Name)
}

function Get-FileVersionTag([string]$Root) {
    $exe = Join-Path $Root 'QQ.exe'
    if (-not (Test-Path $exe)) { return $null }
    try {
        $fv = (Get-Item $exe).VersionInfo.FileVersion
        if ($fv -match '^(\d+)\.(\d+)\.(\d+)\.(\d+)$') {
            return ('{0}.{1}.{2}-{3}' -f $Matches[1], $Matches[2], $Matches[3], $Matches[4])
        }
    } catch { }
    return $null
}

function Resolve-PinVersion([string]$Root) {
    if ($PinVersion) { return $PinVersion }

    $cfgPath = Join-Path $Root 'versions\config.json'
    $cfg = Read-Json $cfgPath
    $cur = Get-Prop $cfg 'curVersion'
    if ($cur -and (Test-Path (Join-Path $Root "versions\$cur"))) { return $cur }

    $dirs = Get-VersionDirs $Root
    if ($dirs.Count -gt 0) {
        # 取版本号最大者
        $best = $null; $bestKey = $null
        foreach ($d in $dirs) {
            if ($d -match '^(\d+)\.(\d+)\.(\d+)-(\d+)$') {
                $key = '{0:D4}{1:D4}{2:D4}{3:D6}' -f [int]$Matches[1], [int]$Matches[2], [int]$Matches[3], [int]$Matches[4]
                if (-not $bestKey -or $key -gt $bestKey) { $bestKey = $key; $best = $d }
            }
        }
        if ($best) { return $best }
    }
    return (Get-FileVersionTag $Root)
}

# ============================================================ 版本黑名单收集

function Get-UpdaterLogPaths {
    $out = @()
    $dir = Join-Path $env:APPDATA 'QQ\log'
    if (Test-Path $dir) {
        $out += (Get-ChildItem $dir -Filter 'updater*.log' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
        $out += (Get-ChildItem $dir -Filter 'app_launcher-*.log' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
    }
    return $out
}

function Get-BlockedFromLogs {
    $found = New-Object System.Collections.Generic.List[string]
    foreach ($log in (Get-UpdaterLogPaths)) {
        try {
            $lines = Get-Content $log -Tail 600 -ErrorAction SilentlyContinue
        } catch { continue }
        if (-not $lines) { continue }
        foreach ($ln in $lines) {
            # hotUpdateApi start check  9.9.37-54395  IsOnErrorVersion
            $m = [regex]::Match($ln, 'start check\s+(' + $VerPattern + ')')
            if ($m.Success) { $found.Add($m.Groups[1].Value); continue }
            # newVersion: '9.9.37-54395'
            $m = [regex]::Match($ln, "newVersion:\s*'(" + $VerPattern + ")'")
            if ($m.Success) { $found.Add($m.Groups[1].Value); continue }
            # 命中启动热更策略-hotUpdate cur:..., ready: 9.9.37-54395
            $m = [regex]::Match($ln, 'ready:\s*(' + $VerPattern + ')')
            if ($m.Success) { $found.Add($m.Groups[1].Value); continue }
            # onUpdateDownloaded ...9.9.37-54395.zip
            $m = [regex]::Match($ln, '(' + $VerPattern + ')\.zip')
            if ($m.Success) { $found.Add($m.Groups[1].Value) }
        }
    }
    return @($found)
}

function Get-BlockedVersions([string]$Root, [string]$Pin) {
    $found = New-Object System.Collections.Generic.List[string]

    function Add-One($v) {
        if (-not $v) { return }
        if ($v -eq $Pin) { return }
        if ($v -notmatch "^$VerPattern$") { return }
        if (-not $found.Contains($v)) { $found.Add($v) }
    }

    # 1) 现有 config.json 的 readyVersion / onErrorVersions
    $cfg = Read-Json (Join-Path $Root 'versions\config.json')
    Add-One (Get-Prop $cfg 'readyVersion')
    $old = Get-Prop $cfg 'onErrorVersions'
    if ($old) { foreach ($v in @($old)) { Add-One $v } }

    # 2) versions 下已有的非当前版本目录（含 a-b 形式补丁工作目录）
    foreach ($d in (Get-VersionDirs $Root)) {
        $all = Get-AllVersions $d
        if ($all.Count -gt 0) { Add-One $all[$all.Count - 1] }
    }

    # 3) 已下载的更新包
    $vdir = Join-Path $Root 'versions'
    foreach ($z in (Get-ChildItem $vdir -File -Filter '*.zip' -ErrorAction SilentlyContinue)) {
        $all = Get-AllVersions $z.BaseName
        if ($all.Count -gt 0) { Add-One $all[$all.Count - 1] }
    }

    # 4) 日志里 QQ 自己说过要升到的版本（新机器首次运行时最关键）
    foreach ($v in (Get-BlockedFromLogs)) { Add-One $v }

    # 5) 上次运行累积的黑名单
    $st = Read-Json $StateFile
    $prev = Get-Prop $st 'blockedVersions'
    if ($prev) { foreach ($v in @($prev)) { Add-One $v } }

    # 用一元逗号防止 PowerShell 把单元素列表展开成字符串
    return ,$found
}

# ============================================================ 配置读写

function New-DefaultConfig([string]$Pin) {
    $buildId = ''
    if ($Pin -match '-(\d+)$') { $buildId = $Matches[1] }
    [pscustomobject]@{
        baseVersion     = $Pin
        curVersion      = $Pin
        prevVersion     = ''
        onErrorVersions = @()
        buildId         = $buildId
        unzipRetryCount = 0
    }
}

function Update-VersionsConfig([string]$Root, [string]$Pin, [string[]]$Blocked, [switch]$ClearBlocked) {
    $path = Join-Path $Root 'versions\config.json'
    $cfg  = Read-Json $path
    if (-not $cfg) { $cfg = New-DefaultConfig $Pin }

    Set-Prop $cfg 'baseVersion' $Pin
    Set-Prop $cfg 'curVersion'  $Pin
    if (-not (Get-Prop $cfg 'prevVersion')) { Set-Prop $cfg 'prevVersion' '' }
    if (-not (Get-Prop $cfg 'buildId')) {
        $buildId = ''
        if ($Pin -match '-(\d+)$') { $buildId = $Matches[1] }
        Set-Prop $cfg 'buildId' $buildId
    }
    if ($null -eq (Get-Prop $cfg 'unzipRetryCount')) { Set-Prop $cfg 'unzipRetryCount' 0 }

    if ($ClearBlocked) {
        Set-Prop $cfg 'onErrorVersions' @()
    } else {
        $list = @()
        foreach ($v in @($Blocked)) { if ($v) { $list += $v } }
        Set-Prop $cfg 'onErrorVersions' $list
    }

    # 清掉“待应用”状态，否则启动器会在下次启动时切到新版本
    Remove-Prop $cfg 'readyVersion'
    Remove-Prop $cfg 'readyInstaller'
    Remove-Prop $cfg 'readyType'

    Write-JsonNoBom $path $cfg
    return $path
}

# ============================================================ 锁定层级选择

function Get-SavedBackstop {
    # 返回上次选择：'acl' | 'none' | $null
    $st = Read-Json $StateFile
    if (-not $st) { return $null }
    $b = Get-Prop $st 'backstop'
    if ($b -eq 'acl' -or $b -eq 'none') { return $b }
    return $null
}

function Test-CanPrompt {
    # 双击 .cmd / 真实控制台才询问；重定向、计划任务等场景不询问
    try {
        if ([Console]::IsInputRedirected) { return $false }
        return [Environment]::UserInteractive
    } catch { return $false }
}

function Resolve-Backstop {
    switch ($Backstop) {
        'acl'  { return 'acl' }
        'none' { return 'none' }
    }

    $saved = Get-SavedBackstop
    $default = if ($saved) { $saved } else { 'none' }

    if (-not (Test-CanPrompt)) {
        Write-Step ("未交互运行，沿用上次层级：{0}" -f (Get-BackstopName $default))
        return $default
    }

    Write-Host ''
    Write-Host '  选择锁定层级：' -ForegroundColor Yellow
    Write-Host '  ------------------------------------------------------------------'
    Write-Host '   [1] 仅黑名单（推荐）'
    Write-Host '       把目标版本写进 QQ 自己的 onErrorVersions，更新在下载前终止。'
    Write-Host '       versions 目录零改动，不涉及任何权限，不影响卸载/修复/安装。'
    Write-Host ''
    Write-Host '   [2] 黑名单 + 文件系统兜底'
    Write-Host '       额外给 versions 目录加拒绝规则：禁止新建文件和子目录。'
    Write-Host '       连将来全新版本号的更新包都落不了盘（连流量都不走）。'
    Write-Host '       代价：卸载 / 修复 / 覆盖安装 QQ 前必须先"恢复更新"。'
    Write-Host '  ------------------------------------------------------------------'
    $hint = if ($default -eq 'acl') { '（默认 2）' } else { '（默认 1）' }
    for ($i = 0; $i -lt 5; $i++) {
        $ans = Read-Host "  请输入 1 或 2 $hint"
        $ans = "$ans".Trim()
        if ($ans -eq '') { return $default }
        if ($ans -eq '1') { return 'none' }
        if ($ans -eq '2') { return 'acl' }
        Write-Warn2 '只能输入 1 或 2。'
    }
    Write-Warn2 "多次无效输入，采用默认层级：$(Get-BackstopName $default)"
    return $default
}

function Get-BackstopName([string]$Mode) {
    if ($Mode -eq 'acl') { return '黑名单 + 文件系统兜底' }
    return '仅黑名单'
}

# ============================================================ ACL 兜底

$script:DenyRights = 6   # CreateFiles(2) | CreateDirectories(4)

function Get-DenyRules([string]$Dir) {
    try { $acl = Get-Acl $Dir } catch { return @() }
    @($acl.Access | Where-Object {
        $_.AccessControlType -eq 'Deny' -and -not $_.IsInherited -and
        [int]$_.FileSystemRights -eq $script:DenyRights
    })
}

function Add-CreateDeny([string]$Dir) {
    $acl = Get-Acl $Dir
    # 注意：-bor 不能内联写在 New-Object 的参数里，会被当成参数解析而失败
    $rights = [System.Security.AccessControl.FileSystemRights]::CreateFiles -bor
              [System.Security.AccessControl.FileSystemRights]::CreateDirectories
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        "$env:USERNAME", $rights,
        [System.Security.AccessControl.InheritanceFlags]::None,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Deny)
    $acl.AddAccessRule($rule)
    Set-Acl -Path $Dir -AclObject $acl
}

function Remove-CreateDeny([string]$Dir) {
    $rules = Get-DenyRules $Dir
    if ($rules.Count -eq 0) { return $false }
    $acl = Get-Acl $Dir
    foreach ($r in $rules) {
        try { $acl.RemoveAccessRuleSpecific($r) | Out-Null } catch { }
    }
    Set-Acl -Path $Dir -AclObject $acl
    return $true
}

# ============================================================ QQ 进程

function Get-QQProcesses { @(Get-Process -Name 'QQ', 'QQEX' -ErrorAction SilentlyContinue) }

function Close-QQ {
    $p = Get-QQProcesses
    if ($p.Count -eq 0) { return }

    if (-not $Force) {
        $interactive = $false
        try { $interactive = -not [Console]::IsInputRedirected } catch { }
        if ($interactive) {
            $ans = Read-Host "  检测到 QQ 正在运行（$($p.Count) 个进程），需要先退出。现在自动关闭吗？[Y/n]"
            if ($ans -and $ans.Trim() -notmatch '^(y|Y|yes|YES|是)$') {
                throw '已取消：QQ 仍在运行。'
            }
        }
    }

    Write-Step "关闭 QQ（$($p.Count) 个进程）..."
    $p | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 300
        if ((Get-QQProcesses).Count -eq 0) { return }
    }
    throw '无法结束 QQ 进程，请手动退出后重试。'
}

# ============================================================ 权限提升

function Invoke-Elevate {
    if ($FromElevated) { return $false }
    if (Test-IsAdmin) { return $false }

    Write-Warn2 '当前权限不足，正在请求管理员权限...'
    $argStr = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" -Action {1} -FromElevated' -f $PSCommandPath, $Action
    if ($InstallRoot) { $argStr += ' -InstallRoot "{0}"' -f $InstallRoot }
    if ($PinVersion)  { $argStr += ' -PinVersion "{0}"'  -f $PinVersion }
    if ($Backstop)    { $argStr += ' -Backstop {0}'      -f $Backstop }
    if ($Force)       { $argStr += ' -Force' }

    try {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argStr -Verb RunAs -ErrorAction Stop
        Write-Step '已在新窗口中以管理员身份继续，本窗口结束。'
        Start-Sleep -Milliseconds 800
        exit 0
    } catch {
        Write-Bad '提权被取消或失败，请右键“以管理员身份运行”。'
        exit 1
    }
}

# ============================================================ 主流程

function Get-LockInfo([string]$Root) {
    $vdir = Join-Path $Root 'versions'
    $cfg  = Read-Json (Join-Path $vdir 'config.json')
    $block = @()
    $raw = Get-Prop $cfg 'onErrorVersions'
    if ($raw) { $block = @($raw | Where-Object { $_ }) }

    $ready = Get-Prop $cfg 'readyVersion'
    $readyDir = $false
    if ($ready) { $readyDir = Test-Path (Join-Path $vdir $ready) }

    [pscustomobject]@{
        Root    = $Root
        Cur     = Get-Prop $cfg 'curVersion'
        Ready   = $ready
        ReadyDir = $readyDir
        Blocked = $block
        Acl     = ((Get-DenyRules $vdir).Count -gt 0)
        Zips    = @(Get-ChildItem $vdir -File -Filter '*.zip' -ErrorAction SilentlyContinue)
        Dirs    = @(Get-VersionDirs $Root)
        HasCfg  = ($null -ne $cfg)
    }
}

function Get-LockGrade($Info) {
    # strong       = 黑名单 + 文件系统兜底
    # blacklist    = 只有黑名单
    # strong-only  = 只有 ACL，黑名单空
    # none         = 没锁
    if ($Info.Acl -and $Info.Blocked.Count -gt 0) { return 'strong' }
    if ($Info.Acl) { return 'strong-only' }
    if ($Info.Blocked.Count -gt 0) { return 'blacklist' }
    return 'none'
}

function Write-LockBanner($Info) {
    $grade = Get-LockGrade $Info
    $bar = '=' * 60

    switch ($grade) {
        'strong' {
            Write-Host "  $bar" -ForegroundColor Green
            Write-Host '    已锁定  ·  文件强锁' -ForegroundColor Green
            Write-Host ("    黑名单 + 目录写保护：停在 {0}，更新包既不下、也写不进盘" -f $Info.Cur) -ForegroundColor Green
            Write-Host "  $bar" -ForegroundColor Green
        }
        'blacklist' {
            Write-Host "  $bar" -ForegroundColor Green
            Write-Host '    已锁定  ·  仅黑名单锁' -ForegroundColor Green
            Write-Host ("    停在 {0}：已知新版本在下载前就被拦下（目录写保护未开）" -f $Info.Cur) -ForegroundColor Green
            Write-Host "  $bar" -ForegroundColor Green
        }
        'strong-only' {
            Write-Host "  $bar" -ForegroundColor Yellow
            Write-Host '    已锁定  ·  文件强锁（但黑名单为空）' -ForegroundColor Yellow
            Write-Host '    目录写保护生效，却没有记录要拦的版本，建议重跑一次「关闭更新」' -ForegroundColor Yellow
            Write-Host "  $bar" -ForegroundColor Yellow
        }
        default {
            Write-Host "  $bar" -ForegroundColor Red
            Write-Host '    未锁定  ·  QQ 会照常自动下载并升级' -ForegroundColor Red
            Write-Host '    想锁住就运行「关闭更新」。' -ForegroundColor Red
            Write-Host "  $bar" -ForegroundColor Red
        }
    }
}

function Write-LockDetail($Info) {
    if ($Info.Cur) {
        Write-Host ("    当前版本   : {0}" -f $Info.Cur)
    } else {
        Write-Host '    当前版本   : <未知>'
    }

    if ($Info.Blocked.Count -gt 0) {
        Write-Host ("    拦截版本   : {0}" -f ($Info.Blocked -join ', '))
    } else {
        Write-Host '    拦截版本   : <无>'
    }

    if ($Info.Ready -and $Info.ReadyDir) {
        Write-Host ("    待应用更新 : {0}  ← 下次启动会生效！" -f $Info.Ready) -ForegroundColor Red
    } elseif ($Info.Ready) {
        Write-Host ("    待应用更新 : {0}（目录缺失，启动器会自行清理）" -f $Info.Ready) -ForegroundColor Yellow
    } else {
        Write-Host '    待应用更新 : 无'
    }

    $zmb = 0
    if ($Info.Zips.Count -gt 0) { $zmb = [math]::Round((($Info.Zips | Measure-Object Length -Sum).Sum / 1MB), 1) }
    Write-Host ("    残留更新包 : {0} 个 ({1} MB)" -f $Info.Zips.Count, $zmb)
    Write-Host ("    版本目录   : {0}" -f $(if ($Info.Dirs.Count -gt 0) { $Info.Dirs -join ', ' } else { '<无>' }))
    Write-Host ("    安装目录   : {0}" -f $Info.Root)
}

function Invoke-Status {
    Write-Head 'QQ 更新锁 · 状态'

    $roots = Get-QQRoots
    if ($roots.Count -eq 0) {
        Write-Bad '没找到 QQNT 安装目录。可用 -InstallRoot 手动指定。'
        return
    }

    $infos = @()
    foreach ($root in $roots) { $infos += (Get-LockInfo $root) }

    # 多处安装时先给一句总览
    if ($infos.Count -gt 1) {
        $lockedCount = @($infos | Where-Object { (Get-LockGrade $_) -ne 'none' }).Count
        $strongCount = @($infos | Where-Object { (Get-LockGrade $_) -in @('strong', 'strong-only') }).Count
        Write-Host ("  共 {0} 处安装：已锁定 {1} 处（其中文件强锁 {2} 处），未锁定 {3} 处" -f `
            $infos.Count, $lockedCount, $strongCount, ($infos.Count - $lockedCount)) -ForegroundColor Cyan
    }

    foreach ($info in $infos) {
        Write-Host ''
        Write-LockBanner $info
        Write-LockDetail $info
    }

    $qq = Get-QQProcesses
    Write-Host ''
    Write-Host ("    QQ 进程    : {0}" -f $(if ($qq.Count -gt 0) { "运行中（$($qq.Count) 个）" } else { '未运行' }))
    Write-Host ''
}

function Invoke-Off {
    Write-Head 'QQ 更新锁 — 关闭更新'

    $roots = Get-QQRoots
    if ($roots.Count -eq 0) {
        Write-Bad '没找到 QQNT 安装目录。'
        Write-Step '请用 -InstallRoot "D:\...\Tencent\QQNT" 手动指定，或确认已安装 QQNT 版 QQ。'
        exit 1
    }

    # 权限检查
    $needElevate = $false
    foreach ($root in $roots) {
        if (-not (Test-CanWriteDir (Join-Path $root 'versions'))) { $needElevate = $true }
    }
    if ($needElevate) {
        if (Invoke-Elevate) { return }
        if (-not (Test-IsAdmin)) {
            Write-Bad '没有写入权限，且提权未成功。请右键“以管理员身份运行”。'
            exit 1
        }
    }

    Close-QQ

    $EffectiveBackstop = Resolve-Backstop

    $allBlocked = New-Object System.Collections.Generic.List[string]

    foreach ($root in $roots) {
        Write-Host "`n  安装目录：$root"
        $pin = Resolve-PinVersion $root
        if (-not $pin) {
            Write-Bad '无法识别当前版本，跳过。可用 -PinVersion 指定。'
            continue
        }
        if (-not (Test-Path (Join-Path $root "versions\$pin"))) {
            Write-Bad "版本目录不存在：versions\$pin，跳过。"
            continue
        }
        Write-Ok "锁定版本：$pin"

        $blocked = Get-BlockedVersions $root $pin
        Write-Step "待拦截版本：$(if ($blocked.Count -gt 0) { $blocked -join ', ' } else { '<无（尚未发现新版本）>' })"

        # 清理已下载的更新包
        foreach ($z in (Get-ChildItem (Join-Path $root 'versions') -File -Filter '*.zip' -ErrorAction SilentlyContinue)) {
            try { Remove-Item $z.FullName -Force; Write-Step "已删除更新包：$($z.Name)" } catch { Write-Warn2 "删除失败：$($z.Name)" }
        }
        # 清理非当前版本目录
        foreach ($d in (Get-VersionDirs $root)) {
            if ($d -eq $pin) { continue }
            try {
                Remove-Item (Join-Path $root "versions\$d") -Recurse -Force
                Write-Step "已删除版本目录：$d"
            } catch { Write-Warn2 "删除失败：$d" }
        }

        Update-VersionsConfig $root $pin $blocked.ToArray() | Out-Null
        Write-Ok 'config.json 已写入（无 readyVersion，已设黑名单）'

        if ($EffectiveBackstop -eq 'acl') {
            $vdir = Join-Path $root 'versions'
            if ((Get-DenyRules $vdir).Count -eq 0) {
                try {
                    Add-CreateDeny $vdir
                    Write-Ok '文件系统兜底已启用（versions 下禁止新建文件/目录）'
                } catch { Write-Warn2 ('ACL 设置失败：' + $_.Exception.Message) }
            } else {
                Write-Step '文件系统兜底已存在'
            }
        } else {
            $vdir = Join-Path $root 'versions'
            if ((Get-DenyRules $vdir).Count -gt 0) {
                try { Remove-CreateDeny $vdir | Out-Null; Write-Ok '已移除文件系统兜底' } catch { }
            }
        }

        foreach ($b in $blocked) { if (-not $allBlocked.Contains($b)) { $allBlocked.Add($b) } }
        $script:PinForState = $pin
    }

    # 记录状态
    $st = Read-Json $StateFile
    $prevList = @()
    if ($st) {
        $pp = Get-Prop $st 'blockedVersions'
        if ($pp) { $prevList = @($pp) }
    }
    foreach ($b in $prevList) { if ($b -and -not $allBlocked.Contains($b)) { $allBlocked.Add($b) } }

    $state = [pscustomobject]@{
        pinnedVersion   = $(if ($script:PinForState) { $script:PinForState } else { $PinVersion })
        blockedVersions = @($allBlocked.ToArray())
        backstop        = $EffectiveBackstop
        lockedAt        = (Get-Date).ToString('s')
    }
    Write-JsonNoBom $StateFile $state

    Write-Host ''
    Write-Ok ("锁定层级：{0}" -f (Get-BackstopName $EffectiveBackstop))
    Write-Ok '完成。下次启动 QQ 会在下载前终止更新检查。'
    Write-Step '验证方法：启动 QQ 后打开 %APPDATA%\QQ\log\updater.log，应有'
    Write-Step '  hotUpdateApi checkIsOnErrorVersion result: true'
    Write-Host ''
}

function Invoke-On {
    Write-Head 'QQ 更新锁 — 恢复更新'

    $roots = Get-QQRoots
    if ($roots.Count -eq 0) {
        Write-Bad '没找到 QQNT 安装目录。'
        exit 1
    }

    $needElevate = $false
    foreach ($root in $roots) {
        if (-not (Test-CanWriteDir (Join-Path $root 'versions'))) { $needElevate = $true }
    }
    if ($needElevate) {
        if (Invoke-Elevate) { return }
    }

    Close-QQ

    foreach ($root in $roots) {
        Write-Host "`n  安装目录：$root"
        $vdir = Join-Path $root 'versions'

        if ((Get-DenyRules $vdir).Count -gt 0) {
            try { Remove-CreateDeny $vdir | Out-Null; Write-Ok '已移除文件系统兜底' }
            catch { Write-Warn2 ('移除 ACL 失败：' + $_.Exception.Message) }
        }

        $pin = Resolve-PinVersion $root
        if (-not $pin) { $pin = Get-Prop (Read-Json (Join-Path $vdir 'config.json')) 'curVersion' }
        if (-not $pin) { Write-Warn2 '无法确定当前版本，跳过'; continue }

        Update-VersionsConfig $root $pin @() -ClearBlocked | Out-Null
        Write-Ok "已清空黑名单，保留版本 $pin"
    }

    if (Test-Path $StateFile) { Remove-Item $StateFile -Force }
    Write-Host ''
    Write-Ok '已恢复：QQ 下次启动会正常检查并下载更新。'
    Write-Host ''
}

# ============================================================ 入口

switch ($Action) {
    'off'    { Invoke-Off }
    'on'     { Invoke-On }
    'status' { Invoke-Status }
}

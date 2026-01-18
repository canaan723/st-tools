# Copyright (c) 2025 清绝 (QingJue) <blog.qjyg.de>
# This script is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
# To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/
#
# 郑重声明：
# 本脚本为免费开源项目，仅供个人学习和非商业用途使用。
# 未经作者授权，严禁将本脚本或其修改版本用于任何形式的商业盈利行为（包括但不限于倒卖、付费部署服务等）。
# 任何违反本协议的行为都将受到法律追究。

$ScriptVersion = "v5.15"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$OutputEncoding = [System.Text.Encoding]::UTF8
try { Add-Type -AssemblyName System.Net.Http } catch {}

$ScriptSelfUpdateUrl = "https://gitee.com/canaan723/st-tools/raw/main/jiuguan/pc-st.ps1"
$HelpDocsUrl = "https://blog.qjyg.de"
$ScriptBaseDir = Split-Path -Path $PSCommandPath -Parent
$ST_Dir = Join-Path $ScriptBaseDir "SillyTavern"
$Repo_Branch = "release"
$Backup_Root_Dir = Join-Path $ScriptBaseDir "_SillyTavern_Backups"
$Backup_Limit = 10
$UpdateFlagFile = Join-Path ([System.IO.Path]::GetTempPath()) ".st_assistant_update_flag"

$ConfigDir = Join-Path $ScriptBaseDir ".config"
if (-not (Test-Path $ConfigDir)) {
    New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null
}
$BackupPrefsConfigFile = Join-Path $ConfigDir "backup_prefs.conf"
$GitSyncConfigFile = Join-Path $ConfigDir "git_sync.conf"
$ProxyConfigFile = Join-Path $ConfigDir "proxy.conf"
$SyncRulesConfigFile = Join-Path $ConfigDir "sync_rules.conf"
$AgreementFile = Join-Path $ConfigDir ".agreement_shown"
$LabConfigFile = Join-Path $ConfigDir "lab.conf"
$GcliDir = Join-Path $ScriptBaseDir "gcli2api"
# 补全 AI Studio 相关路径变量
$ais2apiDir = Join-Path $ScriptBaseDir "ais2api"
$camoufoxDir = Join-Path $ais2apiDir "camoufox"
$camoufoxExe = Join-Path $camoufoxDir "camoufox.exe"

$Mirror_List = @(
    "https://github.com/SillyTavern/SillyTavern.git",
    "https://git.ark.xx.kg/gh/SillyTavern/SillyTavern.git",
    "https://git.723123.xyz/gh/SillyTavern/SillyTavern.git",
    "https://xget.xi-xu.me/gh/SillyTavern/SillyTavern.git",
    "https://gh-proxy.com/github.com/SillyTavern/SillyTavern.git",
    "https://gh.llkk.cc/https://github.com/SillyTavern/SillyTavern.git",
    "https://tvv.tw/https://github.com/SillyTavern/SillyTavern.git",
    "https://proxy.pipers.cn/https://github.com/SillyTavern/SillyTavern.git",
    "https://gh.catmak.name/https://github.com/SillyTavern/SillyTavern.git",
    "https://hub.gitmirror.com/https://github.com/SillyTavern/SillyTavern.git",
    "https://gh-proxy.net/https://github.com/SillyTavern/SillyTavern.git",
    "https://hubproxy-advj.onrender.com/https://github.com/SillyTavern/SillyTavern.git"
)
$CachedMirrors = @()

function Show-Header {
    Write-Host "    " -NoNewline; Write-Host ">>" -ForegroundColor Yellow -NoNewline; Write-Host " 清绝咕咕助手 $($ScriptVersion)" -ForegroundColor Green
    Write-Host "       " -NoNewline; Write-Host "作者: 清绝 | 网址: blog.qjyg.de" -ForegroundColor DarkGray
    Write-Host "    " -NoNewline; Write-Host "本脚本为免费工具，严禁用于商业倒卖！" -ForegroundColor Red
}

function Write-Header($Title) { Write-Host "`n═══ $($Title) ═══" -ForegroundColor Cyan }
function Write-Success($Message) { Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Warning($Message) { Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-Error($Message) { Write-Host "✗ $Message" -ForegroundColor Red }
function Write-ErrorExit($Message) { Write-Host "`n✗ $Message`n流程已终止。" -ForegroundColor Red; Press-Any-Key; exit }
function Press-Any-Key { Write-Host "`n请按任意键返回..." -ForegroundColor Cyan; $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null }
function Check-Command($Command) {
    # 首先尝试使用 Get-Command 检测
    $cmd = Get-Command $Command -ErrorAction SilentlyContinue
    if ($cmd) { return $true }
    
    # 如果 Get-Command 失败，尝试直接运行命令验证
    try {
        $testOutput = & $Command --version 2>&1
        if ($LASTEXITCODE -eq 0 -or $testOutput) { return $true }
    } catch {
        # 忽略异常，继续返回 false
    }
    
    return $false
}

function Get-STConfigValue {
    param([string]$Key)
    $configPath = Join-Path $ST_Dir "config.yaml"
    if (-not (Test-Path $configPath)) { return $null }
    $content = Get-Content $configPath -Raw
    # 仅匹配根层级的键，避免误触嵌套键（如 browserLaunch.port）
    if ($content -match "(?m)^${Key}:\s*([^#\r\n]*)(.*)$") {
        return $Matches[1].Trim().Trim("'").Trim('"')
    }
    return $null
}

function Get-STNestedConfigValue {
    param([string]$ParentKey, [string]$Key)
    $configPath = Join-Path $ST_Dir "config.yaml"
    if (-not (Test-Path $configPath)) { return $null }
    $content = Get-Content $configPath -Raw
    if ($content -match "(?ms)^${ParentKey}:\s*.*?^\s+${Key}:\s*([^#\r\n]*)(.*)$") {
        return $Matches[1].Trim().Trim("'").Trim('"')
    }
    return $null
}

function Update-STConfigValue {
    param([string]$Key, [string]$Value)
    $configPath = Join-Path $ST_Dir "config.yaml"
    if (-not (Test-Path $configPath)) { return $false }
    $content = Get-Content $configPath -Raw
    # 仅匹配根层级的键，保留键名缩进，并尝试保留行尾注释
    # 使用 ${1} 和 ${2} 避免在 $Value 为数字时产生歧义
    $pattern = "(?m)^(${Key}:\s*)[^#\r\n]*(.*)$"
    if ($content -match $pattern) {
        $newContent = $content -replace $pattern, ('${1}' + $Value + '${2}')
        [System.IO.File]::WriteAllText($configPath, $newContent, [System.Text.Encoding]::UTF8)
        return $true
    }
    return $false
}

function Update-STNestedConfigValue {
    param([string]$ParentKey, [string]$Key, [string]$Value)
    $configPath = Join-Path $ST_Dir "config.yaml"
    if (-not (Test-Path $configPath)) { return $false }
    $content = Get-Content $configPath -Raw
    # 匹配父键下的子键，考虑缩进
    $pattern = "(?ms)^(${ParentKey}:\s*.*?^\s+)${Key}:\s*[^#\r\n]*(.*)$"
    if ($content -match $pattern) {
        $newContent = $content -replace $pattern, ('${1}' + $Key + ': ' + $Value + '${2}')
        [System.IO.File]::WriteAllText($configPath, $newContent, [System.Text.Encoding]::UTF8)
        return $true
    }
    return $false
}

function Add-STWhitelistEntry {
    param([string]$Entry)
    $configPath = Join-Path $ST_Dir "config.yaml"
    if (-not (Test-Path $configPath)) { return $false }
    $content = Get-Content $configPath -Raw
    
    # 检查是否已存在
    if ($content -match "- $Entry") { return $true }

    # 寻找 whitelist: 这一行
    if ($content -match "(?m)^whitelist:\s*\r?\n") {
        $newContent = $content -replace "(?m)^whitelist:\s*\r?\n", "whitelist:`n  - $Entry`n"
        [System.IO.File]::WriteAllText($configPath, $newContent, [System.Text.Encoding]::UTF8)
        return $true
    }
    return $false
}

function Check-PortAndShowError {
    param([string]$SillyTavernPath)
    $configPath = Join-Path $SillyTavernPath "config.yaml"
    $port = 8000

    if (Test-Path $configPath) {
        try {
            $configContent = Get-Content $configPath -Raw
            $portLine = $configContent | Select-String -Pattern "(?m)^\s*port:\s*(\d+)"
            if ($portLine) {
                $port = [int]$portLine.Matches[0].Groups[1].Value
            }
        } catch {
            Write-Warning "无法解析 config.yaml 中的端口号，将使用默认端口 8000 进行检查。"
        }
    }

    $connection = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    if ($null -ne $connection) {
        $owningProcess = Get-Process -Id $connection.OwningProcess | Select-Object -First 1
        Write-Error "启动失败：端口 $port 已被占用！"
        Write-Host "  - 占用程序: $($owningProcess.ProcessName) (PID: $($owningProcess.Id))" -ForegroundColor Yellow
        Write-Host "`n请尝试以下解决方案：" -ForegroundColor Cyan
        Write-Host "  1. 如果是之前启动的酒馆未完全关闭，请先【重启电脑】。" -ForegroundColor Cyan
        Write-Host "  2. 如果重启无效，请在主菜单选择 [11] 酒馆配置管理，" -ForegroundColor Cyan
        Write-Host "     将端口修改为其他未被占用的端口号 (如 8001)。" -ForegroundColor Cyan
        Write-ErrorExit "无法继续启动。"
    }
}

function Show-AgreementIfFirstRun {
    if (-not (Test-Path $AgreementFile)) {
        Clear-Host
        Write-Header "使用前必看"
        Write-Host "`n 1. 我是咕咕助手的作者清绝，咕咕助手是 " -NoNewline; Write-Host "完全免费" -ForegroundColor Green -NoNewline; Write-Host " 的，唯一发布地址 " -NoNewline; Write-Host "https://blog.qjyg.de" -ForegroundColor Cyan -NoNewline; Write-Host "，内含宝宝级教程。"
        Write-Host " 2. 如果你是 " -NoNewline; Write-Host "花钱买的" -ForegroundColor Yellow -NoNewline; Write-Host "，那你绝对是 " -NoNewline; Write-Host "被坑了" -ForegroundColor Red -NoNewline; Write-Host "，赶紧退款差评举报。"
        Write-Host " 3. " -NoNewline; Write-Host "严禁拿去倒卖！" -ForegroundColor Red -NoNewline; Write-Host "偷免费开源的东西赚钱，丢人现眼。"
        Write-Host "`n【盗卖名单】" -ForegroundColor Red
        Write-Host " -> 淘宝：" -NoNewline; Write-Host "灿灿AI科技" -ForegroundColor Red
        Write-Host " （持续更新）"
        Write-Host "`n发现盗卖的欢迎告诉我，感谢支持。" -ForegroundColor Green
        Write-Host "─────────────────────────────────────────────────────────────"
        $confirm = Read-Host "请输入 'yes' 表示你已阅读并同意以上条款"
        if ($confirm -eq "yes") {
            if (-not (Test-Path $ConfigDir)) { New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null }
            New-Item -Path $AgreementFile -ItemType File -Force | Out-Null
            Write-Host "`n感谢您的支持！正在进入助手..." -ForegroundColor Green
            Start-Sleep -Seconds 2
        } else {
            Write-Host "`n您未同意使用条款，脚本将自动退出。" -ForegroundColor Red
            exit
        }
    }
}

function Get-UserFolders {
    param([string]$baseDataPath)
    $systemFolders = @("_cache", "_storage", "_uploads", "_webpack")
    return Get-ChildItem -Path $baseDataPath -Directory -ErrorAction SilentlyContinue | Where-Object { $systemFolders -notcontains $_.Name }
}

function Test-GitConnectivity {
    param([string]$Url)
    $job = Start-Job -ScriptBlock {
        param($u)
        try {
            git ls-remote $u HEAD | Out-Null
            return ($LASTEXITCODE -eq 0)
        } catch {
            return $false
        }
    } -ArgumentList $Url
    if (Wait-Job $job -Timeout 10) {
        $result = Receive-Job $job
        Remove-Job $job -Force
        return $result
    } else {
        Stop-Job $job
        Remove-Job $job -Force
        return $false
    }
}


function Run-NpmInstallWithRetry {
    if (-not (Test-Path $ST_Dir)) { return $false }
    Set-Location $ST_Dir
    Write-Warning "正在同步依赖包 (npm install)..."
    npm install --no-audit --no-fund --omit=dev
    if ($LASTEXITCODE -eq 0) { Write-Success "依赖包同步完成。"; return $true }

    Write-Warning "依赖包同步失败，将自动清理缓存并重试..."
    npm cache clean --force --silent
    npm install --no-audit --no-fund --omit=dev
    if ($LASTEXITCODE -eq 0) { Write-Success "依赖包重试同步成功。"; return $true }

    Write-Warning "国内镜像安装失败，将切换到NPM官方源进行最后尝试..."
    try {
        npm config delete registry
        npm install --no-audit --no-fund --omit=dev
        if ($LASTEXITCODE -eq 0) { Write-Success "使用官方源安装依赖成功！"; return $true }
    } finally {
        Write-Warning "正在将 NPM 源恢复为国内镜像..."
        npm config set registry https://registry.npmmirror.com
    }
    Write-Error "所有安装尝试均失败。"
    return $false
}

function Apply-Proxy {
    if (Test-Path $ProxyConfigFile) {
        $port = Get-Content $ProxyConfigFile -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($port)) {
            $proxyUrl = "http://127.0.0.1:$port"
            $env:http_proxy = $proxyUrl
            $env:https_proxy = $proxyUrl
            $env:all_proxy = $proxyUrl
        }
    } else {
        Remove-Item env:http_proxy -ErrorAction SilentlyContinue
        Remove-Item env:https_proxy -ErrorAction SilentlyContinue
        Remove-Item env:all_proxy -ErrorAction SilentlyContinue
    }
}

function Set-Proxy {
    $portInput = Read-Host "请输入代理端口号 [直接回车默认为 7890]"
    if ([string]::IsNullOrWhiteSpace($portInput)) { $portInput = "7890" }
    try {
        $portNum = [int]$portInput.Trim()
        if ($portNum -gt 0 -and $portNum -lt 65536) {
            Set-Content -Path $ProxyConfigFile -Value $portNum
            Apply-Proxy
            Write-Success "代理已设置为: 127.0.0.1:$portNum"
        } else {
            Write-Error "无效的端口号！请输入1-65535之间的数字。"
        }
    } catch {
        Write-Error "无效的端口号！请输入1-65535之间的纯数字。"
    }
    Press-Any-Key
}

function Clear-Proxy {
    if (Test-Path $ProxyConfigFile) {
        Remove-Item $ProxyConfigFile -Force
        Apply-Proxy
        Write-Success "网络代理配置已清除。"
    } else {
        Write-Warning "当前未配置任何代理。"
    }
    Press-Any-Key
}

function Show-ManageProxyMenu {
    while ($true) {
        Clear-Host
        Write-Header "管理网络代理"
        Write-Host "      当前状态: " -NoNewline
        if (Test-Path $ProxyConfigFile) {
            Write-Host "127.0.0.1:$(Get-Content $ProxyConfigFile)" -ForegroundColor Green
        } else {
            Write-Host "未配置" -ForegroundColor Red
        }
        Write-Host "      (此设置仅对咕咕助手内的操作生效，不影响系统全局代理)" -ForegroundColor DarkGray
        Write-Host "`n      [1] " -NoNewline; Write-Host "设置/修改代理" -ForegroundColor Cyan
        Write-Host "      [2] " -NoNewline; Write-Host "清除代理" -ForegroundColor Red
        Write-Host "      [0] " -NoNewline; Write-Host "返回主菜单" -ForegroundColor Cyan
        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            "1" { Set-Proxy }
            "2" { Clear-Proxy }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep -Seconds 1 }
        }
    }
}

function Parse-ConfigFile($filePath) {
    $config = @{}
    if (Test-Path $filePath) {
        Get-Content $filePath | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not $line.StartsWith("#")) {
                $parts = $line.Split('=', 2)
                if ($parts.Length -eq 2) {
                    $key = $parts[0].Trim()
                    $value = $parts[1].Trim()
                    if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                        $value = $value.Substring(1, $value.Length - 2)
                    }
                    $config[$key] = $value
                }
            }
        }
    }
    return $config
}

function Test-GitSyncDeps {
    $gitExists = Check-Command "git"
    $robocopyExists = Check-Command "robocopy"
    
    if (-not $gitExists -or -not $robocopyExists) {
        $missingTools = @()
        if (-not $gitExists) { $missingTools += "Git" }
        if (-not $robocopyExists) { $missingTools += "Robocopy" }
        
        Write-Warning "检测到以下工具缺失: $($missingTools -join ', ')"
        Write-Host "  - 如果您刚安装了这些工具，请尝试【重启终端】或【重启电脑】后再试。" -ForegroundColor Cyan
        Write-Host "  - 如果确认未安装，请先运行主菜单的 [首次部署] 选项。" -ForegroundColor Cyan
        Press-Any-Key
        return $false
    }
    return $true
}

function Ensure-GitIdentity {
    if ([string]::IsNullOrWhiteSpace($(git config --global user.name)) -or [string]::IsNullOrWhiteSpace($(git config --global user.email))) {
        Clear-Host
        Write-Header "首次使用Git同步：配置身份"
        $userName = ""
        $userEmail = ""
        while ([string]::IsNullOrWhiteSpace($userName)) { $userName = Read-Host "请输入您的Git用户名 (例如 Your Name)" }
        while ([string]::IsNullOrWhiteSpace($userEmail)) { $userEmail = Read-Host "请输入您的Git邮箱 (例如 you@example.com)" }
        git config --global user.name "$userName"
        git config --global user.email "$userEmail"
        Write-Success "Git身份信息已配置成功！"
        Start-Sleep -Seconds 2
    }
    return $true
}

function Set-GitSyncConfig {
    Clear-Host
    Write-Header "配置 Git 同步服务"
    $repoUrl = ""
    $repoToken = ""
    while ([string]::IsNullOrWhiteSpace($repoUrl)) { $repoUrl = Read-Host "请输入您的私有仓库HTTPS地址" }
    while ([string]::IsNullOrWhiteSpace($repoToken)) { $repoToken = Read-Host "请输入您的 Personal Access Token (个人访问令牌)" }
    Set-Content -Path $GitSyncConfigFile -Value "REPO_URL=`"$repoUrl`"`nREPO_TOKEN=`"$repoToken`""
    Write-Success "Git同步服务配置已保存！"
    Press-Any-Key
}

function Test-OneMirrorPush($authedUrl) {
    $tempRepoDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -Path $tempRepoDir -ItemType Directory -Force | Out-Null
    $isSuccess = $false
    try {
        Set-Location $tempRepoDir
        git init -q
        git config user.name "test"
        git config user.email "test@example.com"
        git config core.autocrlf false
        Set-Content "testfile.txt" "test"
        git add testfile.txt
        git commit -m "Sync test commit" -q
        git remote add origin $authedUrl
        $testTag = "st-sync-test-$(Get-Date -UFormat %s%N)"
        
        $pushJob = Start-Job -ScriptBlock {
            param($path, $tag)
            Set-Location $path
            git -c credential.helper='' push origin "HEAD:refs/tags/$tag" 2>$null
            return ($LASTEXITCODE -eq 0)
        } -ArgumentList $tempRepoDir, $testTag

        if (Wait-Job $pushJob -Timeout 15) {
            if (Receive-Job $pushJob) {
                $isSuccess = $true
                $deleteJob = Start-Job -ScriptBlock { 
                    param($path, $tag) 
                    Set-Location $path
                    git -c credential.helper='' push origin --delete "refs/tags/$tag" 2>$null 
                } -ArgumentList $tempRepoDir, $testTag
                Wait-Job $deleteJob -Timeout 15 | Out-Null
                Remove-Job $deleteJob -Force
            }
        }
        Remove-Job $pushJob -Force
    } finally {
        Set-Location $ScriptBaseDir
        if(Test-Path $tempRepoDir) { Remove-Item $tempRepoDir -Recurse -Force }
    }
    return $isSuccess
}

function Find-AvailableMirrors {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Download', 'Upload')]
        [string]$TestType,

        [Parameter(Mandatory=$true)]
        [ValidateSet('OfficialOnly', 'MirrorsOnly', 'All')]
        [string]$Mode
    )

    $testTypeDescription = @{
        'Download' = '下载'
        'Upload'   = '上传'
    }
    $modeDescription = @{
        'OfficialOnly' = '仅官方线路'
        'MirrorsOnly'  = '备用镜像线路'
        'All'          = '所有线路'
    }

    $githubUrl = "https://github.com/SillyTavern/SillyTavern.git"
    $mirrorsToTest = @()
    $successfulUrls = New-Object System.Collections.Generic.List[string]

    if ($Mode -eq 'OfficialOnly' -or $Mode -eq 'All') {
        $mirrorsToTest += $githubUrl
    }
    if ($Mode -eq 'MirrorsOnly' -or $Mode -eq 'All') {
        $mirrorsToTest += $Mirror_List | Where-Object { $_ -ne $githubUrl }
    }
    $mirrorsToTest = $mirrorsToTest | Select-Object -Unique

    if ($mirrorsToTest.Count -eq 0) { return @() }

    Write-Warning "开始测试 Git $($testTypeDescription[$TestType]) 线路 ($($modeDescription[$Mode]))..."

    foreach ($mirrorUrl in $mirrorsToTest) {
        $mirrorHost = ($mirrorUrl -split '/')[2]
        Write-Host "  - 正在测试: $($mirrorHost) ..." -NoNewline
        $isSuccess = $false
        
        if ($TestType -eq 'Download') {
            $gitOutput = ""
            $job = Start-Job -ScriptBlock {
                param($url)
                $output = git -c credential.helper='' ls-remote $url HEAD 2>&1
                return @{ Success = ($LASTEXITCODE -eq 0); Output = $output }
            } -ArgumentList $mirrorUrl

            if (Wait-Job $job -Timeout 10) {
                $result = Receive-Job $job
                if ($result.Success) { $isSuccess = $true }
                $gitOutput = $result.Output
            }
            Remove-Job $job -Force
            
            if ($isSuccess) {
                Write-Host "`r  ✓ 测试: $($mirrorHost) [成功]                                  " -ForegroundColor Green
                $successfulUrls.Add($mirrorUrl)
            } else {
                Write-Host "`r  ✗ 测试: $($mirrorHost) [失败]                                  " -ForegroundColor Red
                if ($gitOutput -match "Failed to connect to .* port .*|Could not connect to server") {
                    Write-Error "  └—> 网络连接失败。若您配置了Git全局代理，请确保代理软件已开启，或执行 git config --global --unset http.proxy 清除代理后重试。"
                }
            }

        } elseif ($TestType -eq 'Upload') {
            $gitConfig = Parse-ConfigFile $GitSyncConfigFile
            if (-not $gitConfig.ContainsKey("REPO_URL") -or -not $gitConfig.ContainsKey("REPO_TOKEN")) {
                Write-Error "Git同步配置不完整。"; return @()
            }
            $repoPath = $gitConfig["REPO_URL"] -replace 'https://github.com/', ''
            $repoToken = $gitConfig["REPO_TOKEN"]
            $authedPrivateUrl = "https://$($repoToken)@github.com/$($repoPath)"
            $authedPushUrl = $null

            if ($mirrorHost -eq "github.com") {
                $authedPushUrl = $authedPrivateUrl
            } elseif ($mirrorUrl -like "*hub.gitmirror.com*") {
                $authedPushUrl = "https://$($repoToken)@$($mirrorHost)/$($repoPath)"
            } elseif ($mirrorUrl -match "/gh/") {
                $authedPushUrl = "https://$($repoToken)@$($mirrorHost)/gh/$($repoPath)"
            } elseif ($mirrorUrl -like "*/github.com/*") {
                $proxyPrefix = $mirrorUrl -replace '(https?://)?github\.com/.*'
                if (-not [string]::IsNullOrEmpty($proxyPrefix) -and $proxyPrefix -ne $mirrorUrl) {
                    $authedPushUrl = "$($proxyPrefix)/$($authedPrivateUrl)"
                }
            }

            if ($authedPushUrl) {
                if (Test-OneMirrorPush $authedPushUrl) {
                    $isSuccess = $true
                    $successfulUrls.Add($authedPushUrl)
                }
            }

            if ($isSuccess) {
                Write-Host "`r  ✓ 测试: $($mirrorHost) [成功]                                  " -ForegroundColor Green
            } else {
                Write-Host "`r  ✗ 测试: $($mirrorHost) [失败]                                  " -ForegroundColor Red
            }
        }
    }

    if ($successfulUrls.Count -gt 0) {
        Write-Host ""
        Write-Success "测试完成，共找到 $($successfulUrls.Count) 条可用 $($testTypeDescription[$TestType]) 线路。"
    } else {
        Write-Host ""
        Write-Error "所有 $($testTypeDescription[$TestType]) 线路均测试失败。"
    }
    return $successfulUrls.ToArray()
}

function Backup-ToCloud {
    Clear-Host
    Write-Header "备份数据到云端"
    if (-not (Test-Path $GitSyncConfigFile)) {
        Write-Warning "请先在菜单 [1] 中配置Git同步服务。"; Press-Any-Key; return
    }

    $backupSuccess = $false
    $fullRetestAttempted = $false
    while (-not $backupSuccess) { 
        $pushUrls = @()
        if (-not $fullRetestAttempted) {
            $pushUrls = Find-AvailableMirrors -TestType 'Upload' -Mode 'OfficialOnly'
            if ($pushUrls.Count -eq 0) {
                $pushUrls = Find-AvailableMirrors -TestType 'Upload' -Mode 'MirrorsOnly'
            }
        } else {
            $pushUrls = Find-AvailableMirrors -TestType 'Upload' -Mode 'All'
        }

        if ($pushUrls.Count -eq 0) {
            $retryChoice = Read-Host "`n所有上传线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
            if ($retryChoice -eq 'n') { Write-Warning "用户取消操作。"; break }
            $fullRetestAttempted = $false; continue
        }

        $syncRules = Parse-ConfigFile $SyncRulesConfigFile
        $syncConfigYaml = if ($syncRules.ContainsKey("SYNC_CONFIG_YAML")) { $syncRules["SYNC_CONFIG_YAML"] } else { "false" }
        $userMap = if ($syncRules.ContainsKey("USER_MAP")) { $syncRules["USER_MAP"] } else { "" }
        
        foreach ($pushUrl in $pushUrls) {
            $chosenHost = $pushUrl -replace 'https://.*@' -replace '/.*$'
            Write-Warning "正在尝试使用线路 [$chosenHost] 进行备份..."
            $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
            try {
                git -c credential.helper='' clone --depth 1 $pushUrl $tempDir
                if ($LASTEXITCODE -ne 0) { Write-Error "从云端克隆仓库失败！"; continue }
                Write-Success "已成功从云端克隆仓库。"
                Set-Location $tempDir
                git config core.autocrlf false
                Write-Warning "正在同步本地数据到临时区..."
                $recursiveExcludeDirs = @("extensions", "backups")
                $recursiveExcludeFiles = @("*.log")
                $robocopyExcludeArgs = @($recursiveExcludeDirs | ForEach-Object { "/XD", $_ }) + @($recursiveExcludeFiles | ForEach-Object { "/XF", $_ })
                if (-not [string]::IsNullOrWhiteSpace($userMap) -and $userMap.Contains(":")) {
                    $localUser = $userMap.Split(':')[0]; $remoteUser = $userMap.Split(':')[1]
                    Write-Warning "应用用户映射规则: 本地'$localUser' -> 云端'$remoteUser'"
                    $localUserPath = Join-Path $ST_Dir "data/$localUser"
                    if (Test-Path $localUserPath) {
                        $remoteUserPath = Join-Path $tempDir "data/$remoteUser"
                        robocopy $localUserPath $remoteUserPath /E /PURGE $robocopyExcludeArgs /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
                        if ($LASTEXITCODE -ge 8) { Write-Error "Robocopy 同步 '$localUser' 失败！错误码: $LASTEXITCODE"; continue }
                    } else { Write-Warning "本地用户文件夹 '$localUser' 不存在，跳过同步。" }
                } else {
                    Get-ChildItem -Path . | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force
                    Write-Warning "应用镜像同步规则: 同步所有本地用户文件夹"
                    $localUserFolders = Get-UserFolders -baseDataPath (Join-Path $ST_Dir "data")
                    foreach ($userFolder in $localUserFolders) {
                        $sourcePath = $userFolder.FullName
                        $destPath = Join-Path (Join-Path $tempDir "data") $userFolder.Name
                        robocopy $sourcePath $destPath /E /PURGE $robocopyExcludeArgs /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
                        if ($LASTEXITCODE -ge 8) { Write-Error "Robocopy 同步 '$($userFolder.Name)' 失败！错误码: $LASTEXITCODE"; continue 2 }
                    }
                }
                if ($syncConfigYaml -eq "true" -and (Test-Path (Join-Path $ST_Dir "config.yaml"))) {
                    Copy-Item (Join-Path $ST_Dir "config.yaml") $tempDir -Force
                }
                Set-Location $tempDir
                git add .
                if ($(git status --porcelain).Length -eq 0) {
                    Write-Success "数据与云端一致，无需上传。"; $backupSuccess = $true; break
                }
                Write-Warning "正在提交数据变更..."
                $commitMessage = "💻 Windows 推送: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
                git commit -m $commitMessage -q
                if ($LASTEXITCODE -ne 0) { Write-Error "Git 提交失败！"; continue }
                Write-Warning "正在上传到云端..."
                git -c credential.helper='' push
                if ($LASTEXITCODE -ne 0) { Write-Error "上传失败！"; continue }
                Write-Success "数据成功备份到云端！"; $backupSuccess = $true; break
            } finally {
                Set-Location $ScriptBaseDir
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
        }

        if (-not $backupSuccess) {
            if (-not $fullRetestAttempted) {
                $fullRetestAttempted = $true
                Write-Error "预选线路均备份失败。将进行全量测速并重试所有可用线路..."
            } else {
                Write-Error "已尝试所有可用线路，但备份均失败。"; break
            }
        }
    }
    Press-Any-Key
}

function Restore-FromCloud {
    Clear-Host
    Write-Header "从云端恢复数据"
    if (-not (Test-Path $GitSyncConfigFile)) {
        Write-Warning "请先在菜单 [1] 中配置Git同步服务。"; Press-Any-Key; return
    }
    Write-Warning "此操作将用云端数据【覆盖】本地数据！"
    $backupConfirm = Read-Host "是否在恢复前，先对当前数据进行一次本地备份？(强烈推荐) [Y/n]"
    if ($backupConfirm -ne 'n' -and $backupConfirm -ne 'N') {
        if (-not (New-LocalZipBackup -BackupType "恢复前")) {
            Write-Error "本地备份失败，恢复操作已中止。"; Press-Any-Key; return
        }
    }
    $restoreConfirm = Read-Host "确认要从云端恢复数据吗？[Y/n]"
    if ($restoreConfirm -eq 'n' -or $restoreConfirm -eq 'N') {
        Write-Warning "操作已取消。"; Press-Any-Key; return
    }

    $syncRules = Parse-ConfigFile $SyncRulesConfigFile
    $syncConfigYaml = if ($syncRules.ContainsKey("SYNC_CONFIG_YAML")) { $syncRules["SYNC_CONFIG_YAML"] } else { "false" }
    $userMap = if ($syncRules.ContainsKey("USER_MAP")) { $syncRules["USER_MAP"] } else { "" }
    $gitConfig = Parse-ConfigFile $GitSyncConfigFile
    $repoPath = $gitConfig["REPO_URL"] -replace 'https://github.com/', ''
    $repoToken = $gitConfig["REPO_TOKEN"]
    
    $cloneSuccess = $false
    $fullRetestAttempted = $false
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    
    while (-not $cloneSuccess) {
        $mirrorsToTry = @()
        if (-not $fullRetestAttempted) {
            $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'OfficialOnly'
            if ($mirrorsToTry.Count -eq 0) {
                $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'MirrorsOnly'
            }
        } else {
            $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'All'
        }

        if ($mirrorsToTry.Count -eq 0) {
            $retryChoice = Read-Host "`n所有线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
            if ($retryChoice -eq 'n') { Write-ErrorExit "用户取消操作。" }
            $fullRetestAttempted = $false; continue
        }

        try {
            foreach ($pullUrl in $mirrorsToTry) {
                $chosenHost = ($pullUrl -split '/')[2]
                Write-Warning "正在尝试使用线路 [$chosenHost] 进行恢复..."
                $privateRepoUrl = $pullUrl -replace '/SillyTavern/SillyTavern.git', "/$repoPath"
                $pullUrlWithAuth = $privateRepoUrl -replace 'https://', "https://$($repoToken)@"
                git -c credential.helper='' clone --depth 1 $pullUrlWithAuth $tempDir
                if ($LASTEXITCODE -eq 0) { $cloneSuccess = $true; break }
                Write-Error "使用线路 [$chosenHost] 恢复失败！正在切换下一条..."
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
        } finally {
            if (-not $cloneSuccess -and (Test-Path $tempDir)) { Remove-Item $tempDir -Recurse -Force }
        }

        if (-not $cloneSuccess) {
            if (-not $fullRetestAttempted) {
                $fullRetestAttempted = $true
                Write-Error "预选线路均恢复失败。将进行全量测速并重试所有可用线路..."
            } else {
                Write-Error "已尝试所有可用线路，恢复均失败。"
            }
        }
    }

    try {
        Write-Success "已成功从云端下载数据。"
        if (-not (Get-ChildItem $tempDir)) { Write-Error "下载的数据源无效或为空，恢复操作已中止！"; return }
        Write-Warning "正在将云端数据同步到本地..."
        $recursiveExcludeDirs = @("extensions", "backups")
        $recursiveExcludeFiles = @("*.log")
        $robocopyExcludeArgs = @($recursiveExcludeDirs | ForEach-Object { "/XD", $_ }) + @($recursiveExcludeFiles | ForEach-Object { "/XF", $_ })
        if (-not [string]::IsNullOrWhiteSpace($userMap) -and $userMap.Contains(":")) {
            $localUser = $userMap.Split(':')[0]; $remoteUser = $userMap.Split(':')[1]
            Write-Warning "应用用户映射规则: 云端'$remoteUser' -> 本地'$localUser'"
            $remoteUserPath = Join-Path $tempDir "data/$remoteUser"
            if (Test-Path $remoteUserPath) {
                $localUserPath = Join-Path $ST_Dir "data/$localUser"
                robocopy $remoteUserPath $localUserPath /E /PURGE $robocopyExcludeArgs /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) { Write-Error "Robocopy 恢复 '$localUser' 失败！错误码: $LASTEXITCODE"; return }
            } else { Write-Warning "云端映射文件夹 'data\$remoteUser' 不存在，跳过映射同步。" }
        } else {
            Write-Warning "应用镜像同步规则: 恢复所有云端用户文件夹"
            $sourceDataPath = Join-Path $tempDir "data"; $destDataPath = Join-Path $ST_Dir "data"
            $remoteUserFolders = Get-UserFolders -baseDataPath $sourceDataPath
            $localUserFolders = Get-UserFolders -baseDataPath $destDataPath
            $finalRemoteNames = $remoteUserFolders | ForEach-Object { $_.Name }
            foreach ($localUser in $localUserFolders) {
                if ($finalRemoteNames -notcontains $localUser.Name) {
                    Write-Warning "清理本地多余的用户: $($localUser.Name)"; Remove-Item $localUser.FullName -Recurse -Force
                }
            }
            foreach ($remoteUser in $remoteUserFolders) {
                $sourcePath = $remoteUser.FullName; $destPath = Join-Path $destDataPath $remoteUser.Name
                robocopy $sourcePath $destPath /E /PURGE $robocopyExcludeArgs /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) { Write-Error "Robocopy 恢复 '$($remoteUser.Name)' 失败！错误码: $LASTEXITCODE"; return }
            }
        }
        if ($syncConfigYaml -eq "true" -and (Test-Path (Join-Path $tempDir "config.yaml"))) {
            Copy-Item (Join-Path $tempDir "config.yaml") $ST_Dir -Force
        }
        Write-Host ""
        Write-Success "数据已从云端成功恢复！"
    } finally {
        if (Test-Path $tempDir){ Remove-Item $tempDir -Recurse -Force }
    }
    Press-Any-Key
}

function Clear-GitSyncConfig {
    if (Test-Path $GitSyncConfigFile) {
        $confirm = Read-Host "确认要清除已保存的Git同步配置吗？(y/n)"
        if ($confirm -eq 'y') {
            Remove-Item $GitSyncConfigFile -Force
            Write-Success "Git同步配置已清除。"
        } else {
            Write-Warning "操作已取消。"
        }
    } else {
        Write-Warning "未找到任何Git同步配置。"
    }
    Press-Any-Key
}

function Show-ManageGitConfigMenu {
    while ($true) {
        Clear-Host
        Write-Header "管理同步配置"
        Write-Host "      [1] " -NoNewline; Write-Host "修改/设置同步信息" -ForegroundColor Cyan
        Write-Host "      [2] " -NoNewline; Write-Host "清除所有同步配置" -ForegroundColor Red
        Write-Host "      [0] " -NoNewline; Write-Host "返回上一级" -ForegroundColor Cyan
        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            "1" { Set-GitSyncConfig }
            "2" { Clear-GitSyncConfig }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

function Update-SyncRuleValue($key, $value, $file) {
    $config = Parse-ConfigFile $file
    if ([string]::IsNullOrWhiteSpace($value)) {
        $config.Remove($key) | Out-Null
    } else {
        $config[$key] = $value
    }
    $newContent = $config.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=`"$($_.Value)`"" }
    Set-Content -Path $file -Value $newContent -Encoding utf8
}

function Show-AdvancedSyncSettingsMenu {
    while ($true) {
        Clear-Host
        Write-Header "高级同步设置"
        $rules = Parse-ConfigFile $SyncRulesConfigFile
        Write-Host "  [1] 同步 config.yaml         : " -NoNewline
        if ($rules["SYNC_CONFIG_YAML"] -eq "true") { Write-Host "开启" -F Green } else { Write-Host "关闭" -F Red }
        Write-Host "  [2] 设置用户数据映射        : " -NoNewline
        if ($rules.ContainsKey("USER_MAP") -and -not [string]::IsNullOrWhiteSpace($rules["USER_MAP"])) {
            $localUser = $rules["USER_MAP"].Split(':')[0]
            $remoteUser = $rules["USER_MAP"].Split(':')[1]
            Write-Host "本地 $localUser -> 云端 $remoteUser" -F Green
        } else {
            Write-Host "未设置 (将同步所有用户)" -F Red
        }
        Write-Host "`n  [3] " -NoNewline; Write-Host "重置所有高级设置" -F Red
        Write-Host "  [0] " -NoNewline; Write-Host "返回上一级" -F Cyan
        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            "1" {
                $newStatus = if ($rules["SYNC_CONFIG_YAML"] -eq "true") { "false" } else { "true" }
                Update-SyncRuleValue "SYNC_CONFIG_YAML" $newStatus $SyncRulesConfigFile
                Write-Success "config.yaml 同步已变更为: $newStatus"; Start-Sleep 1
            }
            "2" {
                $local_u = Read-Host "请输入本地用户文件夹名 [直接回车默认为 default-user]"
                if ([string]::IsNullOrWhiteSpace($local_u)) { $local_u = "default-user" }
                $remote_u = Read-Host "请输入要映射到的云端用户文件夹名 [直接回车默认为 default-user]"
                if ([string]::IsNullOrWhiteSpace($remote_u)) { $remote_u = "default-user" }
                Update-SyncRuleValue "USER_MAP" "$($local_u):$($remote_u)" $SyncRulesConfigFile
                Write-Success "用户映射已设置为: $local_u -> $remote_u"; Start-Sleep 1.5
            }
            "3" {
                if (Test-Path $SyncRulesConfigFile) {
                    Remove-Item $SyncRulesConfigFile -Force
                    Write-Success "所有高级同步设置已重置。"
                } else {
                    Write-Warning "没有需要重置的设置。"
                }
                Start-Sleep 1.5
            }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

function Show-GitSyncMenu {
    while ($true) {
        Clear-Host
        Write-Header "数据同步 (Git 方案)"
        if (-not (Test-Path (Join-Path $ST_Dir "start.bat"))) {
            Write-Warning "酒馆尚未安装，无法使用数据同步功能。`n请先返回主菜单选择 [首次部署]。"
            Press-Any-Key
            return
        }
        if (-not (Test-GitSyncDeps)) { return }
        if (-not (Ensure-GitIdentity)) { return }
        Clear-Host
        Write-Header "数据同步 (Git 方案)"
        $gitConfig = Parse-ConfigFile $GitSyncConfigFile
        if ($gitConfig.ContainsKey("REPO_URL")) {
            $currentRepoName = [System.IO.Path]::GetFileNameWithoutExtension($gitConfig["REPO_URL"])
            Write-Host "      " -NoNewline; Write-Host "当前仓库: $currentRepoName" -F Yellow
            Write-Host ""
        }
        Write-Host "`n      [1] " -NoNewline; Write-Host "管理同步配置 (仓库地址/令牌)" -F Cyan
        Write-Host "      [2] " -NoNewline; Write-Host "备份数据 (上传至云端)" -F Green
        Write-Host "      [3] " -NoNewline; Write-Host "恢复数据 (从云端下载)" -F Yellow
        Write-Host "      [4] " -NoNewline; Write-Host "高级同步设置 (用户映射等)" -F Cyan
        Write-Host "      [5] " -NoNewline; Write-Host "导出扩展链接" -F Cyan
        Write-Host "`n      [0] " -NoNewline; Write-Host "返回主菜单" -F Cyan
        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            "1" { Show-ManageGitConfigMenu }
            "2" { Backup-ToCloud }
            "3" { Restore-FromCloud }
            "4" { Show-AdvancedSyncSettingsMenu }
            "5" { Export-ExtensionLinks }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

function Export-ExtensionLinks {
    Clear-Host
    Write-Header "导出扩展链接"
    $allLinks = [System.Collections.Generic.List[string]]::new()
    $outputContent = [System.Text.StringBuilder]::new()

    function Get-RepoUrlFromPath($path) {
        if (Test-Path (Join-Path $path ".git")) {
            $url = (Invoke-Command -ScriptBlock {
                param($p)
                Set-Location -Path $p
                git config --get remote.origin.url
            } -ArgumentList $path)
            return $url.Trim()
        }
        return $null
    }

    $globalExtPath = Join-Path $ST_Dir "public/scripts/extensions/third-party"
    if (Test-Path $globalExtPath) {
        $globalDirs = Get-ChildItem -Path $globalExtPath -Directory -ErrorAction SilentlyContinue
        if ($globalDirs) {
            $outputContent.AppendLine("═══ 全局扩展 ═══") | Out-Null
            foreach ($dir in $globalDirs) {
                $repoUrl = Get-RepoUrlFromPath $dir.FullName
                if (-not [string]::IsNullOrWhiteSpace($repoUrl)) {
                    $outputContent.AppendLine($repoUrl) | Out-Null
                    $allLinks.Add($repoUrl)
                }
            }
        }
    }

    $dataPath = Join-Path $ST_Dir "data"
    if (Test-Path $dataPath) {
        $userDirs = Get-ChildItem -Path $dataPath -Directory -ErrorAction SilentlyContinue
        foreach ($userDir in $userDirs) {
            $userExtPath = Join-Path $userDir.FullName "extensions"
            if (Test-Path $userExtPath) {
                $userExtDirs = Get-ChildItem -Path $userExtPath -Directory -ErrorAction SilentlyContinue
                if ($userExtDirs) {
                    $userLinks = [System.Collections.Generic.List[string]]::new()
                    foreach ($extDir in $userExtDirs) {
                        $repoUrl = Get-RepoUrlFromPath $extDir.FullName
                        if (-not [string]::IsNullOrWhiteSpace($repoUrl)) {
                            $userLinks.Add($repoUrl)
                            $allLinks.Add($repoUrl)
                        }
                    }
                    if ($userLinks.Count -gt 0) {
                        $outputContent.AppendLine() | Out-Null
                        $outputContent.AppendLine("═══ 用户 [$($userDir.Name)] 的扩展 ═══") | Out-Null
                        $userLinks | ForEach-Object { $outputContent.AppendLine($_) | Out-Null }
                    }
                }
            }
        }
    }

    if ($allLinks.Count -eq 0) {
        Write-Warning "未找到任何已安装的Git扩展。"
    } else {
        Write-Host $outputContent.ToString()
        $saveChoice = Read-Host "`n是否将以上链接保存到桌面？ [y/N]"
        if ($saveChoice -eq 'y' -or $saveChoice -eq 'Y') {
            try {
                $desktopPath = [System.Environment]::GetFolderPath('Desktop')
                $fileName = "ST_扩展链接_$(Get-Date -Format 'yyyy-MM-dd').txt"
                $filePath = Join-Path $desktopPath $fileName
                Set-Content -Path $filePath -Value $outputContent.ToString() -Encoding UTF8
                Write-Success "链接已成功保存到桌面: $fileName"
            } catch {
                Write-Error "保存失败: $($_.Exception.Message)"
            }
        }
    }
    Press-Any-Key
}

function Start-SillyTavern {
    Clear-Host
    Write-Header "启动酒馆"

    $labConfig = Parse-ConfigFile $LabConfigFile
    if ($labConfig.ContainsKey("AUTO_START_GCLI") -and $labConfig["AUTO_START_GCLI"] -eq "true") {
        if (Test-Path $GcliDir) {
            if ((Get-Gcli2ApiStatus) -ne "运行中") {
                Write-Host "[gcli2api] 检测到自动启动已开启，正在新窗口中启动服务..." -ForegroundColor DarkGray
                if (Start-Gcli2ApiService) {
                    Start-Sleep -Seconds 1
                } else {
                    Start-Sleep -Seconds 2
                }
            }
        } else {
            Write-Warning "[警告] gcli2api 目录不存在，无法自动启动。"
        }
    }

    if (-not (Test-Path (Join-Path $ST_Dir "start.bat"))) {
        Write-Warning "酒馆尚未安装，请先部署。"
        Press-Any-Key
        return
    }
    
    Check-PortAndShowError -SillyTavernPath $ST_Dir

    Set-Location $ST_Dir
    Write-Host "正在配置NPM镜像并准备启动环境..."
    npm config set registry https://registry.npmmirror.com
    
    $startBatPath = Join-Path $ST_Dir "start.bat"
    Write-Success "环境准备就绪，即将在新窗口中启动酒馆服务..."
    Write-Warning "首次启动或更新后会自动安装依赖，耗时可能较长，请耐心等待..."
    Write-Host "酒馆将在新窗口中运行，请勿关闭该窗口。" -ForegroundColor Cyan
    Write-Host "如需停止服务，请直接关闭酒馆运行窗口。" -ForegroundColor Cyan
    
    Start-Sleep -Seconds 2
    
    Start-Process -FilePath $startBatPath -WorkingDirectory $ST_Dir
    
    Write-Success "酒馆已在新窗口中启动！"
    Write-Host "提示：酒馆服务将在新窗口中运行，请保持该窗口开启。" -ForegroundColor Green
    Write-Host "      本助手窗口现在可以关闭，或按任意键返回主菜单。" -ForegroundColor Cyan
    Press-Any-Key
}

function Install-SillyTavern {
    param([bool]$autoStart = $true)
    Clear-Host
    Write-Header "酒馆部署向导"

    Write-Header "1/3: 检查核心依赖"
    if (-not (Check-Command "git") -or -not (Check-Command "node")) {
        Write-Warning "错误: Git 或 Node.js 未安装。即将为您展示帮助文档..."
        Start-Sleep -Seconds 3; Open-HelpDocs; return
    }
    Write-Success "核心依赖 (Git, Node.js) 已找到。"

    Write-Header "2/3: 下载酒馆主程序"
    if (Test-Path $ST_Dir) {
        Write-Warning "目录 $ST_Dir 已存在，跳过下载。"
    } else {
        $downloadSuccess = $false
        $fullRetestAttempted = $false
        while (-not $downloadSuccess) {
            $mirrorsToTry = @()
            if (-not $fullRetestAttempted) {
                $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'OfficialOnly'
                if ($mirrorsToTry.Count -eq 0) {
                    $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'MirrorsOnly'
                }
            } else {
                $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'All'
            }

            if ($mirrorsToTry.Count -eq 0) {
                $retryChoice = Read-Host "`n所有线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
                if ($retryChoice -eq 'n') { Write-ErrorExit "用户取消操作。" }
                $fullRetestAttempted = $false; continue
            }

            foreach ($mirrorUrl in $mirrorsToTry) {
                $mirrorHost = ($mirrorUrl -split '/')[2]
                Write-Warning "正在尝试从线路 [$($mirrorHost)] 下载 ($Repo_Branch 分支)..."
                $gitOutput = git -c credential.helper='' clone --depth 1 -b $Repo_Branch $mirrorUrl $ST_Dir 2>&1
                if ($LASTEXITCODE -eq 0) { $downloadSuccess = $true; break }
                if ($gitOutput -match "Permission denied") {
                    Write-Error "权限不足，无法创建目录。请尝试以【管理员身份】运行本脚本。"
                    Press-Any-Key
                    exit
                }
                if ($gitOutput -match "Failed to connect to .* port .*|Could not connect to server") {
                    Write-Error "网络连接失败，可能是代理配置问题。"
                    Write-Host "  请检查：" -ForegroundColor Cyan
                    Write-Host "  1. 如果您【需要】使用代理：请确保代理软件已正常运行，开启 TUN 模式或在助手内正确配置代理端口（主菜单 -> 9）。" -ForegroundColor Cyan
                    Write-Host "  2. 如果您【不】使用代理：请检查并清除之前可能设置过的Git全局代理。" -ForegroundColor Cyan
                    Write-Host "     (可在任意终端执行命令： git config --global --unset http.proxy 后重试)" -ForegroundColor DarkGray
                    Press-Any-Key
                }
                Write-Error "使用线路 [$($mirrorHost)] 下载失败！Git输出: $($gitOutput | Out-String)"
                if (Test-Path $ST_Dir) { Remove-Item -Recurse -Force $ST_Dir }
            }

            if (-not $downloadSuccess) {
                if (-not $fullRetestAttempted) {
                    $fullRetestAttempted = $true
                    Write-Error "预选线路均下载失败。将进行全量测速并重试所有可用线路..."
                } else {
                    Write-Error "已尝试所有可用线路，下载均失败。"
                }
            }
        }
        Write-Success "主程序下载完成。"
    }

    Write-Header "3/3: 配置 NPM 环境并安装依赖"
    if (Test-Path $ST_Dir) {
        if (-not (Run-NpmInstallWithRetry)) { Write-ErrorExit "依赖安装最终失败，部署中断。" }
    } else { Write-Warning "酒馆目录不存在，跳过此步。" }

    if ($autoStart) {
        Write-Host "`n"; Write-Success "部署完成！"; Write-Warning "即将进行首次启动..."; Start-Sleep -Seconds 3; Start-SillyTavern
    } else { Write-Success "全新版本下载与配置完成。" }
}

function New-LocalZipBackup {
    param([string]$BackupType, [string[]]$PathsToBackup)
    if (-not (Test-Path $ST_Dir)) {
        Write-Error "酒馆目录不存在，无法创建本地备份。"
        return $null
    }
    if ($null -eq $PathsToBackup) {
        $defaultPaths = @("data", "public/scripts/extensions/third-party", "plugins", "config.yaml")
        $PathsToBackup = if (Test-Path $BackupPrefsConfigFile) { Get-Content $BackupPrefsConfigFile } else { $defaultPaths }
    }
    if (-not (Test-Path $Backup_Root_Dir)) { New-Item -Path $Backup_Root_Dir -ItemType Directory | Out-Null }

    $allBackups = Get-ChildItem -Path $Backup_Root_Dir -Filter "*.zip" | Sort-Object CreationTime
    $currentBackupCount = $allBackups.Count
    Write-Host ""
    Write-Host "当前本地备份数: $currentBackupCount/$Backup_Limit" -ForegroundColor Yellow
    if ($currentBackupCount -ge $Backup_Limit) {
        $oldestBackup = $allBackups[0]
        Write-Warning "警告：本地备份已达上限 ($Backup_Limit/$Backup_Limit)。"
        Write-Host "创建新备份将会自动删除最旧的一个备份文件:"
        Write-Host "  - " -NoNewline; Write-Host "将被删除: $($oldestBackup.Name)" -ForegroundColor Red
        $confirmOverwrite = Read-Host "是否继续创建本地备份？[Y/n]"
        if ($confirmOverwrite -eq 'n' -or $confirmOverwrite -eq 'N') { Write-Warning "操作已取消。"; return $null }
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $backupName = "ST_备份_$($BackupType)_$($timestamp).zip"
    $backupZipPath = Join-Path $Backup_Root_Dir $backupName
    Write-Warning "正在创建“$($BackupType)”类型的本地备份..."
    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -Path $stagingDir -ItemType Directory | Out-Null
    try {
        $hasFiles = $false
        foreach ($item in $PathsToBackup) {
            $sourcePath = Join-Path $ST_Dir $item
            if (-not (Test-Path $sourcePath)) { continue }
            $hasFiles = $true
            if (Test-Path $sourcePath -PathType Container) {
                $destPath = Join-Path $stagingDir $item
                robocopy $sourcePath $destPath /E /XD "_cache" "backups" /XF "*.log" /NFL /NDL /NJH /NJS /NP /R:2 /W:5 | Out-Null
            } else {
                Copy-Item -Path $sourcePath -Destination $stagingDir -Force
            }
        }
        if (-not $hasFiles) { Write-Error "未能收集到任何有效文件进行本地备份。"; return $null }
        Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $backupZipPath -Force -ErrorAction Stop
        if ($currentBackupCount -ge $Backup_Limit) {
            Write-Warning "正在清理旧备份..."
            Remove-Item $oldestBackup.FullName
            Write-Host "  - 已删除: $($oldestBackup.Name)"
        }
        $newAllBackups = Get-ChildItem -Path $Backup_Root_Dir -Filter "*.zip"
        Write-Success "本地备份成功：$backupName (当前: $($newAllBackups.Count)/$Backup_Limit)"
        Write-Host "  " -NoNewline; Write-Host "保存路径: $backupZipPath" -F Cyan
        return $backupZipPath
    } catch {
        Write-Error "创建本地 .zip 备份失败！错误信息: $($_.Exception.Message)"
        return $null
    } finally {
        if (Test-Path $stagingDir) { Remove-Item -Path $stagingDir -Recurse -Force }
    }
}

function Update-SillyTavern {
    Clear-Host
    Write-Header "更新酒馆"
    if (-not (Test-Path (Join-Path $ST_Dir ".git"))) {
        Write-Warning "未找到Git仓库，请先完整部署。"; Press-Any-Key; return
    }
    
    $updateSuccess = $false
    $fullRetestAttempted = $false
    while (-not $updateSuccess) {
        Set-Location $ST_Dir
        $mirrorsToTry = @()
        if (-not $fullRetestAttempted) {
            $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'OfficialOnly'
            if ($mirrorsToTry.Count -eq 0) {
                $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'MirrorsOnly'
            }
        } else {
            $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'All'
        }

        if ($mirrorsToTry.Count -eq 0) {
            $retryChoice = Read-Host "`n所有线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
            if ($retryChoice -eq 'n') { Write-Warning "用户取消操作。"; break }
            $fullRetestAttempted = $false; continue
        }

        $pullSucceeded = $false
        foreach ($mirrorUrl in $mirrorsToTry) {
            $mirrorHost = ($mirrorUrl -split '/')[2]
            Write-Warning "正在尝试使用线路 [$($mirrorHost)] 更新..."
            git remote set-url origin $mirrorUrl
            $gitOutput = git -c credential.helper='' pull origin $Repo_Branch --allow-unrelated-histories --no-rebase 2>&1
            if ($LASTEXITCODE -eq 0) {
                if ($gitOutput -match "Already up to date") { Write-Success "代码已是最新，无需更新。" } else { Write-Success "代码更新成功。" }
                $pullSucceeded = $true; break
            } elseif ($gitOutput -match "Your local changes to the following files would be overwritten|conflict|error: Pulling is not possible because you have unmerged files.|divergent branches|reconcile|index\.lock") {
                Clear-Host
                Write-Header "检测到更新冲突"
                
                $reason = "未知原因"
                $actionDesc = "放弃代码修改并清理环境"
                
                if ($gitOutput -match "Your local changes") {
                    if ($gitOutput -match "package-lock\.json") {
                        $reason = "依赖配置文件 (package-lock.json) 发生冲突。这通常是由于安装扩展或自动更新依赖引起的，并非您的错误。"
                        $actionDesc = "重置系统配置文件以确保更新顺利进行"
                    } else {
                        $reason = "本地代码文件被修改（可能是您手动修改过，或某些插件自动改动了文件）。"
                        $actionDesc = "放弃本地代码修改并清理环境"
                    }
                } elseif ($gitOutput -match "divergent branches|reconcile") {
                    $reason = "本地版本与远程版本存在分叉（通常是由于非正常的更新中断引起）。"
                    $actionDesc = "同步版本状态并清理环境"
                } elseif ($gitOutput -match "index\.lock") {
                    $reason = "Git 环境被锁定（可能有其他 Git 进程正在运行或上次操作异常中断）。"
                    $actionDesc = "解除锁定并清理环境"
                } elseif ($gitOutput -match "conflict|unmerged files") {
                    $reason = "代码合并时发生冲突。"
                    $actionDesc = "放弃冲突的修改并清理环境"
                }

                Write-Warning "原因: $reason"
                Write-Host "`n--- 冲突/错误预览 ---`n$($gitOutput | Select-String -Pattern '^\s+|hint:|fatal:' | Select -First 8)`n--------------------"
                Write-Host "`n此操作将$($actionDesc)，【不会】影响您的聊天记录、角色卡等用户数据。" -ForegroundColor Cyan
                $confirmChoice = Read-Host "是否要强制覆盖本地修改以完成更新？(直接回车=是, 输入n=否)"
                if ($confirmChoice -eq 'n' -or $confirmChoice -eq 'N') {
                    Write-Warning "已取消更新。"; Press-Any-Key; return
                }
                
                Write-Warning "正在清理环境并执行强制覆盖 (git reset --hard)..."
                if (Test-Path ".git/index.lock") { Remove-Item ".git/index.lock" -Force }
                git reset --hard "origin/$Repo_Branch"
                git clean -fd
                git -c credential.helper='' pull origin $Repo_Branch --allow-unrelated-histories --no-rebase
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "强制更新成功。"
                    $pullSucceeded = $true
                } else {
                    Write-Error "强制更新失败！"
                }
                break
            } else {
                if ($gitOutput -match "Permission denied") {
                    Write-Error "权限不足，无法写入文件。请尝试以【管理员身份】运行本脚本。"
                    Press-Any-Key
                    return
                }
                if ($gitOutput -match "Failed to connect to .* port .*|Could not connect to server") {
                    Write-Error "网络连接失败，可能是代理配置问题。"
                    Write-Host "  请检查：" -ForegroundColor Cyan
                    Write-Host "  1. 如果您【需要】使用代理：请确保代理软件已正常运行，且助手内的代理已正确配置（主菜单 -> 9）。" -ForegroundColor Cyan
                    Write-Host "  2. 如果您【不】使用代理：请检查并清除之前可能设置过的Git全局代理。" -ForegroundColor Cyan
                    Write-Host "     (可在任意终端执行命令： git config --global --unset http.proxy 后重试)" -ForegroundColor DarkGray
                    Press-Any-Key
                }
                Write-Error "使用线路 [$($mirrorHost)] 更新失败！Git输出: $($gitOutput | Out-String)"
            }
        }

        if ($pullSucceeded) {
            if (Run-NpmInstallWithRetry) { $updateSuccess = $true }
        } else {
            if (-not $fullRetestAttempted) {
                $fullRetestAttempted = $true
                Write-Error "预选线路均更新失败。将进行全量测速并重试所有可用线路..."
            } else {
                Set-Location $ScriptBaseDir
                Write-Error "已尝试所有可用线路，更新均失败。"
            }
        }
    }
    Set-Location $ScriptBaseDir
    if ($updateSuccess) { Write-Success "酒馆更新完成！" }
    Press-Any-Key
}

function Rollback-SillyTavern {
    Clear-Host
    Write-Header "回退酒馆版本"
    if (-not (Test-Path (Join-Path $ST_Dir ".git"))) {
        Write-Warning "未找到Git仓库，请先完整部署。"; Press-Any-Key; return
    }

    Set-Location $ST_Dir
    Write-Warning "正在从远程仓库获取所有版本信息..."
    
    $fetchSuccess = $false
    $fullRetestAttempted = $false
    while (-not $fetchSuccess) {
        $mirrorsToTry = @()
        if (-not $fullRetestAttempted) {
            $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'OfficialOnly'
            if ($mirrorsToTry.Count -eq 0) {
                $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'MirrorsOnly'
            }
        } else {
            $mirrorsToTry = Find-AvailableMirrors -TestType 'Download' -Mode 'All'
        }

        if ($mirrorsToTry.Count -eq 0) {
            $retryChoice = Read-Host "`n所有线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
            if ($retryChoice -eq 'n') { Write-Error "用户取消操作。"; Press-Any-Key; return }
            $fullRetestAttempted = $false; continue
        }

        foreach ($mirrorUrl in $mirrorsToTry) {
            $mirrorHost = ($mirrorUrl -split '/')[2]
            Write-Warning "正在尝试使用线路 [$($mirrorHost)] 获取版本列表..."
            git remote set-url origin $mirrorUrl
            if (Test-Path ".git/index.lock") { Remove-Item ".git/index.lock" -Force }
            git -c credential.helper='' fetch --all --tags 2>$null
            if ($LASTEXITCODE -eq 0) { $fetchSuccess = $true; break }
            Write-Error "使用线路 [$($mirrorHost)] 获取失败！正在切换下一条..."
        }

        if (-not $fetchSuccess) {
            if (-not $fullRetestAttempted) {
                $fullRetestAttempted = $true
                Write-Error "预选线路均获取失败。将进行全量测速并重试所有可用线路..."
            } else {
                Write-Error "已尝试所有可用线路，获取版本信息均失败。"; Press-Any-Key; return
            }
        }
    }

    Write-Host ""
    Write-Success "版本信息获取成功。"
    $allTags = git tag --sort=-v:refname | Where-Object { $_ -match '^\d' }
    if ($allTags.Count -eq 0) {
        Write-Error "未能获取到任何有效的版本标签。"; Press-Any-Key; return
    }

    $currentPage = 0
    $pageSize = 15
    $filter = ""
    while ($true) {
        Clear-Host
        Write-Header "选择要回退的版本"
        $filteredTags = if ([string]::IsNullOrWhiteSpace($filter)) { $allTags } else { $allTags | Select-String -Pattern $filter }
        $totalPages = [Math]::Ceiling($filteredTags.Count / $pageSize)
        $currentPage = [Math]::Max(0, [Math]::Min($currentPage, $totalPages - 1))
        $tagsToShow = $filteredTags | Select-Object -Skip ($currentPage * $pageSize) -First $pageSize
        
        Write-Host "--- 共 $($filteredTags.Count) 个版本，第 $($currentPage + 1)/$totalPages 页 ---"
        for ($i = 0; $i -lt $tagsToShow.Count; $i++) {
            $index = ($currentPage * $pageSize) + $i + 1
            Write-Host ("  [{0,3}] {1}" -f $index, $tagsToShow[$i])
        }

        Write-Host "`n操作提示:" -ForegroundColor Yellow
        Write-Host "  - 直接输入 " -NoNewline; Write-Host "序号" -ForegroundColor Green -NoNewline; Write-Host " (如 '123') 或 " -NoNewline; Write-Host "版本全名" -ForegroundColor Green -NoNewline; Write-Host " (如 '1.10.0') 进行选择"
        Write-Host "  - 输入 " -NoNewline; Write-Host "a" -ForegroundColor Green -NoNewline; Write-Host " 翻到上一页，" -NoNewline; Write-Host "d" -ForegroundColor Green -NoNewline; Write-Host " 翻到下一页"
        Write-Host "  - 输入 " -NoNewline; Write-Host "f [关键词]" -ForegroundColor Green -NoNewline; Write-Host " 筛选版本 (如 'f 1.10' 或 'f 2023-')"
        Write-Host "  - 输入 " -NoNewline; Write-Host "c" -ForegroundColor Green -NoNewline; Write-Host " 清除筛选，" -NoNewline; Write-Host "q" -ForegroundColor Green -NoNewline; Write-Host " 退出"
        $userInput = Read-Host "`n请输入"

        if ($userInput -eq 'q') { Write-Warning "操作已取消。"; Press-Any-Key; return }
        elseif ($userInput -eq 'a') { if ($currentPage -gt 0) { $currentPage-- } }
        elseif ($userInput -eq 'd') { if (($currentPage + 1) * $pageSize -lt $filteredTags.Count) { $currentPage++ } }
        elseif ($userInput.StartsWith("f ")) { $filter = $userInput.Substring(2); $currentPage = 0 }
        elseif ($userInput -eq 'c') { $filter = ""; $currentPage = 0 }
        else {
            $selectedTag = $null
            if ($userInput -match '^\d+$' -and [int]$userInput -ge 1 -and [int]$userInput -le $filteredTags.Count) {
                $selectedTag = $filteredTags[[int]$userInput - 1]
            } elseif ($filteredTags -contains $userInput) {
                $selectedTag = $userInput
            }

            if ($selectedTag) {
                Write-Host "`n此操作仅会改变酒馆的程序版本，不会影响您的用户数据 (如聊天记录、角色卡等)。" -ForegroundColor Cyan
                $confirm = Read-Host "确认要切换到版本 $($selectedTag) 吗？(直接回车=是, 输入n=否)"
                if ($confirm -eq 'n' -or $confirm -eq 'N') { Write-Warning "操作已取消。"; continue }

                Write-Warning "正在切换到版本 $selectedTag ..."
                if (Test-Path ".git/index.lock") { Remove-Item ".git/index.lock" -Force }
                $checkoutOutput = git checkout -f "tags/$selectedTag" 2>&1
                if ($LASTEXITCODE -ne 0) {
                    Write-Error "切换版本失败！Git输出: $($checkoutOutput | Out-String)"; Press-Any-Key; return
                }
                git clean -fd
                
                Write-Host ""
                Write-Success "版本已成功切换到 $selectedTag"
                if (Run-NpmInstallWithRetry) {
                    Write-Host ""
                    Write-Success "版本回退完成！"
                } else {
                    Write-Error "版本已切换，但依赖安装失败。请尝试手动修复。"
                }
                Press-Any-Key
                return
            } else {
                Write-Error "无效的输入！"; Start-Sleep 1
            }
        }
    }
}

function Show-VersionManagementMenu {
    while ($true) {
        Clear-Host
        Write-Header "酒馆版本管理"
        Write-Host "      [1] " -NoNewline; Write-Host "更新酒馆" -ForegroundColor Green
        Write-Host "      [2] " -NoNewline; Write-Host "回退版本" -ForegroundColor Yellow
        Write-Host "`n      [0] " -NoNewline; Write-Host "返回主菜单" -ForegroundColor Cyan
        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            "1" { Update-SillyTavern }
            "2" { Rollback-SillyTavern }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

function Run-BackupInteractive {
    Clear-Host
    if (-not (Test-Path $ST_Dir)) {
        Write-Warning "酒馆尚未安装，无法备份。"
        Press-Any-Key
        return
    }
    $AllPaths = [ordered]@{
        "data"                                  = "用户数据 (聊天/角色/设置)"
        "public/scripts/extensions/third-party" = "前端扩展"
        "plugins"                               = "后端扩展"
        "config.yaml"                           = "服务器配置 (网络/安全)"
    }
    $Options = @($AllPaths.Keys)
    $SelectionStatus = @{}
    $DefaultSelection = @("data", "public/scripts/extensions/third-party", "plugins", "config.yaml")
    $PathsToLoad = if (Test-Path $BackupPrefsConfigFile) { Get-Content $BackupPrefsConfigFile } else { $DefaultSelection }
    $Options | ForEach-Object { $SelectionStatus[$_] = $false }
    $PathsToLoad | ForEach-Object { if ($SelectionStatus.ContainsKey($_)) { $SelectionStatus[$_] = $true } }

    while ($true) {
        Clear-Host
        Write-Header "创建新的本地备份"
        Write-Host "此处的选择将作为所有本地备份(包括自动备份)的范围。"
        Write-Host "输入数字可切换勾选状态。"
        for ($i = 0; $i -lt $Options.Count; $i++) {
            $key = $Options[$i]
            $description = $AllPaths[$key]
            if ($SelectionStatus[$key]) {
                Write-Host ("  [{0,2}] " -f ($i + 1)) -NoNewline
                Write-Host "[✓] $key" -ForegroundColor Green
            } else {
                Write-Host ("  [{0,2}] [ ] $key" -f ($i + 1))
            }
            Write-Host "      ( $description )" -ForegroundColor Cyan
        }
        Write-Host "`n      "; Write-Host "[回车] 保存设置并开始备份" -NoNewline -ForegroundColor Green
        Write-Host "      "; Write-Host "[0] 返回上一级" -NoNewline -ForegroundColor Red
        Write-Host ""
        $userChoice = Read-Host "请操作 [输入数字, 回车 或 0]"
        if ([string]::IsNullOrEmpty($userChoice)) { break }
        elseif ($userChoice -eq '0') { Write-Warning "操作已取消。"; return }
        elseif ($userChoice -match '^\d+$' -and [int]$userChoice -ge 1 -and [int]$userChoice -le $Options.Count) {
            $selectedIndex = [int]$userChoice - 1
            $selectedKey = $Options[$selectedIndex]
            $SelectionStatus[$selectedKey] = -not $SelectionStatus[$selectedKey]
        } else {
            Write-Warning "无效输入。"; Start-Sleep 1
        }
    }
    $pathsToSave = @()
    foreach ($key in $Options) { if ($SelectionStatus[$key]) { $pathsToSave += $key } }
    if ($pathsToSave.Count -eq 0) {
        Write-Warning "您没有选择任何项目，本地备份已取消。"
        Press-Any-Key
        return
    }
    Set-Content -Path $BackupPrefsConfigFile -Value ($pathsToSave -join "`r`n") -Encoding utf8
    Write-Success "备份范围已保存！"
    Start-Sleep 1
    if (New-LocalZipBackup -BackupType "手动" -PathsToBackup $pathsToSave) {
    } else {
        Write-Error "手动本地备份创建失败。"
    }
    Press-Any-Key
}

function Show-ManageBackupsMenu {
    while ($true) {
        Clear-Host
        if (-not (Test-Path $Backup_Root_Dir)) { New-Item -Path $Backup_Root_Dir -ItemType Directory | Out-Null }
        $backupFiles = Get-ChildItem -Path $Backup_Root_Dir -Filter "*.zip" | Sort-Object CreationTime -Descending
        $count = $backupFiles.Count
        Write-Header "管理已有的本地备份 (当前: $count/$Backup_Limit)"
        if ($count -eq 0) {
            Write-Host "      " -NoNewline; Write-Host "没有找到任何本地备份文件。" -ForegroundColor Yellow
        } else {
            Write-Host " [序号] [类型]   [创建日期与时间]      [大小]     [文件名]"
            Write-Host " ─────────────────────────────────────────────────────────────────────────"
            for ($i = 0; $i -lt $count; $i++) {
                $file = $backupFiles[$i]
                $parts = $file.Name -split '[_.]'
                $type = if ($parts.Length -ge 3) { $parts[2] } else { "未知" }
                $date = if ($parts.Length -ge 4) { $parts[3] } else { "----------" }
                $time = if ($parts.Length -ge 5) { $parts[4].Replace("-", ":") } else { "-----" }
                $size = if ($file.Length -gt 1MB) { "{0:F1} MB" -f ($file.Length / 1MB) } else { "{0:F1} KB" -f ($file.Length / 1KB) }
                Write-Host (" [{0,2}]   {1,-7}  {2} {3}  {4,-9}  {5}" -f ($i + 1), $type, $date, $time, $size, $file.Name)
            }
        }
        Write-Host "`n  " -NoNewline; Write-Host "请输入要删除的备份序号 (多选请用空格隔开, 输入 'all' 全选)。" -ForegroundColor Red
        Write-Host "  按 " -NoNewline; Write-Host "[回车] 键直接返回" -ForegroundColor Cyan -NoNewline
        Write-Host "，或输入 " -NoNewline; Write-Host "[0] 返回" -ForegroundColor Cyan -NoNewline; Write-Host "。"
        $selection = Read-Host "  请操作"
        if ([string]::IsNullOrEmpty($selection) -or $selection -eq '0') { break }
        $filesToDelete = New-Object System.Collections.Generic.List[System.IO.FileInfo]
        if ($selection -eq 'all' -or $selection -eq '*') {
            $filesToDelete.AddRange($backupFiles)
        } else {
            $indices = $selection -split ' ' | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
            foreach ($index in $indices) {
                if ($index -ge 1 -and $index -le $count) {
                    $filesToDelete.Add($backupFiles[$index - 1])
                } else {
                    Write-Error "无效的序号: $index"; Start-Sleep 2; continue 2
                }
            }
        }
        if ($filesToDelete.Count -gt 0) {
            Clear-Host
            Write-Warning "警告：以下本地备份文件将被永久删除，此操作不可撤销！"
            $filesToDelete | ForEach-Object { Write-Host "  - " -NoNewline; Write-Host $_.Name -ForegroundColor Red }
            $confirmDelete = Read-Host "`n确认要删除这 $($filesToDelete.Count) 个文件吗？[y/N]"
            if ($confirmDelete -eq 'y' -or $confirmDelete -eq 'Y') {
                $filesToDelete | ForEach-Object { Remove-Item $_.FullName }
                Write-Success "选定的本地备份文件已删除。"; Start-Sleep 2
            } else {
                Write-Warning "删除操作已取消。"; Start-Sleep 2
            }
        }
    }
}

function Show-BackupMenu {
    while ($true) {
        Clear-Host
        Write-Header "本地备份管理"
        Write-Host "      [1] " -NoNewline; Write-Host "创建新的本地备份" -ForegroundColor Cyan
        Write-Host "      [2] " -NoNewline; Write-Host "管理已有的本地备份" -ForegroundColor Cyan
        Write-Host "`n      [0] " -NoNewline; Write-Host "返回主菜单" -ForegroundColor Cyan
        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            '1' { Run-BackupInteractive }
            '2' { Show-ManageBackupsMenu }
            '0' { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

function Get-GitVersionInfo {
    param([string]$Path)
    if (-not (Test-Path (Join-Path $Path ".git"))) { return "未知" }
    try {
        $currentLocation = Get-Location
        Set-Location $Path
        $date = git log -1 --format=%cd --date=format:'%Y-%m-%d' 2>$null
        $hash = git rev-parse --short HEAD 2>$null
        Set-Location $currentLocation
        if ($date -and $hash) {
            return "$date ($hash)"
        }
    } catch {}
    return "未知"
}

function Get-Gcli2ApiStatus {
    $connection = Get-NetTCPConnection -LocalPort 7861 -State Listen -ErrorAction SilentlyContinue
    if ($null -ne $connection) {
        return "运行中"
    } else {
        return "未运行"
    }
}

function Stop-Gcli2ApiService {
    Write-Warning "正在停止 gcli2api 服务..."
    $connection = Get-NetTCPConnection -LocalPort 7861 -State Listen -ErrorAction SilentlyContinue
    if ($null -ne $connection) {
        $processId = $connection.OwningProcess
        try {
            Stop-Process -Id $processId -Force -ErrorAction Stop
            Write-Success "服务已停止 (PID: $processId)。"
        } catch {
            Write-Error "停止进程 PID:$($processId) 失败: $($_.Exception.Message)"
        }
    } else {
        Write-Warning "服务未在运行。"
    }
}

function Start-Gcli2ApiService {
    if (-not (Test-Path $GcliDir)) {
        Write-Error "gcli2api 尚未安装。"
        return $false
    }
    if ((Get-Gcli2ApiStatus) -eq "运行中") {
        Write-Warning "服务已经在运行中。"
        return $true
    }

    $pythonExe = Join-Path $GcliDir ".venv/Scripts/python.exe"
    $webPy = Join-Path $GcliDir "web.py"
    if (-not (Test-Path $pythonExe) -or -not (Test-Path $webPy)) {
        Write-Error "gcli2api 环境不完整，请尝试重新安装。"
        return $false
    }

    Write-Warning "正在新窗口中启动 gcli2api 服务..."
    try {
        $powerShellExecutable = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
        $command = "& `"$pythonExe`" -u `"$webPy`"; Write-Host '`n进程已结束，请按任意键关闭此窗口...'; [System.Console]::ReadKey({intercept: `$true}) | Out-Null"
        Start-Process $powerShellExecutable -ArgumentList "-NoExit", "-Command", $command -WorkingDirectory $GcliDir
        
        Write-Host "正在等待服务初始化 (最多15秒)..." -ForegroundColor DarkGray
        $startTime = Get-Date
        $timeout = 15
        $connection = $null

        while (((Get-Date) - $startTime).TotalSeconds -lt $timeout) {
            $connection = Get-NetTCPConnection -LocalPort 7861 -State Listen -ErrorAction SilentlyContinue
            if ($null -ne $connection) {
                break
            }
            Start-Sleep -Seconds 1
        }

        if ($null -ne $connection) {
            Write-Success "服务启动成功！请在新窗口中查看日志。"
            return $true
        } else {
            Write-Error "服务启动失败，请在新窗口中查看错误信息。"
            return $false
        }
    } catch {
        Write-Error "启动服务时发生错误: $($_.Exception.Message)"
        return $false
    }
}

function Uninstall-Gcli2Api {
    Clear-Host
    Write-Header "卸载 gcli2api"
    $confirm = Read-Host "确认要卸载 gcli2api 吗？(这将删除程序目录和配置文件) [y/N]"
    if ($confirm -eq 'y') {
        Stop-Gcli2ApiService
        if (Test-Path $GcliDir) {
            Write-Warning "正在删除目录: $GcliDir"
            Remove-Item -Path $GcliDir -Recurse -Force
        }
        Update-SyncRuleValue "AUTO_START_GCLI" $null $LabConfigFile
        Write-Success "gcli2api 已卸载。"
    } else {
        Write-Warning "操作已取消。"
    }
    Press-Any-Key
}

function Install-Gcli2Api {
    Clear-Host
    Write-Header "安装/更新 gcli2api"
    
    Write-Host "【重要提示】" -ForegroundColor Red
    Write-Host "此组件 (gcli2api) 由 " -NoNewline; Write-Host "su-kaka" -ForegroundColor Cyan -NoNewline; Write-Host " 开发。"
    Write-Host "项目地址: https://github.com/su-kaka/gcli2api"
    Write-Host "本脚本仅作为聚合工具提供安装引导，不修改其原始代码。"
    Write-Host "该组件遵循 " -NoNewline; Write-Host "CNC-1.0" -ForegroundColor Yellow -NoNewline; Write-Host " 协议，" -NoNewline; Write-Host "严禁商业用途" -ForegroundColor Red -NoNewline; Write-Host "。"
    Write-Host "所有2api项目均存在封号风险，继续安装即代表您知晓并愿意承担此风险。" -ForegroundColor Red
    Write-Host "继续安装即代表您知晓并同意遵守该协议。"
    Write-Host "────────────────────────────────────────"
    $confirm = Read-Host "请输入 'yes' 确认并继续安装"
    if ($confirm -ne "yes") {
        Write-Warning "用户取消安装。"; Press-Any-Key; return
    }

    Write-Warning "正在检查环境依赖..."
    if (-not (Check-Command "git") -or -not (Check-Command "python")) {
        Write-Error "错误: Git 或 Python 未安装。"
        Write-Host "请确保已安装 Git 和 Python 3.10+ 并将其添加至系统 PATH。" -ForegroundColor Cyan
        Press-Any-Key; return
    }
    if (-not (Check-Command "uv")) {
        Write-Warning "正在安装 uv (Python 环境管理工具)..."
        python -m pip install uv
        if ($LASTEXITCODE -ne 0) { Write-ErrorExit "uv 安装失败！请检查 pip 是否正确配置。" }
    }
    Write-Success "核心依赖检查通过。"

    $labConfig = Parse-ConfigFile $LabConfigFile
    $mirrorPref = if ($labConfig.ContainsKey("GCLI_MIRROR_PREF")) { $labConfig["GCLI_MIRROR_PREF"] } else { "Auto" }
    
    $officialGit = "https://github.com/su-kaka/gcli2api.git"
    $mirrorGit = "https://hub.gitmirror.com/https://github.com/su-kaka/gcli2api.git"
    
    $useOfficialGit = $true
    if ($mirrorPref -eq "Mirror") { $useOfficialGit = $false }
    
    Write-Warning "正在部署 gcli2api (模式: $mirrorPref)..."
    
    if (Test-Path $GcliDir) {
        Write-Warning "检测到旧目录，正在尝试更新..."
        Set-Location $GcliDir
        
        # 尝试更新
        $updateSuccess = $false
        if ($useOfficialGit) {
            Write-Host "尝试从官方源拉取..." -ForegroundColor DarkGray
            git remote set-url origin $officialGit
            git fetch --all
            if ($LASTEXITCODE -eq 0) { $updateSuccess = $true }
        }
        
        if (-not $updateSuccess -and ($mirrorPref -eq "Auto" -or $mirrorPref -eq "Mirror")) {
            if ($useOfficialGit) { Write-Warning "官方源连接失败，自动切换到国内镜像..." }
            git remote set-url origin $mirrorGit
            git fetch --all
            if ($LASTEXITCODE -eq 0) { $updateSuccess = $true }
        }
        
        if (-not $updateSuccess) {
            Set-Location $ScriptBaseDir
            Write-Error "Git 拉取更新失败！请检查网络连接。"; Press-Any-Key; return
        }
        
        git reset --hard origin/$(git rev-parse --abbrev-ref HEAD)
        if ($LASTEXITCODE -ne 0) {
            Set-Location $ScriptBaseDir
            Write-Error "Git 重置失败！请检查文件占用或手动处理。"; Press-Any-Key; return
        }
    } else {
        # 尝试克隆
        $cloneSuccess = $false
        if ($useOfficialGit) {
            Write-Host "尝试从官方源克隆..." -ForegroundColor DarkGray
            git clone $officialGit $GcliDir
            if ($LASTEXITCODE -eq 0) { $cloneSuccess = $true }
        }
        
        if (-not $cloneSuccess -and ($mirrorPref -eq "Auto" -or $mirrorPref -eq "Mirror")) {
            if ($useOfficialGit) { Write-Warning "官方源连接失败，自动切换到国内镜像..." }
            if (Test-Path $GcliDir) { Remove-Item $GcliDir -Recurse -Force }
            git clone $mirrorGit $GcliDir
            if ($LASTEXITCODE -eq 0) { $cloneSuccess = $true }
        }
        
        if (-not $cloneSuccess) {
            Write-Error "克隆 gcli2api 仓库失败！请检查网络或代理设置。"; Press-Any-Key; return
        }
    }
    Set-Location $GcliDir

    Write-Warning "正在初始化 Python 环境并安装依赖 (uv)..."
    python -m uv venv --clear
    
    $installSuccess = $false
    # 依赖安装逻辑
    if ($mirrorPref -eq "Official" -or $mirrorPref -eq "Auto") {
        Write-Warning "尝试使用官方源安装依赖..."
        python -m uv pip install -r requirements.txt --python .venv
        if ($LASTEXITCODE -eq 0) { $installSuccess = $true }
    }
    
    if (-not $installSuccess -and ($mirrorPref -eq "Auto" -or $mirrorPref -eq "Mirror")) {
        if ($mirrorPref -eq "Auto") { Write-Warning "官方源安装失败，自动切换到国内镜像..." } else { Write-Warning "使用国内镜像安装依赖..." }
        python -m uv pip install -r requirements.txt --python .venv --index-url https://pypi.tuna.tsinghua.edu.cn/simple
        if ($LASTEXITCODE -eq 0) { $installSuccess = $true }
    }
    
    if (-not $installSuccess) {
        Set-Location $ScriptBaseDir
        Write-Error "Python 依赖安装失败！"; Press-Any-Key; return
    }
    Set-Location $ScriptBaseDir

    Update-SyncRuleValue "AUTO_START_GCLI" "true" $LabConfigFile

    Write-Success "gcli2api 安装/更新完成！"

    if (Start-Gcli2ApiService) {
        Write-Warning "正在尝试打开 Web 面板 (http://127.0.0.1:7861)..."
        try {
            Start-Process "http://127.0.0.1:7861"
        } catch {
            Write-Error "无法自动打开浏览器。"
        }
    } else {
        Write-Error "服务启动失败，未能自动打开面板。"
    }
    
    Press-Any-Key
}

function Toggle-Gcli2ApiAutostart {
    $labConfig = Parse-ConfigFile $LabConfigFile
    $currentStatus = if ($labConfig.ContainsKey("AUTO_START_GCLI")) { $labConfig["AUTO_START_GCLI"] } else { "false" }
    $newStatus = if ($currentStatus -eq "true") { "false" } else { "true" }
    
    Update-SyncRuleValue "AUTO_START_GCLI" $newStatus $LabConfigFile

    if ($newStatus -eq "true") {
        Write-Success "已开启跟随启动。"
    } else {
        Write-Warning "已关闭跟随启动。"
    }
    Start-Sleep -Seconds 1
}

function Set-LabMirrorPreference {
    param([string]$Key, [string]$Title)
    Clear-Host
    Write-Header "设置 $Title 安装线路"
    $labConfig = Parse-ConfigFile $LabConfigFile
    $currentPref = if ($labConfig.ContainsKey($Key)) { $labConfig[$Key] } else { "Auto" }
    
    $prefText = switch ($currentPref) {
        "Auto" { "自动 (优先海外，失败则切国内)" }
        "Official" { "强制海外 (GitHub/官方源)" }
        "Mirror" { "强制国内 (镜像加速)" }
        default { "自动" }
    }
    
    Write-Host "当前设置: $prefText" -ForegroundColor Yellow
    Write-Host "`n[1] 自动 (推荐)" -ForegroundColor Green
    Write-Host "    优先尝试官方源，如果失败自动切换到国内镜像。"
    Write-Host "[2] 强制海外" -ForegroundColor Cyan
    Write-Host "    只使用官方源。适合网络环境极好(有梯子)的用户。"
    Write-Host "[3] 强制国内" -ForegroundColor Cyan
    Write-Host "    只使用国内镜像。适合无梯子用户。"
    
    $choice = Read-Host "`n请选择 [1-3]"
    $newPref = switch ($choice) {
        "1" { "Auto" }
        "2" { "Official" }
        "3" { "Mirror" }
        default { $null }
    }
    
    if ($newPref) {
        Update-SyncRuleValue $Key $newPref $LabConfigFile
        Write-Success "设置已保存！"
    } else {
        Write-Warning "未修改设置。"
    }
    Start-Sleep -Seconds 1
}

function Show-Gcli2ApiMenu {
    while ($true) {
        Clear-Host
        Write-Header "gcli2api 管理"
        
        $statusText = Get-Gcli2ApiStatus
        $isRunning = $statusText -eq "运行中"
        
        Write-Host "      当前状态: " -NoNewline
        if ($isRunning) { Write-Host $statusText -ForegroundColor Green } else { Write-Host $statusText -ForegroundColor Red }

        if (Test-Path $GcliDir) {
            $version = Get-GitVersionInfo -Path $GcliDir
            Write-Host "      当前版本: " -NoNewline; Write-Host $version -ForegroundColor Yellow
        }

        $labConfig = Parse-ConfigFile $LabConfigFile
        $autoStartEnabled = $labConfig.ContainsKey("AUTO_START_GCLI") -and $labConfig["AUTO_START_GCLI"] -eq "true"
        
        Write-Host "`n      [1] " -NoNewline; Write-Host "安装/更新" -ForegroundColor Cyan
        
        if (Test-Path $GcliDir) {
            if ($isRunning) {
                Write-Host "      [2] " -NoNewline; Write-Host "停止服务" -ForegroundColor Yellow
            } else {
                Write-Host "      [2] " -NoNewline; Write-Host "启动服务" -ForegroundColor Green
            }
            
            Write-Host "      [3] 跟随酒馆启动: " -NoNewline
            if ($autoStartEnabled) { Write-Host "[开启]" -ForegroundColor Green } else { Write-Host "[关闭]" -ForegroundColor Red }

            Write-Host "      [4] " -NoNewline; Write-Host "卸载 gcli2api" -ForegroundColor Red
            Write-Host "      [5] " -NoNewline; Write-Host "打开 Web 面板"
        }
        
        Write-Host "`n      [7] " -NoNewline; Write-Host "切换安装线路" -ForegroundColor Yellow
        Write-Host "      [0] " -NoNewline; Write-Host "返回上一级" -ForegroundColor Cyan

        $choice = Read-Host "`n    请输入选项"
        
        if (-not (Test-Path $GcliDir) -and $choice -ne '1' -and $choice -ne '0') {
            Write-Warning "无效输入。gcli2api 尚未安装。"; Start-Sleep 1.5
            continue
        }

        switch ($choice) {
            "1" { Install-Gcli2Api }
            "2" {
                if ($isRunning) { Stop-Gcli2ApiService } else { Start-Gcli2ApiService }
                Press-Any-Key
            }
            "3" { Toggle-Gcli2ApiAutostart }
            "4" { Uninstall-Gcli2Api }
            "5" {
                try {
                    Start-Process "http://127.0.0.1:7861"
                } catch {
                    Write-Error "无法自动打开浏览器。"
                }
            }
            "7" { Set-LabMirrorPreference "GCLI_MIRROR_PREF" "gcli2api" }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

function Show-STConfigMenu {
    while ($true) {
        Clear-Host
        Write-Header "酒馆配置管理"
        if (-not (Test-Path (Join-Path $ST_Dir "config.yaml"))) {
            Write-Warning "未找到 config.yaml，请先部署酒馆。"
            Press-Any-Key; return
        }

        $currPort = Get-STConfigValue "port"
        $currAuth = Get-STConfigValue "basicAuthMode"
        $currUser = Get-STConfigValue "enableUserAccounts"
        $currListen = Get-STConfigValue "listen"

        $isSingleUser = ($currAuth -eq "true" -and $currUser -eq "false")
        $isMultiUser = ($currAuth -eq "false" -and $currUser -eq "true")
        $isNoAuth = ($currAuth -eq "false" -and $currUser -eq "false")

        $modeText = "未知"
        if ($isNoAuth) { $modeText = "默认 (无账密)" }
        elseif ($isSingleUser) { $modeText = "单用户 (基础账密)" }
        elseif ($isMultiUser) { $modeText = "多用户 (独立账户)" }

        Write-Host "      当前端口: " -NoNewline; Write-Host "$currPort" -ForegroundColor Green
        Write-Host "      当前模式: " -NoNewline; Write-Host "$modeText" -ForegroundColor Green
        if ($isSingleUser) {
            $u = Get-STNestedConfigValue "basicAuthUser" "username"
            $p = Get-STNestedConfigValue "basicAuthUser" "password"
            Write-Host "      当前账密: " -NoNewline; Write-Host "$u / $p" -ForegroundColor DarkGray
        }
        Write-Host "      局域网访问: " -NoNewline
        if ($currListen -eq "true") { Write-Host "已开启" -ForegroundColor Green } else { Write-Host "已关闭" -ForegroundColor Red }

        Write-Host "`n      [1] " -NoNewline; Write-Host "修改端口号" -ForegroundColor Cyan
        Write-Host "      [2] " -NoNewline; Write-Host "切换为：默认无账密模式" -ForegroundColor Cyan
        
        Write-Host "      [3] " -NoNewline
        if ($isSingleUser) { Write-Host "修改单用户账密" -ForegroundColor Cyan } else { Write-Host "切换为：单用户账密模式" -ForegroundColor Cyan }
        
        Write-Host "      [4] " -NoNewline; Write-Host "切换为：多用户账密模式" -ForegroundColor Cyan
        
        Write-Host "      [5] " -NoNewline
        if ($currListen -eq "true") { Write-Host "关闭局域网访问" -ForegroundColor Red } else { Write-Host "允许局域网访问 (需开启账密)" -ForegroundColor Yellow }
        
        Write-Host "`n      [0] " -NoNewline; Write-Host "返回主菜单" -ForegroundColor Cyan

        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            "1" {
                $newPort = Read-Host "请输入新的端口号 (1024-65535)"
                if ($newPort -match '^\d+$' -and [int]$newPort -ge 1024 -and [int]$newPort -le 65535) {
                    if (Update-STConfigValue "port" $newPort) {
                        Write-Success "端口已修改为 $newPort"
                        Write-Warning "设置将在重启酒馆后生效。"
                    }
                } else { Write-Error "无效的端口号。" }
                Press-Any-Key
            }
            "2" {
                Update-STConfigValue "basicAuthMode" "false" | Out-Null
                Update-STConfigValue "enableUserAccounts" "false" | Out-Null
                Update-STConfigValue "listen" "false" | Out-Null
                Write-Success "已切换为默认无账密模式 (局域网访问已同步关闭)。"
                Write-Warning "设置将在重启酒馆后生效。"
                Press-Any-Key
            }
            "3" {
                $u = Read-Host "请输入用户名"
                $p = Read-Host "请输入密码"
                if ([string]::IsNullOrWhiteSpace($u) -or [string]::IsNullOrWhiteSpace($p)) {
                    Write-Error "用户名和密码不能为空！"
                } else {
                    Update-STConfigValue "basicAuthMode" "true" | Out-Null
                    Update-STConfigValue "enableUserAccounts" "false" | Out-Null
                    Update-STNestedConfigValue "basicAuthUser" "username" "`"$u`"" | Out-Null
                    Update-STNestedConfigValue "basicAuthUser" "password" "`"$p`"" | Out-Null
                    Write-Success "单用户账密配置已更新。"
                    Write-Warning "设置将在重启酒馆后生效。"
                }
                Press-Any-Key
            }
            "4" {
                Update-STConfigValue "basicAuthMode" "false" | Out-Null
                Update-STConfigValue "enableUserAccounts" "true" | Out-Null
                Update-STConfigValue "enableDiscreetLogin" "true" | Out-Null
                Write-Success "已切换为多用户账密模式。"
                Write-Host "`n【重要提示】" -ForegroundColor Yellow
                Write-Host "请在启动酒馆后，进入 [用户设置] -> [管理员面板] 设置管理员密码，否则多用户模式可能无法正常工作。" -ForegroundColor Cyan
                Write-Warning "设置将在重启酒馆后生效。"
                Press-Any-Key
            }
            "5" {
                if ($currListen -eq "true") {
                    Update-STConfigValue "listen" "false" | Out-Null
                    Write-Success "局域网访问已关闭。"
                    Write-Warning "设置将在重启酒馆后生效。"
                } else {
                    # 检查是否开启了账密
                    if ($isNoAuth) {
                        Write-Warning "局域网访问必须开启账密模式！"
                        $confirm = Read-Host "是否自动开启单用户账密模式？[Y/n]"
                        if ($confirm -ne 'n') {
                            $u = Read-Host "请设置用户名"
                            $p = Read-Host "请设置密码"
                            if ([string]::IsNullOrWhiteSpace($u) -or [string]::IsNullOrWhiteSpace($p)) {
                                Write-Error "用户名和密码不能为空，操作已取消。"
                                Press-Any-Key; continue
                            }
                            Update-STConfigValue "basicAuthMode" "true" | Out-Null
                            Update-STNestedConfigValue "basicAuthUser" "username" "`"$u`"" | Out-Null
                            Update-STNestedConfigValue "basicAuthUser" "password" "`"$p`"" | Out-Null
                        } else {
                            Write-Error "操作已取消。"
                            Start-Sleep -Seconds 1; continue
                        }
                    }
                    
                    # 开启监听
                    Update-STConfigValue "listen" "true" | Out-Null
                    
                    # 获取本机IP并加入白名单
                    # 过滤 127.x.x.x (回环) 和 169.254.x.x (APIPA/不可用)
                    $ips = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
                        $_.IPAddress -notmatch '^127\.' -and
                        $_.IPAddress -notmatch '^169\.254\.'
                    }
                    
                    $validIps = New-Object System.Collections.Generic.List[object]
                    foreach ($ipObj in $ips) {
                        # 获取物理网卡详情，用于精准排除虚拟网卡
                        $adapter = Get-NetAdapter -InterfaceAlias $ipObj.InterfaceAlias -ErrorAction SilentlyContinue
                        if ($null -eq $adapter) { continue }
                        
                        # 排除常见的虚拟网卡 (通过名称或描述)
                        if ($adapter.Name -match 'VirtualBox|VMware|Pseudo|Teredo|6to4|Loopback') { continue }
                        if ($adapter.InterfaceDescription -match 'Virtual|WSL|Docker|Hyper-V|VPN|ZeroTier|Tailscale') { continue }
                        
                        $validIps.Add(@{ IPObj = $ipObj; Adapter = $adapter })
                    }

                    if ($validIps.Count -gt 0) {
                        Write-Header "检测到以下局域网地址："
                        foreach ($item in $validIps) {
                            $ipObj = $item.IPObj
                            $adapter = $item.Adapter
                            $ip = $ipObj.IPAddress
                            
                            # 识别网卡类型
                            $typeLabel = "[未知]"
                            if ($adapter.Name -like "*Microsoft Wi-Fi Direct Virtual Adapter*") { $typeLabel = "[本机热点]" }
                            elseif ($adapter.MediaType -eq "802.3" -or $adapter.Name -like "*Ethernet*") { $typeLabel = "[有线网络]" }
                            elseif ($adapter.MediaType -eq "Native 802.11" -or $adapter.Name -like "*Wi-Fi*") { $typeLabel = "[WiFi]" }

                            # 动态计算子网网段 (支持全球各种子网掩码)
                            $prefixLength = $ipObj.PrefixLength
                            if ($ip -match '^(\d+\.\d+\.\d+\.\d+)') {
                                $subnet = "$($Matches[1])/$prefixLength"
                                if (Add-STWhitelistEntry $subnet) {
                                    Write-Host "  ✓ " -NoNewline; Write-Host "$typeLabel " -ForegroundColor Green -NoNewline; Write-Host "已将网段 $subnet 加入白名单"
                                }
                            }
                            Write-Host "      访问地址: " -NoNewline; Write-Host "http://$($ip):$currPort" -ForegroundColor Cyan
                        }
                        Write-Host "`n选择建议：" -ForegroundColor Yellow
                        Write-Host "  - " -NoNewline; Write-Host "[有线网络/WiFi] " -ForegroundColor Green -NoNewline; Write-Host ": 适用于其他设备通过 " -NoNewline; Write-Host "路由器 " -ForegroundColor Cyan -NoNewline; Write-Host "或 " -NoNewline; Write-Host "他人热点 " -ForegroundColor Cyan -NoNewline; Write-Host "与这台电脑处于同一局域网时访问。"
                        Write-Host "  - " -NoNewline; Write-Host "[本机热点] " -ForegroundColor Green -NoNewline; Write-Host ": 适用于其他设备直接连接了 " -NoNewline; Write-Host "这台电脑开启的移动热点 " -ForegroundColor Cyan -NoNewline; Write-Host "时访问。"
                        Write-Host "  - " -NoNewline; Write-Host "提示: " -ForegroundColor Yellow -NoNewline; Write-Host "若有多个地址，请优先尝试 " -NoNewline; Write-Host "192.168 " -ForegroundColor Green -NoNewline; Write-Host "开头的地址。"

                        Write-Success "`n局域网访问功能已配置完成。"
                        Write-Warning "设置将在重启酒馆后生效。"
                    } else {
                        Write-Error "未能检测到有效的局域网 IP 地址。"
                    }
                }
                Press-Any-Key
            }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

function Show-ExtraFeaturesMenu {
    while ($true) {
        Clear-Host
        Write-Header "额外功能 (实验室)"
        Write-Host "      [1] " -NoNewline; Write-Host "gcli2api 管理" -ForegroundColor Cyan
        Write-Host "      [3] " -NoNewline; Write-Host "酒馆配置管理" -ForegroundColor Cyan
        Write-Host "      [9] " -NoNewline; Write-Host "获取 AI Studio 凭证" -ForegroundColor Cyan
        Write-Host "`n      [0] " -NoNewline; Write-Host "返回主菜单" -ForegroundColor Cyan
        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            "1" { Show-Gcli2ApiMenu }
            "3" { Show-STConfigMenu }
            "9" { Get-AiStudioToken }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

# --- 补全缺失的核心功能函数 ---

function Open-HelpDocs {
    Clear-Host
    Write-Header "查看帮助文档"
    Write-Host "文档网址: "
    Write-Host $HelpDocsUrl -ForegroundColor Cyan
    Write-Host "`n"
    try {
        Start-Process $HelpDocsUrl
        Write-Success "已尝试在浏览器中打开，若未自动跳转请手动复制上方网址。"
    } catch {
        Write-Warning "无法自动打开浏览器。"
    }
    Press-Any-Key
}

function Get-UnifiedMirrorCandidates {
    param($GitUrl, $FileUrl)
    $candidates = @()
    $candidates += [PSCustomObject]@{ Name = "官方线路 (github.com)"; GitUrl = $GitUrl; FileUrl = $FileUrl }
    
    $seenHosts = @("github.com")
    
    foreach ($m in $Mirror_List) {
        $hostName = ($m -split '/')[2]
        if ($seenHosts -contains $hostName) { continue }
        
        $g = $null; $f = $null
        
        if ($m -match "/gh/") {
            $base = $m.Substring(0, $m.IndexOf("/gh/"))
            $repoPath = $GitUrl -replace '^https://github.com/', ''
            $filePath = $FileUrl -replace '^https://github.com/', ''
            $g = "$base/gh/$repoPath"
            $f = "$base/gh/$filePath"
        } elseif ($m -match "/https://github.com/") {
            $base = $m.Substring(0, $m.IndexOf("/https://github.com/"))
            $g = "$base/$GitUrl"
            $f = "$base/$FileUrl"
        } elseif ($m -match "/github.com/") {
            $base = $m.Substring(0, $m.IndexOf("/github.com/"))
            $g = "$base/$GitUrl"
            $f = "$base/$FileUrl"
        }
        
        if ($g -and $f) {
            $candidates += [PSCustomObject]@{ Name = "镜像线路 ($hostName)"; GitUrl = $g; FileUrl = $f }
            $seenHosts += $hostName
        }
    }
    return $candidates
}

function Select-UnifiedMirror {
    param($GitUrl, $FileUrl)
    
    $candidates = Get-UnifiedMirrorCandidates -GitUrl $GitUrl -FileUrl $FileUrl
    $successfulCandidates = New-Object System.Collections.Generic.List[object]

    Write-Warning "正在测试可用下载线路，请稍候..."
    
    foreach ($c in $candidates) {
        Write-Host "  - 正在测试: $($c.Name)..." -NoNewline
        $isSuccess = $false
        try {
            $req = [System.Net.WebRequest]::Create($c.FileUrl)
            $req.Method = "HEAD"
            $req.Timeout = 7000
            $resp = $req.GetResponse()
            $statusCode = [int]$resp.StatusCode
            if ($statusCode -ge 200 -and $statusCode -lt 400) {
                $isSuccess = $true
                $successfulCandidates.Add($c)
            }
            $resp.Close()
        } catch {
        }

        if ($isSuccess) {
            Write-Host "`r  ✓ 测试: $($c.Name) [成功]                                  " -ForegroundColor Green
        } else {
            Write-Host "`r  ✗ 测试: $($c.Name) [失败]                                  " -ForegroundColor Red
        }
    }

    if ($successfulCandidates.Count -eq 0) {
        Write-Error "`n所有下载线路均测试失败！`n可能是网络问题、代理配置错误或镜像服务器暂时不可用。"
        Press-Any-Key
        return $null
    }
    
    Write-Host ""
    Write-Success "测试完成，共找到 $($successfulCandidates.Count) 条可用线路。"

    $successful = @{}
    for ($i = 0; $i -lt $successfulCandidates.Count; $i++) {
        $successful[($i + 1)] = $successfulCandidates[$i]
    }

    while ($true) {
        Clear-Host
        Write-Header "选择下载线路"
        Write-Success "请选择一条可用线路进行下载："
        foreach ($k in ($successful.Keys | Sort-Object)) {
            Write-Host ("  [{0,2}] {1}" -f $k, $successful[$k].Name) -ForegroundColor Cyan
        }
        Write-Host "`n  [0] 取消操作" -ForegroundColor Red
        $choice = Read-Host "`n请输入序号"
        if ($choice -eq '0') { return $null }
        if ($choice -match '^\d+$' -and $successful.ContainsKey([int]$choice)) {
            return $successful[[int]$choice]
        }
    }
}

function Download-FileWithHttpClient {
    param(
        [Parameter(Mandatory=$true)] [string]$Url,
        [Parameter(Mandatory=$true)] [string]$DestPath
    )
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromMinutes(10)
    
    try {
        $response = $client.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $response.EnsureSuccessStatusCode() | Out-Null

        $totalBytes = $response.Content.Headers.ContentLength
        $readChunkSize = 8192
        $buffer = New-Object byte[] $readChunkSize
        $totalRead = 0

        $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $fileStream = [System.IO.File]::Create($DestPath)

        do {
            $bytesRead = $stream.Read($buffer, 0, $readChunkSize)
            $fileStream.Write($buffer, 0, $bytesRead)
            $totalRead += $bytesRead
            
            if ($totalBytes -gt 0) {
                $percent = ($totalRead / $totalBytes) * 100
                $receivedMB = $totalRead / 1MB
                $totalMB = $totalBytes / 1MB
                $statusText = "下载中: {0:N2} MB / {1:N2} MB ({2:N0}%)" -f $receivedMB, $totalMB, $percent
                Write-Progress -Activity "正在下载文件" -Status $statusText -PercentComplete $percent
            } else {
                $receivedMB = $totalRead / 1MB
                $statusText = "下载中: {0:N2} MB" -f $receivedMB
                Write-Progress -Activity "正在下载文件" -Status $statusText
            }
        } while ($bytesRead -gt 0)
        
        Write-Progress -Activity "正在下载文件" -Completed
    } finally {
        if ($stream) { $stream.Dispose() }
        if ($fileStream) { $fileStream.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Get-AiStudioToken {
    Clear-Host
    Write-Header "获取 AI Studio 凭证"

    if (-not (Check-Command "git") -or -not (Check-Command "node")) {
        Write-Error "未检测到 Git 或 Node.js，无法继续。"
        Write-Warning "请先在主菜单选择 [首次部署] 或手动安装这些依赖。"
        Press-Any-Key
        return
    }
    Write-Success "环境检查通过 (Git, Node.js 已安装)。"

    $targetGitUrl = "https://github.com/Ellinav/ais2api.git"
    $targetFileUrl = "https://github.com/daijro/camoufox/releases/download/v135.0.1-beta.24/camoufox-135.0.1-beta.24-win.x86_64.zip"
    
    $needClone = -not (Test-Path $ais2apiDir)
    $needDownload = -not (Test-Path $camoufoxExe)
    
    if ($needClone -or $needDownload) {
        $selectedMirror = Select-UnifiedMirror -GitUrl $targetGitUrl -FileUrl $targetFileUrl
        if (-not $selectedMirror) {
            Write-Error "未选择线路或操作取消。"
            Press-Any-Key
            return
        }
        
        if ($needClone) {
            Write-Warning "正在克隆 ais2api 项目..."
            $gitOutput = git clone $selectedMirror.GitUrl $ais2apiDir 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Error "克隆失败！Git输出: $($gitOutput | Out-String)"
                Press-Any-Key; return
            }
        }
        
        if ($needDownload) {
            if (-not (Test-Path $camoufoxDir)) { New-Item -Path $camoufoxDir -ItemType Directory | Out-Null }
            $zipPath = Join-Path $ais2apiDir "camoufox.zip"
            Write-Warning "正在下载 Camoufox 内核..."
            try {
                Download-FileWithHttpClient -Url $selectedMirror.FileUrl -DestPath $zipPath
                Write-Success "下载完成，正在解压..."
                Expand-Archive -Path $zipPath -DestinationPath $camoufoxDir -Force
                Remove-Item $zipPath -Force
                
                if (-not (Test-Path $camoufoxExe)) {
                    $nestedExe = Get-ChildItem -Path $camoufoxDir -Filter "camoufox.exe" -Recurse | Select-Object -First 1
                    if ($nestedExe) {
                        $parentDir = $nestedExe.Directory.FullName
                        Get-ChildItem -Path $parentDir | Move-Item -Destination $camoufoxDir -Force
                    }
                }
                Write-Success "Camoufox 配置完成。"
            } catch {
                Write-Error "下载或解压失败: $($_.Exception.Message)"
                Press-Any-Key; return
            }
        }
    }

    Set-Location $ais2apiDir
    if (-not (Test-Path "node_modules")) {
        Write-Warning "正在安装依赖 (npm install)..."
        npm install
        if ($LASTEXITCODE -ne 0) { Write-Error "依赖安装失败！"; Set-Location $ScriptBaseDir; Press-Any-Key; return }
    }

    while ($true) {
        Clear-Host
        Write-Header "准备获取凭证"
        Write-Host "即将启动浏览器..." -ForegroundColor Cyan
        Write-Host "1. 请在弹出的浏览器中登录您的谷歌账号。" -ForegroundColor Yellow
        Write-Host "2. 登录成功看到 AI Studio 页面后，请保持浏览器开启。" -ForegroundColor Yellow
        Write-Host "3. 回到本窗口按回车，即可自动获取凭证并关闭浏览器。" -ForegroundColor Yellow
        Write-Host "4. 凭证将保存在 ais2api\single-line-auth 文件中。" -ForegroundColor Green
        
        node save-auth.js
        Write-Success "操作结束。"
        
        Get-Process -Name "camoufox" -ErrorAction SilentlyContinue | Stop-Process -Force

        while ($true) {
            Write-Host "`n后续操作：" -ForegroundColor Cyan
            Write-Host " [1] 继续获取 (切换账号)" -ForegroundColor Green
            Write-Host " [2] 打开凭证文件" -ForegroundColor Yellow
            Write-Host " [0] 返回上一级" -ForegroundColor Red
            $next = Read-Host " 请输入"
            if ($next -eq '1') { break }
            if ($next -eq '2') {
                $authFile = Join-Path $ais2apiDir "single-line-auth"
                if (Test-Path $authFile) { Invoke-Item $authFile } else { Write-Warning "凭证文件不存在。" }
            }
            if ($next -eq '0') { Set-Location $ScriptBaseDir; return }
        }
    }
}

function Update-AssistantScript {
    Clear-Host
    Write-Header "更新咕咕助手脚本"

    $confirm = Read-Host "确认要检查并更新咕咕助手脚本吗？[Y/n]"
    if ($confirm -eq 'n' -or $confirm -eq 'N') { return }

    Write-Warning "正在从服务器获取最新版本..."
    try {
        $newScriptContent = (Invoke-WebRequest -Uri $ScriptSelfUpdateUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
        if ([string]::IsNullOrWhiteSpace($newScriptContent)) { Write-ErrorExit "下载失败：脚本内容为空！" }

        $newScriptContent = $newScriptContent.TrimStart([char]0xFEFF)

        $currentScriptContent = (Get-Content -Path $PSCommandPath -Raw).TrimStart([char]0xFEFF)
        if ($newScriptContent.Replace("`r`n", "`n").Trim() -eq $currentScriptContent.Replace("`r`n", "`n").Trim()) {
            Write-Success "当前已是最新版本。"
            Press-Any-Key; return
        }

        $newFile = Join-Path $ScriptBaseDir "pc-st.new.ps1"
        $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText($newFile, $newScriptContent, $utf8WithBom)

        $batchPath = Join-Path $ScriptBaseDir "upd.bat"
        $starter = Join-Path $ScriptBaseDir "咕咕助手.bat"
        $batchContent = @"
@echo off
title 正在更新咕咕助手...
timeout /t 2 >nul
:retry_del
del /f /q "$PSCommandPath" >nul 2>&1
if exist "$PSCommandPath" (
    timeout /t 1 >nul
    goto retry_del
)
move /y "$newFile" "$PSCommandPath" >nul
start "" "$starter"
del %0
"@
        [System.IO.File]::WriteAllText($batchPath, $batchContent, [System.Text.Encoding]::GetEncoding(936))

        Write-Warning "助手即将重启以应用更新..."
        Start-Process $batchPath; exit
    } catch {
        Write-Error "更新失败: $($_.Exception.Message)"
        Write-Host "`n若自动更新失败，请前往博客 " -NoNewline; Write-Host "https://blog.qjyg.de" -ForegroundColor Cyan
        Write-Host "重新下载脚本压缩包，并手动使用新下载的 " -NoNewline; Write-Host "咕咕助手.bat" -ForegroundColor Yellow -NoNewline; Write-Host " 和 " -NoNewline; Write-Host "pc-st.ps1" -ForegroundColor Yellow
        Write-Host " 替换当前正在使用的同名文件。"
        Press-Any-Key
    }
}

# --- 脚本执行入口 ---

function Check-ForUpdatesOnStart {
    $jobScriptBlock = {
        param($url, $flag, $path)
        try {
            $new = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content
            if (-not [string]::IsNullOrWhiteSpace($new)) {
               $new = $new.TrimStart([char]0xFEFF)
                $old = (Get-Content -Path $path -Raw).TrimStart([char]0xFEFF)
                if ($new.Replace("`r`n", "`n").Trim() -ne $old.Replace("`r`n", "`n").Trim()) {
                    [System.IO.File]::Create($flag).Close()
                } else {
                    if (Test-Path $flag) { Remove-Item $flag -Force }
                }
            }
        } catch {}
    }
    Start-Job -ScriptBlock $jobScriptBlock -ArgumentList $ScriptSelfUpdateUrl, $UpdateFlagFile, $PSCommandPath | Out-Null
}

Apply-Proxy
Show-AgreementIfFirstRun
Check-ForUpdatesOnStart
git config --global --add safe.directory '*' | Out-Null

while ($true) {
    Clear-Host
    Show-Header
    $updateNoticeText = if (Test-Path $UpdateFlagFile) { " [!] 有更新" } else { "" }
    Write-Host "`n    选择一个操作来开始：`n"
    Write-Host "      [1] " -NoNewline -ForegroundColor Green; Write-Host "启动酒馆"
    Write-Host "      [2] " -NoNewline -ForegroundColor Cyan; Write-Host "数据同步 (Git 云端)"
    Write-Host "      [3] " -NoNewline -ForegroundColor Cyan; Write-Host "本地备份管理"
    Write-Host "      [4] " -NoNewline -ForegroundColor Yellow; Write-Host "首次部署 (全新安装)`n"
    Write-Host "      [5] 酒馆版本管理      [6] 更新咕咕助手$($updateNoticeText)"
    Write-Host "      [7] 打开酒馆文件夹    [8] 查看帮助文档"
    Write-Host "      [9] 配置网络代理      [11] " -NoNewline; Write-Host "酒馆配置管理" -ForegroundColor Cyan
    Write-Host "      [10] " -NoNewline -ForegroundColor Magenta; Write-Host "额外功能 (实验室)`n"
    Write-Host "      [0] " -NoNewline -ForegroundColor Red; Write-Host "退出咕咕助手`n"
    $choice = Read-Host "    请输入选项数字"
    switch ($choice) {
        "1" { Start-SillyTavern }
        "2" { Show-GitSyncMenu }
        "3" { Show-BackupMenu }
        "4" { Install-SillyTavern }
        "5" { Show-VersionManagementMenu }
        "6" { Update-AssistantScript }
        "7" { if (Test-Path $ST_Dir) { Invoke-Item $ST_Dir } else { Write-Warning '目录不存在，请先部署！'; Start-Sleep 1.5 } }
        "8" { Open-HelpDocs }
        "9" { Show-ManageProxyMenu }
        "10" { Show-ExtraFeaturesMenu }
        "11" { Show-STConfigMenu }
        "0" { if (Test-Path $UpdateFlagFile) { Remove-Item $UpdateFlagFile -Force }; Write-Host "感谢使用，咕咕助手已退出。"; exit }
        default { Write-Warning "无效输入，请重新选择。"; Start-Sleep -Seconds 1.5 }
    }
}

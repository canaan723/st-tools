# SillyTavern 助手 v2.1
# 作者: Qingjue | 小红书号: 826702880
# =========================================================================

# --- 初始化与环境设置 ---
# 强制使用 TLS 1.2 安全协议
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# 强制使用 UTF-8 编码处理外部程序输出，解决乱码问题
$OutputEncoding = [System.Text.Encoding]::UTF8


# =========================================================================
#   核心配置
# =========================================================================

# 脚本自身更新地址
$ScriptSelfUpdateUrl = "https://gitee.com/canaan723/st-tools/raw/main/jiuguan/pc-st.ps1"
# 帮助文档地址
$HelpDocsUrl = "https://blog.qjyg.de"
# 脚本所在目录
$ScriptBaseDir = Split-Path -Path $PSCommandPath -Parent
# SillyTavern 主程序目录
$ST_Dir = Join-Path $ScriptBaseDir "SillyTavern"
# Git 下载/更新时使用的分支
$Repo_Branch = "release"
# 本地备份文件存放根目录
$Backup_Root_Dir = Join-Path $ScriptBaseDir "_SillyTavern_Backups"
# 本地备份文件数量上限
$Backup_Limit = 10
# 脚本更新提示的临时标记文件
$UpdateFlagFile = Join-Path ([System.IO.Path]::GetTempPath()) ".st_assistant_update_flag"

# --- 统一配置文件路径 ---
# 将所有配置文件存放在用户目录下的 .config/pc-st 中
$ConfigDir = Join-Path $ScriptBaseDir ".config"
if (-not (Test-Path $ConfigDir)) {
    New-Item -Path $ConfigDir -ItemType Directory -Force | Out-Null
}
$BackupPrefsConfigFile = Join-Path $ConfigDir "backup_prefs.conf"
$GitSyncConfigFile = Join-Path $ConfigDir "git_sync.conf"
$ProxyConfigFile = Join-Path $ConfigDir "proxy.conf"
$SyncRulesConfigFile = Join-Path $ConfigDir "sync_rules.conf"

# Git 镜像列表，用于加速下载和更新
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

# 用于缓存镜像测速结果，避免重复测试
$CachedMirrors = @()


# =========================================================================
#   辅助函数库
# =========================================================================

# --- UI 输出函数 ---
function Write-Header($Title) { Write-Host "`n═══ $($Title) ═══" -ForegroundColor Cyan }
function Write-Success($Message) { Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Warning($Message) { Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-Error($Message) { Write-Host "✗ $Message" -ForegroundColor Red }
function Write-ErrorExit($Message) { Write-Host "`n✗ $Message`n流程已终止。" -ForegroundColor Red; Press-Any-Key; exit }
function Press-Any-Key { Write-Host "`n请按任意键返回..." -ForegroundColor Cyan; $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null }

# 检查命令是否存在
function Check-Command($Command) { return (Get-Command $Command -ErrorAction SilentlyContinue) }

# 获取用户数据文件夹列表，排除系统文件夹
function Get-UserFolders {
    param([string]$baseDataPath)
    $systemFolders = @("_cache", "_storage", "_uploads", "_webpack")
    return Get-ChildItem -Path $baseDataPath -Directory -ErrorAction SilentlyContinue | Where-Object { $systemFolders -notcontains $_.Name }
}

# 测试并找出最快的 Git 镜像
function Find-FastestMirror {
    param([bool]$excludeOfficial = $false)
    if ($CachedMirrors.Count -gt 0) { Write-Success "已使用缓存的测速结果。"; return $CachedMirrors }
    Write-Warning "开始测试 Git 备用镜像连通性与速度..."
    $githubUrl = "https://github.com/SillyTavern/SillyTavern.git"
    $mirrorsToTest = $Mirror_List
    if ($excludeOfficial) { $mirrorsToTest = $Mirror_List | Where-Object { $_ -ne $githubUrl } }
    if ($mirrorsToTest.Count -eq 0) { Write-Error "没有可用的备用镜像进行测试。"; return @() }

    $jobs = @{}
    foreach ($mirrorUrl in $mirrorsToTest) {
        $scriptBlock = {
            param($u)
            $start = Get-Date
            try {
                git ls-remote $u HEAD | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $end = Get-Date
                    return @{ Url = $u; Time = ($end - $start).TotalSeconds }
                }
            } catch {}
            return $null
        }
        $jobs[$mirrorUrl] = Start-Job -ScriptBlock $scriptBlock -ArgumentList $mirrorUrl
    }
    Wait-Job $jobs.Values -Timeout 15 | Out-Null

    $results = @()
    foreach ($mirrorUrl in $jobs.Keys) {
        $job = $jobs[$mirrorUrl]
        $mirrorHost = ($mirrorUrl -split '/')[2]
        if ($job.State -eq 'Completed') {
            $result = Receive-Job $job
            if ($result) {
                $results += $result
                Write-Host ("  - 测试: {0} - 耗时 {1:N2}s [成功]" -f $mirrorHost, $result.Time) -ForegroundColor Green
            } else {
                Write-Host ("  - 测试: {0} [失败]" -f $mirrorHost) -ForegroundColor Red
            }
        } else {
            Write-Host ("  - 测试: {0} [超时/失败]" -f $mirrorHost) -ForegroundColor Red
        }
        Remove-Job -Job $job -Force
    }

    if ($results.Count -gt 0) {
        $sortedMirrors = $results | Sort-Object Time | ForEach-Object { $_.Url }
        Write-Success "测试完成，找到 $($results.Count) 个可用备用线路。"
        $script:CachedMirrors = $sortedMirrors
        return $script:CachedMirrors
    } else {
        Write-Error "所有备用线路均测试失败。"
        return @()
    }
}

# 运行 npm install 并带重试机制
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


# =========================================================================
#   网络代理功能模块
# =========================================================================

# 应用代理配置到环境变量
function Apply-Proxy {
    if (Test-Path $ProxyConfigFile) {
        $port = Get-Content $ProxyConfigFile -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($port)) {
            $proxyUrl = "http://1227.0.0.1:$port"
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

# 设置代理端口
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

# 清除代理配置
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

# 显示代理管理菜单
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
        Write-Host "      (此设置仅对本助手内的操作生效，不影响系统全局代理)" -ForegroundColor DarkGray
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


# =========================================================================
#   Git 同步功能模块
# =========================================================================

# 解析 key=value 格式的配置文件
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

# 检查 Git 同步所需的依赖 (git, robocopy)
function Test-GitSyncDeps {
    if (-not (Check-Command "git") -or -not (Check-Command "robocopy")) {
        Write-Warning "Git尚未安装，请先运行 [首次部署]。"
        Press-Any-Key
        return $false
    }
    return $true
}

# 确保 Git 用户名和邮箱已配置
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

# 设置 Git 同步的仓库地址和 Token
function Set-GitSyncConfig {
    Clear-Host
    Write-Header "配置 Git 同步服务"
    $repoUrl = ""
    $repoToken = ""
    while ([string]::IsNullOrWhiteSpace($repoUrl)) { $repoUrl = Read-Host "请输入您的私有仓库HTTPS地址" }
    while ([string]::IsNullOrWhiteSpace($repoToken)) { $repoToken = Read-Host "请输入您的Personal Access Token" }
    Set-Content -Path $GitSyncConfigFile -Value "REPO_URL=`"$repoUrl`"`nREPO_TOKEN=`"$repoToken`""
    Write-Success "Git同步服务配置已保存！"
    Press-Any-Key
}

# 测试单个镜像是否支持推送
function Test-OneMirrorPush($authedUrl) {
    $tempRepoDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -Path $tempRepoDir -ItemType Directory -Force | Out-Null
    $exitCode = 1
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
        $job = Start-Job -ScriptBlock { git push origin "HEAD:refs/tags/st-sync-test-$(Get-Date -UFormat %s%N)" }
        if (Wait-Job $job -Timeout 15) {
            if ($job.State -eq 'Completed') {
                $jobDelete = Start-Job -ScriptBlock { git push origin --delete "refs/tags/st-sync-test-$(Get-Date -UFormat %s%N)" }
                Wait-Job $jobDelete -Timeout 15 | Out-Null
                Remove-Job $jobDelete -Force
                $exitCode = 0
            }
        }
        Remove-Job $job -Force
    } finally {
        Set-Location $ScriptBaseDir
        Remove-Item $tempRepoDir -Recurse -Force
    }
    return ($exitCode -eq 0)
}

# 寻找支持推送 (上传) 的 Git 镜像
function Find-PushableMirror {
    $gitConfig = Parse-ConfigFile $GitSyncConfigFile
    if (-not $gitConfig.ContainsKey("REPO_URL") -or -not $gitConfig.ContainsKey("REPO_TOKEN")) {
        Write-Error "Git同步配置不完整或不存在。"
        return @()
    }
    $repoUrl = $gitConfig["REPO_URL"]
    $repoToken = $gitConfig["REPO_TOKEN"]
    Write-Warning "正在自动测试支持数据上传的加速线路..."
    $repoPath = $repoUrl -replace 'https://github.com/', ''
    $githubPublicUrl = "https://github.com/SillyTavern/SillyTavern.git"
    $successfulUrls = New-Object System.Collections.Generic.List[string]

    if ($Mirror_List -contains $githubPublicUrl) {
        $officialUrl = "https://$($repoToken)@github.com/$($repoPath)"
        Write-Host "  - 优先测试: 官方 GitHub ..." -NoNewline
        if (Test-OneMirrorPush $officialUrl) {
            Write-Host "`r  ✓ [成功]                                  " -ForegroundColor Green
            $successfulUrls.Add($officialUrl)
            return $successfulUrls.ToArray()
        } else {
            Write-Host "`r  ✗ [失败]                                  " -ForegroundColor Red
        }
    }

    $otherMirrors = $Mirror_List | Where-Object { $_ -ne $githubPublicUrl }
    if ($otherMirrors.Count > 0) {
        Write-Warning "已启动并行测试，将完整测试所有镜像..."
        $jobs = @{}
        foreach ($mirrorUrl in $otherMirrors) {
            $scriptBlock = {
                param($mUrl, $rToken, $rPath)
                $authedPushUrl = ""
                $mirrorHost = ($mUrl -split '/')[2]
                if ($mUrl -like "*hub.gitmirror.com*") { $authedPushUrl = "https://$($rToken)@$($mirrorHost)/$($rPath)" }
                elseif ($mUrl -like "*/gh/*") { $authedPushUrl = "https://$($rToken)@$($mirrorHost)/gh/$($rPath)" }
                elseif ($mUrl -like "*/github.com/*") { $authedPushUrl = "https://ghproxy.com/https://github.com/$($rPath)" }
                else { return $null }
                $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
                New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
                $isSuccess = $false
                try {
                    Set-Location $tempDir
                    git init -q
                    git config user.name "test"; git config user.email "test@example.com"; git config core.autocrlf false
                    Set-Content "f.txt" "t"; git add .; git commit -m "t" -q
                    git remote add origin $authedPushUrl
                    $pushJob = Start-Job -ScriptBlock { git push origin "HEAD:refs/tags/st-sync-test-$(Get-Date -UFormat %s%N)" }
                    if (Wait-Job $pushJob -Timeout 15) {
                        if ($pushJob.State -eq 'Completed') {
                            $delJob = Start-Job -ScriptBlock { git push origin --delete "refs/tags/st-sync-test-$(Get-Date -UFormat %s%N)" }
                            Wait-Job $delJob -Timeout 15 | Out-Null
                            Remove-Job $delJob -Force
                            $isSuccess = $true
                        }
                    }
                    Remove-Job $pushJob -Force
                } finally {
                    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
                }
                if ($isSuccess) { return $authedPushUrl } else { return $null }
            }
            $jobs[$mirrorUrl] = Start-Job -ScriptBlock $scriptBlock -ArgumentList $mirrorUrl, $repoToken, $repoPath
        }
        Wait-Job $jobs.Values -Timeout 30 | Out-Null

        foreach ($mirrorUrl in $jobs.Keys) {
            $job = $jobs[$mirrorUrl]
            $mirrorHost = ($mirrorUrl -split '/')[2]
            if ($job.State -eq 'Completed') {
                $pushUrl = Receive-Job $job
                if ($pushUrl) {
                    $successfulUrls.Add($pushUrl)
                    Write-Host ("  - 测试: {0} [成功]" -f $mirrorHost) -ForegroundColor Green
                } else {
                    Write-Host ("  - 测试: {0} [失败]" -f $mirrorHost) -ForegroundColor Red
                }
            } else {
                Write-Host ("  - 测试: {0} [失败]" -f $mirrorHost) -ForegroundColor Red
            }
            Remove-Job -Job $job -Force
        }
    }

    if ($successfulUrls.Count > 0) {
        Write-Success "测试完成，找到 $($successfulUrls.Count) 条可用上传线路。"
        return $successfulUrls.ToArray()
    } else {
        Write-Error "所有上传线路均测试失败。"
        return @()
    }
}

# 核心功能：备份数据到云端 (上传)
function Backup-ToCloud {
    Clear-Host
    Write-Header "Git备份数据到云端 (上传)"
    if (-not (Test-Path $GitSyncConfigFile)) {
        Write-Warning "请先在菜单 [1] 中配置Git同步服务。"
        Press-Any-Key
        return
    }

    $pushUrls = Find-PushableMirror
    if ($pushUrls.Count -eq 0) {
        Write-Error "未能找到任何支持上传的线路。"
        Press-Any-Key
        return
    }

    $syncRules = Parse-ConfigFile $SyncRulesConfigFile
    $syncConfigYaml = if ($syncRules.ContainsKey("SYNC_CONFIG_YAML")) { $syncRules["SYNC_CONFIG_YAML"] } else { "false" }
    $userMap = if ($syncRules.ContainsKey("USER_MAP")) { $syncRules["USER_MAP"] } else { "" }
    $backupSuccess = $false

    foreach ($pushUrl in $pushUrls) {
        $chosenHost = $pushUrl -replace 'https://.*@' -replace '/.*$'
        Write-Warning "正在尝试使用线路 [$chosenHost] 进行备份..."
        $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
        try {
            try {
                git clone --depth 1 $pushUrl $tempDir
                if ($LASTEXITCODE -ne 0) { Write-Error "从云端克隆仓库失败！"; continue }
                Write-Success "已成功从云端克隆仓库。"
                Set-Location $tempDir
                git config core.autocrlf false
                Write-Warning "正在同步本地数据到临时区..."

                # 定义 robocopy 排除规则
                $recursiveExcludeDirs = @("extensions", "backups")
                $recursiveExcludeFiles = @("*.log")
                $robocopyExcludeArgs = @($recursiveExcludeDirs | ForEach-Object { "/XD", $_ }) + @($recursiveExcludeFiles | ForEach-Object { "/XF", $_ })

                if (-not [string]::IsNullOrWhiteSpace($userMap) -and $userMap.Contains(":")) {
                    # 映射同步模式：只同步指定的用户文件夹
                    $localUser = $userMap.Split(':')[0]
                    $remoteUser = $userMap.Split(':')[1]
                    Write-Warning "应用用户映射规则: 本地'$localUser' -> 云端'$remoteUser'"
                    $localUserPath = Join-Path $ST_Dir "data/$localUser"
                    if (Test-Path $localUserPath) {
                        $remoteUserPath = Join-Path $tempDir "data/$remoteUser"
                        robocopy $localUserPath $remoteUserPath /E /PURGE $robocopyExcludeArgs /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
                    } else {
                        Write-Warning "本地用户文件夹 '$localUser' 不存在，跳过同步。"
                    }
                } else {
                    # 镜像同步模式：同步所有用户文件夹
                    Get-ChildItem -Path . | Where-Object { $_.Name -ne ".git" } | Remove-Item -Recurse -Force
                    Write-Warning "应用镜像同步规则: 同步所有本地用户文件夹"
                    $sourceDataPath = Join-Path $ST_Dir "data"
                    $destDataPath = Join-Path $tempDir "data"
                    $topLevelExcludeDirs = @("_cache", "_storage", "_uploads", "_webpack")
                    $finalExcludeArgs = $robocopyExcludeArgs + @($topLevelExcludeDirs | ForEach-Object { "/XD", $_ })
                    robocopy $sourceDataPath $destDataPath /E /PURGE $finalExcludeArgs /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
                }
                if ($syncConfigYaml -eq "true" -and (Test-Path (Join-Path $ST_Dir "config.yaml"))) {
                    Copy-Item (Join-Path $ST_Dir "config.yaml") $tempDir -Force
                }

                Set-Location $tempDir
                git add .
                if ($(git status --porcelain).Length -eq 0) {
                    Write-Success "数据与云端一致，无需上传。"
                    $backupSuccess = $true
                    break
                }
                Write-Warning "正在提交数据变更..."
                $commitMessage = "来自Windows的数据同步: $(Get-Date -Format 'yyyy年MM月dd日 HH:mm:ss')"
                git commit -m $commitMessage -q
                if ($LASTEXITCODE -ne 0) { Write-Error "Git 提交失败！"; continue }
                Write-Warning "正在上传到云端... (请稍候，下方为实时进度)"
                git push
                if ($LASTEXITCODE -ne 0) { Write-Error "上传失败！"; continue }
                Write-Success "数据成功备份到云端！"
                $backupSuccess = $true
                break
            } catch {
                Write-Error "在处理线路 [$chosenHost] 时发生意外错误: $($_.Exception.Message)"
                continue
            }
        } finally {
            Set-Location $ScriptBaseDir
            if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
        }
    }
    if (-not $backupSuccess) { Write-Error "已尝试所有可用线路，但备份均失败。" }
    Press-Any-Key
}

# 核心功能：从云端恢复数据 (下载)
function Restore-FromCloud {
    Clear-Host
    Write-Header "Git从云端恢复数据 (下载)"
    if (-not (Test-Path $GitSyncConfigFile)) {
        Write-Warning "请先在菜单 [1] 中配置Git同步服务。"
        Press-Any-Key
        return
    }
    Write-Warning "此操作将用云端数据【覆盖】本地数据！"
    $backupConfirm = Read-Host "是否在恢复前，先对当前数据进行一次本地备份？(强烈推荐) [Y/n]"
    if ($backupConfirm -ne 'n' -and $backupConfirm -ne 'N') {
        if (-not (New-LocalZipBackup -BackupType "恢复前")) {
            Write-Error "本地备份失败，恢复操作已中止。"
            Press-Any-Key
            return
        }
    }
    $restoreConfirm = Read-Host "确认要从云端恢复数据吗？[Y/n]"
    if ($restoreConfirm -eq 'n' -or $restoreConfirm -eq 'N') {
        Write-Warning "操作已取消。"
        Press-Any-Key
        return
    }

    $syncRules = Parse-ConfigFile $SyncRulesConfigFile
    $syncConfigYaml = if ($syncRules.ContainsKey("SYNC_CONFIG_YAML")) { $syncRules["SYNC_CONFIG_YAML"] } else { "false" }
    $userMap = if ($syncRules.ContainsKey("USER_MAP")) { $syncRules["USER_MAP"] } else { "" }
    $restoreSuccess = $false
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())

    try {
        $gitConfig = Parse-ConfigFile $GitSyncConfigFile
        $repoPath = $gitConfig["REPO_URL"] -replace 'https://github.com/', ''
        $repoToken = $gitConfig["REPO_TOKEN"]
        $officialPrivateUrl = "https://$($repoToken)@github.com/$repoPath"

        Write-Warning "正在尝试使用官方线路 [github.com] 进行恢复... (请稍候，下方为实时进度)"
        git clone --depth 1 $officialPrivateUrl $tempDir
        if ($LASTEXITCODE -ne 0) {
            Write-Error "官方线路恢复失败！正在启动备用线路测试..."
            if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            $pullUrls = Find-FastestMirror -excludeOfficial $true
            if ($pullUrls.Count -eq 0) { Write-Error "未能找到任何可用的备用下载线路。"; return }
            foreach ($pullUrl in $pullUrls) {
                $chosenHost = ($pullUrl -split '/')[2]
                Write-Warning "正在尝试使用备用线路 [$chosenHost] 进行恢复..."
                $privateRepoUrl = $pullUrl -replace '/SillyTavern/SillyTavern.git', "/$repoPath"
                $pullUrlWithAuth = $privateRepoUrl -replace 'https://', "https://$($repoToken)@"
                git clone --depth 1 $pullUrlWithAuth $tempDir
                if ($LASTEXITCODE -eq 0) { $restoreSuccess = $true; break }
                Write-Error "使用备用线路 [$chosenHost] 恢复失败！正在切换下一条..."
                if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
            }
            if (-not $restoreSuccess) { Write-Error "已尝试所有备用线路，但恢复均失败。"; return }
        }
        Write-Success "已成功从云端下载数据。"
        if (-not (Get-ChildItem $tempDir)) { Write-Error "下载的数据源无效或为空，恢复操作已中止！"; return }
        Write-Warning "正在将云端数据同步到本地..."

        # 定义 robocopy 排除规则
        $recursiveExcludeDirs = @("extensions", "backups")
        $recursiveExcludeFiles = @("*.log")
        $robocopyExcludeArgs = @($recursiveExcludeDirs | ForEach-Object { "/XD", $_ }) + @($recursiveExcludeFiles | ForEach-Object { "/XF", $_ })

        if (-not [string]::IsNullOrWhiteSpace($userMap) -and $userMap.Contains(":")) {
            # 映射同步模式
            $localUser = $userMap.Split(':')[0]
            $remoteUser = $userMap.Split(':')[1]
            Write-Warning "应用用户映射规则: 云端'$remoteUser' -> 本地'$localUser'"
            $remoteUserPath = Join-Path $tempDir "data/$remoteUser"
            if (Test-Path $remoteUserPath) {
                $localUserPath = Join-Path $ST_Dir "data/$localUser"
                robocopy $remoteUserPath $localUserPath /E /PURGE $robocopyExcludeArgs /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
            } else {
                Write-Warning "云端映射文件夹 'data\$remoteUser' 不存在，跳过映射同步。"
            }
        } else {
            # 镜像同步模式
            Write-Warning "应用镜像同步规则: 恢复所有云端用户文件夹"
            $sourceDataPath = Join-Path $tempDir "data"
            $destDataPath = Join-Path $ST_Dir "data"
            $remoteUserFolders = Get-UserFolders -baseDataPath $sourceDataPath
            $localUserFolders = Get-UserFolders -baseDataPath $destDataPath
            $finalRemoteFolders = $remoteUserFolders
            $finalRemoteNames = $finalRemoteFolders | ForEach-Object { $_.Name }
            foreach ($localUser in $localUserFolders) {
                if ($finalRemoteNames -notcontains $localUser.Name) {
                    Write-Warning "清理本地多余的用户: $($localUser.Name)"
                    Remove-Item $localUser.FullName -Recurse -Force
                }
            }
            foreach ($remoteUser in $finalRemoteFolders) {
                $sourcePath = $remoteUser.FullName
                $destPath = Join-Path $destDataPath $remoteUser.Name
                robocopy $sourcePath $destPath /E /PURGE $robocopyExcludeArgs /R:2 /W:5 /NFL /NDL /NJH /NJS /NP | Out-Null
            }
        }
        if ($syncConfigYaml -eq "true" -and (Test-Path (Join-Path $tempDir "config.yaml"))) {
            Copy-Item (Join-Path $tempDir "config.yaml") $ST_Dir -Force
        }
        Write-Success "`n数据已从云端成功恢复！"
    } finally {
        if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    }
    Press-Any-Key
}

# 清除 Git 同步配置
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

# 导出已安装扩展的 Git 链接
function Export-ExtensionLinks {
    Clear-Host
    Write-Header "导出扩展链接"
    $allLinks = [System.Collections.Generic.List[string]]::new()
    $outputContent = [System.Text.StringBuilder]::new()
    function Get-RepoUrl($path) {
        if (Test-Path (Join-Path $path ".git")) {
            try {
                Set-Location $path
                $url = git config --get remote.origin.url
                return $url.Trim()
            } finally {
                Set-Location $ScriptBaseDir
            }
        }
        return $null
    }
    $globalExtPath = Join-Path $ST_Dir "public/scripts/extensions/third-party"
    if (Test-Path $globalExtPath) {
        $globalLinks = @(Get-ChildItem -Path $globalExtPath -Directory | ForEach-Object { Get-RepoUrl $_.FullName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($globalLinks.Count -gt 0) {
            $outputContent.AppendLine("═══ 全局扩展 ═══") | Out-Null
            $globalLinks | ForEach-Object { $outputContent.AppendLine($_) | Out-Null; $allLinks.Add($_) }
        }
    }
    $dataPath = Join-Path $ST_Dir "data"
    if (Test-Path $dataPath) {
        Get-ChildItem -Path $dataPath -Directory | ForEach-Object {
            $userDir = $_
            $userExtPath = Join-Path $userDir.FullName "extensions"
            if (Test-Path $userExtPath) {
                $userLinks = @(Get-ChildItem -Path $userExtPath -Directory | ForEach-Object { Get-RepoUrl $_.FullName } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($userLinks.Count -gt 0) {
                    $outputContent.AppendLine() | Out-Null
                    $outputContent.AppendLine("═══ 用户 [$($userDir.Name)] 的扩展 ═══") | Out-Null
                    $userLinks | ForEach-Object { $outputContent.AppendLine($_) | Out-Null; $allLinks.Add($_) }
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

# 显示 Git 同步配置管理菜单
function Show-ManageGitConfigMenu {
    while ($true) {
        Clear-Host
        Write-Header "管理 Git 同步配置"
        Write-Host "      [1] " -NoNewline; Write-Host "修改/设置同步信息" -ForegroundColor Cyan
        Write-Host "      [2] " -NoNewline; Write-Host "清除所有同步配置" -ForegroundColor Red
        Write-Host "      [0] " -NoNewline; Write-Host "返回上一级" -ForegroundColor Cyan
        $choice = Read-Host "`n    请输入选项"
        switch ($choice) {
            "1" { Set-GitSyncConfig; return }
            "2" { Clear-GitSyncConfig }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep 1 }
        }
    }
}

# 更新同步规则配置文件中的键值
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

# 显示高级同步设置菜单
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
            Write-Host "未设置" -F Red
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

# 显示 Git 数据同步主菜单
function Show-GitSyncMenu {
    while ($true) {
        Clear-Host
        Write-Header "数据同步 (Git 方案)"
        if (-not (Test-Path (Join-Path $ST_Dir "start.bat"))) {
            Write-Warning "SillyTavern 尚未安装，无法使用数据同步功能。`n请先返回主菜单选择 [首次部署]。"
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
        Write-Host "`n      [1] " -NoNewline; Write-Host "管理同步配置 (仓库地址/Token)" -F Cyan
        Write-Host "      [2] " -NoNewline; Write-Host "备份到云端 (上传)" -F Green
        Write-Host "      [3] " -NoNewline; Write-Host "从云端恢复 (下载)" -F Yellow
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


# =========================================================================
#   核心功能函数
# =========================================================================

# 启动 SillyTavern
function Start-SillyTavern {
    Clear-Host
    Write-Header "启动 SillyTavern"
    if (-not (Test-Path (Join-Path $ST_Dir "start.bat"))) {
        Write-Warning "SillyTavern 尚未安装，请先部署。"
        Press-Any-Key
        return
    }
    Set-Location $ST_Dir
    Write-Host "正在配置NPM镜像并准备启动环境..."
    npm config set registry https://registry.npmmirror.com
    Write-Warning "环境准备就绪，正在启动SillyTavern服务..."
    Write-Warning "首次启动或更新后会自动安装依赖，耗时可能较长，请耐心等待..."
    Write-Warning "服务将在此窗口中运行，请勿关闭。"
    try {
        cmd /c "start.bat"
    } catch {
        Write-Warning "SillyTavern 服务已停止。"
    }
    Press-Any-Key
}

# 首次安装 SillyTavern
function Install-SillyTavern {
    param([bool]$autoStart = $true)
    Clear-Host
    Write-Header "SillyTavern 部署向导"

    Write-Header "1/3: 检查核心依赖"
    if (-not (Check-Command "git") -or -not (Check-Command "node")) {
        Write-Warning "错误: Git 或 Node.js 未安装。即将为您展示帮助文档..."
        Start-Sleep -Seconds 3
        Open-HelpDocs
        return
    }
    Write-Success "核心依赖 (Git, Node.js) 已找到。"

    Write-Header "2/3: 下载 ST 主程序"
    if (Test-Path $ST_Dir) {
        Write-Warning "目录 $ST_Dir 已存在，跳过下载。"
    } else {
        $downloadSuccess = $false
        while (-not $downloadSuccess) {
            $officialUrl = "https://github.com/SillyTavern/SillyTavern.git"
            Write-Warning "正在尝试从官方线路 [github.com] 下载主程序 ($Repo_Branch 分支)..."
            git clone --depth 1 -b $Repo_Branch $officialUrl $ST_Dir
            if ($LASTEXITCODE -eq 0) {
                $downloadSuccess = $true
            } else {
                Write-Error "官方线路下载失败！正在启动备用线路测试..."
                if (Test-Path $ST_Dir) { Remove-Item -Recurse -Force $ST_Dir }
                $mirrorUrlList = Find-FastestMirror -excludeOfficial $true
                if ($mirrorUrlList.Count -eq 0) {
                    $retryChoice = Read-Host "`n所有备用线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
                    if ($retryChoice -eq 'n') { Write-ErrorExit "用户取消操作。" }
                    $script:CachedMirrors = @()
                    continue
                }
                foreach ($mirrorUrl in $mirrorUrlList) {
                    $mirrorHost = ($mirrorUrl -split '/')[2]
                    Write-Warning "正在尝试从备用镜像 [$($mirrorHost)] 下载..."
                    git clone --depth 1 -b $Repo_Branch $mirrorUrl $ST_Dir
                    if ($LASTEXITCODE -eq 0) { $downloadSuccess = $true; break }
                    Write-Error "使用备用镜像 [$($mirrorHost)] 下载失败！正在切换下一条线路..."
                    if (Test-Path $ST_Dir) { Remove-Item -Recurse -Force $ST_Dir }
                }
            }
            if (-not $downloadSuccess) {
                $retryChoice = Read-Host "`n所有线路均下载失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
                if ($retryChoice -eq 'n') { Write-ErrorExit "下载失败，用户取消操作。" }
                $script:CachedMirrors = @()
            }
        }
        Write-Success "主程序下载完成。"
    }

    Write-Header "3/3: 配置 NPM 环境并安装依赖"
    if (Test-Path $ST_Dir) {
        if (-not (Run-NpmInstallWithRetry)) { Write-ErrorExit "依赖安装最终失败，部署中断。" }
    } else {
        Write-Warning "SillyTavern 目录不存在，跳过此步。"
    }

    if ($autoStart) {
        Write-Host "`n"
        Write-Success "部署完成！"
        Write-Warning "即将进行首次启动..."
        Start-Sleep -Seconds 3
        Start-SillyTavern
    } else {
        Write-Success "全新版本下载与配置完成。"
    }
}

# 创建一个新的本地 Zip 备份
function New-LocalZipBackup {
    param([string]$BackupType, [string[]]$PathsToBackup)
    if (-not (Test-Path $ST_Dir)) {
        Write-Error "SillyTavern 目录不存在，无法创建本地备份。"
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

# 更新 SillyTavern 主程序
function Update-SillyTavern {
    Clear-Host
    Write-Header "更新 SillyTavern 主程序"
    if (-not (Test-Path (Join-Path $ST_Dir ".git"))) {
        Write-Warning "未找到Git仓库，请先完整部署。"
        Press-Any-Key
        return
    }
    $updateSuccess = $false
    while (-not $updateSuccess) {
        Set-Location $ST_Dir
        $officialUrl = "https://github.com/SillyTavern/SillyTavern.git"
        Write-Warning "正在尝试使用官方线路 [github.com] 更新..."
        git remote set-url origin $officialUrl
        $gitOutput = git pull origin $Repo_Branch 2>&1
        if ($LASTEXITCODE -eq 0) {
            if ($gitOutput -match "Already up to date") { Write-Success "代码已是最新，无需更新。" } else { Write-Success "代码更新成功。" }
            if (Run-NpmInstallWithRetry) { $updateSuccess = $true }
        } else {
            if ($gitOutput -match "Your local changes to the following files would be overwritten|conflict|error: Pulling is not possible because you have unmerged files.") {
                Clear-Host
                Write-Header "检测到更新冲突！"
                Write-Warning "原因: 你可能修改过酒馆的某些文件，导致无法自动合并新版本。"
                Write-Host "--- 冲突文件预览 ---`n$($gitOutput | Select-String -Pattern '^\s+' | Select -First 5)`n--------------------"
                Write-Host "`n请选择操作方式："
                Write-Host "  [回车] " -NoNewline -ForegroundColor Green; Write-Host "自动备份并重新安装 (推荐)"
                Write-Host "  [1]    " -NoNewline -ForegroundColor Yellow; Write-Host "强制覆盖更新 (危险)"
                Write-Host "  [0]    " -NoNewline -ForegroundColor Cyan; Write-Host "放弃更新"
                $conflictChoice = Read-Host "`n请输入选项"
                if ([string]::IsNullOrEmpty($conflictChoice)) { $conflictChoice = 'default' }
                switch ($conflictChoice) {
                    'default' {
                        Clear-Host
                        Write-Header "步骤 1/5: 创建本地备份"
                        $dataBackupZipPath = New-LocalZipBackup -BackupType "更新前"
                        if (-not $dataBackupZipPath) { Write-ErrorExit "本地备份创建失败，更新流程终止。" }
                        Write-Header "步骤 2/5: 完整备份当前目录"
                        $renamedBackupDir = "$($ST_Dir)_backup_$(Get-Date -Format 'yyyyMMddHHmmss')"
                        try {
                            Set-Location $ScriptBaseDir
                            Rename-Item -Path $ST_Dir -NewName $renamedBackupDir -ErrorAction Stop
                        } catch {
                            Write-ErrorExit "备份失败，请检查权限或手动重命名后重试。"
                        }
                        Write-Success "旧目录已完整备份为: $($renamedBackupDir | Split-Path -Leaf)"
                        Write-Header "步骤 3/5: 下载并安装新版 SillyTavern"
                        Install-SillyTavern -autoStart $false
                        if (-not (Test-Path $ST_Dir)) { Write-ErrorExit "新版本安装失败，流程终止。" }
                        Write-Header "步骤 4/5: 自动恢复用户数据"
                        try {
                            Write-Warning "正在将备份数据解压至新目录..."
                            Expand-Archive -Path $dataBackupZipPath -DestinationPath $ST_Dir -Force -ErrorAction Stop
                            Write-Success "用户数据已成功恢复到新版本中。"
                        } catch {
                            Write-ErrorExit "数据恢复失败！错误: $($_.Exception.Message)"
                        }
                        Write-Header "步骤 5/5: 更新完成，请确认"
                        Write-Success "SillyTavern 已更新并恢复数据！"
                        Write-Warning "请注意:"
                        Write-Host "  - 您的聊天记录、角色卡、插件和设置已恢复。"
                        Write-Host "  - 如果您曾手动修改过酒馆核心文件(如 server.js)，这些修改需要您重新操作。"
                        Write-Host "  - 您的完整旧版本已备份在: " -NoNewline; Write-Host ($renamedBackupDir | Split-Path -Leaf) -ForegroundColor Cyan
                        Write-Host "  - 本次恢复所用的核心本地备份位于: " -NoNewline; Write-Host (Join-Path ($Backup_Root_Dir | Split-Path -Leaf) ($dataBackupZipPath | Split-Path -Leaf)) -ForegroundColor Cyan
                        Write-Host "`n请按任意键，启动更新后的 SillyTavern..." -ForegroundColor Cyan
                        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
                        Start-SillyTavern
                        return
                    }
                    '1' {
                        Write-Warning "正在执行强制覆盖 (git reset --hard)..."
                        git reset --hard origin/$Repo_Branch
                        if (git pull origin $Repo_Branch) {
                            Write-Success "强制更新成功。"
                            if (Run-NpmInstallWithRetry) { $updateSuccess = $true }
                        } else {
                            Write-Error "强制更新失败！"
                        }
                        break
                    }
                    default {
                        Write-Warning "已取消更新。"
                        Press-Any-Key
                        return
                    }
                }
            }
            Write-Error "官方线路更新失败！正在启动备用线路测试..."
            $mirrorUrlList = Find-FastestMirror -excludeOfficial $true
            if ($mirrorUrlList.Count -eq 0) {
                $retryChoice = Read-Host "`n所有备用线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
                if ($retryChoice -eq 'n') { Write-Warning "用户取消操作。"; break }
                $script:CachedMirrors = @()
            }
            foreach ($mirrorUrl in $mirrorUrlList) {
                $mirrorHost = ($mirrorUrl -split '/')[2]
                Write-Warning "正在尝试使用备用镜像 [$($mirrorHost)] 更新..."
                git remote set-url origin $mirrorUrl
                $gitOutput = git pull origin $Repo_Branch 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "代码更新成功。"
                    if (Run-NpmInstallWithRetry) { $updateSuccess = $true }
                    break
                } else {
                    Write-Error "使用备用镜像 [$($mirrorHost)] 更新失败！正在切换下一条线路..."
                }
            }
        }
        if (-not $updateSuccess) {
            Set-Location $ScriptBaseDir
            $retryChoice = Read-Host "`n所有线路均更新失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
            if ($retryChoice -eq 'n') { Write-Warning "更新失败，用户取消操作。"; break }
            $script:CachedMirrors = @()
        }
    }
    Set-Location $ScriptBaseDir
    if ($updateSuccess) { Write-Success "SillyTavern 更新完成！" }
    Press-Any-Key
}

# 交互式创建本地备份
function Run-BackupInteractive {
    Clear-Host
    if (-not (Test-Path $ST_Dir)) {
        Write-Warning "SillyTavern 尚未安装，无法备份。"
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

# 显示本地备份管理菜单
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

# 显示本地备份主菜单
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

# 打开帮助文档
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

# 更新助手脚本自身
function Update-AssistantScript {
    Clear-Host
    Write-Header "更新助手脚本"
    Write-Warning "正在从服务器获取最新版本..."
    try {
        $newScriptContent = (Invoke-WebRequest -Uri $ScriptSelfUpdateUrl -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
        if ([string]::IsNullOrWhiteSpace($newScriptContent)) { Write-ErrorExit "下载失败：脚本内容为空！" }
        $currentScriptContent = Get-Content -Path $PSCommandPath -Raw
        if ($newScriptContent.Replace("`r`n", "`n").Trim() -eq $currentScriptContent.Replace("`r`n", "`n").Trim()) {
            Write-Success "当前已是最新版本。"
            Press-Any-Key
            return
        }
        $newFileName = "pc-st(新版本).ps1"
        $newFilePath = Join-Path $ScriptBaseDir $newFileName
        Set-Content -Path $newFilePath -Value $newScriptContent -Encoding UTF8
        Clear-Host
        Write-Header "新版本下载完成！"
        Write-Success "新版本已保存为: $newFileName"
        Write-Warning "请按以下步骤手动完成更新 (本窗口将保持打开供您参考):"
        Write-Host "`n  1. " -NoNewline; Write-Host "在即将自动打开的文件夹中..." -ForegroundColor Cyan
        Write-Host "  2. " -NoNewline; Write-Host "先删除旧的 'pc-st.ps1' 文件。" -ForegroundColor Cyan
        Write-Host "  3. " -NoNewline; Write-Host "再将 '$newFileName' 重命名为 'pc-st.ps1'。" -ForegroundColor Cyan
        Write-Host "`n完成后，请手动关闭本窗口，并重新运行 '酒馆助手.bat' 即可。" -ForegroundColor Green
        Write-Host "`n"
        Write-Warning "4秒后将自动为您打开文件夹..."
        Start-Sleep -Seconds 4
        Invoke-Item $ScriptBaseDir
        exit
    } catch {
        Write-ErrorExit "下载脚本时发生错误！`n`n错误详情: $($_.Exception.Message)"
    }
}

# 启动时在后台检查更新
function Check-ForUpdatesOnStart {
    $jobScriptBlock = {
        param($url, $flag, $path)
        try {
            $new = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content
            if (-not [string]::IsNullOrWhiteSpace($new)) {
                $old = Get-Content -Path $path -Raw
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


# =========================================================================
#   主菜单与脚本入口
# =========================================================================

# 启动时应用代理并检查更新
Apply-Proxy
Check-ForUpdatesOnStart

# 主循环
while ($true) {
    Clear-Host
    Write-Host @"
    ╔═════════════════════════════════╗
    ║      SillyTavern 助手 v2.1      ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
"@ -ForegroundColor Cyan
    $updateNoticeText = if (Test-Path $UpdateFlagFile) { " [!] 有更新" } else { "" }
    Write-Host "`n    选择一个操作来开始：`n"
    Write-Host "      [1] " -NoNewline -ForegroundColor Green; Write-Host "启动 SillyTavern"
    Write-Host "      [2] " -NoNewline -ForegroundColor Cyan; Write-Host "数据同步 (Git 云端)"
    Write-Host "      [3] " -NoNewline -ForegroundColor Cyan; Write-Host "本地备份管理"
    Write-Host "      [4] " -NoNewline -ForegroundColor Yellow; Write-Host "首次部署 (全新安装)`n"
    Write-Host "      [5] 更新 ST 主程序    [6] 更新助手脚本$($updateNoticeText)"
    Write-Host "      [7] 打开 ST 文件夹    [8] 查看帮助文档"
    Write-Host "      [9] 配置网络代理`n"
    Write-Host "      [0] " -NoNewline -ForegroundColor Red; Write-Host "退出助手`n"
    $choice = Read-Host "    请输入选项数字"
    switch ($choice) {
        "1" { Start-SillyTavern }
        "2" { Show-GitSyncMenu }
        "3" { Show-BackupMenu }
        "4" { Install-SillyTavern }
        "5" { Update-SillyTavern }
        "6" { Update-AssistantScript }
        "7" { if (Test-Path $ST_Dir) { Invoke-Item $ST_Dir } else { Write-Warning '目录不存在，请先部署！'; Start-Sleep 1.5 } }
        "8" { Open-HelpDocs }
        "9" { Show-ManageProxyMenu }
        "0" { if (Test-Path $UpdateFlagFile) { Remove-Item $UpdateFlagFile -Force }; Write-Host "感谢使用，助手已退出。"; exit }
        default { Write-Warning "无效输入，请重新选择。"; Start-Sleep -Seconds 1.5 }
    }
}

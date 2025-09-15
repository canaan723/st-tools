[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# SillyTavern 助手 v1.5
# 作者: Qingjue | 小红书号: 826702880

# =========================================================================
#   核心配置
# =========================================================================

$ScriptSelfUpdateUrl = "https://gitee.com/canaan723/st-tools/raw/main/jiuguan/pc-st.ps1"
$HelpDocsUrl = "https://blog.qjyg.de"
$ScriptBaseDir = Split-Path -Path $PSCommandPath -Parent
$ST_Dir = Join-Path $ScriptBaseDir "SillyTavern"
$Repo_Branch = "release"
$Backup_Root_Dir = Join-Path $ScriptBaseDir "_SillyTavern_Backups"
$Backup_Limit = 10
$ConfigFile = Join-Path $ScriptBaseDir ".st_assistant.conf"
$UpdateFlagFile = Join-Path ([System.IO.Path]::GetTempPath()) ".st_assistant_update_flag"

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
    "https://gh-proxy.net/https://github.com/SillyTavern/SillyTavern.git"
)

# =========================================================================
#   辅助函数库
# =========================================================================

function Write-Header($Title) { Write-Host "`n═══ $($Title) ═══" -ForegroundColor Cyan }
function Write-Success($Message) { Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Warning($Message) { Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-Error($Message) { Write-Host "✗ $Message" -ForegroundColor Red }
function Write-ErrorExit($Message) { Write-Host "`n✗ $Message`n流程已终止。" -ForegroundColor Red; Press-Any-Key; exit }
function Press-Any-Key { Write-Host "`n请按任意键返回..." -ForegroundColor Cyan; $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null }
function Check-Command($Command) { return (Get-Command $Command -ErrorAction SilentlyContinue) }

function Find-FastestMirror {
    Write-Warning "开始测试 Git 镜像连通性与速度..."
    $githubUrl = "https://github.com/SillyTavern/SillyTavern.git"
    
    if ($Mirror_List -contains $githubUrl) {
        Write-Host "  [1/?] 正在优先测试 GitHub 官方源..." -ForegroundColor Cyan -NoNewline
        $job = Start-Job -ScriptBlock { param($url) git ls-remote $url HEAD } -ArgumentList $githubUrl
        if (Wait-Job -Job $job -Timeout 15) {
            Write-Host "`r  [✓] GitHub 官方源直连可用，将优先使用！          " -ForegroundColor Green
            Remove-Job -Job $job -Force
            return @($githubUrl)
        } else {
            Write-Host "`r  [✗] GitHub 官方源连接超时，将测试其他镜像...      " -ForegroundColor Red
            Remove-Job -Job $job -Force
        }
    }

    $otherMirrors = $Mirror_List | Where-Object { $_ -ne $githubUrl }
    if ($otherMirrors.Count -eq 0) {
        Write-Error "没有其他可用的镜像进行测试。"
        return $null
    }

    $jobInfoList = @()
    foreach ($mirrorUrl in $otherMirrors) {
        $jobInfo = [PSCustomObject]@{
            Job  = Start-Job -ScriptBlock { param($u) git ls-remote $u HEAD } -ArgumentList $mirrorUrl
            Url  = $mirrorUrl
            Host = ($mirrorUrl -split '/')[2]
        }
        $jobInfoList += $jobInfo
    }

    Write-Host "  已启动并行测试，等待所有镜像响应..."
    Wait-Job -Job ($jobInfoList.Job) -Timeout 15 | Out-Null

    $results = @{}
    foreach ($jobInfo in $jobInfoList) {
        $job = $jobInfo.Job
        if ($job.State -eq 'Completed') {
            $elapsedSeconds = ($job.PSEndTime - $job.PSBeginTime).TotalSeconds
            Write-Host ("  [✓] 测试成功: {0} - 耗时 {1:N2}s" -f $jobInfo.Host, $elapsedSeconds) -ForegroundColor Green
            $results[$jobInfo.Url] = $elapsedSeconds
        } else {
            Write-Host ("  [✗] 测试失败: {0} - 连接超时或无效" -f $jobInfo.Host) -ForegroundColor Red
        }
        Remove-Job -Job $job -Force
    }

    if ($results.Count -eq 0) {
        Write-Error "所有镜像都无法连接，请检查网络或更新镜像列表。"
        return $null
    }

    $sortedUrls = $results.Keys | Sort-Object { $results[$_] }
    $fastestUrl = $sortedUrls[0]
    $fastestTime = $results[$fastestUrl]
    $fastestHost = ($fastestUrl -split '/')[2]
    Write-Success ("已选定最快镜像: {0} (耗时 {1:N2}s)" -f $fastestHost, $fastestTime)
    
    return $sortedUrls
}

function Run-NpmInstallWithRetry {
    Write-Warning "正在同步依赖包 (npm install)..."
    npm install --no-audit --no-fund --omit=dev
    if ($LASTEXITCODE -eq 0) {
        Write-Success "依赖包同步完成。"
        return $true
    }

    Write-Warning "依赖包同步失败，将自动清理缓存并使用国内镜像重试..."
    npm cache clean --force --silent
    npm install --no-audit --no-fund --omit=dev
    if ($LASTEXITCODE -eq 0) {
        Write-Success "依赖包重试同步成功。"
        return $true
    }
    
    Write-Warning "国内镜像安装失败，将切换到NPM官方源进行最后尝试 (此过程可能很慢)..."
    try {
        npm config delete registry
        npm install --no-audit --no-fund --omit=dev
        if ($LASTEXITCODE -eq 0) {
            Write-Success "使用官方源安装依赖成功！"
            return $true
        }
    } finally {
        Write-Host "正在将 NPM 源恢复为国内镜像..."
        npm config set registry https://registry.npmmirror.com
    }
    
    Write-Error "所有尝试均失败，请检查网络或手动在 SillyTavern 目录运行 'npm install' 查看详细错误。"
    return $false
}

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
            $mirrorUrlList = Find-FastestMirror
            if ($null -eq $mirrorUrlList) {
                $retryChoice = Read-Host "`n所有线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
                if ($retryChoice -eq 'n') { Write-ErrorExit "用户取消操作。" }
                continue
            }
            
            foreach ($mirrorUrl in $mirrorUrlList) {
                $mirrorHost = ($mirrorUrl -split '/')[2]
                Write-Warning "正在尝试从镜像 [$($mirrorHost)] 下载主程序 ($Repo_Branch 分支)..."
                git clone --depth 1 -b $Repo_Branch $mirrorUrl $ST_Dir
                
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "主程序下载完成。"
                    $downloadSuccess = $true
                    break
                } else {
                    Write-Error "使用镜像 [$($mirrorHost)] 下载失败！正在切换下一条线路..."
                    if (Test-Path $ST_Dir) { Remove-Item -Recurse -Force $ST_Dir }
                }
            }
            
            if (-not $downloadSuccess) {
                $retryChoice = Read-Host "`n所有线路均下载失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
                if ($retryChoice -eq 'n') { Write-ErrorExit "下载失败，用户取消操作。" }
            }
        }
    }

    Write-Header "3/3: 配置 NPM 环境"
    if (Test-Path $ST_Dir) {
        Set-Location $ST_Dir
        Write-Warning "正在配置NPM国内镜像..."
        npm config set registry https://registry.npmmirror.com
        Write-Success "NPM配置完成。"
    } else {
        Write-Warning "SillyTavern 目录不存在，跳过此步。"
    }

    if ($autoStart) {
        Write-Host "`n"
        Write-Success "部署完成！"
        Write-Warning "即将进行首次启动..."
        Write-Host "3秒后将自动开始..."
        Start-Sleep -Seconds 3
        Start-SillyTavern
    } else {
        Write-Success "全新版本下载与配置完成。"
    }
}

function Create-DataZipBackup {
    Write-Warning "正在创建核心数据备份 (.zip)..."
    if (-not (Test-Path $ST_Dir)) {
        Write-Error "SillyTavern 目录不存在，无法备份。"
        return $null
    }

    $pathsToBackup = @(
        "data",
        "public/scripts/extensions/third-party",
        "plugins",
        "config.yaml"
    )
    
    if (-not (Test-Path $Backup_Root_Dir)) { New-Item -Path $Backup_Root_Dir -ItemType Directory | Out-Null }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $backupName = "ST_核心数据_$($timestamp).zip"
    $backupZipPath = Join-Path $Backup_Root_Dir $backupName
    
    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -Path $stagingDir -ItemType Directory | Out-Null
    
    try {
        $hasFiles = $false
        foreach ($item in $pathsToBackup) {
            $sourcePath = Join-Path $ST_Dir $item
            if (-not (Test-Path $sourcePath)) { continue }
            $hasFiles = $true
            if (Test-Path $sourcePath -PathType Container) {
                $destPath = Join-Path $stagingDir $item
                robocopy $sourcePath $destPath /E /NFL /NDL /NJH /NJS /NP /R:2 /W:5 | Out-Null
            } else {
                Copy-Item -Path $sourcePath -Destination $stagingDir -Force
            }
        }
        
        if (-not $hasFiles) {
            Write-Error "未能收集到任何有效的数据文件进行备份。"
            return $null
        }
        
        Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $backupZipPath -Force -ErrorAction Stop
        Write-Success "核心数据备份成功: $backupName"
        return $backupZipPath
    } catch {
        Write-Error "创建 .zip 备份失败！错误信息: $($_.Exception.Message)"
        return $null
    } finally {
        if (Test-Path $stagingDir) { Remove-Item -Path $stagingDir -Recurse -Force }
    }
}

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
        $mirrorUrlList = Find-FastestMirror
        if ($null -eq $mirrorUrlList) {
            $retryChoice = Read-Host "`n所有线路均测试失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
            if ($retryChoice -eq 'n') { Write-Warning "用户取消操作。"; Press-Any-Key; return }
            continue
        }
        
        $pullAttempted = $false
        Set-Location $ST_Dir

        foreach ($mirrorUrl in $mirrorUrlList) {
            $mirrorHost = ($mirrorUrl -split '/')[2]
            Write-Warning "正在尝试使用镜像 [$($mirrorHost)] 更新..."
            git remote set-url origin $mirrorUrl
            
            Write-Warning "正在拉取最新代码 (git pull)..."
            $gitOutput = git pull origin $Repo_Branch 2>&1
            
            if ($LASTEXITCODE -eq 0) {
                Write-Success "代码更新成功。"
                if (Run-NpmInstallWithRetry) { $updateSuccess = $true }
                break
            } 
            
            if ($gitOutput -match "Your local changes to the following files would be overwritten|conflict|error: Pulling is not possible because you have unmerged files.") {
                Clear-Host
                Write-Header "检测到更新冲突！"
                Write-Warning "原因: 你可能修改过酒馆的某些文件，导致无法自动合并新版本。"
                Write-Host "--- 冲突文件预览 ---`n$($gitOutput | Select-String -Pattern '^\s+' | Select -First 5)`n--------------------"
                Write-Host "`n请选择操作方式："
                Write-Host "  [回车] " -NoNewline -ForegroundColor Green; Write-Host "自动备份并重新安装 (推荐)"
                Write-Host "  [1]    " -NoNewline -ForegroundColor Yellow; Write-Host "强制覆盖更新 (危险，将丢失你的修改)"
                Write-Host "  [0]    " -NoNewline -ForegroundColor Cyan; Write-Host "放弃更新，手动处理"
                $conflictChoice = Read-Host "`n请输入选项"

                if ([string]::IsNullOrEmpty($conflictChoice)) { $conflictChoice = 'default' }

                switch ($conflictChoice) {
                    'default' {
                        Clear-Host
                        Write-Header "步骤 1/5: 创建核心数据备份"
                        $dataBackupZipPath = Create-DataZipBackup
                        if (-not $dataBackupZipPath) { Write-ErrorExit "核心数据备份(.zip)创建失败，更新流程终止。" }

                        Write-Header "步骤 2/5: 完整备份当前目录"
                        $renamedBackupDir = "$($ST_Dir)_backup_$(Get-Date -Format 'yyyyMMddHHmmss')"
                        try { 
                            Set-Location $ScriptBaseDir
                            Rename-Item -Path $ST_Dir -NewName $renamedBackupDir -ErrorAction Stop 
                        } catch { Write-ErrorExit "备份失败，请检查权限或手动重命名后重试。" }
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
                        Write-Host "  - 本次恢复所用的核心数据备份位于: " -NoNewline; Write-Host (Join-Path ($Backup_Root_Dir | Split-Path -Leaf) ($dataBackupZipPath | Split-Path -Leaf)) -ForegroundColor Cyan
                        
                        Write-Warning "`n即将为您打开程序根目录以便核对..."
                        Start-Sleep -Seconds 3
                        Invoke-Item $ScriptBaseDir

                        Write-Host "`n请按任意键，启动更新后的 SillyTavern..." -ForegroundColor Cyan
                        $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null
                        
                        Start-SillyTavern
                        return
                    }
                    '1' {
                        Write-Warning "正在执行强制覆盖... (git reset --hard)"
                        git reset --hard origin/$Repo_Branch
                        Write-Warning "正在重新拉取代码..."
                        git pull origin $Repo_Branch
                        if ($LASTEXITCODE -eq 0) {
                            Write-Success "强制更新成功。"
                            if (Run-NpmInstallWithRetry) { $updateSuccess = $true }
                        } else {
                            Write-Error "强制更新失败！"
                        }
                        $pullAttempted = $true
                        break
                    }
                    default {
                        Write-Warning "已取消更新，你可以稍后手动处理冲突。"
                        Press-Any-Key
                        return
                    }
                }
            } else {
                Write-Error "使用镜像 [$($mirrorHost)] 更新失败！错误信息如下："
                Write-Host ($gitOutput | Select -Last 5)
                Write-Error "正在切换下一条线路..."
            }
        }

        if ($pullAttempted) { break }

        if (-not $updateSuccess) {
            Set-Location $ScriptBaseDir
            $retryChoice = Read-Host "`n所有线路均更新失败。是否重新测速并重试？(直接回车=是, 输入n=否)"
            if ($retryChoice -eq 'n') {
                Write-Warning "更新失败，用户取消操作。"
                break
            }
        }
    }
    
    Set-Location $ScriptBaseDir
    Press-Any-Key
}

function Run-BackupInteractive {
    Clear-Host
    Write-Header "创建自定义备份"
    if (-not (Test-Path $ST_Dir)) {
        Write-Warning "SillyTavern 尚未安装，请先部署。"
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
    $DefaultSelection = "data", "plugins", "public/scripts/extensions/third-party"
    $PathsToLoad = if (Test-Path $ConfigFile) { Get-Content $ConfigFile } else { $DefaultSelection }
    
    $Options | ForEach-Object { $SelectionStatus[$_] = $false }
    $PathsToLoad | ForEach-Object { if ($SelectionStatus.ContainsKey($_)) { $SelectionStatus[$_] = $true } }

    while ($true) {
        Clear-Host
        Write-Header "请选择要备份的内容"
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
        Write-Host "`n      "
        Write-Host "[回车] 开始备份" -NoNewline -ForegroundColor Green
        Write-Host "      "
        Write-Host "[0] 取消备份" -NoNewline -ForegroundColor Red
        Write-Host ""
        
        $userChoice = Read-Host "请操作 [输入数字, 回车 或 0]"
        if ([string]::IsNullOrEmpty($userChoice)) {
            break
        } elseif ($userChoice -eq '0') {
            Write-Warning "备份已取消。"
            Press-Any-Key
            return
        } elseif ($userChoice -match '^\d+$' -and [int]$userChoice -ge 1 -and [int]$userChoice -le $Options.Count) {
            $selectedIndex = [int]$userChoice - 1
            $selectedKey = $Options[$selectedIndex]
            $SelectionStatus[$selectedKey] = -not $SelectionStatus[$selectedKey]
        } else {
            Write-Warning "无效输入。"
            Start-Sleep -Seconds 1
        }
    }

    $pathsToBackup = @()
    foreach ($key in $Options) {
        if ($SelectionStatus[$key] -and (Test-Path (Join-Path $ST_Dir $key))) {
            $pathsToBackup += $key
        }
    }

    if ($pathsToBackup.Count -eq 0) {
        Write-Warning "您没有选择任何有效的项目，备份已取消。"
        Press-Any-Key
        return
    }

    if (-not (Test-Path $Backup_Root_Dir)) { New-Item -Path $Backup_Root_Dir -ItemType Directory | Out-Null }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
    $backupName = "ST_备份_$($timestamp).zip"
    $backupZipPath = Join-Path $Backup_Root_Dir $backupName
    
    Write-Host "`n"
    Write-Warning "包含项目:"
    $pathsToBackup | ForEach-Object { Write-Host "  - $_" }
    
    $stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString())
    New-Item -Path $stagingDir -ItemType Directory | Out-Null
    
    try {
        Write-Warning "正在收集文件并准备打包..."
        $excludeDirs = @("_cache", "backups")
        $excludeFiles = @("*.log")
        
        foreach ($item in $pathsToBackup) {
            $sourcePath = Join-Path $ST_Dir $item
            if (-not (Test-Path $sourcePath)) { continue }
            
            if (Test-Path $sourcePath -PathType Container) {
                $destPath = Join-Path $stagingDir $item
                robocopy $sourcePath $destPath /E /XD $excludeDirs /XF $excludeFiles /NFL /NDL /NJH /NJS /NP /R:2 /W:5 | Out-Null
            } else {
                Copy-Item -Path $sourcePath -Destination $stagingDir -Force
            }
        }
        
        if (-not (Get-ChildItem -Path $stagingDir)) {
            Write-ErrorExit "未能收集到任何文件，备份已取消。"
            return
        }
        
        Write-Warning "正在压缩文件..."
        Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $backupZipPath -Force -ErrorAction Stop
        
        Set-Content -Path $ConfigFile -Value ($pathsToBackup -join "`r`n") -Encoding utf8
        Write-Success "备份成功：$backupName"
    } catch {
        Write-ErrorExit "备份失败！错误信息: $($_.Exception.Message)"
        return
    } finally {
        if (Test-Path $stagingDir) { Remove-Item -Path $stagingDir -Recurse -Force }
    }
    
    $allBackups = Get-ChildItem -Path $Backup_Root_Dir -Filter "*.zip" | Sort-Object CreationTime -Descending
    Write-Warning "正在清理旧备份 (当前/上限: $($allBackups.Count)/$Backup_Limit)..."
    if ($allBackups.Count -gt $Backup_Limit) {
        $allBackups | Select-Object -Skip $Backup_Limit | ForEach-Object {
            Remove-Item $_.FullName
            Write-Host "  - 已删除旧备份: $($_.Name)"
        }
        Write-Success "清理完成。"
    }
    
    Press-Any-Key
}

function Delete-Backup {
    Clear-Host
    Write-Header "删除旧备份"
    if (-not (Test-Path $ST_Dir)) { Write-Warning "SillyTavern 尚未安装，请先部署。"; Press-Any-Key; return }
    if (-not (Test-Path $Backup_Root_Dir)) { New-Item -Path $Backup_Root_Dir -ItemType Directory | Out-Null }

    $backupFiles = Get-ChildItem -Path $Backup_Root_Dir -Filter "*.zip" | Sort-Object CreationTime -Descending
    if ($backupFiles.Count -eq 0) {
        Write-Warning "未找到任何备份文件。"
        Press-Any-Key
        return
    }

    Write-Host "检测到以下备份 (当前/上限: $($backupFiles.Count)/$Backup_Limit):"
    for ($i = 0; $i -lt $backupFiles.Count; $i++) {
        $file = $backupFiles[$i]
        $size = "{0:N2} MB" -f ($file.Length / 1MB)
        Write-Host ("    [{0,2}] {1,-40} ({2})" -f ($i + 1), $file.Name, $size)
    }
    
    $choice = Read-Host "`n输入要删除的备份编号 (其他键取消)"
    if (-not ($choice -match '^\d+$') -or [int]$choice -lt 1 -or [int]$choice -gt $backupFiles.Count) {
        Write-Warning "操作已取消。"
        Press-Any-Key
        return
    }
    
    $chosenBackup = $backupFiles[[int]$choice - 1]
    $confirm = Read-Host "确认删除 '$($chosenBackup.Name)' 吗？(y/n)"
    if ($confirm -eq 'y') {
        Remove-Item $chosenBackup.FullName
        Write-Success "备份已删除。"
    } else {
        Write-Warning "操作已取消。"
    }
    
    Press-Any-Key
}

function Show-MigrationGuide {
    Clear-Host
    Write-Header "数据迁移 / 恢复指南"
    if (-not (Test-Path $ST_Dir)) {
        Write-Warning "SillyTavern 尚未安装，请先部署。"
        Press-Any-Key
        return
    }

    Write-Warning "请遵循以下步骤进行操作:"
    Write-Host "  1. 找到你的备份压缩包 (位于: " -NoNewline; Write-Host $Backup_Root_Dir -ForegroundColor Cyan -NoNewline; Write-Host ")"
    Write-Host "  2. 将压缩包复制到 SillyTavern 的根目录 (位于: " -NoNewline; Write-Host $ST_Dir -ForegroundColor Cyan -NoNewline; Write-Host ")"
    Write-Host "  3. 在根目录中，右键点击压缩包，选择 '全部解压缩...'。"
    Write-Host "  4. 如果提示文件已存在，请选择 '替换目标中的文件'。"
    Write-Host "`n"
    Write-Host "如需更详细的图文教程，请在主菜单选择 " -NoNewline; Write-Host "[7] 查看帮助文档" -NoNewline -ForegroundColor Yellow; Write-Host "."
    
    Press-Any-Key
}

function Show-DataManagementMenu {
    while ($true) {
        Clear-Host
        Write-Header "SillyTavern 数据管理"
        Write-Host "      [1] " -NoNewline; Write-Host "创建自定义备份" -ForegroundColor Green
        Write-Host "      [2] " -NoNewline; Write-Host "数据迁移/恢复指南" -ForegroundColor Cyan
        Write-Host "      [3] " -NoNewline; Write-Host "删除旧备份" -ForegroundColor Red
        Write-Host "      [0] " -NoNewline; Write-Host "返回主菜单" -ForegroundColor Cyan
        
        $dm_choice = Read-Host "`n    请输入选项"
        switch ($dm_choice) {
            "1" { Run-BackupInteractive }
            "2" { Show-MigrationGuide }
            "3" { Delete-Backup }
            "0" { return }
            default { Write-Warning "无效输入。"; Start-Sleep -Seconds 1 }
        }
    }
}

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

function Update-AssistantScript {
    Clear-Host
    Write-Header "更新助手脚本"
    Write-Warning "正在从服务器获取最新版本..."
    
    try {
        $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
        $newScriptContent = (Invoke-WebRequest -Uri $ScriptSelfUpdateUrl -UseBasicParsing -UserAgent $userAgent -TimeoutSec 30 -ErrorAction Stop).Content
        
        if ([string]::IsNullOrWhiteSpace($newScriptContent)) {
            Write-ErrorExit "下载失败：从服务器获取到的脚本内容为空！请检查网络连接或稍后再试。"
            return
        }
        
        $currentScriptContent = Get-Content -Path $PSCommandPath -Raw
        $normalizedNew = $newScriptContent.Replace("`r`n", "`n").Trim()
        $normalizedOld = $currentScriptContent.Replace("`r`n", "`n").Trim()
        
        if ($normalizedNew -eq $normalizedOld) {
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
        $errorMessage = "下载脚本时发生错误！`n`n"
        $errorMessage += "--- 调试信息 ---`n"
        $errorMessage += "请求地址: $($ScriptSelfUpdateUrl)`n"
        $errorMessage += "错误类型: $($_.Exception.GetType().FullName)`n"
        $errorMessage += "错误详情: $($_.Exception.Message)`n"
        if ($_.Exception.InnerException) { $errorMessage += "内部错误: $($_.Exception.InnerException.Message)`n" }
        $errorMessage += "------------------`n"
        $errorMessage += "请将以上 [调试信息] 完整截图，以便分析问题。"
        Write-ErrorExit $errorMessage
    }
}

function Check-ForUpdatesOnStart {
    $jobScriptBlock = {
        param($url, $flag, $path)
        try {
            $userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
            $new = (Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent $userAgent -TimeoutSec 10).Content
            
            if (-not [string]::IsNullOrWhiteSpace($new)) {
                $old = Get-Content -Path $path -Raw
                $normalizedNew = $new.Replace("`r`n", "`n").Trim()
                $normalizedOld = $old.Replace("`r`n", "`n").Trim()
                
                if ($normalizedNew -ne $normalizedOld) {
                    [System.IO.File]::Create($flag).Close()
                } else {
                    if (Test-Path $flag) { Remove-Item $flag -Force }
                }
            }
        } catch {
        }
    }
    Start-Job -ScriptBlock $jobScriptBlock -ArgumentList $ScriptSelfUpdateUrl, $UpdateFlagFile, $PSCommandPath | Out-Null
}

# =========================================================================
#   主菜单与脚本入口
# =========================================================================

Check-ForUpdatesOnStart

while ($true) {
    Clear-Host
    Write-Host @"
    ╔═════════════════════════════════╗
    ║      SillyTavern 助手 v1.5      ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
"@ -ForegroundColor Cyan

    $updateNoticeText = if (Test-Path $UpdateFlagFile) { " [!] 有更新" } else { "" }

    Write-Host "`n    选择一个操作来开始：`n"
    Write-Host "      [1] " -NoNewline -ForegroundColor Green; Write-Host "启动 SillyTavern"
    Write-Host "      [2] " -NoNewline -ForegroundColor Cyan; Write-Host "数据管理"
    Write-Host "      [3] " -NoNewline -ForegroundColor Yellow; Write-Host "首次部署 (全新安装)`n"
    
    $col1_row1 = "[4] 更新 ST 主程序"
    $col2_row1 = "[5] 更新助手脚本"
    Write-Host "      $($col1_row1.PadRight(22))" -NoNewline
    Write-Host $col2_row1 -NoNewline
    if ($updateNoticeText) { Write-Host $updateNoticeText -ForegroundColor Yellow } else { Write-Host "" }

    $col1_row2 = "[6] 打开 SillyTavern 文件夹"
    $col2_row2 = "[7] 查看帮助文档"
    Write-Host "      $($col1_row2.PadRight(22))" -NoNewline; Write-Host $col2_row2; Write-Host ""
    
    Write-Host "      [0] " -NoNewline -ForegroundColor Red; Write-Host "退出助手`n"
    
    $choice = Read-Host "    请输入选项数字"

    switch ($choice) {
        "1" { Start-SillyTavern }
        "2" { Show-DataManagementMenu }
        "3" { Install-SillyTavern }
        "4" { Update-SillyTavern }
        "5" { Update-AssistantScript }
        "6" {
            if (Test-Path $ST_Dir) {
                Invoke-Item $ST_Dir
            } else {
                Write-Warning '目录不存在，请先部署！'
                Start-Sleep 1.5
            }
        }
        "7" { Open-HelpDocs }
        "0" {
            if (Test-Path $UpdateFlagFile) { Remove-Item $UpdateFlagFile -Force }
            Write-Host "感谢使用，助手已退出。"
            exit
        }
        default {
            Write-Warning "无效输入，请重新选择。"
            Start-Sleep -Seconds 1.5
        }
    }
}

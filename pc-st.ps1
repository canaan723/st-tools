# SillyTavern 助手 v1.0
# 作者: Qingjue | 小红书号: 826702880

# --- 核心配置 ---
$ScriptSelfUpdateUrl = "https://gitee.com/Qingjue/st-helper/raw/master/pc-st.ps1"
$HelpDocsUrl = "https://stdocs.723123.xyz"
$ScriptBaseDir = $PSScriptRoot
$ST_Dir = Join-Path $ScriptBaseDir "SillyTavern"
$Mirror_List = @(
    "https://github.com/SillyTavern/SillyTavern.git", 
    "https://git.ark.xx.kg/gh/SillyTavern/SillyTavern.git", 
    "https://git.723123.xyz/gh/SillyTavern/SillyTavern.git", 
    "https://xget.xi-xu.me/gh/SillyTavern/SillyTavern.git", 
    "https://gh-proxy.com/github.com/SillyTavern/SillyTavern.git", 
    "https://gh.llkk.cc/https://github.com/SillyTavern/SillyTavern.git", 
    "https://tvv.tw/https://github.com/SillyTavern/SillyTavern.git", 
    "https://proxy.pipers.cn/https://github.com/SillyTavern/SillyTavern.git"
)
$Repo_Branch = "release"
$Backup_Root_Dir = Join-Path $ST_Dir "_我的备份"
$Backup_Limit = 10
$ConfigFile = Join-Path $ScriptBaseDir ".st_assistant.conf"
$UpdateFlagFile = Join-Path ([System.IO.Path]::GetTempPath()) ".st_assistant_update_flag"

# =========================================================================
#   辅助函数库
# =========================================================================
function Write-Header($Title) { Write-Host "`n═══ $($Title) ═══" -ForegroundColor Cyan }
function Write-Success($Message) { Write-Host "✓ $Message" -ForegroundColor Green }
function Write-Warning($Message) { Write-Host "⚠ $Message" -ForegroundColor Yellow }
function Write-ErrorExit($Message) { Write-Host "`n✗ $Message`n流程已终止。" -ForegroundColor Red; Press-Any-Key }
function Press-Any-Key { Write-Host "`n请按任意键返回..." -ForegroundColor Cyan; $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") | Out-Null }
function Check-Command($Command) { return (Get-Command $Command -ErrorAction SilentlyContinue) }

function Find-FastestMirror {
    $fastestMirror = $null
    $minTime = 9999
    Write-Warning "开始测试 Git 镜像连通性与速度..."
    for ($i = 0; $i -lt $Mirror_List.Count; $i++) {
        $mirrorUrl = $Mirror_List[$i]
        $mirrorHost = ($mirrorUrl -split '/')[2]
        Write-Host ("  [{0}/{1}] 正在测试: {2} ..." -f ($i + 1), $Mirror_List.Count, $mirrorHost) -ForegroundColor Cyan -NoNewline
        $job = Start-Job -ScriptBlock { param($url) git ls-remote $url HEAD } -ArgumentList $mirrorUrl
        if (Wait-Job -Job $job -Timeout 8) {
            $elapsedSeconds = (Get-Date) - $job.PSBeginTime | Select-Object -ExpandProperty TotalSeconds
            Write-Host ("`r  [✓] 测试成功: {0} - 耗时 {1:N2}s          " -f $mirrorHost, $elapsedSeconds) -ForegroundColor Green
            if ($elapsedSeconds -lt $minTime) {
                $minTime = $elapsedSeconds
                $fastestMirror = $mirrorUrl
            }
        } else {
            Write-Host ("`r  [✗] 测试失败: {0} - 连接超时或无效      " -f $mirrorHost) -ForegroundColor Red
        }
        Remove-Job -Job $job -Force
    }
    if ($null -eq $fastestMirror) {
        Write-ErrorExit "所有镜像都无法连接，请检查网络或更新镜像列表。"
        return $null
    } else {
        $fastestHost = ($fastestMirror -split '/')[2]
        Write-Success ("已选定最快镜像: {0} (耗时 {1:N2}s)" -f $fastestHost, $minTime)
        return $fastestMirror
    }
}

# =========================================================================
#   核心功能模块
# =========================================================================
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
    Clear-Host
    Write-Header "SillyTavern 首次部署向导"

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
        $fastestRepoUrl = Find-FastestMirror
        if ($null -eq $fastestRepoUrl) { return }
        Write-Warning "正在从最快镜像下载主程序 ($Repo_Branch 分支)..."
        git clone --depth 1 -b $Repo_Branch $fastestRepoUrl $ST_Dir
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorExit "主程序下载失败！"
            return
        }
        Write-Success "主程序下载完成。"
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

    Write-Host "`n"
    Write-Success "部署完成！"
    Write-Warning "即将进行首次启动，这个过程会安装大量依赖，耗时可能非常长 (5-20分钟)，请耐心等待！"
    Write-Host "3秒后将自动开始..."
    Start-Sleep -Seconds 3
    Start-SillyTavern
}

function Update-SillyTavern {
    Clear-Host
    Write-Header "更新 SillyTavern 主程序"
    if (-not (Test-Path (Join-Path $ST_Dir ".git"))) {
        Write-Warning "未找到Git仓库，请先完整部署。"
        Press-Any-Key
        return
    }
    Set-Location $ST_Dir
    $fastestRepoUrl = Find-FastestMirror
    if ($null -eq $fastestRepoUrl) { return }
    Write-Warning "正在同步远程仓库地址..."
    git remote set-url origin $fastestRepoUrl
    Write-Warning "正在拉取最新代码..."
    git pull origin $Repo_Branch
    if ($LASTEXITCODE -eq 0) {
        Write-Success "代码更新成功。"
        Write-Warning "正在同步依赖包..."
        npm install --no-audit --no-fund --omit=dev
        Write-Success "依赖包更新完成。"
    } else {
        Write-Warning "代码更新失败，可能存在冲突。"
    }
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
    $AllPaths = [ordered]@{ "data"="用户数据 (聊天/角色/设置)"; "public/scripts/extensions/third-party"="前端扩展"; "plugins"="后端扩展"; "config.yaml"="服务器配置 (网络/安全)" }
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
    
    if (-not (Test-Path $Backup_Root_Dir)) {
        New-Item -Path $Backup_Root_Dir -ItemType Directory | Out-Null
    }
    
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
        $excludeDirs = @(".git", "_cache", "backups")
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
    if (-not (Test-Path $ST_Dir)) {
        Write-Warning "SillyTavern 尚未安装，请先部署。"
        Press-Any-Key
        return
    }
    if (-not (Test-Path $Backup_Root_Dir)) {
        New-Item -Path $Backup_Root_Dir -ItemType Directory | Out-Null
    }
    
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
    Write-Host "  3. 在根目录中，右键点击压缩包，选择 `全部解压缩...`。"
    Write-Host "  4. 如果提示文件已存在，请选择 `替换目标中的文件`。"
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
            default {
                Write-Warning "无效输入。"
                Start-Sleep -Seconds 1
            }
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
        $newScriptContent = (Invoke-WebRequest -Uri $ScriptSelfUpdateUrl -UseBasicParsing -ErrorAction Stop).Content
        $currentScriptContent = Get-Content -Path $MyInvocation.MyCommand.Path -Raw
        if ($newScriptContent -eq $currentScriptContent) {
            Write-Success "当前已是最新版本。"
            Press-Any-Key
            return
        }
        $tempFile = $MyInvocation.MyCommand.Path + ".new"
        Set-Content -Path $tempFile -Value $newScriptContent -Encoding UTF8BOM
        $updaterScript = @"
@echo off
chcp 65001 > nul
echo 正在应用更新...
timeout /t 2 /nobreak > nul
move /y "$($tempFile)" "$($MyInvocation.MyCommand.Path)"
echo 更新完成！正在重新启动助手...
timeout /t 1 /nobreak > nul
start "" "%~dp0双击我启动助手.bat"
exit
"@
        $updaterPath = Join-Path $ScriptBaseDir "updater.bat"
        Set-Content -Path $updaterPath -Value $updaterScript
        Start-Process -FilePath $updaterPath -WindowStyle Hidden
        Write-Success "更新程序已启动，本窗口即将关闭。"
        Start-Sleep -Seconds 3
        exit
    } catch {
        Write-ErrorExit "更新失败！无法从 $($ScriptSelfUpdateUrl) 下载脚本。"
    }
}

function Check-ForUpdatesOnStart {
    Start-Job -ScriptBlock {
        param($url, $flag, $path)
        try {
            $new = (Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10).Content
            $old = Get-Content -Path $path -Raw
            if ($new -ne $old) {
                [System.IO.File]::Create($flag).Close()
            } else {
                if (Test-Path $flag) { Remove-Item $flag -Force }
            }
        } catch {}
    } -ArgumentList $ScriptSelfUpdateUrl, $UpdateFlagFile, $MyInvocation.MyCommand.Path | Out-Null
}

# --- 主菜单与脚本入口 ---
Check-ForUpdatesOnStart
while ($true) {
    Clear-Host
    Write-Host @"
    ╔═════════════════════════════════╗
    ║      SillyTavern 助手 v1.0      ║
    ║   by Qingjue | XHS:826702880    ║
    ╚═════════════════════════════════╝
"@ -ForegroundColor Cyan
    
    $updateNoticeText = if (Test-Path $UpdateFlagFile) { " [!] 有更新" } else { "" }
    
    Write-Host "`n    选择一个操作来开始：`n"
    Write-Host "      " -NoNewline; Write-Host "[1] " -NoNewline -ForegroundColor Green; Write-Host "启动 SillyTavern"
    Write-Host "      " -NoNewline; Write-Host "[2] " -NoNewline -ForegroundColor Cyan; Write-Host "数据管理"
    Write-Host "      " -NoNewline; Write-Host "[3] " -NoNewline -ForegroundColor Yellow; Write-Host "首次部署 (全新安装)`n"
    
    $col1_row1 = "[4] 更新 ST 主程序"
    $col2_row1 = "[5] 更新助手脚本"
    Write-Host "      $($col1_row1.PadRight(22))" -NoNewline; Write-Host $col2_row1 -NoNewline
    if ($updateNoticeText) { Write-Host $updateNoticeText -ForegroundColor Yellow } else { Write-Host "" }
    
    $col1_row2 = "[6] 打开 SillyTavern 文件夹"
    $col2_row2 = "[7] 查看帮助文档"
    Write-Host "      $($col1_row2.PadRight(22))" -NoNewline; Write-Host $col2_row2; Write-Host ""
    
    Write-Host "      " -NoNewline; Write-Host "[0] " -NoNewline -ForegroundColor Red; Write-Host "退出助手`n"
    
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
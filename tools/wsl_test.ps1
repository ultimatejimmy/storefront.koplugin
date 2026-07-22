param (
    [switch]$Watch
)

# Ensure WSL passes software rendering and X11 driver flags to fix graphics crashes & black screen issues in Copy Mode
$env:LIBGL_ALWAYS_SOFTWARE = "1"
$env:SDL_VIDEO_DRIVER = "x11"
$env:SDL_VIDEODRIVER = "x11"

$EnvList = @("LIBGL_ALWAYS_SOFTWARE/u", "SDL_VIDEO_DRIVER/u", "SDL_VIDEODRIVER/u")
foreach ($item in $EnvList) {
    $varName = $item.Split('/')[0]
    if ($env:WSLENV) {
        if ($env:WSLENV -notlike "*$varName*") {
            $env:WSLENV = "$env:WSLENV:$item"
        }
    } else {
        $env:WSLENV = $item
    }
}

$WslHome = (wsl sh -c "echo -n ~").Trim()
$PluginDir = "storefront.koplugin"
$WSLDest = "$WslHome/.config/koreader/plugins/storefront.koplugin"

# Probe for the squashfs-root location in WSL
$SquashPath = ""
$UserNameLower = $env:USERNAME.ToLower()
$ProbedPaths = @(
    "/home/jimmy/squashfs-root",
    "/home/$env:USERNAME/squashfs-root",
    "/home/$UserNameLower/squashfs-root",
    "/mnt/c/Users/$env:USERNAME/squashfs-root",
    "/mnt/c/Users/$UserNameLower/squashfs-root"
)
foreach ($path in $ProbedPaths) {
    $null = wsl test -d $path
    if ($LASTEXITCODE -eq 0) {
        $SquashPath = $path
        break
    }
}
if (-not $SquashPath) {
    $SquashPath = "/home/jimmy/squashfs-root"
}
Write-Host "Using KOReader installation path: $SquashPath" -ForegroundColor Yellow

function Run-Workflow {
    Write-Host "`n--- Starting Verification Workflow ---" -ForegroundColor Cyan
    
    # 1. Sync
    Write-Host "Syncing to WSL..." -NoNewline
    wsl mkdir -p (Split-Path $WSLDest -Parent)
    
    wsl rsync -rv --delete --exclude=".git" --exclude="*.log" --exclude="storefront_config.lua" --exclude="storefront_configuration.lua" "./$PluginDir/" "$WSLDest/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }
    wsl rsync -rv --delete "./tests/" "$WSLDest/tests/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }
    Write-Host " SUCCESS" -ForegroundColor Green

    # 2. Unit Tests
    Write-Host "Running unit tests (Bundled LuaJIT in WSL)..."
    $TestCmd = "cd {0}/usr/lib/koreader && env SQUASHFS_ROOT={0} LUA_PATH='{1}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {1}/tests/storefront_plugin_paths_test.lua" -f $SquashPath, $WSLDest
    wsl bash -c `"$TestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Plugin Path Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running README Markdown-to-HTML unit tests..."
    $ReadmeTestCmd = "cd {0}/usr/lib/koreader && env SQUASHFS_ROOT={0} LUA_PATH='{1}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {1}/tests/storefront_readme_test.lua" -f $SquashPath, $WSLDest
    wsl bash -c `"$ReadmeTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "README Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running Release Notes unit tests..."
    $ReleaseNotesTestCmd = "cd {0}/usr/lib/koreader && env SQUASHFS_ROOT={0} LUA_PATH='{1}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {1}/tests/storefront_release_notes_test.lua" -f $SquashPath, $WSLDest
    wsl bash -c `"$ReleaseNotesTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Release Notes Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running UI loading crash tests..."
    $UiTestCmd = "cd {0}/usr/lib/koreader && env SQUASHFS_ROOT={0} LUA_PATH='{1}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {1}/tests/storefront_ui_test.lua" -f $SquashPath, $WSLDest
    wsl bash -c `"$UiTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "UI Crash Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Tests PASSED" -ForegroundColor Green

    # 3. Restart KOReader
    Write-Host "Restarting KOReader..." -ForegroundColor Cyan
    wsl pkill -9 -f koreader 2>$null
    wsl pkill -9 -f AppRun 2>$null
    Start-Sleep -Seconds 1

    # Define start command
    $DefaultCmd = "C:\Windows\System32\wsl.exe --exec dbus-launch --exit-with-session bash -c `"cd $SquashPath && ./launch_with_log.sh`""
    $StartCmd = if ($env:KOREADER_START_CMD) { $env:KOREADER_START_CMD } else { $DefaultCmd }
    
    Write-Host "Starting KOReader: $StartCmd"
    # Use cmd /c start to ensure it's fully detached and quotes are preserved
    $cmdLine = "/c start `"`" $StartCmd"
    Start-Process cmd.exe -ArgumentList $cmdLine -WindowStyle Hidden

    Write-Host "`nReady!" -ForegroundColor Green
    return $true
}

if ($Watch) {
    Write-Host "Watching for changes..." -ForegroundColor Magenta
    $watcher = New-Object System.IO.FileSystemWatcher
    $watcher.Path = (Get-Item ".").FullName
    $watcher.Filter = "*.lua"
    $watcher.IncludeSubdirectories = $true
    $watcher.EnableRaisingEvents = $true

    $action = {
        Run-Workflow
    }

    Register-ObjectEvent $watcher "Changed" -Action $action
    Register-ObjectEvent $watcher "Created" -Action $action
    Register-ObjectEvent $watcher "Deleted" -Action $action
    Register-ObjectEvent $watcher "Renamed" -Action $action

    while ($true) { Start-Sleep -Seconds 1 }
} else {
    Run-Workflow
}

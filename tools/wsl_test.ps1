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
    }
    else {
        $env:WSLENV = $item
    }
}

$WslHome = (wsl sh -c "echo -n ~").Trim()
$PluginDir = "storefront.koplugin"
$WSLDest = "$WslHome/.config/koreader/plugins/storefront.koplugin"

# The .deb package installs system-wide, so the app directory is static
$AppDir = "/usr/lib/koreader"
Write-Host "Using KOReader installation path: $AppDir" -ForegroundColor Yellow

function Run-Workflow {
    Write-Host "`n--- Starting Verification Workflow ---" -ForegroundColor Cyan
    
    # 1. Sync
    Write-Host "Syncing to WSL..." -NoNewline
    wsl mkdir -p (Split-Path $WSLDest -Parent)
    
    wsl rsync -rv --delete --exclude=".git" --exclude="*.log" --exclude="storefront_config.lua" --exclude="storefront_configuration.lua" "./storefront.koplugin/" "$WSLDest/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }

    # The config is intentionally excluded above so a local WSL token is not
    # overwritten. Bootstrap it only when the destination does not have one.
    Write-Host "Ensuring WSL config module..." -NoNewline
    wsl rsync -av --ignore-existing "./storefront.koplugin/storefront_config.lua" "$WSLDest/storefront_config.lua"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED (config sync)" -ForegroundColor Red
        return $false
    }
    Write-Host " SUCCESS" -ForegroundColor Green

    wsl rsync -rv --delete "./tests/" "$WSLDest/tests/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        return $false
    }
    # Sync assets folder (fonts, icons, etc.) separately since it lives outside PluginDir
    wsl rsync -av --delete "./storefront.koplugin/assets/" "$WSLDest/assets/"
    if ($LASTEXITCODE -ne 0) {
        Write-Host " FAILED (assets sync)" -ForegroundColor Red
        return $false
    }
    Write-Host " SUCCESS" -ForegroundColor Green

    # 2. Unit Tests
    Write-Host "Running unit tests (Bundled LuaJIT in WSL)..."
    $TestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {0}/tests/storefront_plugin_paths_test.lua" -f $WSLDest
    wsl bash -c `"$TestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Plugin Path Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running README Markdown-to-HTML unit tests..."
    $ReadmeTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {0}/tests/storefront_readme_test.lua" -f $WSLDest
    wsl bash -c `"$ReadmeTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "README Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running README Cache Refresh & Change Detection unit tests..."
    $ReadmeRefreshTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {0}/tests/storefront_readme_cache_refresh_test.lua" -f $WSLDest
    wsl bash -c `"$ReadmeRefreshTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "README Cache Refresh Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running Release Notes unit tests..."
    $ReleaseNotesTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {0}/tests/storefront_release_notes_test.lua" -f $WSLDest
    wsl bash -c `"$ReleaseNotesTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Release Notes Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running Plugin Launch & Module Integrity tests..."
    $LaunchTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {0}/tests/storefront_launch_test.lua" -f $WSLDest
    wsl bash -c `"$LaunchTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Plugin Launch Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running UI loading crash tests..."
    $UiTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {0}/tests/storefront_ui_test.lua" -f $WSLDest
    wsl bash -c `"$UiTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "UI Crash Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running Font System unit tests..."
    $FontTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {0}/tests/storefront_font_test.lua" -f $WSLDest
    wsl bash -c `"$FontTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Font System Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Running Ignore Updates unit tests..."
    $IgnoreTestCmd = "cd $AppDir && LUA_PATH='{0}/?.lua;./?.lua;./?/init.lua;frontend/?.lua;frontend/?/init.lua;libs/?.lua;common/?.lua;common/?/init.lua;;' ./luajit {0}/tests/storefront_ignore_test.lua" -f $WSLDest
    wsl bash -c `"$IgnoreTestCmd`"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Ignore Updates Tests FAILED." -ForegroundColor Red
        return $false
    }
    Write-Host "Tests PASSED" -ForegroundColor Green

    # 3. Restart KOReader
    Write-Host "Restarting KOReader..." -ForegroundColor Cyan
    wsl pkill -9 -f koreader 2>$null
    Start-Sleep -Seconds 1

    # Define start command
    $DefaultCmd = "C:\Windows\System32\wsl.exe --exec dbus-launch --exit-with-session bash -c `"/usr/bin/koreader`""
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
}
else {
    Run-Workflow
}

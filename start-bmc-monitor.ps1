# Starts the Blackmagic Camera monitor: Android emulator + in-emulator mDNS relay + LAN relay.
$ErrorActionPreference = "Continue"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Sdk = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$Adb = Join-Path $Sdk "platform-tools\adb.exe"
$Emu = Join-Path $Sdk "emulator\emulator.exe"
$Avd = "BMC_Monitor"
$Pkg = "com.blackmagicdesign.android.blackmagiccam"
$Host.UI.RawUI.WindowTitle = "Blackmagic Camera Monitor (relay)"

function Emu-Running { (& $Adb devices 2>$null) -match "^emulator-\d+\s+device" }

if (-not (Emu-Running)) {
    Write-Host "Starting emulator $Avd ..."
    # Cold boot every time (-no-snapshot): quick-boot snapshots with GPU host mode
    # can hang on load with a black screen after the window is closed.
    Start-Process -FilePath $Emu -ArgumentList @("-avd", $Avd, "-gpu", "host", "-no-boot-anim", "-no-snapshot") -WindowStyle Normal
    $deadline = (Get-Date).AddMinutes(4)
    do {
        Start-Sleep -Seconds 3
        $booted = (& $Adb shell getprop sys.boot_completed 2>$null) -join "" -replace "\s", ""
    } while ($booted -ne "1" -and (Get-Date) -lt $deadline)
    if ($booted -ne "1") { Write-Host "Emulator did not finish booting in 4 minutes." -ForegroundColor Red }
    else { Write-Host "Emulator booted." }
} else {
    Write-Host "Emulator already running."
}

# Make sure the app is installed (first run after a wipe).
$installed = (& $Adb shell pm list packages $Pkg 2>$null) -join ""
if ($installed -notmatch $Pkg) {
    Write-Host "Installing Blackmagic Camera into the emulator ..."
    $apks = Get-ChildItem (Join-Path $Here "apk") -Filter *.apk | ForEach-Object { $_.FullName }
    & $Adb install-multiple -r $apks
    foreach ($p in "CAMERA","RECORD_AUDIO","ACCESS_FINE_LOCATION","ACCESS_COARSE_LOCATION","READ_MEDIA_VIDEO","BLUETOOTH_SCAN","BLUETOOTH_CONNECT") {
        & $Adb shell pm grant $Pkg "android.permission.$p" 2>$null
    }
}

# In-emulator relay.
& $Adb forward tcp:5354 tcp:5354 | Out-Null
$running = (& $Adb shell "ps -A | grep bmcrelay-guest" 2>$null) -join ""
if ($running -notmatch "bmcrelay-guest") {
    & $Adb push (Join-Path $Here "bmcrelay-guest") /data/local/tmp/bmcrelay-guest | Out-Null
    & $Adb shell chmod 755 /data/local/tmp/bmcrelay-guest
    & $Adb shell "nohup /data/local/tmp/bmcrelay-guest > /data/local/tmp/relay.log 2>&1 &"
    Write-Host "Started relay inside emulator."
}

# Bring the app to the front.
& $Adb shell monkey -p $Pkg -c android.intent.category.LAUNCHER 1 2>$null | Out-Null

# LAN relay (this window). Ctrl+C to stop. Extra args (e.g. --both) are passed through.
Write-Host ""
$py = "python"
if (-not (Get-Command python -ErrorAction SilentlyContinue)) {
    $cand = Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"
    if (Test-Path $cand) { $py = $cand } else { $py = "py" }
}
& $py (Join-Path $Here "bmcrelay_host.py") @args

# install.ps1 - one-shot setup of the Blackmagic Camera monitor on a Windows PC.
#
# Run from a clone of the repo:
#     powershell -ExecutionPolicy Bypass -File install.ps1
# or without git, straight from GitHub:
#     irm https://raw.githubusercontent.com/Husienvora/bmc-monitor/main/install.ps1 | iex
#
# Installs (per-user, no admin needed): JDK 17, Python 3, Android command-line tools,
# emulator + Android 16 x86_64 image, the BMC_Monitor virtual device, the Blackmagic
# Camera APK (downloaded at install time, not redistributed), and a Desktop shortcut.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$RepoZip = "https://github.com/Husienvora/bmc-monitor/archive/refs/main.zip"
$CmdlineToolsUrl = "https://dl.google.com/android/repository/commandlinetools-win-13114758_latest.zip"
$SystemImage = "system-images;android-36;google_apis;x86_64"
$AvdName = "BMC_Monitor"
$ApkPackage = "com.blackmagicdesign.android.blackmagiccam"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

# --- 0. Bootstrap: if piped via iex, fetch the repo first ---------------------------------
if (-not $PSScriptRoot) {
    $Target = Join-Path $env:USERPROFILE "bmc-monitor"
    Step "Downloading repo to $Target"
    $tmp = Join-Path $env:TEMP "bmc-monitor.zip"
    Invoke-WebRequest -Uri $RepoZip -OutFile $tmp
    $ext = Join-Path $env:TEMP "bmc-monitor-extract"
    if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }
    Expand-Archive $tmp $ext
    $inner = Get-ChildItem $ext | Select-Object -First 1
    if (Test-Path $Target) { Copy-Item (Join-Path $inner.FullName "*") $Target -Recurse -Force }
    else { Move-Item $inner.FullName $Target }
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Target "install.ps1")
    return
}
$Here = $PSScriptRoot

# --- 1. Hypervisor check ------------------------------------------------------------------
Step "Checking virtualization"
$hv = (Get-CimInstance Win32_ComputerSystem).HypervisorPresent
$cpuVt = (Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled
if (-not $hv -and -not $cpuVt) {
    Write-Host "Hardware virtualization looks disabled. The emulator needs it." -ForegroundColor Yellow
    Write-Host "Enable VT-x/AMD-V in BIOS, or run as admin:" -ForegroundColor Yellow
    Write-Host "  Enable-WindowsOptionalFeature -Online -FeatureName HypervisorPlatform" -ForegroundColor Yellow
    Write-Host "Continuing anyway; the emulator may fail to start." -ForegroundColor Yellow
}

# --- 2. JDK + Python via winget -----------------------------------------------------------
Step "Installing JDK 17 and Python (winget)"
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { throw "winget not found. Install 'App Installer' from the Microsoft Store, then re-run." }
$javaHome = Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium" -Directory -Filter "jdk-17*" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $javaHome) {
    winget install --id EclipseAdoptium.Temurin.17.JDK -e --accept-package-agreements --accept-source-agreements --silent | Out-Null
    $javaHome = Get-ChildItem "$env:ProgramFiles\Eclipse Adoptium" -Directory -Filter "jdk-17*" | Select-Object -First 1 -ExpandProperty FullName
}
if (-not $javaHome) { throw "JDK 17 not found after install." }
$env:JAVA_HOME = $javaHome
$env:PATH = "$javaHome\bin;$env:PATH"

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py -or ((& python --version 2>&1) -notmatch "Python 3")) {
    winget install --id Python.Python.3.12 -e --accept-package-agreements --accept-source-agreements --silent | Out-Null
    $env:PATH = "$env:LOCALAPPDATA\Programs\Python\Python312;$env:LOCALAPPDATA\Programs\Python\Python312\Scripts;$env:PATH"
}
& python -m pip install --quiet --upgrade zeroconf

# --- 3. Android SDK -----------------------------------------------------------------------
$Sdk = Join-Path $env:LOCALAPPDATA "Android\Sdk"
$SdkMgr = Join-Path $Sdk "cmdline-tools\latest\bin\sdkmanager.bat"
if (-not (Test-Path $SdkMgr)) {
    Step "Installing Android command-line tools"
    New-Item -ItemType Directory -Force (Join-Path $Sdk "cmdline-tools") | Out-Null
    $zip = Join-Path $env:TEMP "clt.zip"
    Invoke-WebRequest -Uri $CmdlineToolsUrl -OutFile $zip
    $ext = Join-Path $env:TEMP "clt-extract"
    if (Test-Path $ext) { Remove-Item $ext -Recurse -Force }
    Expand-Archive $zip $ext
    Move-Item (Join-Path $ext "cmdline-tools") (Join-Path $Sdk "cmdline-tools\latest")
}
Step "Installing emulator, platform-tools and $SystemImage (about 1.5 GB)"
$yes = "y`n" * 20
$yes | & $SdkMgr --licenses | Out-Null
& $SdkMgr --install "emulator" "platform-tools" $SystemImage | Out-Null

# --- 4. Virtual device --------------------------------------------------------------------
$AvdDir = Join-Path $env:USERPROFILE ".android\avd\$AvdName.avd"
if (-not (Test-Path (Join-Path $AvdDir "config.ini"))) {
    Step "Creating virtual device $AvdName"
    "no" | & (Join-Path $Sdk "cmdline-tools\latest\bin\avdmanager.bat") create avd -n $AvdName -k $SystemImage -d "pixel_tablet" -f | Out-Null
}
$cfg = Join-Path $AvdDir "config.ini"
$lines = Get-Content $cfg | Where-Object { $_ -notmatch '^(hw\.ramSize|hw\.gpu\.enabled|hw\.gpu\.mode|hw\.initialOrientation|hw\.keyboard)\s*=' }
$lines += "hw.ramSize = 4096", "hw.gpu.enabled = yes", "hw.gpu.mode = host", "hw.initialOrientation = landscape", "hw.keyboard = yes"
Set-Content $cfg $lines

# --- 5. Blackmagic Camera APK -------------------------------------------------------------
$ApkDir = Join-Path $Here "apk"
New-Item -ItemType Directory -Force $ApkDir | Out-Null
if (-not (Get-ChildItem $ApkDir -Filter "config.x86_64.apk" -ErrorAction SilentlyContinue)) {
    Step "Downloading Blackmagic Camera for Android (universal bundle)"
    $xapk = Join-Path $env:TEMP "bmc.xapk"
    try {
        Invoke-WebRequest -Uri "https://d.apkpure.com/b/XAPK/$ApkPackage?version=latest" -OutFile $xapk `
            -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36" `
            -Headers @{ Referer = "https://apkpure.com/" }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($xapk)
        foreach ($e in $z.Entries) {
            if ($e.Name -in "$ApkPackage.apk", "config.x86_64.apk", "config.xhdpi.apk", "config.xxhdpi.apk", "config.xxxhdpi.apk") {
                [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $ApkDir $e.Name), $true)
            }
        }
        $z.Dispose()
    } catch {
        Write-Host "Automatic APK download failed: $_" -ForegroundColor Yellow
        Write-Host "Download the 'universal' APK bundle (3.x, Android 13+) from apkmirror.com," -ForegroundColor Yellow
        Write-Host "extract base.apk + split_config.x86_64.apk + a *dpi split into: $ApkDir" -ForegroundColor Yellow
    }
}

# --- 6. Desktop shortcut ------------------------------------------------------------------
Step "Creating Desktop shortcut"
$desktop = [Environment]::GetFolderPath("Desktop")
$ws = New-Object -ComObject WScript.Shell
$sc = $ws.CreateShortcut((Join-Path $desktop "Blackmagic Monitor.lnk"))
$sc.TargetPath = Join-Path $Here "Blackmagic Monitor.cmd"
$sc.WorkingDirectory = $Here
$sc.IconLocation = (Join-Path $Sdk "emulator\emulator.exe") + ",0"
$sc.Description = "Android emulator as Blackmagic Camera remote monitor/controller"
$sc.Save()

Write-Host ""
Write-Host "Install complete." -ForegroundColor Green
Write-Host "1. Double-click 'Blackmagic Monitor' on the Desktop (first boot takes 1-2 min)."
Write-Host "2. In the emulator app: Settings > Remote Camera Control > On, Use This Phone as: Controller."
Write-Host "3. On the iPhone: Settings > Remote Camera Control > On, Use This iPhone as: Remote Camera."

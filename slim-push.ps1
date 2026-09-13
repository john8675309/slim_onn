#Requires -Version 5.1
# PC-side installer for Windows PowerShell 5.1 and PowerShell 7.
# Downloads the payload, then runs slim-device.sh on the selected Android TV.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
# Windows PowerShell 5.1 can otherwise default to older TLS versions.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$Payload = Join-Path $PSScriptRoot 'slim-payload'
$Remote = '/data/local/tmp/slim'
$script:Target = ''
$script:AdbStatus = 0

function Invoke-Adb {
    param([string[]]$Arguments)
    $deviceArgs = @()
    if ($script:Target) { $deviceArgs = @('-s', $script:Target) }
    # Supply a closed input stream so adb cannot consume later prompt answers.
    '' | & $script:AdbPath @deviceArgs @Arguments
    $script:AdbStatus = $LASTEXITCODE
}

function Read-YesNo {
    param([string]$Prompt)
    while ($true) {
        $answer = Read-Host "$Prompt (y/n)"
        if ($null -eq $answer) { return $false }
        if ($answer -match '^[Yy]') { return $true }
        if ($answer -match '^[Nn]') { return $false }
        Write-Host 'Please answer y or n.'
    }
}

function Get-PayloadFile {
    param([string]$Url, [string]$Name, [string]$Sha256 = '')
    $destination = Join-Path $Payload $Name
    Write-Host "  downloading $Name..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $destination
        if ($Sha256 -and (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $Sha256) {
            throw 'Checksum mismatch'
        }
        return $true
    } catch {
        Write-Host "  download failed: $Name ($($_.Exception.Message))" -ForegroundColor Red
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        return $false
    }
}

try {
    $adbCommand = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $adbCommand) { throw 'ADB is not installed or is not on PATH. Install Android SDK Platform-Tools and add its folder to PATH.' }
    $script:AdbPath = $adbCommand.Source
    $deviceScript = Join-Path $PSScriptRoot 'slim-device.sh'
    if (-not (Test-Path -LiteralPath $deviceScript -PathType Leaf)) { throw 'Keep slim-device.sh beside slim-push.ps1.' }

    if ($env:ANDROID_SERIAL) { $script:Target = $env:ANDROID_SERIAL }
    elseif ($env:SLIM_SERIAL) { $script:Target = $env:SLIM_SERIAL }
    if (-not $script:Target) {
        $devices = @(Invoke-Adb -Arguments @('devices'))
        if ($script:AdbStatus -ne 0) { throw 'Could not list ADB devices.' }
        $online = @($devices | ForEach-Object {
            if ($_ -match '^(\S+)\s+device\s*$') { $Matches[1] }
        })
        if ($online.Count -eq 0) {
            Write-Host 'No device attached.'
            $address = Read-Host 'Enter the IP address of your Android TV (e.g., 192.168.1.100)'
            if ([string]::IsNullOrWhiteSpace($address)) { throw 'No IP address supplied.' }
            $serial = "$($address.Trim()):5555"
            Invoke-Adb -Arguments @('connect', $serial)
            $null = Read-Host 'Approve the ADB connection on your TV, then press Enter'
            Invoke-Adb -Arguments @('connect', $serial)
            $script:Target = $serial
        } elseif ($online.Count -eq 1) {
            $script:Target = $online[0]
        } else {
            Write-Host 'More than one device is attached:'
            for ($i = 0; $i -lt $online.Count; $i++) { Write-Host "  $($i + 1)) $($online[$i])" }
            $selection = Read-Host 'Which one? (number)'
            $pick = 0
            if ($selection -notmatch '^[0-9]+$' -or -not [int]::TryParse($selection, [ref]$pick) -or $pick -lt 1 -or $pick -gt $online.Count) {
                throw 'No valid selection. Set $env:SLIM_SERIAL to choose a device explicitly.'
            }
            $script:Target = $online[$pick - 1]
        }
    }
    Invoke-Adb -Arguments @('get-state') | Out-Null
    if ($script:AdbStatus -ne 0) { throw "Could not reach device: $script:Target" }
    $model = (Invoke-Adb -Arguments @('shell', 'getprop ro.product.model') | Out-String).Trim()
    Write-Host "Target: $script:Target ($model)" -ForegroundColor Green

    if (Test-Path -LiteralPath $Payload) { Remove-Item -LiteralPath $Payload -Recurse -Force }
    $null = New-Item -ItemType Directory -Path $Payload
    Write-Host "`nBuilding the payload..."
    $null = Get-PayloadFile 'https://github.com/john8675309/flauncher/releases/download/v0.1.1/flauncher-0.1.1.apk' 'flauncher.apk'
    if (Read-YesNo 'Do you want to install Emby?') {
        $abiList = Invoke-Adb -Arguments @('shell', 'getprop ro.product.cpu.abilist')
        $embyAbi = 'armeabi-v7a'
        if (($abiList -join '') -match 'arm64-v8a') { $embyAbi = 'arm64-v8a' }
        Write-Host "  device ABI: $embyAbi"
        $null = Get-PayloadFile "https://github.com/MediaBrowser/Emby.Releases/raw/master/android/emby-android-google-$embyAbi-release.apk" 'Emby.apk'
    }
    Write-Host "`nChoose an IPTV app to install:`n1) IPTV Smarters`n2) Tivimate`n3) JTV`n4) None"
    $wantButtonMapper = $false
    switch (Read-Host 'Enter your choice (1-4)') {
        '1' { $wantButtonMapper = Get-PayloadFile 'https://www.johnhass.com/s.apk' 'sm.apk' }
        '2' { $wantButtonMapper = Get-PayloadFile 'https://files.tivimate.com/tivimate.apk' 'tivimate.apk' }
        '3' {
            Write-Host '  checking for the latest JTV...'
            try {
                $manifest = Invoke-RestMethod -Uri 'https://johnhass.com/jtv.json'
                if (-not $manifest.apkUrl) { throw 'No apkUrl in the JTV manifest' }
                $sdkText = (Invoke-Adb -Arguments @('shell', 'getprop ro.build.version.sdk') | Out-String).Trim()
                $sdk = 0
                if ($manifest.minSdk -and [int]::TryParse($sdkText, [ref]$sdk) -and $sdk -lt [int]$manifest.minSdk) {
                    Write-Host "  JTV $($manifest.versionName) needs SDK $($manifest.minSdk), device is SDK $sdk. Skipping." -ForegroundColor Red
                } else {
                    Write-Host "  JTV $($manifest.versionName)"
                    $wantButtonMapper = Get-PayloadFile $manifest.apkUrl 'jtv.apk' $manifest.sha256
                }
            } catch { Write-Host "  could not prepare JTV, skipping: $($_.Exception.Message)" -ForegroundColor Red }
        }
        '4' { Write-Host '  skipping IPTV app' }
        default { Write-Host '  invalid choice, skipping IPTV app' }
    }
    if ($wantButtonMapper) {
        $null = Get-PayloadFile 'https://github.com/john8675309/tvbuttonmapper/releases/download/v0.1.0/tvbuttonmapper-v0.1.0-debug.apk' 'tvbuttonmapper.apk'
    }

    $manifestUrl = 'https://raw.githubusercontent.com/john8675309/slim_onn/main/slim.json'
    if ($env:SLIM_MANIFEST_URL) { $manifestUrl = $env:SLIM_MANIFEST_URL }
    $manifestPath = Join-Path $Payload 'slim.json'
    Write-Host "`nAdding the debloat manifest..."
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $manifestUrl -OutFile $manifestPath
        if ((Get-Item -LiteralPath $manifestPath).Length -eq 0) { throw 'Empty manifest' }
        Write-Host "  from $manifestUrl"
    } catch {
        $fallback = Join-Path $PSScriptRoot 'slim.json'
        if (Test-Path -LiteralPath $fallback -PathType Leaf) {
            Copy-Item -LiteralPath $fallback -Destination $manifestPath -Force
            Write-Host "  published copy unreachable, using $fallback" -ForegroundColor Yellow
        } else {
            Remove-Item -LiteralPath $manifestPath -Force -ErrorAction SilentlyContinue
            Write-Host '  no slim.json available -- the device will skip the debloat' -ForegroundColor Red
        }
    }

    $apks = @(Get-ChildItem -LiteralPath $Payload -Filter '*.apk' -File)
    $checksums = @($apks | ForEach-Object {
        '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name
    })
    # Android needs LF and no BOM, including when this runs in Windows PowerShell.
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $Payload 'sha256sums'), ($checksums -join "`n") + "`n", $utf8)
    $stagedScript = Join-Path $Payload 'slim-device.sh'
    [IO.File]::WriteAllText($stagedScript, [IO.File]::ReadAllText($deviceScript).Replace("`r`n", "`n"), $utf8)
    Write-Host "`nPayload:"
    $apks | ForEach-Object { Write-Host ('  {0} ({1:N1} MB)' -f $_.Name, ($_.Length / 1MB)) }

    Write-Host "`nPushing to $Remote..."
    Invoke-Adb -Arguments @('shell', "rm -rf $Remote; mkdir -p $Remote")
    if ($script:AdbStatus -ne 0) { throw 'Could not prepare the device payload directory.' }
    # Push files individually to avoid platform-specific directory/. semantics.
    foreach ($file in Get-ChildItem -LiteralPath $Payload -File) {
        Invoke-Adb -Arguments @('push', $file.FullName, "$Remote/$($file.Name)") | Out-Null
        if ($script:AdbStatus -ne 0) { throw "Push failed: $($file.Name)" }
    }
    Write-Host 'Payload pushed.' -ForegroundColor Green
    $openAccounts = 0
    if (Read-YesNo 'Open the account-removal screen on the TV at the end?') { $openAccounts = 1 }
    Write-Host "`n---- running on the device ----"
    Invoke-Adb -Arguments @('shell', "SLIM_OPEN_ACCOUNTS=$openAccounts sh $Remote/slim-device.sh")
    $status = $script:AdbStatus
    Write-Host "---- device finished ----`n"
    if ($openAccounts -eq 1) { Write-Host 'If an account was listed, remove it on the TV with the remote.' }
    Write-Host "To re-run later without downloading again:`n  adb -s $script:Target shell sh $Remote/slim-device.sh"
    Write-Host "Run 'adb -s $script:Target reboot' to apply everything."
    exit $status
} catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

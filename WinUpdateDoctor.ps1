<#
.SYNOPSIS
    Windows Update Doctor - Diagnosa dan Perbaikan Masalah Windows Update & BITS Stuck.

.DESCRIPTION
    Script komprehensif untuk mendeteksi penyebab Windows Update stuck (seperti status "Pending Download"),
    memeriksa antrean BITS yang macet/error, memeriksa Delivery Optimization (DoSvc),
    serta melakukan perbaikan (remediasi) terstruktur dengan membersihkan cache yang rusak
    dan memulai ulang layanan terkait.

.PARAMETER Action
    Pilihan aksi:
    - Diagnose : Hanya memindai dan melaporkan kesehatan komponen Windows Update.
    - Repair   : Menjalankan prosedur pembersihan, reset antrean BITS, dan cache update.
    - All      : Menjalankan diagnosa, melakukan perbaikan, lalu verifikasi ulang.

.PARAMETER Force
    Jika disertakan, script akan melakukan perbaikan tanpa meminta konfirmasi interaktif.

.PARAMETER KeepOldCache
    Jika disertakan, folder SoftwareDistribution lama akan di-rename menjadi .old dan disimpan,
    bukan langsung dihapus.

.EXAMPLE
    .\WinUpdateDoctor.ps1 -Action Diagnose
    .\WinUpdateDoctor.ps1 -Action Repair -Force
    .\WinUpdateDoctor.ps1 -Action All
#>

[CmdletBinding()]
param(
    [ValidateSet("Diagnose", "Repair", "All")]
    [string]$Action = "All",

    [switch]$Force,
    [switch]$KeepOldCache
)

# Set UTF-8 encoding for clean console symbols
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LogDir = Join-Path -Path $PSScriptRoot -ChildPath "logs"
if (-not (Test-Path -Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path -Path $LogDir -ChildPath ("update-doctor_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [ValidateSet("INFO", "SUCCESS", "WARN", "ERROR", "TITLE")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $fileMsg = "[$timestamp] [$Level] $Message"
    Add-Content -Path $LogFile -Value $fileMsg -ErrorAction SilentlyContinue

    switch ($Level) {
        "TITLE" {
            Write-Host "`n=== $Message ===" -ForegroundColor Cyan
        }
        "INFO" {
            Write-Host "[INFO]  $Message" -ForegroundColor Gray
        }
        "SUCCESS" {
            Write-Host "[OK]    $Message" -ForegroundColor Green
        }
        "WARN" {
            Write-Host "[WARN]  $Message" -ForegroundColor Yellow
        }
        "ERROR" {
            Write-Host "[ERROR] $Message" -ForegroundColor Red
        }
    }
}

function Test-IsAdmin {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-SystemDiskInfo {
    $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($drive) {
        $freeGB = [math]::Round($drive.Free / 1GB, 2)
        $totalGB = [math]::Round(($drive.Used + $drive.Free) / 1GB, 2)
        return [PSCustomObject]@{
            FreeGB  = $freeGB
            TotalGB = $totalGB
        }
    }
    return $null
}

function Test-MeteredNetwork {
    try {
        $profile = Get-NetConnectionProfile -IPv4Connectivity Internet -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($profile -and $profile.InterfaceAlias -like "*Wi-Fi*") {
            $wlan = netsh wlan show interfaces | Out-String
            if ($wlan -match 'Profile\s+:\s+(.+)') {
                $profName = $matches[1].Trim()
                $costInfo = netsh wlan show profile name="$profName" | Out-String
                if ($costInfo -match 'Cost\s+:\s+Fixed' -or $costInfo -match 'Cost\s+:\s+Variable') {
                    return $true
                }
            }
        }
    }
    catch { }
    return $false
}

function Invoke-Diagnose {
    Write-Log "MEMULAI DIAGNOSA SISTEM WINDOWS UPDATE" -Level TITLE

    $issuesFound = 0

    # 1. Cek Hak Akses Administrator
    if (Test-IsAdmin) {
        Write-Log "Izin Administrator: Terpenuhi." -Level SUCCESS
    } else {
        Write-Log "Script tidak berjalan sebagai Administrator! Beberapa perbaikan akan gagal." -Level ERROR
        $issuesFound++
    }

    # 2. Cek Sisa Ruang Disk C:
    $disk = Get-SystemDiskInfo
    if ($disk) {
        if ($disk.FreeGB -lt 15) {
            Write-Log "Kapasitas Drive C: tersisa $($disk.FreeGB) GB dari $($disk.TotalGB) GB (Rendah - dapat menggagalkan download update)." -Level WARN
            $issuesFound++
        } else {
            Write-Log "Kapasitas Drive C: tersisa $($disk.FreeGB) GB dari $($disk.TotalGB) GB (Cukup)." -Level SUCCESS
        }
    }

    # 3. Cek Status Layanan Terkait
    Write-Log "Memeriksa status layanan sistem..." -Level INFO
    $services = @("wuauserv", "bits", "cryptsvc", "dosvc", "trustedinstaller")
    foreach ($svcName in $services) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -eq "Running") {
                Write-Log "Layanan '$svcName' sedang berjalan (${svc.StartType})." -Level SUCCESS
            } else {
                Write-Log "Layanan '$svcName' sedang berhenti (${svc.StartType})." -Level INFO
            }
        } else {
            Write-Log "Layanan '$svcName' tidak ditemukan!" -Level WARN
            $issuesFound++
        }
    }

    # 4. Cek Antrean BITS (Background Intelligent Transfer Service)
    Write-Log "Memeriksa antrean transfer BITS..." -Level INFO
    $bitsJobs = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue
    $stuckBits = $bitsJobs | Where-Object { $_.JobState -in @("Error", "Suspended", "TransientError") }
    if ($stuckBits) {
        Write-Log "Ditemukan $(@($stuckBits).Count) antrean BITS macet/bermasalah:" -Level WARN
        foreach ($job in $stuckBits) {
            Write-Log "  -> Job: $($job.DisplayName) | State: $($job.JobState) | Progress: $($job.BytesTransferred)/$($job.BytesTotal) bytes" -Level WARN
        }
        $issuesFound++
    } else {
        Write-Log "Antrean BITS bersih dari job yang macet/error (Total job aktif: $(@($bitsJobs).Count))." -Level SUCCESS
    }

    # 5. Cek Delivery Optimization (DoSvc)
    Write-Log "Memeriksa status Delivery Optimization..." -Level INFO
    try {
        $doJobs = Get-DeliveryOptimizationStatus -ErrorAction SilentlyContinue
        $pausedDo = $doJobs | Where-Object { $_.Status -eq "Paused" }
        if ($pausedDo) {
            Write-Log "Ditemukan $(@($pausedDo).Count) unduhan Delivery Optimization dalam status 'Paused'." -Level WARN
            $issuesFound++
        } else {
            Write-Log "Delivery Optimization normal (Job aktif: $(@($doJobs).Count))." -Level SUCCESS
        }
    }
    catch {
        Write-Log "Tidak dapat membaca status Delivery Optimization: $($_.Exception.Message)" -Level INFO
    }

    # 6. Cek Metered Connection
    if (Test-MeteredNetwork) {
        Write-Log "Koneksi jaringan terdeteksi 'Metered'. Windows Update dapat menahan download otomatis." -Level WARN
        $issuesFound++
    } else {
        Write-Log "Koneksi jaringan tidak dibatasi (Unrestricted)." -Level SUCCESS
    }

    # 7. Cek Daftar Pending Update
    Write-Log "Memeriksa antrean update yang belum selesai..." -Level INFO
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $res = $searcher.Search("IsInstalled=0")
        $pendingCount = $res.Updates.Count
        if ($pendingCount -gt 0) {
            Write-Log "Ditemukan $pendingCount item pembaruan yang belum selesai:" -Level INFO
            foreach ($u in $res.Updates) {
                $dlStatus = if ($u.IsDownloaded) { "Downloaded" } else { "Pending Download" }
                $level = if ($u.IsDownloaded) { "SUCCESS" } else { "WARN" }
                Write-Log "  * [$dlStatus] $($u.Title)" -Level $level
            }
            if ($res.Updates | Where-Object { -not $_.IsDownloaded }) {
                Write-Log "Terdapat item dengan status 'Pending Download' yang tertahan." -Level WARN
                $issuesFound++
            }
        } else {
            Write-Log "Tidak ada pembaruan tertunda yang ditemukan." -Level SUCCESS
        }
    }
    catch {
        Write-Log "Gagal mencari daftar pembaruan: $($_.Exception.Message)" -Level WARN
    }

    Write-Log "HASIL DIAGNOSA SELESAI" -Level TITLE
    if ($issuesFound -gt 0) {
        Write-Log "Terdeteksi $issuesFound indikasi masalah yang memerlukan perbaikan/reset." -Level WARN
        return $false
    } else {
        Write-Log "Komponen Windows Update dalam kondisi prima." -Level SUCCESS
        return $true
    }
}

function Invoke-Repair {
    Write-Log "MEMULAI PERBAIKAN WINDOWS UPDATE" -Level TITLE

    if (-not (Test-IsAdmin)) {
        Write-Log "Perbaikan memerlukan hak akses Administrator! Jalankan script ini sebagai Admin." -Level ERROR
        return $false
    }

    # 1. Hentikan Layanan Terkait
    Write-Log "1. Menghentikan layanan Windows Update, BITS, Cryptographic, dan Delivery Optimization..." -Level INFO
    $servicesToStop = @("wuauserv", "bits", "cryptsvc", "dosvc")
    foreach ($svcName in $servicesToStop) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") {
            try {
                Stop-Service -Name $svcName -Force -ErrorAction Stop
                Write-Log "   Layanan '$svcName' berhasil dihentikan." -Level SUCCESS
            } catch {
                Write-Log "   Gagal menghentikan '$svcName': $($_.Exception.Message)" -Level WARN
            }
        }
    }

    # Beri jeda 2 detik agar file handles terlepas
    Start-Sleep -Seconds 2

    # 2. Bersihkan Antrean BITS yang Macet (termasuk job level SYSTEM)
    Write-Log "2. Membersihkan antrean transfer BITS yang macet..." -Level INFO
    try {
        $allBits = Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue
        if ($allBits) {
            $allBits | Remove-BitsTransfer -ErrorAction SilentlyContinue
            Write-Log "   Berhasil membersihkan $(@($allBits).Count) antrean transfer BITS via API." -Level SUCCESS
        }

        # Bersihkan file database BITS fisik untuk membuang job milik akun SYSTEM yang terkunci
        $downloaderDir = "$env:ProgramData\Microsoft\Network\Downloader"
        if (Test-Path -Path $downloaderDir) {
            Get-ChildItem -Path $downloaderDir -Filter "qmgr*.*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
            Write-Log "   Database antrean BITS (qmgr) berhasil di-reset ke kondisi awal." -Level SUCCESS
        }
    } catch {
        Write-Log "   Gagal membersihkan transfer BITS: $($_.Exception.Message)" -Level WARN
    }

    # 3. Bersihkan Cache Delivery Optimization
    Write-Log "3. Mengosongkan cache Delivery Optimization..." -Level INFO
    try {
        $doCachePath = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
        if (Test-Path -Path $doCachePath) {
            Get-ChildItem -Path $doCachePath -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "   Cache Delivery Optimization dibersihkan." -Level SUCCESS
        }
    } catch {
        Write-Log "   Gagal membersihkan cache DO: $($_.Exception.Message)" -Level WARN
    }

    # 4. Reset Folder SoftwareDistribution & catroot2
    Write-Log "4. Mereset cache SoftwareDistribution & catroot2..." -Level INFO
    $sdPath = "$env:SystemRoot\SoftwareDistribution"
    $catPath = "$env:SystemRoot\System32\catroot2"
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

    # Penanganan SoftwareDistribution
    if (Test-Path -Path $sdPath) {
        $sdBackup = "$sdPath.bak_$timestamp"
        $renamed = $false
        try {
            Rename-Item -Path $sdPath -NewName (Split-Path -Leaf $sdBackup) -ErrorAction Stop
            Write-Log "   Folder SoftwareDistribution di-backup ke: $sdBackup" -Level SUCCESS
            $renamed = $true
        } catch {
            Write-Log "   Rename terkunci, membersihkan subfolder SoftwareDistribution\Download..." -Level WARN
            try {
                Get-ChildItem -Path "$sdPath\Download" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "   Subfolder SoftwareDistribution\Download berhasil dibersihkan." -Level SUCCESS
            } catch {
                Write-Log "   Gagal membersihkan folder Download: $($_.Exception.Message)" -Level ERROR
            }
        }

        # Jika KeepOldCache tidak diset dan rename berhasil, hapus folder backup sebelumnya
        if (-not $KeepOldCache -and $renamed) {
            # Jalankan background cleanup agar tidak memblokir
            Start-Job -ScriptBlock {
                param($path)
                Start-Sleep -Seconds 10
                Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
            } -ArgumentList $sdBackup | Out-Null
        }
    }

    # Penanganan catroot2
    if (Test-Path -Path $catPath) {
        $catBackup = "$catPath.bak_$timestamp"
        try {
            Rename-Item -Path $catPath -NewName (Split-Path -Leaf $catBackup) -ErrorAction Stop
            Write-Log "   Folder catroot2 di-backup ke: $catBackup" -Level SUCCESS
            if (-not $KeepOldCache) {
                Start-Job -ScriptBlock {
                    param($path)
                    Start-Sleep -Seconds 10
                    Remove-Item -Path $path -Recurse -Force -ErrorAction SilentlyContinue
                } -ArgumentList $catBackup | Out-Null
            }
        } catch {
            Write-Log "   catroot2 terkunci oleh proses sistem (normal jika cryptsvc masih melepas handle)." -Level INFO
        }
    }

    # 5. Nyalakan Kembali Layanan Sistem
    Write-Log "5. Memulai ulang layanan sistem Windows Update..." -Level INFO
    $servicesToStart = @("cryptsvc", "bits", "dosvc", "wuauserv")
    foreach ($svcName in $servicesToStart) {
        try {
            Set-Service -Name $svcName -StartupType Automatic -ErrorAction SilentlyContinue
            Start-Service -Name $svcName -ErrorAction Stop
            Write-Log "   Layanan '$svcName' berhasil dijalankan kembali." -Level SUCCESS
        } catch {
            Write-Log "   Gagal menyalakan '$svcName': $($_.Exception.Message)" -Level WARN
        }
    }

    # 6. Memicu Ulang Proses Scan & Download Windows Update
    Write-Log "6. Memicu ulang pemindaian dan pengunduhan Windows Update..." -Level INFO
    try {
        Start-Process -FilePath "usoclient.exe" -ArgumentList "ResetAuthorization" -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Start-Process -FilePath "usoclient.exe" -ArgumentList "StartInteractiveScan" -NoNewWindow -ErrorAction SilentlyContinue
        Start-Process -FilePath "usoclient.exe" -ArgumentList "StartDownload" -NoNewWindow -ErrorAction SilentlyContinue
        Write-Log "   Perintah unduhan ulang berhasil dikirimkan ke Update Session Orchestrator (USO)." -Level SUCCESS
    } catch {
        Write-Log "   Tidak dapat memanggil usoclient: $($_.Exception.Message)" -Level WARN
    }

    Write-Log "PROSES PERBAIKAN SELESAI" -Level TITLE
    return $true
}

# --- Entry Point ---
Clear-Host
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       WINDOWS UPDATE DOCTOR - DIAGNOSE & REPAIR          " -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Log file: $LogFile`n" -ForegroundColor DarkGray

switch ($Action) {
    "Diagnose" {
        $healthy = Invoke-Diagnose
        if (-not $healthy) {
            Write-Host "`nSaran: Jalankan script dengan parameter '-Action Repair' untuk mengatasi masalah ini." -ForegroundColor Yellow
        }
    }

    "Repair" {
        if (-not $Force) {
            $confirm = Read-Host "Apakah Anda yakin ingin mereset cache dan memulai ulang layanan update? (Y/N)"
            if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                Write-Log "Operasi perbaikan dibatalkan oleh pengguna." -Level WARN
                exit 0
            }
        }
        Invoke-Repair
    }

    "All" {
        $healthy = Invoke-Diagnose
        if (-not $healthy) {
            if (-not $Force) {
                Write-Host ""
                $confirm = Read-Host "Terdeteksi masalah. Jalankan perbaikan sekarang? (Y/N)"
                if ($confirm -ne 'Y' -and $confirm -ne 'y') {
                    Write-Log "Perbaikan dilewati oleh pengguna." -Level WARN
                    exit 0
                }
            } else {
                Write-Log "Mode -Force aktif, melanjutkan ke perbaikan otomatis..." -Level INFO
            }

            Invoke-Repair

            Write-Host "`nMenunggu 5 detik untuk inisialisasi ulang layanan..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 5

            Write-Log "VERIFIKASI STATUS SETELAH PERBAIKAN" -Level TITLE
            Invoke-Diagnose | Out-Null
        } else {
            Write-Log "Sistem dalam keadaan normal. Tidak ada perbaikan yang diperlukan." -Level SUCCESS
        }
    }
}

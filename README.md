# 🩺 Windows Update Doctor (`win-update-doctor`)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20%7C%20Server-0078D6?logo=windows)](https://microsoft.com/windows)
[![Shell: PowerShell](https://img.shields.io/badge/Language-PowerShell-5391FE?logo=powershell)](https://github.com/PowerShell/PowerShell)

**Windows Update Doctor** adalah toolkit otomatis berbasis PowerShell untuk mendiagnosa, mendeteksi akar masalah, dan memperbaiki pembaruan Windows yang macet (*stuck*) pada status **"Pending Download"**, antrean BITS (*Background Intelligent Transfer Service*) yang tersumbat, atau *Delivery Optimization* (DoSvc) yang berstatus *Paused*.

---

## ⚡ Fitur Utama (Key Features)

- **🔍 Intelligent Pre-Flight Diagnostic**:
  - Memeriksa hak akses Administrator (UAC).
  - Memeriksa kesehatan status layanan sistem (`wuauserv`, `bits`, `cryptsvc`, `dosvc`, `trustedinstaller`).
  - Memindai antrean BITS multi-user untuk job berstatus `Error`, `Suspended`, atau `TransientError`.
  - Memeriksa status pipeline *Delivery Optimization* (`Paused` vs `Active`).
  - Mengukur sisa ruang penyimpanan Drive C: dan status pembatasan kuota jaringan (*Metered connection*).
  - Memeriksa daftar paket pembaruan yang tertahan melalui antarmuka COM `Microsoft.Update.Session`.

- **🛠️ Safe & Targeted Remediation**:
  - Menghentikan dan memulai ulang layanan sistem secara terkoordinasi.
  - Membersihkan seluruh antrean BITS yang macet, termasuk pembersihan file fisik database `qmgr.db` untuk job milik `NT AUTHORITY\SYSTEM` yang terkunci.
  - Mengosongkan cache *Delivery Optimization*.
  - Melakukan backup otomatis sebelum mereset folder `SoftwareDistribution` dan `catroot2`.
  - Memicu pemindaian dan unduhan bersih secara otomatis melalui *Update Session Orchestrator* (`usoclient`).

- **🖥️ Easy Launcher**:
  - Disertai file `Run-AsAdmin.bat` untuk eksekusi langsung sekali klik dengan elevasi otomatis ke Administrator.

---

## 📁 Struktur Repositori

```text
win-update-doctor/
├── WinUpdateDoctor.ps1   # Script engine utama (Diagnose, Repair, Verify)
├── Run-AsAdmin.bat       # Launcher praktis dengan auto UAC elevation
├── .gitignore            # Filter log dan temporary files
├── LICENSE               # Lisensi open-source MIT
└── README.md             # Panduan dan dokumentasi teknis
```

---

## 🚀 Cara Penggunaan

### Opsi 1: Menggunakan Launcher Cepat (Rekomendasi)
Klik dua kali file **`Run-AsAdmin.bat`**.  
Jendela konfirmasi Administrator (UAC) akan muncul otomatis. Script akan memindai sistem dan menawarkan perbaikan jika ditemukan masalah.

### Opsi 2: Melalui PowerShell (Admin)

Buka PowerShell sebagai Administrator di folder ini, lalu jalankan sesuai mode:

#### 1. Diagnosa Lengkap (Hanya Memeriksa Tanpa Mengubah Sistem)
```powershell
.\WinUpdateDoctor.ps1 -Action Diagnose
```

#### 2. Perbaikan Langsung (Reset BITS & Cache Update)
```powershell
.\WinUpdateDoctor.ps1 -Action Repair -Force
```

#### 3. Alur Komprehensif (Diagnosa $\to$ Perbaiki $\to$ Verifikasi Ulang)
```powershell
.\WinUpdateDoctor.ps1 -Action All -Force
```

---

## 📋 Parameter CLI

| Parameter | Tipe | Default | Deskripsi |
| :--- | :--- | :--- | :--- |
| `-Action` | `Diagnose` \| `Repair` \| `All` | `All` | Memilih alur kerja: diagnosa saja, perbaikan saja, atau keduanya bertahap. |
| `-Force` | `Switch` | `False` | Melewati konfirmasi interaktif (cocok untuk otomasi atau remote script). |
| `-KeepOldCache` | `Switch` | `False` | Mempertahankan folder backup `.bak` lama alih-alih menghapusnya setelah sukses. |

---

## 📄 Lisensi

Proyek ini dilisensikan di bawah lisensi [MIT License](LICENSE) - bebas digunakan, dimodifikasi, dan didistribusikan.

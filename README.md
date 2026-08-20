<div align="center">

# 🎬 TorBox Media Server

**A single-command, zero-storage personal streaming setup — powered by TorBox cloud.**

[![ShellCheck](https://github.com/nordicnode/TorBox-Media-Server/actions/workflows/lint.yml/badge.svg)](https://github.com/nordicnode/TorBox-Media-Server/actions/workflows/lint.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Requires-Docker-blue?logo=docker)](https://docs.docker.com/get-docker/)
[![TorBox](https://img.shields.io/badge/Powered%20by-TorBox-orange)](https://torbox.app)
[![Platform Support](https://img.shields.io/badge/OS-Linux%20%7C%20macOS%20%7C%20Windows-brightgreen)](#-platform-support)

</div>

> **Your request → TorBox finds & stores → You stream. Zero local storage.**

A complete debrid-powered media server stack using Docker. **No media is stored locally** — everything streams directly from [TorBox](https://torbox.app)'s cloud. Think of it as your own personal Netflix where *you* decide what's available, backed by TorBox's cloud download and cache infrastructure.

---

## ⚡ Quick Start

### macOS

Open **Terminal** and run:

```bash
git clone https://github.com/nordicnode/TorBox-Media-Server.git && cd TorBox-Media-Server
chmod +x setup_macos.sh && ./setup_macos.sh
```

For unattended installs:

```bash
TORBOX_API_KEY="your-api-key" ./setup_macos.sh --yes
```

> **Note on macOS:** The macOS setup uses **STRM files** (streaming pointer text files) and **Jellyfin** (which natively supports STRM). No FUSE drivers or kernel extensions required!

---

### Linux

```bash
git clone https://github.com/nordicnode/TorBox-Media-Server.git && cd TorBox-Media-Server
chmod +x setup.sh && ./setup.sh
```

For unattended installs:

```bash
TORBOX_API_KEY="your-api-key" TORBOX_MEDIA_SERVER="jellyfin" ./setup.sh --yes
```

---

### CasaOS (Ubuntu / Debian)

SSH into your CasaOS machine and run:

```bash
curl -fsSL https://raw.githubusercontent.com/nordicnode/TorBox-Media-Server/main/install-casaos.sh | TORBOX_API_KEY="your-api-key" bash
```

---

### Windows

Open **PowerShell** as **Administrator** and run:

```powershell
git clone https://github.com/nordicnode/TorBox-Media-Server.git
cd TorBox-Media-Server
.\setup.ps1
```

---

## 💻 Platform Support

| Operating System | Streaming Method | Media Server | Auto-Start |
| :--- | :--- | :--- | :--- |
| **Linux** (Arch, Ubuntu, Debian, Fedora, CachyOS) | FUSE Mount (`rclone`) | Jellyfin or Plex | `systemd` service |
| **macOS** (macOS 13+ Intel & Apple Silicon) | STRM Files | Jellyfin | `launchd` service |
| **Windows** (Windows 10/11) | WinFSP / FUSE Mount | Jellyfin or Plex | Windows Task / Docker |
| **CasaOS** | FUSE Mount | Jellyfin or Plex | Docker Compose |

---

## 📑 Table of Contents

- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [Service URLs & Ports](#service-urls--ports)
- [Connecting Seerr to Jellyfin & *arrs](#connecting-seerr-to-jellyfin--arrs)
- [Management Script](#management-script)
- [Hardware Acceleration (GPU)](#hardware-acceleration-gpu)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## How It Works

```
  You request a movie/show in Seerr (or Radarr/Sonarr)
                    │
                    ▼
  Radarr/Sonarr search Prowlarr indexers for the torrent
                    │
                    ▼
  Torrent is sent to Decypharr (qBittorrent API mock)
                    │
                    ▼
  Decypharr sends the torrent hash to TorBox Cloud API
                    │
                    ▼
  TorBox fetches/caches the media in the cloud
                    │
                    ▼
  Linux/Win: Mounted via WebDAV (rclone FUSE)
  macOS: Pointed via lightweight .strm text files
                    │
                    ▼
  Streamed directly on Jellyfin / Plex / Smart TV!
```

---

## 🌐 Service URLs & Ports

After running setup, access your services in your web browser:

| Service | Port | Description | Web URL |
| :--- | :--- | :--- | :--- |
| **Jellyfin** | `8096` | Media Server | `http://localhost:8096` |
| **Seerr** | `5055` | Media Discovery & Requests | `http://localhost:5055` |
| **Radarr** | `7878` | Movie Manager | `http://localhost:7878` |
| **Sonarr** | `8989` | TV Show Manager | `http://localhost:8989` |
| **Prowlarr** | `9696` | Indexer Manager | `http://localhost:9696` |
| **Byparr** | `8191` | Cloudflare Bypass Proxy | `http://localhost:8191` |
| **Decypharr** | `8282` | TorBox Debrid Bridge | `http://localhost:8282` |

> **Viewing Passwords & Keys:**
> Run `cd torbox-media-server && ./manage.sh keys` to view your auto-generated admin passwords and API keys.

---

## 🔗 Connecting Seerr to Jellyfin & *arrs

When configuring **Seerr** for the first time via `http://localhost:5055`:

### 1. Connecting Jellyfin in Seerr

Inside Docker, containers talk to each other using **Docker container network names**, not `localhost`.

- **Server Name:** `Jellyfin`
- **Host / IP:** `http://jellyfin` *(Use `jellyfin`, NOT `localhost`)*
- **Port:** `8096`
- **Use SSL:** Off
- Click **Test Connection**, then enter your Jellyfin admin credentials or API key.

### 2. Connecting Radarr & Sonarr in Seerr

Seerr connects automatically during setup, but if prompted manually:
- **Radarr Server Name:** `Radarr`
- **Hostname:** `radarr`
- **Port:** `7878`
- **API Key:** Copy from `./manage.sh keys`

- **Sonarr Server Name:** `Sonarr`
- **Hostname:** `sonarr`
- **Port:** `8989`
- **API Key:** Copy from `./manage.sh keys`

---

## 🛠️ Management Script

Use `manage.sh` (or `manage_macos.sh`) inside your installation directory to control your stack:

```bash
cd torbox-media-server

./manage.sh status     # Check container status
./manage.sh logs       # View logs (follow mode)
./manage.sh logs byparr # View logs for a specific service
./manage.sh start      # Start all services
./manage.sh stop       # Stop all services
./manage.sh restart    # Restart all services
./manage.sh update     # Pull updated Docker images & restart
./manage.sh keys       # View API keys and credentials
./manage.sh health     # Run health check against all endpoints
./manage.sh backup     # Back up configuration and .env
./manage.sh restore    # Restore configuration and .env from backup
```

---

## 🚀 Hardware Acceleration (GPU Transcoding)

- **Linux (Intel / AMD / NVIDIA):** GPU passthrough is auto-detected during `setup.sh` and injected into `docker-compose.override.yml` (`/dev/dri` for Intel/AMD, NVIDIA container toolkit for NVIDIA).
- **macOS (Apple Silicon M-Series):** Docker Desktop for Mac runs containers in a Linux VM without GPU passthrough. Docker containers use **software (CPU) transcoding**. Apple Silicon M1/M2/M3/M4 CPUs can easily handle 1080p software transcoding.
  - *Advanced Option for macOS 4K Hardware Acceleration:* You can optionally install Jellyfin natively on macOS via Homebrew (`brew install --cask jellyfin`) to leverage Apple Metal GPU transcoding directly.

---

## 🧹 Uninstalling

To cleanly remove all containers, configuration files, auto-start services, and data directories:

### macOS

```bash
./uninstall_macos.sh
```

### Linux

```bash
./uninstall.sh
```

### Windows

```powershell
.\uninstall.ps1
```

---

## ❓ Troubleshooting

### 1. Jellyfin is unreachable or Seerr cannot connect to Jellyfin

- **First Boot Delay:** On initial startup, Jellyfin takes 20-30 seconds to initialize its database. Wait 30 seconds and refresh `http://localhost:8096`.
- **Connecting inside Docker (Seerr):** Use `http://jellyfin:8096` as the server address inside Seerr settings. `localhost` inside Seerr points to Seerr itself, not Jellyfin.
- **Check container health:** Run `./manage.sh status` or `./manage.sh health` to ensure containers are running.

### 2. Byparr permission denied error (`/var/cache/uv`)

If Byparr logs show permission issues on `/var/cache/uv`:
1. Re-run setup: `./setup_macos.sh`
2. Or force recreate the container:
   ```bash
   cd torbox-media-server
   docker compose up -d --force-recreate byparr
   ```

### 3. Media scanning is slow on macOS

macOS uses VirtioFS file sharing into Docker. STRM files are lightweight text files created in your data directory (`~/torbox-media`). Jellyfin reads these files almost instantaneously.

---

## 📄 License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

*Disclaimer: This project is an independent open-source tool and is not affiliated with or endorsed by TorBox. Users are responsible for adhering to all applicable laws and terms of service.*

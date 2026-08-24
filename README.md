<div align="center">

# 🎬 TorBox Media Server — macOS Edition

**A single-command, zero-storage personal streaming setup — powered by TorBox cloud.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker](https://img.shields.io/badge/Requires-Docker_Desktop-blue?logo=docker)](https://www.docker.com/products/docker-desktop/)
[![TorBox](https://img.shields.io/badge/Powered%20by-TorBox-orange)](https://torbox.app)
[![macOS](https://img.shields.io/badge/macOS-13%2B-brightgreen?logo=apple)](#requirements)
[![Shell](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnubash)](https://www.gnu.org/software/bash/)

</div>

> **Your request → TorBox finds & stores → You stream. Zero local storage.**

A macOS-native fork of TorBox Media Server that sets up a complete debrid-powered streaming stack with a single command. **No media is stored locally** — everything streams directly from [TorBox](https://torbox.app)'s cloud through lightweight STRM files. Think of it as your own personal Netflix where *you* decide what's available.

This fork is **macOS-only** and uses **STRM files + Jellyfin** — no FUSE drivers, kernel extensions, or Plex required.

---

## 📑 Table of Contents

- [How It Works](#-how-it-works)
- [Requirements](#-requirements)
- [Quick Start](#-quick-start)
- [What the Setup Does](#-what-the-setup-does)
- [Service URLs & Ports](#-service-urls--ports)
- [Management Script](#-management-script)
- [Connecting Seerr to Jellyfin & *arrs](#-connecting-seerr-to-jellyfin--arrs)
- [Hardware Acceleration](#-hardware-acceleration-gpu-transcoding)
- [Non-Interactive Install](#-non-interactive-install)
- [Uninstalling](#-uninstalling)
- [Testing](#-testing)
- [Troubleshooting](#-troubleshooting)
- [Project Structure](#-project-structure)
- [License](#-license)

---

## 🔄 How It Works

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
  TorBox Media Center creates lightweight .strm files
                    │
                    ▼
  Jellyfin reads the .strm files and streams directly!
```

**STRM files** are tiny text files (a few bytes each) containing a direct streaming URL. Jellyfin natively understands them — no filesystem mounts, no FUSE, no kernel extensions. Your `~/torbox-media` directory stays nearly empty.

---

## 📋 Requirements

| Requirement | Details |
|:---|:---|
| **OS** | macOS 13+ (Ventura or later) — Intel & Apple Silicon |
| **Docker Desktop** | [Download here](https://www.docker.com/products/docker-desktop/) — must be installed and running |
| **TorBox Account** | [Sign up](https://torbox.app) and grab your API key from [Settings](https://torbox.app/settings) |
| **CLI Tools** | `curl`, `jq`, `openssl` — auto-installed via [Homebrew](https://brew.sh) if missing |
| **Ports** | 8096, 5055, 7878, 8989, 9696, 8191, 8282 must be available |

> All ports are bound to `127.0.0.1` — your services are only accessible from your Mac, not the network.

---

## ⚡ Quick Start

1. **Install [Docker Desktop](https://www.docker.com/products/docker-desktop/)** and make sure it's running.

2. **Clone and run:**

```bash
git clone https://github.com/theb8821/TorBox-Media-Server.git && cd TorBox-Media-Server
chmod +x setup_macos.sh && ./setup_macos.sh
```

3. **Follow the prompts:**
   - Enter your TorBox API key (validated against the TorBox API)
   - Confirm the install directory (default: `~/torbox-media-server`)
   - Confirm the media data directory (default: `~/torbox-media`)

4. **That's it.** The script handles everything else — pulling images, starting containers, configuring all services, and setting up auto-start at login.

5. **Open Jellyfin** at [`http://localhost:8096`](http://localhost:8096) and start streaming!

---

## 🏗️ What the Setup Does

The `setup_macos.sh` script is fully self-contained (~100KB). Running it:

1. **Validates prerequisites** — checks macOS, Docker Desktop, Docker version (20+), and port availability
2. **Generates configuration** — creates `.env` with auto-detected PUID, PGID, timezone, and auto-generated API keys/passwords
3. **Sets up Docker Compose** — copies `docker-compose.macos.yml` to your install directory
4. **Generates `manage.sh`** — a post-install management script for day-to-day operations
5. **Pulls and starts** all 8 Docker containers
6. **Auto-configures all services** via their APIs:
   - Connects Radarr/Sonarr to Decypharr (download client)
   - Configures root folders, naming templates, and quality profiles
   - Syncs Prowlarr with Radarr/Sonarr
   - Connects Seerr to Radarr, Sonarr, and Jellyfin
   - Pushes admin credentials into all *arr services
7. **Installs a launchd service** — auto-starts the stack at login

> **Idempotent re-runs:** Running `setup_macos.sh` again preserves your existing API keys and passwords. Only missing values are regenerated.

---

## 🌐 Service URLs & Ports

After setup completes, access your services in the browser:

| Service | Port | Description | URL |
|:---|:---|:---|:---|
| **Jellyfin** | `8096` | Media Server | [`http://localhost:8096`](http://localhost:8096) |
| **Seerr** | `5055` | Media Discovery & Requests | [`http://localhost:5055`](http://localhost:5055) |
| **Radarr** | `7878` | Movie Manager | [`http://localhost:7878`](http://localhost:7878) |
| **Sonarr** | `8989` | TV Show Manager | [`http://localhost:8989`](http://localhost:8989) |
| **Prowlarr** | `9696` | Indexer Manager | [`http://localhost:9696`](http://localhost:9696) |
| **Byparr** | `8191` | Cloudflare Bypass Proxy | [`http://localhost:8191`](http://localhost:8191) |
| **Decypharr** | `8282` | TorBox Debrid Bridge | [`http://localhost:8282`](http://localhost:8282) |
| **TorBox Media Center** | — | STRM File Generator | *(no web UI)* |

> **View credentials anytime:** `cd ~/torbox-media-server && ./manage.sh keys`

---

## 🛠️ Management Script

After installation, use `manage.sh` inside your install directory to control the stack:

```bash
cd ~/torbox-media-server

./manage.sh status       # Check container status & health
./manage.sh start        # Start all services
./manage.sh stop         # Stop all services
./manage.sh restart      # Restart all services
./manage.sh logs         # Follow logs (all services)
./manage.sh logs byparr  # Follow logs for a specific service
./manage.sh pull         # Pull latest Docker image versions
./manage.sh update       # Pull latest images & recreate containers
./manage.sh down         # Stop & tear down containers and networks
./manage.sh urls         # Display all service URLs & ports
./manage.sh keys         # View API keys & credentials
./manage.sh health       # Run HTTP health checks on all endpoints
./manage.sh fetch        # Trigger TorBox cloud sync & Jellyfin refresh
./manage.sh shell radarr # Open a shell inside a container
./manage.sh enable       # Enable auto-start at login (launchd)
./manage.sh disable      # Disable auto-start at login
./manage.sh backup       # Create timestamped backup of config & .env
./manage.sh version      # Display manage.sh version
./manage.sh help         # Show all available commands
```

---

## 🔗 Connecting Seerr to Jellyfin & *arrs

The setup script **auto-configures Seerr** with Jellyfin, Radarr, and Sonarr. If you need to manually reconfigure:

### Jellyfin Connection (in Seerr)

Inside Docker, containers communicate using **container names**, not `localhost`:

| Setting | Value |
|:---|:---|
| **Server Name** | `Jellyfin` |
| **Host / IP** | `http://jellyfin` *(not `localhost`)* |
| **Port** | `8096` |
| **Use SSL** | Off |

Click **Test Connection**, then enter your Jellyfin admin credentials.

### Radarr & Sonarr Connection (in Seerr)

| Setting | Radarr | Sonarr |
|:---|:---|:---|
| **Server Name** | `Radarr` | `Sonarr` |
| **Hostname** | `radarr` | `sonarr` |
| **Port** | `7878` | `8989` |
| **API Key** | From `./manage.sh keys` | From `./manage.sh keys` |

---

## 🚀 Hardware Acceleration (GPU Transcoding)

Docker Desktop on macOS runs containers inside a Linux VM — **there is no GPU passthrough**. All transcoding uses **software (CPU)**. This is perfectly fine:

- **Apple Silicon (M1–M4)** handles 1080p software transcoding with ease
- **Intel Macs** also work well for 1080p

> **Want 4K hardware transcoding?** Install Jellyfin natively via Homebrew (`brew install --cask jellyfin`) to leverage Apple Metal GPU acceleration directly on macOS, bypassing Docker's CPU-only limitation.

---

## 🤖 Non-Interactive Install

For automated or scripted deployments, use the `--yes` flag:

```bash
TORBOX_API_KEY="your-api-key" ./setup_macos.sh --yes
```

You can pre-configure values by setting environment variables or editing [`.env.example`](.env.example):

```bash
# Copy and edit the template
cp .env.example .env

# Then run non-interactively
./setup_macos.sh --yes
```

Available environment variables:

| Variable | Required | Default |
|:---|:---|:---|
| `TORBOX_API_KEY` | **Yes** | — |
| `INSTALL_DIR` | No | `~/torbox-media-server` |
| `DATA_DIR` | No | `~/torbox-media` |
| `PUID` | No | Auto-detected |
| `PGID` | No | Auto-detected |
| `TZ` | No | Auto-detected |
| `RADARR_API_KEY` | No | Auto-generated |
| `SONARR_API_KEY` | No | Auto-generated |
| `PROWLARR_API_KEY` | No | Auto-generated |
| `ADMIN_PASSWORD` | No | Auto-generated |
| `JELLYFIN_API_KEY` | No | Auto-generated |

---

## 🧹 Uninstalling

To cleanly remove everything:

```bash
./uninstall_macos.sh
```

This removes:
- All Docker containers and volumes
- The launchd auto-start service (`~/Library/LaunchAgents/com.torbox.mediaserver.plist`)
- The install directory (`~/torbox-media-server`)
- Docker images used by the stack
- Optionally, the media data directory (`~/torbox-media`) — you'll be asked

Use `./uninstall_macos.sh --yes` to skip the confirmation prompt (media data directory will still be confirmed separately).

---

## 🧪 Testing

Tests are Bash scripts using a lightweight framework in [`tests/test_utils.sh`](tests/test_utils.sh):

```bash
# Unit tests (mask_key, generate_api_key, generate_password, etc.)
bash tests/test_setup_functions.sh

# API key validation tests
bash tests/test_api_key.sh

# Full E2E suite (syntax, config, compose, manage.sh, launchd, uninstall)
bash tests/test_e2e.sh
```

Linting and formatting:

```bash
# ShellCheck
shellcheck setup_macos.sh uninstall_macos.sh tests/*.sh

# shfmt (check)
shfmt -d -i 4 -ci setup_macos.sh uninstall_macos.sh tests/

# shfmt (auto-fix)
shfmt -w -i 4 -ci setup_macos.sh uninstall_macos.sh tests/
```

---

## ❓ Troubleshooting

### Jellyfin is unreachable or Seerr can't connect

- **First boot delay:** Jellyfin takes 20–30 seconds to initialize on first startup. Wait and refresh [`http://localhost:8096`](http://localhost:8096).
- **Inside Docker:** Use `http://jellyfin:8096` in Seerr settings. `localhost` inside Seerr points to the Seerr container itself, not Jellyfin.
- **Check health:** Run `./manage.sh status` or `./manage.sh health`.

### Byparr permission denied (`/var/cache/uv`)

If Byparr logs show permission errors:

```bash
# Option 1: Re-run setup
./setup_macos.sh

# Option 2: Force recreate the container
cd ~/torbox-media-server && docker compose up -d --force-recreate byparr
```

### Media scanning is slow

STRM files are lightweight text files (a few bytes each). Jellyfin reads them almost instantly. If scanning seems slow, check Docker Desktop's resource allocation (Settings → Resources) and ensure VirtioFS file sharing is enabled.

### Ports already in use

The setup script checks port availability before starting. If a port conflict is detected, stop the conflicting service or change the port in `docker-compose.yml` and `.env`.

### Docker Desktop not running

The setup script requires Docker Desktop to be running. Open Docker Desktop from your Applications folder or run:

```bash
open -a Docker
```

Wait for it to fully start before re-running the setup.

---

## 📁 Project Structure

```
TorBox-Media-Server/
├── setup_macos.sh              # Main setup script (self-contained, ~100KB)
├── uninstall_macos.sh           # Clean uninstall script
├── docker-compose.macos.yml     # Docker Compose for the macOS stack
├── .env.example                 # Template for non-interactive installs
├── lib/
│   └── env.sh                   # Shared env parsing library
├── tests/
│   ├── test_utils.sh            # Lightweight test framework (pass/fail/summary)
│   ├── test_setup_functions.sh  # Unit tests for setup functions
│   ├── test_api_key.sh          # API key validation tests
│   └── test_e2e.sh              # Full end-to-end test suite
├── GEMINI.md                    # AI coding agent guidance
├── TORBOX_WORKFLOW_FINDINGS_AND_FIXES.md  # Architecture documentation
├── .shellcheckrc                # ShellCheck configuration
├── LICENSE                      # MIT License
└── .gitignore
```

### Generated Files (after running setup)

```
~/torbox-media-server/           # Install directory
├── docker-compose.yml           # Active Docker Compose file
├── .env                         # Generated environment config
└── manage.sh                    # Post-install management script

~/torbox-media/                  # Media data directory (STRM files)
├── movies/
└── tv/

~/Library/LaunchAgents/
└── com.torbox.mediaserver.plist # Auto-start at login
```

---

## 📄 License

This project is licensed under the **MIT License**. See the [LICENSE](LICENSE) file for details.

*Disclaimer: This project is an independent open-source tool and is not affiliated with or endorsed by TorBox. Users are responsible for adhering to all applicable laws and terms of service.*

# GEMINI.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

TorBox Media Server is a set of shell scripts that installs, configures, and runs a complete debrid-powered media server using Docker. This is a **macOS-only fork**. There is no Linux or Windows support. **No media is stored locally** — everything streams from TorBox's cloud. This fork uses STRM files and Jellyfin. The main entry point is `setup_macos.sh`, which generates configs, a Docker Compose file, and a `manage.sh` script.

## Repository Structure

| File | Purpose |
|------|---------|
| `setup_macos.sh` | Main macOS setup script. Interactive by default; supports `--yes` for non-interactive installs. Generates `docker-compose.yml`, `.env`, `manage.sh`, and launchd service. |
| `uninstall_macos.sh` | macOS uninstall script. Clean removal of containers, configs, data, and launchd service. |
| `docker-compose.macos.yml` | macOS Docker Compose (STRM files, Jellyfin only). Reference Docker Compose file (copied to install dir by `setup_macos.sh`). |
| `.env.example` | Template for non-interactive installs. Users set env vars before running `setup_macos.sh --yes`. |
| `lib/env.sh` | Shared env parsing library. |
| `TORBOX_WORKFLOW_FINDINGS_AND_FIXES.md` | Architecture doc. |
| `tests/` | Shell-based test suites testing `setup_macos.sh`. |
| `.shellcheckrc` | ShellCheck config with intentional disables (e.g., `SC2034`, `SC2086`). |

## Common Commands

### Run tests

```bash
# Unit tests (mask_key, generate_api_key, etc.)
bash tests/test_setup_functions.sh

# API key tests
bash tests/test_api_key.sh

# Full E2E test suite (syntax, config generation, compose validation, manage.sh generation, launchd correctness, uninstall safety)
bash tests/test_e2e.sh
```

Note: these tests target `setup_macos.sh`.

### Lint / format

```bash
# ShellCheck (lint)
shellcheck setup_macos.sh uninstall_macos.sh tests/*.sh

# shfmt (format)
shfmt -d -i 4 -ci setup_macos.sh uninstall_macos.sh tests/
shfmt -w -i 4 -ci setup_macos.sh uninstall_macos.sh tests/   # write changes
```

### Validate manually

```bash
# Syntax check
bash -n setup_macos.sh
bash -n uninstall_macos.sh
bash -n tests/test_*.sh
```

### Run the setup script

```bash
# Interactive
chmod +x setup_macos.sh && ./setup_macos.sh

# Non-interactive
TORBOX_API_KEY="your-key" ./setup_macos.sh --yes
```

## Architecture

### Script architecture

`setup_macos.sh` is the main Bash script broken into sections with visual comment dividers. It is designed to be self-contained and runnable on macOS systems. Key design decisions:

- **Self-contained**: All functions, config generation logic, and the entire `manage.sh` script are embedded as heredocs inside `setup_macos.sh`. This means `setup_macos.sh` can be downloaded and run standalone without dependencies on other repo files.
- ** Generated artifacts**: Running `setup_macos.sh` produces:
  - `torbox-media-server/.env` — auto-detected/generated values (PUID, PGID, TZ, API keys, passwords).
  - `torbox-media-server/docker-compose.yml` — copied from repo.
  - `torbox-media-server/manage.sh` — post-install management script (status, logs, update, stop, start, keys, etc.), generated via concatenated heredocs.
  - `~/Library/LaunchAgents/com.torbox.mediaserver.plist` — launchd plist for auto-start.
- **Idempotent re-runs**: Existing `.env` values are preserved; only missing values are regenerated. This ensures API keys and passwords remain stable across updates.
- **Interrupt safety**: `trap` handlers clean up partial installations on `SIGINT`/`SIGTERM`.

### Service orchestration

The stack uses Docker Compose with STRM files via the TorBox Media Center container. The macOS fork is Jellyfin only. Software transcoding is used in Docker.

- **TorBox Media Center** — generates STRM files and handles TorBox synchronization.
- **Decypharr** — mocks qBittorrent API, connects to TorBox.
- **Prowlarr** — indexer aggregator.
- **Byparr** — FlareSolverr-compatible bypass for Prowlarr.
- **Radarr / Sonarr** — movie/TV show management (auto-configured via API after startup).
- **Seerr** — request / discovery UI (auto-configured via API).
- **Jellyfin** — media server.

### Auto-configuration pipeline

After `docker compose up`, `setup_macos.sh` performs automated first-time config via the *arr APIs:

1. **Download clients** — connects Radarr/Sonarr to Decypharr (qBittorrent API).
2. **Root folders** — adds `/data/movies` and `/data/tv`.
3. **Media management & naming** — sets naming templates, quality profiles, and enables upgrades.
4. **Prowlarr apps & proxy** — syncs Prowlarr with Radarr/Sonarr.
5. **Seerr** — connects to Radarr/Sonarr and Jellyfin.
6. **Auth sync** — pushes `.env` admin credentials into *arr services.

### Port map (single source of truth in `setup_macos.sh`)

| Service | Port |
|---------|------|
| TorBox Media Center | - |
| Decypharr | 8282 |
| Prowlarr | 9696 |
| Byparr | 8191 |
| Radarr | 7878 |
| Sonarr | 8989 |
| Seerr | 5055 |
| Jellyfin | 8096 |

## Testing approach

Tests are Bash scripts using a lightweight framework defined in `tests/test_utils.sh` (`pass`/`fail`/`print_summary`).

- `test_setup_functions.sh` sources specific functions from `setup_macos.sh` using `sed` to extract them by name (e.g., `source <(sed -n '/^generate_api_key() {/,/^}/p' setup_macos.sh)`). This avoids side effects from sourcing the entire script.
- `test_e2e.sh` validates the full pipeline: syntax, config generation, compose validation, `manage.sh` generation, launchd correctness, and uninstall safety. All tests target `setup_macos.sh`.

## Code style

- Functions are named with underscores (e.g., `generate_api_key`, `run_with_spinner`).
- Long sections are separated by visual `# ==== … ====` dividers.
- User-facing messages use the `log_*` helpers (`log_info`, `log_warn`, `log_error`, `log_step`, `log_section`).
- All shell scripts must pass ShellCheck.
- Commit messages use conventional commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`).

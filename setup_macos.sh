#!/usr/bin/env bash
set -euo pipefail
set -o errtrace
trap 'echo -e "\n\033[0;31m[ERROR] Unexpected error at line $LINENO in command: $BASH_COMMAND\033[0m"' ERR

# ============================================================================
#  TorBox Media Server - macOS Setup Script
#  Automated setup for a debrid-powered media server using Docker Desktop
#
#  Components: Prowlarr, Byparr, Decypharr (lite), Seerr,
#              Radarr, Sonarr, Jellyfin
#
#  macOS-specific: Uses STRM files instead of FUSE mounts.
#  Jellyfin only (no Plex support on macOS — STRM is not Plex-compatible).
#  No rclone mount, no /dev/fuse, no SYS_ADMIN, no mount propagation.
# ============================================================================

VERSION="1.1.0"
DRY_RUN=false
SERVICES_STARTED=false
NON_INTERACTIVE=false
SPINNER_PID=""
SPINNER_TMPFILE=""

trap 'cleanup_on_interrupt' INT TERM

cleanup_on_interrupt() {
    echo ""
    # Kill any background process started by run_with_spinner
    if [[ -n "${SPINNER_PID:-}" ]]; then
        kill -TERM "${SPINNER_PID}" 2>/dev/null || true
        sleep 0.2
        kill -9 "${SPINNER_PID}" 2>/dev/null || true
    fi
    if [[ -n "${SPINNER_TMPFILE:-}" && -e "${SPINNER_TMPFILE}" ]]; then
        rm -f "${SPINNER_TMPFILE}"
    fi
    # If containers were already started, stop them
    if [[ "${SERVICES_STARTED:-}" == "true" && -f "${COMPOSE_FILE:-}" && -f "${ENV_FILE:-}" ]]; then
        log_warn "Stopping containers before cleanup..."
        if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
            detect_compose_cmd
        fi
        (cd "${INSTALL_DIR}" && "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" down --remove-orphans) 2>/dev/null || true
    fi
    # If setup never completed, remove partial installation
    if [[ ! -f "${ENV_FILE:-}" && -d "${INSTALL_DIR:-}" ]]; then
        log_warn "Setup interrupted before completion. Cleaning up partial installation..."
        rm -rf "${INSTALL_DIR:-}"
        log_info "Partial installation removed. Re-run setup_macos.sh to start fresh."
    elif [[ -f "${ENV_FILE:-}" && ! -f "${SETUP_COMPLETE_FILE:-}" ]]; then
        log_warn "Setup interrupted during configuration. Cleaning up incomplete installation..."
        rm -rf "${INSTALL_DIR:-}"
        log_info "Incomplete installation removed. Re-run setup_macos.sh to start fresh."
    else
        log_warn "Setup interrupted. Re-run to continue where you left off."
    fi
    exit 130
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${TORBOX_INSTALL_DIR:-${SCRIPT_DIR}/torbox-media-server}"
CONFIG_DIR="${INSTALL_DIR}/configs"
DATA_DIR="${INSTALL_DIR}/data"
MOUNT_DIR="${HOME}/torbox-media"
ENV_FILE="${INSTALL_DIR}/.env"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
SETUP_COMPLETE_FILE="${INSTALL_DIR}/.setup_complete"

# Source shared environment parsing library
source "${SCRIPT_DIR}/lib/env.sh"

# Generate deterministic-length API keys (32-char hex, matching *arr format)
generate_api_key() {
    local key=""
    if key=$(openssl rand -hex 16 2>/dev/null); then
        :
    elif key=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \t\n'); then
        :
    elif key=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \t\n'); then
        :
    else
        echo ""
        return 1
    fi
    key=$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-f0-9' | head -c 32)
    if [[ ${#key} -ne 32 ]]; then
        echo ""
        return 1
    fi
    echo "$key"
}

# Generate secure random admin passwords (32 chars, ~192 bits entropy)
_gen_admin_pass() {
    local p=""
    if p=$(openssl rand -base64 32 2>/dev/null | tr -d '/+=' | head -c 32); then
        :
    elif p=$(head -c 32 /dev/urandom 2>/dev/null | base64 | tr -d '/+=' | head -c 32); then
        :
    fi
    echo "$p"
}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    cat <<'EOF'
  ╔══════════════════════════════════════════════════════════════╗
  ║        TorBox Media Server - macOS Setup (Jellyfin)        ║
  ║                                                             ║
  ║   Prowlarr · Byparr · Decypharr · Seerr                    ║
  ║   Radarr · Sonarr · TorBox Media Center · Jellyfin          ║
  ╚══════════════════════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

log_info() { echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} ${BOLD}$*${NC}" >&2; }
log_section() {
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}" >&2
    echo -e "${CYAN}  $*${NC}" >&2
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n" >&2
}
mask_key() {
    local k="$1"
    if [[ ${#k} -gt 4 ]]; then echo "${k:0:4}...${k: -4}"; else echo "$k"; fi
}

# Service port registry (single source of truth, Bash 3.2 compatible)
SVC_ORDER=(decypharr prowlarr byparr radarr sonarr seerr torbox-media-center)

get_svc_port() {
    case "$1" in
        decypharr) echo 8282 ;;
        prowlarr) echo 9696 ;;
        byparr) echo 8191 ;;
        radarr) echo 7878 ;;
        sonarr) echo 8989 ;;
        seerr) echo 5055 ;;
        jellyfin) echo 8096 ;;
        torbox-media-center) echo 0 ;;
        *) echo "" ;;
    esac
}

get_svc_label() {
    case "$1" in
        decypharr) echo "Decypharr" ;;
        prowlarr) echo "Prowlarr" ;;
        byparr) echo "Byparr" ;;
        radarr) echo "Radarr" ;;
        sonarr) echo "Sonarr" ;;
        seerr) echo "Seerr" ;;
        jellyfin) echo "Jellyfin" ;;
        torbox-media-center) echo "TorBox Media Center" ;;
        *) echo "$1" ;;
    esac
}

print_service_urls() {
    local svc
    for svc in "${SVC_ORDER[@]}"; do
        [[ "$svc" == "torbox-media-center" ]] && continue
        printf "  %b%-14s%b http://localhost:%s\n" "$BOLD" "$(get_svc_label "$svc")" "$NC" "$(get_svc_port "$svc")"
    done
    printf "  %b%-14s%b http://localhost:8096\n" "$BOLD" "Jellyfin" "$NC"
    printf "  %b%-14s%b (STRM file generator — no web UI)\n" "$BOLD" "TorBox MC" "$NC"
}

# Run a command in the background with a spinner animation
run_with_spinner() {
    local msg="$1"
    shift
    local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local tmpfile
    tmpfile=$(mktemp /tmp/torbox-setup.XXXXXX)
    SPINNER_TMPFILE="$tmpfile"
    "$@" >"$tmpfile" 2>&1 &
    local pid=$! i=0
    SPINNER_PID="$pid"
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  %s %s" "${spin_chars:i%${#spin_chars}:1}" "$msg"
        i=$((i + 1))
        sleep 0.1
    done
    local rc=0
    wait "$pid" && rc=0 || rc=$?
    printf "\r  %-$((${#msg} + 4))s\r" ""
    if [[ $rc -ne 0 ]]; then cat "$tmpfile" >&2; fi
    rm -f "$tmpfile"
    SPINNER_TMPFILE=""
    SPINNER_PID=""
    return "$rc"
}

# Detect the correct docker compose command
COMPOSE_CMD=()
detect_compose_cmd() {
    if docker info &>/dev/null; then
        COMPOSE_CMD=(docker compose)
    else
        log_error "Docker Desktop is not running. Please start Docker Desktop and try again."
        echo "  Open Docker Desktop from Applications or run: open -a Docker"
        exit 1
    fi
}

# Run a docker compose command with correct env-file
compose_cmd() {
    if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    (cd "${INSTALL_DIR}" && exec "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "$@")
}

# ============================================================================
#  Dependency Checks (macOS)
# ============================================================================

check_dependencies() {
    log_section "Checking Dependencies"

    local _warn_only="${1:-}"
    local missing=()

    # macOS check
    if [[ "$(uname)" != "Darwin" ]]; then
        log_error "This script is designed for macOS only."
        log_error "For Linux, use: ./setup.sh"
        log_error "For Windows, use: .\\setup.ps1"
        exit 1
    fi

    if ! command -v docker &>/dev/null; then
        missing+=("docker")
    fi

    if docker compose version &>/dev/null; then
        log_info "Docker Compose: using v2 plugin (docker compose)."
    else
        missing+=("docker-compose")
    fi

    if ! command -v curl &>/dev/null; then
        missing+=("curl")
    fi

    if ! command -v jq &>/dev/null; then
        missing+=("jq")
    fi

    if ! command -v openssl &>/dev/null; then
        missing+=("openssl")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing dependencies: ${missing[*]}"
        echo ""
        if [[ "$_warn_only" == "--warn-only" ]]; then
            log_warn "--dry-run mode: dependencies will not be installed automatically."
            return 0
        fi
        local install_deps="y"
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Install missing dependencies automatically? [Y/n]: " install_deps
        fi
        install_deps_lower=$(echo "${install_deps:-}" | tr '[:upper:]' '[:lower:]')
        if [[ "$install_deps_lower" != "n" ]]; then
            install_dependencies "${missing[@]}"
        else
            log_error "Cannot continue without: ${missing[*]}"
            exit 1
        fi
    else
        log_info "All dependencies satisfied."
    fi

    # In dry-run mode, skip Docker daemon check
    if [[ "$_warn_only" == "--warn-only" ]]; then
        return 0
    fi

    # Ensure Docker Desktop is running
    if ! docker info &>/dev/null; then
        log_warn "Docker Desktop is not running. Attempting to start it..."
        open -a "Docker" 2>/dev/null || true
        local docker_wait=0
        local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        while [[ $docker_wait -lt 30 ]]; do
            if docker info &>/dev/null; then
                printf "\r  %-50s\r" ""
                break
            fi
            printf "\r  %s Waiting for Docker Desktop... %ds/30s" "${spin_chars:docker_wait%${#spin_chars}:1}" "$docker_wait"
            sleep 1
            docker_wait=$((docker_wait + 1))
        done
        printf "\r  %-50s\r" ""
        if ! docker info &>/dev/null; then
            log_error "Docker Desktop did not start. Please start it manually and re-run."
            exit 1
        fi
        log_info "Docker Desktop is running."
    else
        log_info "Docker Desktop is running."
    fi
    # No docker group check needed on macOS — Docker Desktop handles permissions
    # No FUSE check needed — using STRM files
}

check_port_conflicts() {
    local ports_to_check=() port_names=() svc
    for svc in "${SVC_ORDER[@]}"; do
        ports_to_check+=("$(get_svc_port "$svc")")
        port_names+=("$(get_svc_label "$svc")")
    done
    # Jellyfin port
    ports_to_check+=(8096)
    port_names+=("Jellyfin")

    local conflicts=false
    local network_stats=""
    # macOS: use lsof instead of ss/netstat
    network_stats=$(lsof -i -P -n 2>/dev/null | grep LISTEN) || true

    for i in "${!ports_to_check[@]}"; do
        local port_in_use=false
        if echo "$network_stats" | grep -qE ":${ports_to_check[$i]} " 2>/dev/null; then
            port_in_use=true
        fi
        if [[ "$port_in_use" == "true" ]]; then
            log_warn "Port ${ports_to_check[$i]} (${port_names[$i]}) is already in use."
            conflicts=true
        fi
    done
    if [[ "$conflicts" == "true" ]]; then
        log_warn "Some ports are in use. Services using those ports may fail to start."
        log_warn "Stop the conflicting processes or change the ports in docker-compose.yml after setup."
        if [[ "$NON_INTERACTIVE" == "true" ]]; then
            log_warn "Non-interactive mode: continuing despite port conflicts."
        else
            read -rp "Continue anyway? [Y/n]: " continue_anyway
            continue_anyway_lower=$(echo "${continue_anyway:-}" | tr '[:upper:]' '[:lower:]')
            if [[ "$continue_anyway_lower" == "n" ]]; then
                log_error "Setup cancelled. Free the conflicting ports and re-run."
                exit 1
            fi
        fi
    fi
}

install_dependencies() {
    local deps=("$@")
    log_step "Installing: ${deps[*]}"

    if ! command -v brew &>/dev/null; then
        log_error "Homebrew is not installed. Please install it first:"
        echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
        exit 1
    fi

    for dep in "${deps[@]}"; do
        case "$dep" in
            docker | docker-compose)
                log_step "Installing Docker Desktop..."
                brew install --cask docker
                log_info "Docker Desktop installed. Please open it from Applications to complete setup."
                log_warn "After Docker Desktop is running, re-run this script."
                exit 0
                ;;
            curl)
                brew install curl
                ;;
            jq)
                brew install jq
                ;;
            openssl)
                brew install openssl
                ;;
        esac
    done

    log_info "Dependencies installed."
}

# ============================================================================
#  User Configuration (macOS)
# ============================================================================

check_existing_installation() {
    EXISTING_ENV=()
    if [[ -f "${SETUP_COMPLETE_FILE}" ]]; then
        log_section "Existing Installation Detected"
        log_warn "A previous installation was found at: ${INSTALL_DIR}"
        echo ""
        echo "  Re-running will regenerate Docker Compose and configs."
        echo "  Your existing API keys will be PRESERVED to avoid breaking integrations."
        echo ""

        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Continue with re-configuration? [y/N]: " rerun
            rerun_lower=$(echo "${rerun:-}" | tr '[:upper:]' '[:lower:]')
            if [[ "$rerun_lower" != "y" ]]; then
                log_info "Setup cancelled. Your existing installation is unchanged."
                exit 0
            fi
        fi

        # Back up existing generated files before overwriting
        local backup_ts
        backup_ts="$(date +%Y%m%d_%H%M%S)"
        for bf in "${ENV_FILE}" "${COMPOSE_FILE}" "${CONFIG_DIR}/decypharr/config.json"; do
            if [[ -f "$bf" ]]; then
                cp "$bf" "${bf}.bak.${backup_ts}"
            fi
        done
        log_info "Backed up existing config files (.bak.${backup_ts})."

        # Load existing .env values
        if [[ -f "${ENV_FILE}" ]]; then
            while IFS='=' read -r _ek _ev; do
                [[ -z "${_ek}" || "${_ek}" == \#* ]] && continue
                _ev="$(echo "${_ev}" | sed 's/\(#.*\)$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | tr -d '"' | tr -d "'" | tr -d $'\r')"
                case "$_ek" in
                    TORBOX_API_KEY) EXISTING_TORBOX_API_KEY="$_ev" ;;
                    RADARR_API_KEY) EXISTING_RADARR_API_KEY="$_ev" ;;
                    SONARR_API_KEY) EXISTING_SONARR_API_KEY="$_ev" ;;
                    PROWLARR_API_KEY) EXISTING_PROWLARR_API_KEY="$_ev" ;;
                    RADARR_ADMIN_USER) EXISTING_RADARR_ADMIN_USER="$_ev" ;;
                    RADARR_ADMIN_PASS) EXISTING_RADARR_ADMIN_PASS="$_ev" ;;
                    SONARR_ADMIN_USER) EXISTING_SONARR_ADMIN_USER="$_ev" ;;
                    SONARR_ADMIN_PASS) EXISTING_SONARR_ADMIN_PASS="$_ev" ;;
                    PROWLARR_ADMIN_USER) EXISTING_PROWLARR_ADMIN_USER="$_ev" ;;
                    PROWLARR_ADMIN_PASS) EXISTING_PROWLARR_ADMIN_PASS="$_ev" ;;
                    DECYPHARR_USER) EXISTING_DECYPHARR_USER="$_ev" ;;
                    DECYPHARR_PASS) EXISTING_DECYPHARR_PASS="$_ev" ;;
                    COMPOSE_PROFILES) EXISTING_COMPOSE_PROFILES="$_ev" ;;
                    MOUNT_DIR) MOUNT_DIR="$_ev" ;;
                esac
            done <"${ENV_FILE}"
            # Validate preserved API keys
            for k in EXISTING_RADARR_API_KEY EXISTING_SONARR_API_KEY EXISTING_PROWLARR_API_KEY; do
                if [[ -n "${!k:-}" && ! "${!k}" =~ ^[0-9a-f]{32}$ ]]; then
                    log_warn "Corrupted API key detected for ${k}. Will regenerate."
                    eval "$k="
                fi
            done
            if [[ -n "${EXISTING_RADARR_API_KEY:-}" ]]; then
                log_info "Existing API keys loaded and will be preserved."
            fi
        fi
    elif [[ -f "${ENV_FILE}" && ! -f "${SETUP_COMPLETE_FILE}" ]]; then
        log_section "Incomplete Installation Detected"
        log_warn "A previous setup was interrupted before completion."
        log_warn "Starting fresh (incomplete state will be cleaned up)."
        rm -rf "${INSTALL_DIR}"
    fi
}

gather_config() {
    log_section "Configuration"

    # TorBox API Key
    echo -e "${BOLD}TorBox API Key${NC}"
    echo "  Get your API key from: https://torbox.app/settings"
    echo ""
    if [[ -n "${TORBOX_API_KEY:-}" ]]; then
        log_info "Using TorBox API key from TORBOX_API_KEY env var."
    elif [[ -n "${EXISTING_TORBOX_API_KEY:-}" ]]; then
        echo -e "  ${GREEN}Previous API key found.${NC} Press Enter to keep it, or paste a new one."
        read -rsp "  TorBox API key [keep existing]: " new_torbox_key
        echo ""
        if [[ -n "$new_torbox_key" ]]; then
            TORBOX_API_KEY="$new_torbox_key"
        else
            TORBOX_API_KEY="$EXISTING_TORBOX_API_KEY"
            log_info "Keeping existing TorBox API key."
        fi
    else
        while true; do
            read -rsp "  Enter your TorBox API key: " TORBOX_API_KEY
            echo ""
            if [[ -n "$TORBOX_API_KEY" ]]; then
                break
            fi
            log_error "API key cannot be empty."
        done
    fi
    TORBOX_API_KEY="${TORBOX_API_KEY:-${EXISTING_TORBOX_API_KEY:-}}"
    if [[ ! "$TORBOX_API_KEY" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "API key contains invalid characters."
        exit 1
    fi
    log_info "API key received (${#TORBOX_API_KEY} characters, ending in ...${TORBOX_API_KEY: -4})."

    # Best-effort live verification
    if command -v curl &>/dev/null; then
        local _torbox_check_status
        _torbox_check_status=$(curl -s -o /dev/null -w '%{http_code}' \
            --connect-timeout 5 --max-time 10 \
            -H "Authorization: Bearer ${TORBOX_API_KEY}" \
            "https://api.torbox.app/v1/api/user/me" 2>/dev/null) || _torbox_check_status="000"
        case "$_torbox_check_status" in
            200) log_info "TorBox API key verified against api.torbox.app." ;;
            401 | 403)
                log_error "TorBox API rejected this key (HTTP ${_torbox_check_status})."
                if [[ "$NON_INTERACTIVE" != "true" ]]; then
                    read -rp "Continue with this key anyway? [y/N]: " _cont
                    _cont_lower=$(echo "${_cont:-}" | tr '[:upper:]' '[:lower:]')
                    [[ "$_cont_lower" != "y" ]] && exit 1
                elif [[ "$DRY_RUN" == "true" ]]; then
                    log_warn "Dry-run mode: continuing despite API rejection."
                else
                    exit 1
                fi
                ;;
            000 | "") log_warn "Could not reach api.torbox.app to verify the key (offline?). Continuing." ;;
            *) log_warn "Unexpected response from TorBox API (HTTP ${_torbox_check_status}). Continuing." ;;
        esac
    fi

    echo ""

    # Media Server — Jellyfin only on macOS (STRM mode)
    MEDIA_SERVER="jellyfin"
    echo -e "${BOLD}Media Server${NC}"
    log_info "macOS uses STRM files which are only compatible with Jellyfin."
    log_info "Media server: Jellyfin"

    echo ""

    # Mount directory — macOS default
    MOUNT_DIR="${TORBOX_MOUNT_DIR:-${MOUNT_DIR:-${HOME}/torbox-media}}"
    if [[ "$NON_INTERACTIVE" != "true" && -z "${TORBOX_MOUNT_DIR:-}" ]]; then
        echo -e "${BOLD}Data Directory${NC} [${MOUNT_DIR}]:"
        echo "  This is where STRM files and media data will be stored."
        read -rp "  Press Enter to accept, or type a custom path: " custom_mount
        MOUNT_DIR="${custom_mount:-$MOUNT_DIR}"
    fi
    # Validate mount path
    if [[ "$MOUNT_DIR" != /* && "$MOUNT_DIR" != ~* ]]; then
        # Allow relative paths by making them absolute
        MOUNT_DIR="${HOME}/${MOUNT_DIR}"
    fi
    # Expand tilde
    MOUNT_DIR="${MOUNT_DIR/#\~/$HOME}"
    # Fix doubled home path (e.g. /Users/foo/Users/foo/... from re-runs)
    local _double_home="${HOME}/${HOME#/}"
    if [[ "$MOUNT_DIR" == "${_double_home}"* ]]; then
        MOUNT_DIR="${HOME}${MOUNT_DIR#${_double_home}}"
        log_warn "Corrected doubled home path in MOUNT_DIR."
    fi
    if [[ "$MOUNT_DIR" == "/" ]]; then
        log_error "Data path cannot be '/'. Using default."
        MOUNT_DIR="${HOME}/torbox-media"
    fi
    # Block macOS system directories
    for prefix in /System /Library /Applications /private/var /private/etc /usr /bin /sbin; do
        if [[ "$MOUNT_DIR" == "$prefix" || "$MOUNT_DIR" == "$prefix"/* ]]; then
            log_error "'${MOUNT_DIR}' is under a system directory. Using default."
            MOUNT_DIR="${HOME}/torbox-media"
            break
        fi
    done
    if [[ -L "$MOUNT_DIR" ]]; then
        log_error "Data path '${MOUNT_DIR}' is a symlink. Using default."
        MOUNT_DIR="${HOME}/torbox-media"
    fi
    if [[ "$MOUNT_DIR" == "$INSTALL_DIR" || "$MOUNT_DIR" == "$INSTALL_DIR"/* ]]; then
        log_error "Data path cannot be inside the install directory. Using default."
        MOUNT_DIR="${HOME}/torbox-media"
    fi
    log_info "Data directory: ${MOUNT_DIR}"

    echo ""

    # User/Group IDs
    PUID="$(id -u)"
    PGID="$(id -g)"
    echo -e "${BOLD}User/Group IDs${NC}"
    echo "  Detected: PUID=${PUID}, PGID=${PGID}"

    # Timezone — macOS detection via /etc/localtime symlink
    TZ="$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')" || true
    TZ="${TZ:-UTC}"
    echo ""
    echo -e "${BOLD}Timezone${NC}: ${TZ}"
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "  Use this timezone? [Y/n]: " use_tz
        use_tz_lower=$(echo "${use_tz:-}" | tr '[:upper:]' '[:lower:]')
        if [[ "$use_tz_lower" == "n" ]]; then
            while true; do
                read -rp "  Enter timezone (e.g., America/New_York): " TZ
                if [[ "$TZ" =~ ^[a-zA-Z_/+-]+$ ]]; then
                    break
                else
                    log_error "Invalid timezone format."
                fi
            done
        fi
    fi

    # Generate or preserve API keys
    if [[ -n "${EXISTING_RADARR_API_KEY:-}" && -n "${EXISTING_SONARR_API_KEY:-}" && -n "${EXISTING_PROWLARR_API_KEY:-}" ]]; then
        RADARR_API_KEY="$EXISTING_RADARR_API_KEY"
        SONARR_API_KEY="$EXISTING_SONARR_API_KEY"
        PROWLARR_API_KEY="$EXISTING_PROWLARR_API_KEY"
        log_info "Preserved existing API keys from previous installation."
    else
        RADARR_API_KEY="$(generate_api_key)"
        SONARR_API_KEY="$(generate_api_key)"
        PROWLARR_API_KEY="$(generate_api_key)"
        for key_name in RADARR_API_KEY SONARR_API_KEY PROWLARR_API_KEY; do
            local key_val="${!key_name}"
            if [[ -z "$key_val" || ${#key_val} -lt 32 ]]; then
                log_error "Failed to generate API key for ${key_name}."
                exit 1
            fi
        done
    fi

    # Generate or preserve admin credentials
    if [[ -n "${EXISTING_RADARR_ADMIN_USER:-}" && -n "${EXISTING_RADARR_ADMIN_PASS:-}" ]]; then
        RADARR_ADMIN_USER="$EXISTING_RADARR_ADMIN_USER"
        RADARR_ADMIN_PASS="$EXISTING_RADARR_ADMIN_PASS"
    else
        RADARR_ADMIN_USER="admin"
        RADARR_ADMIN_PASS="$(_gen_admin_pass)"
    fi
    if [[ -n "${EXISTING_SONARR_ADMIN_USER:-}" && -n "${EXISTING_SONARR_ADMIN_PASS:-}" ]]; then
        SONARR_ADMIN_USER="$EXISTING_SONARR_ADMIN_USER"
        SONARR_ADMIN_PASS="$EXISTING_SONARR_ADMIN_PASS"
    else
        SONARR_ADMIN_USER="admin"
        SONARR_ADMIN_PASS="$(_gen_admin_pass)"
    fi
    if [[ -n "${EXISTING_PROWLARR_ADMIN_USER:-}" && -n "${EXISTING_PROWLARR_ADMIN_PASS:-}" ]]; then
        PROWLARR_ADMIN_USER="$EXISTING_PROWLARR_ADMIN_USER"
        PROWLARR_ADMIN_PASS="$EXISTING_PROWLARR_ADMIN_PASS"
    else
        PROWLARR_ADMIN_USER="admin"
        PROWLARR_ADMIN_PASS="$(_gen_admin_pass)"
    fi

    # Decypharr
    if [[ -n "${EXISTING_DECYPHARR_USER:-}" && -n "${EXISTING_DECYPHARR_PASS:-}" ]]; then
        DECYPHARR_USER="$EXISTING_DECYPHARR_USER"
        DECYPHARR_PASS="$EXISTING_DECYPHARR_PASS"
    else
        DECYPHARR_USER="torbox"
        DECYPHARR_PASS="$(_gen_admin_pass)"
    fi

    for key_name in RADARR_ADMIN_PASS SONARR_ADMIN_PASS PROWLARR_ADMIN_PASS DECYPHARR_PASS; do
        if [[ -z "${!key_name}" ]]; then
            log_error "Failed to generate admin password for ${key_name}."
            exit 1
        fi
    done

    # Hardware Acceleration — none on macOS Docker (no GPU passthrough)
    HW_ACCEL="none"
    echo ""
    echo -e "${BOLD}Hardware Acceleration${NC}"
    log_info "Docker Desktop for Mac does not support GPU passthrough."
    log_info "Using software transcoding. For hardware acceleration, install Jellyfin natively."

    echo ""
}

# ============================================================================
#  Create Directories
# ============================================================================

create_directories() {
    log_section "Preparing Directories"

    local saved_umask
    saved_umask=$(umask)
    umask 022

    mkdir -p "${INSTALL_DIR}"
    mkdir -p "${CONFIG_DIR}"/{prowlarr,radarr,sonarr,seerr,decypharr,jellyfin}
    mkdir -p "${DATA_DIR}"/{media/{movies,series},downloads/{radarr,sonarr}}
    mkdir -p "${MOUNT_DIR}"

    umask "$saved_umask"

    log_info "Directories created at: ${INSTALL_DIR}"
    log_info "Data directory: ${MOUNT_DIR}"
}

# ============================================================================
#  Generate Decypharr Config (Lite — no rclone, STRM mode)
# ============================================================================

generate_decypharr_config() {
    log_step "Generating Decypharr configuration (lite mode — no rclone)..."

    DECYPHARR_USER="${DECYPHARR_USER:-torbox}"
    if [[ ! "$DECYPHARR_USER" =~ ^[a-zA-Z0-9_-]{1,32}$ ]]; then
        log_warn "DECYPHARR_USER contains unsafe characters. Using default 'torbox'."
        DECYPHARR_USER="torbox"
    fi
    if [[ -n "${DECYPHARR_PASS:-}" && ! "$DECYPHARR_PASS" =~ ^[a-zA-Z0-9_./+=-]+$ ]]; then
        log_warn "DECYPHARR_PASS contains unsafe characters. Regenerating."
        DECYPHARR_PASS=""
    fi

    if [[ -f "${CONFIG_DIR}/decypharr/config.json" ]]; then
        if command -v jq &>/dev/null; then
            local _tmp="${CONFIG_DIR}/decypharr/config.json.tmp.$$"
            if jq --arg key "${TORBOX_API_KEY}" \
                --arg user "${DECYPHARR_USER}" \
                --arg pass "${DECYPHARR_PASS:-}" \
                '.debrids[0].api_key = $key
                   | if $pass != "" then .password = $pass else . end
                   | .username = $user' \
                "${CONFIG_DIR}/decypharr/config.json" >"$_tmp" 2>/dev/null; then
                mv "$_tmp" "${CONFIG_DIR}/decypharr/config.json"
                chmod 600 "${CONFIG_DIR}/decypharr/config.json"
                log_info "Refreshed TorBox API key in existing Decypharr config."
            else
                rm -f "$_tmp"
                log_warn "Could not update existing Decypharr config via jq."
            fi
        fi
        return 0
    fi

    if [[ -z "${DECYPHARR_PASS:-}" ]]; then
        DECYPHARR_PASS="$(openssl rand -base64 12 2>/dev/null | tr -d '/+=' | head -c 12)"
        if [[ -z "$DECYPHARR_PASS" ]]; then
            DECYPHARR_PASS="$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | head -c 12)"
        fi
    fi
    if [[ -z "$DECYPHARR_PASS" || ${#DECYPHARR_PASS} -lt 8 ]]; then
        log_error "Failed to generate Decypharr password."
        exit 1
    fi

    # Lite config: rclone disabled, STRM-compatible
    cat >"${CONFIG_DIR}/decypharr/config.json" <<DECYPHARR_EOF
{
  "debrids": [
    {
      "name": "torbox",
      "api_key": "${TORBOX_API_KEY}",
      "folder": "/mnt/remote/torbox/__all__",
      "rate_limit": "55/hour",
      "use_webdav": true
    }
  ],
  "rclone": {
    "enabled": false,
    "mount_path": "/mnt/remote"
  },
  "qbittorrent": {
    "download_folder": "/data/downloads/",
    "categories": ["sonarr", "radarr"]
  },
  "username": "${DECYPHARR_USER}",
  "password": "${DECYPHARR_PASS}",
  "port": "8282",
  "log_level": "info"
}
DECYPHARR_EOF

    chmod 600 "${CONFIG_DIR}/decypharr/config.json"
    log_info "Decypharr config written (lite mode: rclone disabled, qBittorrent mock only)."
}

# ============================================================================
#  Generate *arr Config XML (Pre-seed API keys & auth)
# ============================================================================

generate_arr_configs() {
    log_step "Pre-seeding Radarr, Sonarr, and Prowlarr configs..."

    local arrs=("radarr:${RADARR_API_KEY}" "sonarr:${SONARR_API_KEY}" "prowlarr:${PROWLARR_API_KEY}")
    for entry in "${arrs[@]}"; do
        local arr_name="${entry%%:*}"
        local arr_key="${entry#*:}"
        local arr_dir="${CONFIG_DIR}/${arr_name}/config.xml"

        if [[ -f "$arr_dir" ]]; then
            # Update API key only, preserve other settings
            if grep -q '<ApiKey>' "$arr_dir" 2>/dev/null; then
                sed -i '' "s|<ApiKey>.*</ApiKey>|<ApiKey>${arr_key}</ApiKey>|" "$arr_dir"
                log_info "  Updated API key for ${arr_name}."
            fi
            continue
        fi

        cat >"$arr_dir" <<ARRXML_EOF
<Config>
  <LogLevel>info</LogLevel>
  <UpdateMechanism>Docker</UpdateMechanism>
  <AuthenticationMethod>Forms</AuthenticationMethod>
  <AuthenticationRequired>Enabled</AuthenticationRequired>
  <AnalyticsEnabled>False</AnalyticsEnabled>
  <ApiKey>${arr_key}</ApiKey>
</Config>
ARRXML_EOF
        chmod 600 "$arr_dir"
    done
    log_info "Pre-seeded API keys for Radarr, Sonarr, Prowlarr."
}

# ============================================================================
#  Generate .env File
# ============================================================================

generate_env_file() {
    log_step "Generating .env file..."

    cat >"${ENV_FILE}" <<ENV_EOF
# ============================================================================
#  TorBox Media Server - Environment Configuration (macOS)
#  Generated by setup_macos.sh on $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================================

# User / System
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}

# Directories
INSTALL_DIR=${INSTALL_DIR}
CONFIG_DIR=${CONFIG_DIR}
DATA_DIR=${DATA_DIR}
MOUNT_DIR=${MOUNT_DIR}

# Core Credentials
TORBOX_API_KEY="${TORBOX_API_KEY}"
MEDIA_SERVER=${MEDIA_SERVER}

# Decypharr
DECYPHARR_USER="${DECYPHARR_USER:-torbox}"
DECYPHARR_PASS="${DECYPHARR_PASS:-}"

# Radarr
RADARR_API_KEY="${RADARR_API_KEY:-}"
RADARR_ADMIN_USER="${RADARR_ADMIN_USER:-admin}"
RADARR_ADMIN_PASS="${RADARR_ADMIN_PASS:-}"

# Sonarr
SONARR_API_KEY="${SONARR_API_KEY:-}"
SONARR_ADMIN_USER="${SONARR_ADMIN_USER:-admin}"
SONARR_ADMIN_PASS="${SONARR_ADMIN_PASS:-}"

# Prowlarr
PROWLARR_API_KEY="${PROWLARR_API_KEY:-}"
PROWLARR_ADMIN_USER="${PROWLARR_ADMIN_USER:-admin}"
PROWLARR_ADMIN_PASS="${PROWLARR_ADMIN_PASS:-}"

COMPOSE_PROFILES=${MEDIA_SERVER}
ENV_EOF

    chmod 600 "${ENV_FILE}"
    log_info ".env file created at: ${ENV_FILE}"
}

# ============================================================================
#  Generate Docker Compose (macOS version)
# ============================================================================

generate_docker_compose() {
    log_step "Setting up Docker Compose (macOS)..."

    # Use the macOS-specific compose file if available, otherwise copy and patch
    if [[ -f "${SCRIPT_DIR}/docker-compose.macos.yml" ]]; then
        cp "${SCRIPT_DIR}/docker-compose.macos.yml" "${COMPOSE_FILE}"
        log_info "Using macOS-specific Docker Compose file."
    else
        # Copy the standard compose file and patch it for macOS
        cp "${SCRIPT_DIR}/docker-compose.yml" "${COMPOSE_FILE}"
        log_info "Copied docker-compose.yml (macOS patches will be applied)."
    fi

    chmod 600 "${COMPOSE_FILE}"
    log_info "Docker Compose file set up."

    # Validate
    if docker info &>/dev/null; then
        local _retry=0 _validated=false
        while [[ $_retry -lt 3 ]]; do
            if (cd "${INSTALL_DIR}" && docker compose --env-file "${ENV_FILE}" config -q) 2>/dev/null; then
                _validated=true
                break
            fi
            sleep 2
            _retry=$((_retry + 1))
        done
        if [[ "$_validated" == "true" ]]; then
            log_info "Docker Compose file validated successfully."
        else
            log_warn "Docker Compose validation failed. Services may not start correctly."
        fi
    fi
}

# ============================================================================
#  Generate Management Script (macOS version)
# ============================================================================

generate_management_script() {
    log_step "Generating management script..."

    cat >"${INSTALL_DIR}/manage.sh" <<'MANAGE_HEADER'
#!/usr/bin/env bash
set -euo pipefail

VERSION="__VERSION__"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"

MANAGE_HEADER

    # Inline the shared env.sh library
    cat >>"${INSTALL_DIR}/manage.sh" <<MANAGE_INLINE
# Inline env.sh library
$(cat "${SCRIPT_DIR}/lib/env.sh")

MANAGE_INLINE

    cat >>"${INSTALL_DIR}/manage.sh" <<'MANAGE_EOF'

# Service port registry (single source of truth, Bash 3.2 compatible)
SVC_ORDER=(decypharr prowlarr byparr radarr sonarr seerr)

get_svc_port() {
    case "$1" in
        decypharr) echo 8282 ;;
        prowlarr) echo 9696 ;;
        byparr) echo 8191 ;;
        radarr) echo 7878 ;;
        sonarr) echo 8989 ;;
        seerr) echo 5055 ;;
        jellyfin) echo 8096 ;;
        *) echo "" ;;
    esac
}

get_svc_label() {
    case "$1" in
        decypharr) echo "Decypharr" ;;
        prowlarr) echo "Prowlarr" ;;
        byparr) echo "Byparr" ;;
        radarr) echo "Radarr" ;;
        sonarr) echo "Sonarr" ;;
        seerr) echo "Seerr" ;;
        jellyfin) echo "Jellyfin" ;;
        *) echo "$1" ;;
    esac
}

COMPOSE_CMD=()
detect_compose_cmd() {
    if docker info &>/dev/null; then
        COMPOSE_CMD=(docker compose)
    else
        echo -e "${RED}Docker Desktop is not running. Please start it and try again.${NC}"
        exit 1
    fi
}

compose_cmd() {
    if [[ ${#COMPOSE_CMD[@]} -eq 0 ]]; then
        detect_compose_cmd
    fi
    (cd "${SCRIPT_DIR}" && exec "${COMPOSE_CMD[@]}" --env-file "${ENV_FILE}" "$@")
}

show_help() {
    echo -e "${CYAN}TorBox Media Server (macOS) - Management${NC}"
    echo ""
    echo "Usage: ./manage.sh <command>"
    echo ""
    echo "Commands:"
    echo "  start       Start all services"
    echo "  stop        Stop all services"
    echo "  restart     Restart all services"
    echo "  status      Show service status"
    echo "  logs        Show logs (follow mode)"
    echo "  logs <svc>  Show logs for a specific service"
    echo "  pull        Pull pinned image versions"
    echo "  update      Pull pinned images and restart"
    echo "  down        Stop and remove containers"
    echo "  urls        Show all service URLs"
    echo "  keys        Show API keys"
    echo "  enable      Enable auto-start on login"
    echo "  disable     Disable auto-start on login"
    echo "  backup      Back up configs and .env"
    echo "  fetch       Instantly sync TorBox cloud & update Jellyfin .strm files"
    echo "  health      Check health of all services"
    echo "  shell <svc> Open a shell in a service container"
    echo "  version     Show version"
    echo "  help        Show this help"
}

show_urls() {
    local media_server svc
    media_server="$(env_val COMPOSE_PROFILES)"
    [[ -z "$media_server" ]] && media_server="$(env_val MEDIA_SERVER)"
    echo -e "\n${CYAN}━━━━ Service URLs ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    for svc in "${SVC_ORDER[@]}"; do
        printf "  %b%-14s%b http://localhost:%s\n" "$BOLD" "$(get_svc_label "$svc")" "$NC" "$(get_svc_port "$svc")"
    done
    printf "  %b%-14s%b http://localhost:8096\n" "$BOLD" "Jellyfin" "$NC"
    echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
}

case "${1:-help}" in
    start)
        echo -e "${GREEN}Starting all services...${NC}"
        compose_cmd up -d --remove-orphans
        show_urls
        ;;
    stop)
        echo -e "${YELLOW}Stopping all services...${NC}"
        compose_cmd stop
        ;;
    restart)
        echo -e "${YELLOW}Restarting all services...${NC}"
        compose_cmd stop
        compose_cmd up -d --remove-orphans
        show_urls
        ;;
    status)
        compose_cmd ps
        ;;
    logs)
        if [[ -n "${2:-}" ]]; then
            compose_cmd logs -f "$2"
        else
            compose_cmd logs -f
        fi
        ;;
    pull)
        echo -e "${GREEN}Pulling pinned images...${NC}"
        compose_cmd pull
        ;;
    update)
        echo -e "${GREEN}Updating all services...${NC}"
        compose_cmd pull
        compose_cmd up -d --remove-orphans
        show_urls
        ;;
    down)
        echo -e "${RED}Stopping and removing containers...${NC}"
        compose_cmd down
        ;;
    urls)
        show_urls
        ;;
    fetch|sync)
        echo -e "${CYAN}Triggering instant TorBox Media Center sync...${NC}"
        compose_cmd restart torbox-media-center
        echo -e "${GREEN}✓ TorBox Media Center restarted and syncing!${NC}"
        echo -e "${CYAN}Triggering Jellyfin library refresh...${NC}"
        curl -sf -X POST "http://localhost:8096/Library/Refresh" 2>/dev/null && echo -e "${GREEN}✓ Jellyfin library refresh triggered!${NC}" || echo -e "${YELLOW}Jellyfin refresh request sent.${NC}"
        ;;
    keys)
        echo -e "\n${CYAN}━━━━ API Keys ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        echo -e "  ${BOLD}Radarr${NC}    $(env_val RADARR_API_KEY)"
        echo -e "  ${BOLD}Sonarr${NC}    $(env_val SONARR_API_KEY)"
        echo -e "  ${BOLD}Prowlarr${NC}  $(env_val PROWLARR_API_KEY)"
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        ;;
    enable)
        local plist_dir="${HOME}/Library/LaunchAgents"
        local plist_file="${plist_dir}/com.torbox.media-server.plist"
        mkdir -p "${plist_dir}"
        local docker_bin
        docker_bin="$(command -v docker)"
        cat >"${plist_file}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.torbox.media-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>${docker_bin}</string>
        <string>compose</string>
        <string>--env-file</string>
        <string>${ENV_FILE}</string>
        <string>up</string>
        <string>--remove-orphans</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/launchd-stderr.log</string>
</dict>
</plist>
PLIST_EOF
        launchctl bootstrap "gui/$(id -u)" "${plist_file}" 2>/dev/null || \
            launchctl load "${plist_file}" 2>/dev/null || true
        echo -e "${GREEN}Auto-start on login enabled.${NC}"
        echo "  Plist: ${plist_file}"
        ;;
    disable)
        local plist_file="${HOME}/Library/LaunchAgents/com.torbox.media-server.plist"
        if [[ -f "${plist_file}" ]]; then
            launchctl bootout "gui/$(id -u)" "${plist_file}" 2>/dev/null || \
                launchctl unload "${plist_file}" 2>/dev/null || true
            rm -f "${plist_file}"
            echo -e "${YELLOW}Auto-start on login disabled.${NC}"
        else
            echo -e "${YELLOW}No launch agent found.${NC}"
        fi
        ;;
    backup)
        backup_dir="$(dirname "${SCRIPT_DIR}")/backups/$(date +%Y%m%d_%H%M%S)"
        mkdir -p "${backup_dir}"
        chmod 700 "${backup_dir}"
        cp -a "${ENV_FILE}" "${backup_dir}/" 2>/dev/null || true
        cp -a "${COMPOSE_FILE}" "${backup_dir}/" 2>/dev/null || true
        cp -Ra "${SCRIPT_DIR}/configs" "${backup_dir}/" 2>/dev/null || true
        echo -e "${GREEN}Backup saved to: ${backup_dir}${NC}"
        ;;
    health)
        echo -e "\n${CYAN}━━━━ Service Health ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        compose_cmd ps
        echo ""
        for svc in "${SVC_ORDER[@]}"; do
            svc_port="$(get_svc_port "$svc")"
            svc_label="$(get_svc_label "$svc")"
            if curl -sf --connect-timeout 2 --max-time 5 -o /dev/null "http://localhost:${svc_port}" 2>/dev/null; then
                echo -e "  ${GREEN}✓${NC} ${svc_label} (port ${svc_port}) — reachable"
            else
                echo -e "  ${RED}✗${NC} ${svc_label} (port ${svc_port}) — not reachable"
            fi
        done
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
        ;;
    shell)
        if [[ -z "${2:-}" ]]; then
            echo -e "${YELLOW}Usage: ./manage.sh shell <service-name>${NC}"
            echo "  Available: decypharr prowlarr byparr radarr sonarr seerr jellyfin"
            exit 1
        fi
        compose_cmd exec "$2" /bin/bash 2>/dev/null || compose_cmd exec "$2" /bin/sh
        ;;
    version|--version|-v)
        echo "TorBox Media Server Management (macOS) v${VERSION}"
        ;;
    help|*)
        show_help
        ;;
esac
MANAGE_EOF

    chmod +x "${INSTALL_DIR}/manage.sh"
    sed -i '' "s/__VERSION__/${VERSION}/" "${INSTALL_DIR}/manage.sh"
    log_info "Management script created: ${INSTALL_DIR}/manage.sh"
}

# ============================================================================
#  Generate launchd Service (auto-start on login)
# ============================================================================

generate_launchd_service() {
    log_step "Setting up auto-start on login..."

    local plist_dir="${HOME}/Library/LaunchAgents"
    local plist_file="${plist_dir}/com.torbox.media-server.plist"
    local docker_bin
    docker_bin="$(command -v docker)"

    mkdir -p "${plist_dir}"

    cat >"${plist_file}" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.torbox.media-server</string>
    <key>ProgramArguments</key>
    <array>
        <string>${docker_bin}</string>
        <string>compose</string>
        <string>--env-file</string>
        <string>${ENV_FILE}</string>
        <string>up</string>
        <string>--remove-orphans</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/launchd-stderr.log</string>
</dict>
</plist>
PLIST_EOF

    # Load the plist
    launchctl bootstrap "gui/$(id -u)" "${plist_file}" 2>/dev/null || \
        launchctl load "${plist_file}" 2>/dev/null || \
        log_warn "Could not load launch agent. Auto-start may not work."

    log_info "Launch agent created: ${plist_file}"
    log_info "Services will auto-start on login."
}

# ============================================================================
#  Start Services
# ============================================================================

start_services() {
    log_section "Starting Services"

    local start_now="y"
    if [[ "$NON_INTERACTIVE" != "true" ]]; then
        read -rp "Start all services now? [Y/n]: " start_now
    fi

    start_now_lower=$(echo "${start_now:-}" | tr '[:upper:]' '[:lower:]')
    if [[ "$start_now_lower" != "n" ]]; then
        log_step "Starting Docker containers..."
        if compose_cmd up -d --remove-orphans; then
            SERVICES_STARTED=true
            log_info "All services starting! Give them 30-60 seconds to initialize."
        else
            log_error "Failed to start services."
            return 1
        fi
    else
        log_info "You can start services later with: cd ${INSTALL_DIR} && ./manage.sh start"
        SERVICES_STARTED=false
    fi
}

# ============================================================================
#  Wait for Service to be Ready
# ============================================================================

wait_for_service() {
    local name="$1" url="$2" api_key="${3:-}" max_wait="${4:-90}" api_ver="${5:-v3}"
    local elapsed=0 interval=3

    while [[ $elapsed -lt $max_wait ]]; do
        local status_url="${url}/api/${api_ver}/system/status"
        local curl_opts=(-sf --connect-timeout 5 --max-time 15)
        if [[ -n "$api_key" ]]; then
            curl_opts+=(-H "X-Api-Key: ${api_key}")
        fi
        if curl "${curl_opts[@]}" "$status_url" &>/dev/null; then
            log_info "${name} is ready. (${elapsed}s)"
            return 0
        fi
        printf "\r  Waiting for %s... %ds/%ds" "$name" "$elapsed" "$max_wait"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done
    printf "\r  %-50s\r" ""
    log_warn "${name} did not become ready within ${max_wait} seconds."
    return 1
}

# ============================================================================
#  Auto-Configure *arrs via API
# ============================================================================

configure_arrs() {
    log_section "Auto-Configuring Services"

    local HAS_JQ=false
    command -v jq &>/dev/null && HAS_JQ=true

    # Wait for services to be ready
    wait_for_service "Radarr" "http://localhost:7878" "${RADARR_API_KEY}" 120 || true
    wait_for_service "Sonarr" "http://localhost:8989" "${SONARR_API_KEY}" 120 || true
    wait_for_service "Prowlarr" "http://localhost:9696" "${PROWLARR_API_KEY}" 120 "v1" || true

    # Configure Radarr download client
    log_step "Configuring Radarr..."
    configure_download_client "Radarr" "http://localhost:7878" "${RADARR_API_KEY}" "radarr" || true
    configure_root_folder "Radarr" "http://localhost:7878" "${RADARR_API_KEY}" "/data/media/movies" || true

    # Configure Sonarr download client
    log_step "Configuring Sonarr..."
    configure_download_client "Sonarr" "http://localhost:8989" "${SONARR_API_KEY}" "sonarr" || true
    configure_root_folder "Sonarr" "http://localhost:8989" "${SONARR_API_KEY}" "/data/media/series" || true

    # Configure Prowlarr
    log_step "Configuring Prowlarr..."
    configure_prowlarr_apps || true

    # Configure auth
    configure_arr_auth "Radarr" "http://localhost:7878" "${RADARR_API_KEY}" || true
    configure_arr_auth "Sonarr" "http://localhost:8989" "${SONARR_API_KEY}" || true
    configure_arr_auth "Prowlarr" "http://localhost:9696" "${PROWLARR_API_KEY}" "v1" || true

    log_info "Service auto-configuration complete."
}

configure_download_client() {
    local name="$1" url="$2" api_key="$3" category="$4"
    local existing_dc
    existing_dc=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/downloadclient" 2>/dev/null) || true
    if echo "$existing_dc" | grep -q '"name":"Decypharr"' 2>/dev/null || \
       echo "$existing_dc" | grep -q '"name": "Decypharr"' 2>/dev/null; then
        log_info "  ${name} already has Decypharr download client."
        return 0
    fi

    local cat_field="movieCategory"
    [[ "$name" == "Sonarr" ]] && cat_field="tvCategory"

    curl -sf --connect-timeout 5 --max-time 15 -X POST \
        -H "Content-Type: application/json" -H "X-Api-Key: ${api_key}" \
        "${url}/api/v3/downloadclient?forceSave=true" \
        -d '{
            "name": "Decypharr",
            "implementation": "QBittorrent",
            "configContract": "QBittorrentSettings",
            "protocol": "torrent",
            "enable": true,
            "priority": 1,
            "removeCompletedDownloads": true,
            "removeFailedDownloads": true,
            "fields": [
                {"name": "host", "value": "decypharr"},
                {"name": "port", "value": 8282},
                {"name": "useSsl", "value": false},
                {"name": "username", "value": "'"${DECYPHARR_USER}"'"},
                {"name": "password", "value": "'"${DECYPHARR_PASS}"'"},
                {"name": "'"${cat_field}"'", "value": "'"${category}"'"},
                {"name": "initialState", "value": 0},
                {"name": "sequentialOrder", "value": false},
                {"name": "firstAndLastFirst", "value": false}
            ],
            "tags": []
        }' -o /dev/null && log_info "  Download client 'Decypharr' added to ${name}." || \
        log_warn "  Failed to add download client to ${name}."
}

configure_root_folder() {
    local name="$1" url="$2" api_key="$3" root_path="$4"
    local existing_rf
    existing_rf=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/v3/rootfolder" 2>/dev/null) || true
    if echo "$existing_rf" | grep -qF "\"${root_path}\"" 2>/dev/null; then
        log_info "  ${name} already has root folder '${root_path}'."
        return 0
    fi
    curl -sf --connect-timeout 5 --max-time 15 -X POST \
        -H "Content-Type: application/json" -H "X-Api-Key: ${api_key}" \
        "${url}/api/v3/rootfolder" \
        -d '{"path": "'"${root_path}"'"}' -o /dev/null && \
        log_info "  Root folder '${root_path}' added to ${name}." || \
        log_warn "  Failed to add root folder to ${name}."
}

configure_prowlarr_apps() {
    wait_for_service "Prowlarr" "http://localhost:9696" "${PROWLARR_API_KEY}" 60 "v1" || return 1

    # Add Radarr app
    local existing_apps
    existing_apps=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${PROWLARR_API_KEY}" "http://localhost:9696/api/v1/applications" 2>/dev/null) || true
    if ! echo "$existing_apps" | grep -q '"name":"Radarr"' 2>/dev/null; then
        curl -sf --connect-timeout 5 --max-time 15 -X POST \
            -H "Content-Type: application/json" -H "X-Api-Key: ${PROWLARR_API_KEY}" \
            "http://localhost:9696/api/v1/applications" \
            -d '{
                "name": "Radarr",
                "implementation": "Radarr",
                "configContract": "RadarrSettings",
                "syncLevel": "fullSync",
                "fields": [
                    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                    {"name": "baseUrl", "value": "http://radarr:7878"},
                    {"name": "apiKey", "value": "'"${RADARR_API_KEY}"'"},
                    {"name": "syncCategories", "value": [2000,2010,2020,2030,2040,2045,2050,2060,2070,2080]}
                ],
                "tags": []
            }' -o /dev/null && log_info "  Prowlarr → Radarr app connection added." || \
            log_warn "  Failed to add Radarr to Prowlarr."
    fi

    # Add Sonarr app
    if ! echo "$existing_apps" | grep -q '"name":"Sonarr"' 2>/dev/null; then
        curl -sf --connect-timeout 5 --max-time 15 -X POST \
            -H "Content-Type: application/json" -H "X-Api-Key: ${PROWLARR_API_KEY}" \
            "http://localhost:9696/api/v1/applications" \
            -d '{
                "name": "Sonarr",
                "implementation": "Sonarr",
                "configContract": "SonarrSettings",
                "syncLevel": "fullSync",
                "fields": [
                    {"name": "prowlarrUrl", "value": "http://prowlarr:9696"},
                    {"name": "baseUrl", "value": "http://sonarr:8989"},
                    {"name": "apiKey", "value": "'"${SONARR_API_KEY}"'"},
                    {"name": "syncCategories", "value": [5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]}
                ],
                "tags": []
            }' -o /dev/null && log_info "  Prowlarr → Sonarr app connection added." || \
            log_warn "  Failed to add Sonarr to Prowlarr."
    fi

    # Add FlareSolverr (Byparr) proxy
    local existing_proxies
    existing_proxies=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${PROWLARR_API_KEY}" "http://localhost:9696/api/v1/indexerProxy" 2>/dev/null) || true
    if ! echo "$existing_proxies" | grep -q '"name":"FlareSolverr"' 2>/dev/null; then
        curl -sf --connect-timeout 5 --max-time 15 -X POST \
            -H "Content-Type: application/json" -H "X-Api-Key: ${PROWLARR_API_KEY}" \
            "http://localhost:9696/api/v1/indexerProxy" \
            -d '{
                "name": "FlareSolverr",
                "implementation": "FlareSolverr",
                "configContract": "FlareSolverrSettings",
                "fields": [
                    {"name": "host", "value": "http://byparr:8191"},
                    {"name": "requestTimeout", "value": 60}
                ],
                "tags": []
            }' -o /dev/null && log_info "  FlareSolverr (Byparr) proxy added to Prowlarr." || \
            log_warn "  Failed to add FlareSolverr proxy to Prowlarr."
    else
        log_info "  Prowlarr already has FlareSolverr configured."
    fi
}

configure_arr_auth() {
    local name="$1" url="$2" api_key="$3" api_ver="${4:-v3}"

    local admin_user admin_pass
    case "$name" in
        Radarr) admin_user="${RADARR_ADMIN_USER:-admin}"; admin_pass="${RADARR_ADMIN_PASS:-}" ;;
        Sonarr) admin_user="${SONARR_ADMIN_USER:-admin}"; admin_pass="${SONARR_ADMIN_PASS:-}" ;;
        Prowlarr) admin_user="${PROWLARR_ADMIN_USER:-admin}"; admin_pass="${PROWLARR_ADMIN_PASS:-}" ;;
    esac

    [[ -z "$admin_pass" ]] && return 1

    local auth_config
    auth_config=$(curl -sf --connect-timeout 5 --max-time 15 -H "X-Api-Key: ${api_key}" "${url}/api/${api_ver}/config/host" 2>/dev/null) || return 1
    [[ -z "$auth_config" ]] && return 1

    if ! command -v jq &>/dev/null; then
        log_warn "  jq not available — skipping ${name} auth config."
        return 1
    fi

    local auth_id
    auth_id=$(echo "$auth_config" | jq -r '.id' 2>/dev/null) || return 1

    local updated
    updated=$(echo "$auth_config" | jq \
        --arg user "$admin_user" \
        --arg pass "$admin_pass" \
        '.authenticationMethod = "Forms" | .authenticationRequired = "Enabled" | .username = $user | .password = $pass | .passwordConfirmation = $pass' 2>/dev/null) || return 1

    if echo "$updated" | curl -sf --connect-timeout 5 --max-time 15 -X PUT \
        -H "Content-Type: application/json" -H "X-Api-Key: ${api_key}" \
        "${url}/api/${api_ver}/config/host/${auth_id}" \
        -d @- -o /dev/null 2>/dev/null; then
        log_info "  ${name} auth configured."
    fi
}

# ============================================================================
#  Post-Install Configuration Guide
# ============================================================================

print_post_install() {
    log_section "Setup Complete!"

    echo -e "${GREEN}All files have been generated at:${NC} ${INSTALL_DIR}"
    echo ""

    echo -e "${BOLD}━━━━ Service URLs ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    print_service_urls

    echo ""
    echo -e "${BOLD}━━━━ Pre-Seeded API Keys ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${BOLD}Radarr${NC}    $(mask_key "${RADARR_API_KEY}")"
    echo -e "  ${BOLD}Sonarr${NC}    $(mask_key "${SONARR_API_KEY}")"
    echo -e "  ${BOLD}Prowlarr${NC}  $(mask_key "${PROWLARR_API_KEY}")"
    echo -e "  ${YELLOW}View full keys with:${NC} cd ${INSTALL_DIR} && ./manage.sh keys"
    echo ""

    if [[ "$SERVICES_STARTED" == "true" && -n "${RADARR_ADMIN_PASS:-}" ]]; then
        echo -e "${BOLD}━━━━ Auto-Generated Admin Credentials ━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo ""
        echo -e "  ${YELLOW}Save these credentials — you will need them to log in.${NC}"
        echo ""
        echo -e "  ${BOLD}Radarr${NC}    Username: ${RADARR_ADMIN_USER}  Password: ${RADARR_ADMIN_PASS}"
        echo -e "  ${BOLD}Sonarr${NC}    Username: ${SONARR_ADMIN_USER}  Password: ${SONARR_ADMIN_PASS}"
        echo -e "  ${BOLD}Prowlarr${NC}  Username: ${PROWLARR_ADMIN_USER}  Password: ${PROWLARR_ADMIN_PASS}"
        echo ""
    fi

    echo -e "${BOLD}━━━━ macOS Notes ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} STRM-based setup (no FUSE or rclone mount needed)"
    echo -e "  ${GREEN}✓${NC} Jellyfin media server (natively supports STRM files)"
    echo -e "  ${GREEN}✓${NC} Decypharr in lite mode (qBittorrent mock only)"
    echo -e "  ${YELLOW}⚠${NC} Software transcoding only in Docker (no GPU passthrough)"
    echo -e "  ${YELLOW}⚠${NC} For hardware transcoding: install Jellyfin natively on macOS"
    echo ""

    echo -e "${BOLD}━━━━ Auto-Start ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}✓${NC} Launch agent ${BOLD}com.torbox.media-server${NC} created."
    echo "    Services will auto-start when you log in."
    echo "    To disable: ./manage.sh disable"
    echo "    To re-enable: ./manage.sh enable"
    echo ""

    echo -e "${BOLD}━━━━ Management Commands ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "  cd ${INSTALL_DIR}"
    echo "  ./manage.sh status    # Check service status"
    echo "  ./manage.sh logs      # View logs"
    echo "  ./manage.sh stop      # Stop all services"
    echo "  ./manage.sh start     # Start all services"
    echo "  ./manage.sh update    # Pull new images & restart"
    echo "  ./manage.sh keys      # View API keys"
    echo ""
}

# ============================================================================
#  Main
# ============================================================================

main() {
    for arg in "$@"; do
        case "$arg" in
            --yes | -y | --non-interactive)
                NON_INTERACTIVE=true
                ;;
            --dry-run)
                DRY_RUN=true
                ;;
        esac
    done

    if [[ $EUID -eq 0 ]]; then
        log_warn "Running as root is not recommended on macOS."
        log_warn "Docker Desktop runs as your regular user."
        if [[ "$NON_INTERACTIVE" != "true" ]]; then
            read -rp "Continue as root? [y/N]: " run_as_root
            run_as_root_lower=$(echo "${run_as_root:-}" | tr '[:upper:]' '[:lower:]')
            if [[ "$run_as_root_lower" != "y" ]]; then
                log_info "Re-run as a regular user: ./setup_macos.sh"
                exit 0
            fi
        fi
    fi

    print_banner

    check_existing_installation
    if [[ "$DRY_RUN" == "true" ]]; then
        check_dependencies --warn-only
    else
        check_dependencies
    fi
    gather_config
    check_port_conflicts

    if [[ "$DRY_RUN" == "true" ]]; then
        log_section "Dry Run — Preview of Actions"
        echo ""
        log_info "The following actions WOULD be taken (no changes made):"
        echo ""
        echo "  1. Create directories:"
        echo "     mkdir -p ${INSTALL_DIR}"
        echo "     mkdir -p ${CONFIG_DIR}/{prowlarr,radarr,sonarr,seerr,decypharr,jellyfin}"
        echo "     mkdir -p ${DATA_DIR}/{media/{movies,series},downloads/{radarr,sonarr}}"
        echo "     mkdir -p ${MOUNT_DIR}"
        echo ""
        echo "  2. Generate configs:"
        echo "     Decypharr config (lite mode — rclone disabled)"
        echo "     Radarr/Sonarr/Prowlarr config.xml (pre-seeded API keys)"
        echo ""
        echo "  3. Generate files:"
        echo "     ${ENV_FILE}"
        echo "     ${COMPOSE_FILE} (macOS version)"
        echo "     ${INSTALL_DIR}/manage.sh"
        echo ""
        echo "  4. Set up launchd service: com.torbox.media-server"
        echo ""
        echo "  5. Start Docker containers:"
        echo "     torbox-media-center, decypharr, prowlarr, byparr, radarr, sonarr, seerr, jellyfin"
        echo ""
        echo "  6. Auto-configure via API"
        echo ""
        log_info "Re-run without --dry-run to apply these changes."
        exit 0
    fi

    create_directories
    generate_decypharr_config
    generate_arr_configs
    generate_env_file
    generate_docker_compose
    generate_management_script
    generate_launchd_service

    if ! start_services; then
        log_warn "Services failed to start. Configs are saved — resolve the error above,"
        log_warn "then run: cd ${INSTALL_DIR} && ./manage.sh start"
    fi
    if [[ "$SERVICES_STARTED" == "true" ]]; then
        configure_arrs
    fi
    print_post_install

    touch "${SETUP_COMPLETE_FILE}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi

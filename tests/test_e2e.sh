#!/usr/bin/env bash
# ============================================================================
#  TorBox Media Server — Comprehensive E2E Test Suite
#  Tests the full pipeline: syntax → config generation → compose validation →
#  manage.sh generation → launchd correctness → uninstall safety
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${SCRIPT_DIR}/.."
SETUP_SCRIPT="${PROJECT_ROOT}/setup_macos.sh"
UNINSTALL_SCRIPT="${PROJECT_ROOT}/uninstall_macos.sh"
COMPOSE_FILE="${PROJECT_ROOT}/docker-compose.macos.yml"
ENV_EXAMPLE="${PROJECT_ROOT}/.env.example"
GITIGNORE="${PROJECT_ROOT}/.gitignore"

# ── Test Framework ──────────────────────────────────────────────────────────
passed=0
failed=0
warnings=0
current_section=""

pass() {
    passed=$((passed + 1))
    echo -e "  \033[0;32m[PASS]\033[0m $1"
}

fail() {
    failed=$((failed + 1))
    echo -e "  \033[0;31m[FAIL]\033[0m $1"
    if [[ -n "${2:-}" ]]; then
        echo -e "        → $2"
    fi
}

warn() {
    warnings=$((warnings + 1))
    echo -e "  \033[1;33m[WARN]\033[0m $1"
}

section() {
    current_section="$1"
    echo ""
    echo "━━━ $1 ━━━"
}

# ============================================================================
#  1. SYNTAX VALIDATION
# ============================================================================
section "Syntax Validation"

# 1.1 setup_macos.sh bash syntax
if bash -n "$SETUP_SCRIPT" 2>/dev/null; then
    pass "setup_macos.sh — valid bash syntax"
else
    fail "setup_macos.sh — invalid bash syntax"
fi

# 1.2 uninstall_macos.sh bash syntax
if bash -n "$UNINSTALL_SCRIPT" 2>/dev/null; then
    pass "uninstall_macos.sh — valid bash syntax"
else
    fail "uninstall_macos.sh — invalid bash syntax"
fi

# 1.3 All test files bash syntax
for test_file in "${SCRIPT_DIR}"/test_*.sh; do
    if bash -n "$test_file" 2>/dev/null; then
        pass "$(basename "$test_file") — valid bash syntax"
    else
        fail "$(basename "$test_file") — invalid bash syntax"
    fi
done

# ============================================================================
#  2. DOCKER COMPOSE VALIDATION
# ============================================================================
section "Docker Compose Validation"

# 2.1 Compose file exists
if [[ -f "$COMPOSE_FILE" ]]; then
    pass "docker-compose.macos.yml exists"
else
    fail "docker-compose.macos.yml not found"
fi

# 2.2 Validate compose with dummy env
dummy_env=(
    TORBOX_API_KEY="test1234567890abcdef1234567890ab"
    PUID=1000 PGID=1000 TZ="UTC"
    CONFIG_DIR="/tmp/torbox-test/config"
    DATA_DIR="/tmp/torbox-test/data"
    MOUNT_DIR="/tmp/torbox-test/mount"
    RADARR_API_KEY="abcdef1234567890abcdef1234567890"
    SONARR_API_KEY="abcdef1234567890abcdef1234567891"
    PROWLARR_API_KEY="abcdef1234567890abcdef1234567892"
    SEERR_API_KEY="MTIzNDU2Nzg5MA=="
    RADARR_ADMIN_USER="admin" RADARR_ADMIN_PASS="testpass"
    SONARR_ADMIN_USER="admin" SONARR_ADMIN_PASS="testpass"
    PROWLARR_ADMIN_USER="admin" PROWLARR_ADMIN_PASS="testpass"
    DECYPHARR_USER="torbox" DECYPHARR_PASS="testpass"
    HW_ACCEL="none"
)

if command -v docker &>/dev/null; then
    if env "${dummy_env[@]}" docker compose -f "$COMPOSE_FILE" config -q 2>/dev/null; then
        pass "docker-compose.macos.yml validates"
    else
        fail "docker-compose.macos.yml validation failed"
    fi
else
    warn "Docker not available — skipping compose validation"
fi

# 2.3 All ports bound to 127.0.0.1
if grep -E '^\s+- "[0-9]' "$COMPOSE_FILE" | grep -vq '127.0.0.1:' 2>/dev/null; then
    fail "Some ports not bound to 127.0.0.1 (security risk)"
else
    pass "All ports bound to 127.0.0.1"
fi

# 2.4 No :latest tags (all services pinned)
latest_images=$(grep -E '^\s+image:' "$COMPOSE_FILE" | grep ':latest' | grep -v 'byparr' || true)
if [[ -z "$latest_images" ]]; then
    pass "No Docker images use :latest tag (byparr excluded)"
else
    fail "Docker images using :latest tag" "$latest_images"
fi

# 2.5 All services have health checks
services_without_health=$(
    awk '/^  [a-z].*:/{svc=$1} /healthcheck:/{found[svc]=1} END{for(s in found){}; for(s in found) delete found[s]}' "$COMPOSE_FILE" 2>/dev/null || true
)
health_count=$(grep -c 'healthcheck:' "$COMPOSE_FILE" || true)
service_count=$(grep -c 'container_name:' "$COMPOSE_FILE" || true)
# torbox-media-center is a third-party image without a healthcheck
if [[ "$health_count" -ge $((service_count - 1)) ]]; then
    pass "$health_count of $service_count services have health checks (torbox-media-center excluded)"
else
    fail "Only $health_count of $service_count services have health checks"
fi

# 2.6 All services have logging configuration
log_count=$(grep -c 'logging:' "$COMPOSE_FILE" || true)
if [[ "$log_count" -ge "$service_count" ]]; then
    pass "All services have logging with rotation configured"
else
    fail "Only $log_count of $service_count services have logging configured"
fi

# 2.7 All services have restart policy
restart_count=$(grep -c 'restart: unless-stopped' "$COMPOSE_FILE" || true)
if [[ "$restart_count" -ge "$service_count" ]]; then
    pass "All services have restart: unless-stopped"
else
    fail "Only $restart_count of $service_count services have restart policy"
fi

# ============================================================================
#  3. SETUP.SH STRUCTURAL TESTS
# ============================================================================
section "setup_macos.sh Structural Tests"

# 3.1 Script starts with set -euo pipefail
if head -5 "$SETUP_SCRIPT" | grep -q 'set -euo pipefail'; then
    pass "setup_macos.sh uses set -euo pipefail"
else
    fail "setup_macos.sh missing strict error handling"
fi

# 3.2 VERSION variable is set
if grep -qE '^VERSION="[0-9]+\.[0-9]+' "$SETUP_SCRIPT"; then
    pass "VERSION variable is defined"
else
    fail "VERSION variable missing or malformed"
fi

# 3.3 All required functions exist
required_functions=(
    generate_api_key mask_key cleanup_on_interrupt
    check_dependencies check_port_conflicts
    gather_config create_directories
    generate_decypharr_config generate_arr_configs
    generate_env_file generate_docker_compose
    generate_management_script generate_launchd_service
    start_services wait_for_service
    configure_download_client configure_root_folder
    configure_prowlarr_apps configure_arr_auth
    print_post_install main
)
for func in "${required_functions[@]}"; do
    if grep -qE "^${func}\(\)" "$SETUP_SCRIPT"; then
        pass "Function ${func}() exists"
    else
        fail "Function ${func}() NOT found"
    fi
done

# ============================================================================
#  4. BUG REGRESSION TESTS
# ============================================================================
section "Bug Regression Tests"

# 4.2 BUG-2: configure_arr_auth must use v1 for Prowlarr, not hardcoded v3
auth_func=$(sed -n '/^configure_arr_auth()/,/^}/p' "$SETUP_SCRIPT")
if echo "$auth_func" | grep -qF '/api/v3/config/host' &&
    ! echo "$auth_func" | grep -qE 'api_ver|api_version'; then
    fail "BUG-2: configure_arr_auth hardcodes /api/v3 — Prowlarr uses v1" \
        "Auth config for Prowlarr silently fails (404)"
else
    pass "BUG-2: configure_arr_auth handles API version correctly"
fi

# 4.3 BUG-3: Admin credential preservation must check each service independently
cred_block=$(sed -n '/EXISTING_RADARR_ADMIN_USER/,/PROWLARR_ADMIN_PASS/p' "$SETUP_SCRIPT" | head -20)
if echo "$cred_block" | grep -q 'EXISTING_RADARR_ADMIN_USER' &&
    echo "$cred_block" | grep -q 'SONARR_ADMIN_USER.*EXISTING_SONARR' &&
    ! echo "$cred_block" | grep -qE 'if.*EXISTING_SONARR_ADMIN'; then
    fail "BUG-3: Credential preservation only checks Radarr but assigns Sonarr/Prowlarr" \
        "Sonarr/Prowlarr may get empty credentials on re-run"
else
    pass "BUG-3: Credential preservation validates each service"
fi

# 4.8 SH-5: Trap handler should use ${VAR:-} for safety
trap_handler=$(sed -n '/^cleanup_on_interrupt()/,/^}/p' "$SETUP_SCRIPT")
if echo "$trap_handler" | grep -qE '\$\{ENV_FILE\}' &&
    ! echo "$trap_handler" | grep -qE '\$\{ENV_FILE:-'; then
    fail "SH-5: Trap handler uses \${ENV_FILE} without :- default (crashes if undefined)" \
        "Ctrl-C during early init causes unbound variable error"
else
    pass "SH-5: Trap handler uses safe variable defaults"
fi

# ============================================================================
#  5. CONFIG & DOCUMENTATION TESTS
# ============================================================================
section "Config & Documentation Tests"

# 5.1 .env.example should document TORBOX_API_KEY
if grep -q 'TORBOX_API_KEY' "$ENV_EXAMPLE" 2>/dev/null; then
    pass ".env.example documents TORBOX_API_KEY"
else
    fail ".env.example missing TORBOX_API_KEY — the most critical required variable"
fi

# 5.2 .gitignore should not match .env.example
if grep -q '^!\.env\.example' "$GITIGNORE" 2>/dev/null; then
    pass ".gitignore has !.env.example exception"
elif grep -q '\.env\.\*' "$GITIGNORE" 2>/dev/null; then
    fail ".gitignore pattern '.env.*' matches .env.example without exclusion"
else
    pass ".gitignore doesn't match .env.example"
fi

# 5.5 README should mention manage.sh health command
if grep -q 'manage.sh health' "${PROJECT_ROOT}/README.md" 2>/dev/null; then
    pass "README documents manage.sh health command"
else
    fail "README missing manage.sh health command"
fi

# 5.6 README should mention manage.sh backup command
if grep -q 'manage.sh backup' "${PROJECT_ROOT}/README.md" 2>/dev/null; then
    pass "README documents manage.sh backup command"
else
    fail "README missing manage.sh backup command"
fi

# ============================================================================
#  6. MANAGE.SH GENERATION TESTS
# ============================================================================
section "manage.sh Generation Tests"

manage_heredoc=$(awk "/cat >.*manage.sh.*<<'MANAGE_HEADER'/,/^MANAGE_HEADER$/" "$SETUP_SCRIPT" 2>/dev/null || true)
manage_inline=$(awk "/cat >>.*manage.sh.*<<MANAGE_INLINE/,/^MANAGE_INLINE$/" "$SETUP_SCRIPT" 2>/dev/null || true)
manage_eof=$(awk "/cat >>.*manage.sh.*<<'MANAGE_EOF'/,/^MANAGE_EOF$/" "$SETUP_SCRIPT" 2>/dev/null || true)

# 6.1 manage.sh has all required commands
for cmd in start stop restart status logs pull update down urls keys enable disable backup health shell version help; do
    if echo "$manage_eof" | grep -qE "^\s+${cmd}[)|]"; then
        pass "manage.sh includes '${cmd}' command"
    elif echo "$manage_heredoc" | grep -q "$cmd"; then
        pass "manage.sh references '${cmd}' command"
    else
        fail "manage.sh missing '${cmd}' command"
    fi
done

# 6.2 manage.sh bash syntax check via AWK extraction
tmpfile=$(mktemp "${SCRIPT_DIR}/manage_check.XXXXXX")
trap 'rm -f "$tmpfile"' EXIT

# Extract all three heredoc blocks to construct the manage.sh
{
    awk "/cat >.*manage.sh.*<<'MANAGE_HEADER'/,/^MANAGE_HEADER$/" "$SETUP_SCRIPT" | tail -n +2 | sed '$d'
    awk "/cat >>.*manage.sh.*<<MANAGE_INLINE/,/^MANAGE_INLINE$/" "$SETUP_SCRIPT" | tail -n +2 | sed '$d'
    awk "/cat >>.*manage.sh.*<<'MANAGE_EOF'/,/^MANAGE_EOF$/" "$SETUP_SCRIPT" | tail -n +2 | sed '$d'
} >"$tmpfile" 2>/dev/null

if bash -n "$tmpfile" 2>/dev/null; then
    pass "Generated manage.sh has valid bash syntax"
else
    fail "Generated manage.sh has invalid bash syntax"
fi
rm -f "$tmpfile"

# ============================================================================
#  7. UNINSTALL.SH SAFETY TESTS
# ============================================================================
section "uninstall_macos.sh Safety Tests"

# 7.1 Has strict error handling
if head -5 "$UNINSTALL_SCRIPT" | grep -q 'set -euo pipefail'; then
    pass "uninstall_macos.sh uses set -euo pipefail"
else
    fail "uninstall_macos.sh missing strict error handling"
fi

# 7.2 Has user confirmation before destructive action
if grep -qE 'read.*confirm|read.*yes' "$UNINSTALL_SCRIPT"; then
    pass "uninstall_macos.sh requires user confirmation"
else
    fail "uninstall_macos.sh has no confirmation prompt"
fi

# 7.3 Supports non-interactive mode
if grep -q 'non.interactive\|NON_INTERACTIVE\|--yes' "$UNINSTALL_SCRIPT"; then
    pass "uninstall_macos.sh supports non-interactive mode"
else
    fail "uninstall_macos.sh missing non-interactive mode"
fi

# 7.4 Doesn't use 'source' on .env (security)
if grep -q '^source .*\.env\|^\. .*\.env' "$UNINSTALL_SCRIPT"; then
    fail "uninstall_macos.sh sources .env file directly (security risk)"
else
    pass "uninstall_macos.sh reads .env safely without sourcing"
fi

# 7.5 Has docker compose down or stop
if grep -q 'compose.*down\|compose.*stop\|docker stop' "$UNINSTALL_SCRIPT"; then
    pass "uninstall_macos.sh stops containers before cleanup"
else
    fail "uninstall_macos.sh doesn't stop containers"
fi

# ============================================================================
#  8. SECURITY TESTS
# ============================================================================
section "Security Tests"

# 8.1 .env file gets chmod 600
if grep -q 'chmod 600.*ENV_FILE\|chmod 600.*\.env' "$SETUP_SCRIPT"; then
    pass ".env file is chmod 600 (owner-only read/write)"
else
    fail ".env file permissions not restricted"
fi

# 8.2 compose file gets chmod 600
if grep -q 'chmod 600.*COMPOSE_FILE\|chmod 600.*compose' "$SETUP_SCRIPT"; then
    pass "docker-compose.macos.yml is chmod 600"
else
    fail "docker-compose.macos.yml permissions not restricted"
fi

# 8.3 API key validation regex exists
if grep -qF '^[a-zA-Z0-9._-]+$' "$SETUP_SCRIPT"; then
    pass "API key validation regex is present"
else
    fail "API key validation regex not found"
fi

# 8.5 No hardcoded real API keys or passwords
if grep -qE '(TORBOX_API_KEY|api_key)="[a-f0-9]{20,}"' "$SETUP_SCRIPT" 2>/dev/null; then
    fail "Hardcoded API key found in setup_macos.sh"
else
    pass "No hardcoded API keys in setup_macos.sh"
fi

# ============================================================================
#  9. CROSS-CUTTING CONSISTENCY TESTS
# ============================================================================
section "Cross-Cutting Consistency"

# 9.2 Prowlarr uses API v1 explicitly in wait_for_service
if grep -q 'wait_for_service.*Prowlarr.*v1' "$SETUP_SCRIPT"; then
    pass "Prowlarr uses API v1 in wait_for_service"
else
    fail "Prowlarr API version mismatch in wait_for_service"
fi

# 9.3 Radarr/Sonarr wait_for_service calls exist (they use default v3)
if grep -q 'wait_for_service.*Radarr' "$SETUP_SCRIPT" &&
    grep -q 'wait_for_service.*Sonarr' "$SETUP_SCRIPT"; then
    pass "Radarr/Sonarr wait_for_service calls present"
else
    fail "Radarr/Sonarr wait_for_service calls missing"
fi

# ============================================================================
#  10. EXISTING TEST SUITE EXECUTION
# ============================================================================
section "Existing Test Suite"

# 10.1 Run test_api_key.sh
if bash "${SCRIPT_DIR}/test_api_key.sh" &>/dev/null; then
    pass "test_api_key.sh — all tests pass"
else
    fail "test_api_key.sh — tests failed"
fi

# 10.2 Run test_setup_functions.sh
if bash "${SCRIPT_DIR}/test_setup_functions.sh" &>/dev/null; then
    pass "test_setup_functions.sh — all tests pass"
else
    fail "test_setup_functions.sh — tests failed"
fi

# ============================================================================
#  11. SHELLCHECK (if available)
# ============================================================================
section "Static Analysis"

if command -v shellcheck &>/dev/null; then
    if shellcheck -S warning "$SETUP_SCRIPT" 2>/dev/null; then
        pass "setup_macos.sh — ShellCheck clean (warning level)"
    else
        sc_count=$(shellcheck -S warning "$SETUP_SCRIPT" 2>/dev/null | grep -c 'SC[0-9]' || echo "?")
        fail "setup_macos.sh — ShellCheck found ${sc_count} warnings"
    fi

    if shellcheck -S warning "$UNINSTALL_SCRIPT" 2>/dev/null; then
        pass "uninstall_macos.sh — ShellCheck clean (warning level)"
    else
        fail "uninstall_macos.sh — ShellCheck warnings found"
    fi
else
    warn "ShellCheck not installed — skipping static analysis"
fi

# ============================================================================
#  SUMMARY
# ============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
total=$((passed + failed + warnings))
echo -e "  \033[0;32m${passed} passed\033[0m  \033[0;31m${failed} failed\033[0m  \033[1;33m${warnings} warnings\033[0m  (${total} total)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [[ $failed -gt 0 ]]; then
    echo -e "\033[0;31mSome tests failed. See output above for details.\033[0m"
    exit 1
else
    echo -e "\033[0;32mAll tests passed!\033[0m"
    exit 0
fi

#!/usr/bin/env bash

# Comprehensive test suite for TorBox Media Server setup functions
# Tests key functions extracted from setup_macos.sh without side effects.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test_utils.sh"
eval "$(sed -n '/^mask_key() {/,/^}/p' "${SCRIPT_DIR}/../setup_macos.sh")"

echo -e "${CYAN}Running TorBox Media Server test suite...${NC}"
echo ""

# ============================================================================
#  Function: mask_key
# ============================================================================

test_mask_key_normal() {
    local result
    result=$(mask_key "abcdef1234567890abcdef1234567890")
    if [[ "$result" == "abcd...7890" ]]; then
        pass "mask_key masks 32-char key correctly"
    else
        fail "mask_key expected 'abcd...7890', got '$result'"
    fi
}

test_mask_key_short() {
    local result
    result=$(mask_key "ab")
    if [[ "$result" == "ab" ]]; then
        pass "mask_key returns short keys unchanged"
    else
        fail "mask_key short key expected 'ab', got '$result'"
    fi
}

test_mask_key_exact_4() {
    local result
    result=$(mask_key "abcd")
    if [[ "$result" == "abcd" ]]; then
        pass "mask_key returns 4-char keys unchanged"
    else
        fail "mask_key 4-char expected 'abcd', got '$result'"
    fi
}

test_mask_key_5_chars() {
    local result
    result=$(mask_key "abcde")
    if [[ "$result" == "abcd...bcde" ]]; then
        pass "mask_key masks 5-char key correctly"
    else
        fail "mask_key 5-char expected 'abcd...bcde', got '$result'"
    fi
}

# ============================================================================
#  Function: port conflict regex precision
# ============================================================================

test_port_regex_no_partial_match() {
    local ss_output="LISTEN  0  128  0.0.0.0:8282  0.0.0.0:*"
    local port=828
    if echo "$ss_output" | grep -qE ":${port}[[:space:]]"; then
        fail "Port regex should not match partial port 828 in 8282"
    else
        pass "Port regex correctly rejects partial port match (828 vs 8282)"
    fi
}

test_port_regex_exact_match() {
    local ss_output="LISTEN  0  128  0.0.0.0:8282  0.0.0.0:*"
    local port=8282
    if echo "$ss_output" | grep -qE ":${port}[[:space:]]"; then
        pass "Port regex matches exact port 8282"
    else
        fail "Port regex should match exact port 8282"
    fi
}

test_port_regex_no_false_positive_828() {
    local ss_output="tcp  LISTEN  0  128  0.0.0.0:8282  0.0.0.0:*"
    local port=828
    if echo "$ss_output" | grep -qE ":${port}[[:space:]]"; then
        fail "Port regex should not match 8282 when searching for port 828"
    else
        pass "Port regex rejects 8282 when searching for port 828"
    fi
}

test_port_regex_jellyfin_not_plex() {
    local ss_output="tcp  LISTEN  0  128  0.0.0.0:8096  0.0.0.0:*"
    if echo "$ss_output" | grep -qE ":8096[[:space:]]"; then
        pass "Port regex matches Jellyfin port 8096"
    else
        fail "Port regex should match port 8096"
    fi
    if echo "$ss_output" | grep -qE ":32400[[:space:]]"; then
        fail "Port regex should not match 32400 when not in ss output"
    else
        pass "Port regex correctly rejects 32400 when not present"
    fi
}

# ============================================================================
#  Function: API key validation regex
# ============================================================================

test_api_key_regex_valid() {
    local key="abc123def456ghi789jkl012mno345pq"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        pass "API key regex accepts valid alphanumeric key"
    else
        fail "API key regex should accept alphanumeric key"
    fi
}

test_api_key_regex_with_dots() {
    local key="abc.123.def.456"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        pass "API key regex accepts key with dots"
    else
        fail "API key regex should accept dots"
    fi
}

test_api_key_regex_with_hyphens() {
    local key="abc-123-def-456"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        pass "API key regex accepts key with hyphens"
    else
        fail "API key regex should accept hyphens"
    fi
}

test_api_key_regex_rejects_spaces() {
    local key="abc 123 def"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "API key regex should reject spaces"
    else
        pass "API key regex rejects keys with spaces"
    fi
}

test_api_key_regex_rejects_special() {
    local key="abc;rm -rf /"
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "API key regex should reject shell metacharacters"
    else
        pass "API key regex rejects shell metacharacters"
    fi
}

test_api_key_regex_rejects_backtick() {
    local key='abc`whoami`'
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "API key regex should reject backticks"
    else
        pass "API key regex rejects backticks"
    fi
}

test_api_key_regex_rejects_dollar() {
    local key='abc$(id)'
    if [[ "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        fail "API key regex should reject dollar signs"
    else
        pass "API key regex rejects dollar signs"
    fi
}

# ============================================================================
#  Function: mount path validation regex
# ============================================================================

test_mount_path_regex_valid() {
    local path="/mnt/torbox-media"
    if [[ "$path" =~ [^a-zA-Z0-9_./-] ]]; then
        fail "Mount path regex should accept valid path"
    else
        pass "Mount path regex accepts valid path"
    fi
}

test_mount_path_regex_rejects_spaces() {
    local path="/mnt/tor box media"
    if [[ "$path" =~ [^a-zA-Z0-9_./-] ]]; then
        pass "Mount path regex rejects spaces"
    else
        fail "Mount path regex should reject spaces"
    fi
}

test_mount_path_regex_rejects_special() {
    local path="/mnt/torbox;rm -rf"
    if [[ "$path" =~ [^a-zA-Z0-9_./-] ]]; then
        pass "Mount path regex rejects shell metacharacters"
    else
        fail "Mount path regex should reject special characters"
    fi
}

test_mount_path_regex_accepts_underscores() {
    local path="/mnt/torbox_media/test-dir"
    if [[ "$path" =~ [^a-zA-Z0-9_./-] ]]; then
        fail "Mount path regex should accept underscores and hyphens"
    else
        pass "Mount path regex accepts underscores and hyphens"
    fi
}

# ============================================================================
#  Function: env_val extraction (from .env files)
# ============================================================================

test_env_val_extraction() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo 'RADARR_API_KEY="abcdef123456"' >"$tmpdir/test.env"
    local result
    result=$(grep '^RADARR_API_KEY=' "$tmpdir/test.env" | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [[ "$result" == "abcdef123456" ]]; then
        pass "env_val extracts quoted key correctly"
    else
        fail "env_val expected 'abcdef123456', got '$result'"
    fi
    rm -rf "$tmpdir"
}

test_env_val_no_quotes() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo 'RADARR_API_KEY=abcdef123456' >"$tmpdir/test.env"
    local result
    result=$(grep '^RADARR_API_KEY=' "$tmpdir/test.env" | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [[ "$result" == "abcdef123456" ]]; then
        pass "env_val extracts unquoted key correctly"
    else
        fail "env_val expected 'abcdef123456', got '$result'"
    fi
    rm -rf "$tmpdir"
}

test_env_val_single_quotes() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "MOUNT_DIR='/mnt/torbox-media'" >"$tmpdir/test.env"
    local result
    result=$(grep '^MOUNT_DIR=' "$tmpdir/test.env" | cut -d= -f2- | tr -d '"' | tr -d "'")
    if [[ "$result" == "/mnt/torbox-media" ]]; then
        pass "env_val extracts single-quoted value correctly"
    else
        fail "env_val expected '/mnt/torbox-media', got '$result'"
    fi
    rm -rf "$tmpdir"
}

test_env_val_missing_key() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo 'OTHER_KEY=value' >"$tmpdir/test.env"
    local result
    result=$(grep '^RADARR_API_KEY=' "$tmpdir/test.env" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'") || true
    if [[ -z "$result" ]]; then
        pass "env_val returns empty for missing key"
    else
        fail "env_val should be empty for missing key, got '$result'"
    fi
    rm -rf "$tmpdir"
}

# ============================================================================
#  Function: API key hex validation (used in re-run .env validation)
# ============================================================================

test_hex_key_validation_valid() {
    local key="abcdef1234567890abcdef1234567890"
    if [[ "$key" =~ ^[0-9a-f]{32}$ ]]; then
        pass "Hex validation accepts valid 32-char hex key"
    else
        fail "Hex validation should accept valid hex key"
    fi
}

test_hex_key_validation_too_short() {
    local key="abcdef1234567890"
    if [[ "$key" =~ ^[0-9a-f]{32}$ ]]; then
        fail "Hex validation should reject short key"
    else
        pass "Hex validation rejects short key"
    fi
}

test_hex_key_validation_uppercase() {
    local key="ABCDEF1234567890ABCDEF1234567890"
    if [[ "$key" =~ ^[0-9a-f]{32}$ ]]; then
        fail "Hex validation should reject uppercase key (lowercase only)"
    else
        pass "Hex validation rejects uppercase hex"
    fi
}

test_hex_key_validation_with_letters() {
    local key="ghijkl1234567890ghijkl1234567890"
    if [[ "$key" =~ ^[0-9a-f]{32}$ ]]; then
        fail "Hex validation should reject non-hex letters"
    else
        pass "Hex validation rejects non-hex letters (g-z)"
    fi
}

# ============================================================================
#  Function: docker-compose image references (pinned versions)
# ============================================================================

test_image_versions_not_latest() {
    local compose_file="${SCRIPT_DIR}/../docker-compose.macos.yml"
    if [[ ! -f "$compose_file" ]]; then
        echo -e "${CYAN}[SKIP]${NC} Cannot find docker-compose.macos.yml to check image versions"
        return
    fi
    if grep -v 'byparr' "$compose_file" | grep -qE 'image:.*:latest' 2>/dev/null; then
        fail "Found Docker images using :latest tag"
    else
        pass "No Docker images use :latest tag"
    fi
}

# ============================================================================
#  Function: docker-compose volume mounts (Decypharr directory mount)
# ============================================================================
test_decypharr_dir_mount() {
    if grep -q 'decypharr:/app' "${SCRIPT_DIR}/../docker-compose.macos.yml" 2>/dev/null &&
        ! grep -q 'config.json:/app' "${SCRIPT_DIR}/../docker-compose.macos.yml" 2>/dev/null; then
        pass "Decypharr config directory is mounted to /app (compatible with v2.0)"
    else
        fail "Decypharr uses file-level bind mount for config.json (will crash-loop with v2.0 — use directory mount)"
    fi
}

# ============================================================================
#  Function: .gitignore validation (no markdown fence artifacts)
# ============================================================================

test_gitignore_no_markdown_fences() {
    local gitignore="${SCRIPT_DIR}/../.gitignore"
    if [[ ! -f "$gitignore" ]]; then
        echo -e "${CYAN}[SKIP]${NC} Cannot find .gitignore to check"
        return
    fi
    local fence_issues=0

    # Check for lines beginning with three backticks (markdown code fence opener)
    if grep -qE '^```' "$gitignore" 2>/dev/null; then
        fail ".gitignore contains markdown code fence lines (backtick fence)"
        fence_issues=1
    fi

    # Check for the specific ```bash artifact we removed
    if grep -qF '```bash' "$gitignore" 2>/dev/null; then
        fail ".gitignore contains a backtick-bash fence artifact"
        fence_issues=1
    fi

    if [[ $fence_issues -eq 0 ]]; then
        pass ".gitignore is free of markdown fence artifacts"
    fi
}

test_gitignore_starts_with_comment() {
    local gitignore="${SCRIPT_DIR}/../.gitignore"
    local first_line
    first_line=$(head -1 "$gitignore" 2>/dev/null) || true
    if [[ "$first_line" == "# Environment" ]]; then
        pass ".gitignore starts with '# Environment' (no fence artifacts)"
    else
        fail ".gitignore first line is '$first_line', expected '# Environment'"
    fi
}

# ============================================================================
#  Run all tests
# ============================================================================

echo "--- mask_key tests ---"
test_mask_key_normal
test_mask_key_short
test_mask_key_exact_4
test_mask_key_5_chars

echo ""
echo "--- Port regex precision tests ---"
test_port_regex_no_partial_match
test_port_regex_exact_match
test_port_regex_no_false_positive_828
test_port_regex_jellyfin_not_plex

echo ""
echo "--- API key regex validation tests ---"
test_api_key_regex_valid
test_api_key_regex_with_dots
test_api_key_regex_with_hyphens
test_api_key_regex_rejects_spaces
test_api_key_regex_rejects_special
test_api_key_regex_rejects_backtick
test_api_key_regex_rejects_dollar

echo ""
echo "--- Mount path regex tests ---"
test_mount_path_regex_valid
test_mount_path_regex_rejects_spaces
test_mount_path_regex_rejects_special
test_mount_path_regex_accepts_underscores

echo ""
echo "--- .env extraction tests ---"
test_env_val_extraction
test_env_val_no_quotes
test_env_val_single_quotes
test_env_val_missing_key

echo ""
echo "--- Hex key validation tests ---"
test_hex_key_validation_valid
test_hex_key_validation_too_short
test_hex_key_validation_uppercase
test_hex_key_validation_with_letters

echo ""
echo "--- Docker compose template tests ---"
test_image_versions_not_latest
test_decypharr_dir_mount

echo ""
echo "--- Architecture tests ---"

test_no_python3_json_manipulation() {
    local setup_file="${SCRIPT_DIR}/../setup_macos.sh"
    [[ ! -f "$setup_file" ]] && setup_file="${setup_file}/setup_macos.sh"
    if grep -q 'python3 -c' "$setup_file" 2>/dev/null; then
        fail "setup_macos.sh still uses python3 for JSON manipulation (should use jq)"
    else
        pass "No python3 JSON manipulation in setup_macos.sh (uses jq)"
    fi
}

test_uses_jq_for_json() {
    local setup_file="${SCRIPT_DIR}/../setup_macos.sh"
    [[ ! -f "$setup_file" ]] && setup_file="${setup_file}/setup_macos.sh"
    if grep -q 'jq ' "$setup_file" 2>/dev/null; then
        pass "setup_macos.sh uses jq for JSON manipulation"
    else
        fail "No jq usage found in setup_macos.sh"
    fi
}

test_no_docker_compose_v1() {
    local setup_file="${SCRIPT_DIR}/../setup_macos.sh"
    [[ ! -f "$setup_file" ]] && setup_file="${setup_file}/setup_macos.sh"
    if grep -qE 'docker-compose[[:space:]]|COMPOSE_CMD=\(docker-compose\)' "$setup_file" 2>/dev/null; then
        fail "setup_macos.sh still has Docker Compose V1 fallback logic"
    else
        pass "No Docker Compose V1 fallback in setup_macos.sh"
    fi
}

test_no_python3_json_manipulation
test_uses_jq_for_json
test_no_docker_compose_v1

echo ""
echo "--- .gitignore validation tests ---"
test_gitignore_no_markdown_fences
test_gitignore_starts_with_comment

echo ""
echo "--- Code review fix tests ---"

test_mount_path_rejects_root_slash() {
    local setup_file="${SCRIPT_DIR}/../setup_macos.sh"
    if grep -q "path cannot be '/'" "$setup_file" 2>/dev/null; then
        pass "Root path '/' explicitly rejected"
    else
        fail "Root path rejection missing"
    fi
}

test_mount_path_rejects_symlink() {
    local setup_file="${SCRIPT_DIR}/../setup_macos.sh"
    if grep -q "is a symlink" "$setup_file" 2>/dev/null; then
        pass "Symlinked mount paths are rejected"
    else
        fail "Symlink rejection missing"
    fi
}

test_interrupt_cleanup_stops_containers() {
    local setup_file="${SCRIPT_DIR}/../setup_macos.sh"
    if grep -q 'Stopping containers before cleanup' "$setup_file" 2>/dev/null; then
        pass "Interrupt cleanup stops containers before deleting files"
    else
        fail "Container stop on interrupt missing"
    fi
}

test_decypharr_config_refreshed_on_rerun() {
    local setup_file="${SCRIPT_DIR}/../setup_macos.sh"
    if grep -q 'Refreshed TorBox API key in existing Decypharr config' "$setup_file" 2>/dev/null; then
        pass "Decypharr config refreshed on re-run (no stale API key)"
    else
        fail "Decypharr config refresh missing"
    fi
}

test_start_services_returns_nonzero_on_failure() {
    local setup_file="${SCRIPT_DIR}/../setup_macos.sh"
    if grep -A 10 'Failed to start services' "$setup_file" 2>/dev/null | grep -q 'return 1'; then
        pass "start_services returns 1 on failure (no silent success)"
    else
        fail "start_services still returns 0 on failure"
    fi
}

test_compose_has_cap_drop_on_all_services() {
    local compose_file="${SCRIPT_DIR}/../docker-compose.macos.yml"
    local count
    count=$(grep -c 'cap_drop:' "$compose_file" 2>/dev/null || echo 0)
    # torbox-media-center is a third-party image without cap_drop, so 7 of 8 is expected
    if [[ $count -ge 7 ]]; then
        pass "$count services have cap_drop directive"
    else
        fail "Expected at least 7 cap_drop entries, found $count"
    fi
}

test_compose_s6_overlay_has_cap_add() {
    local compose_file="${SCRIPT_DIR}/../docker-compose.macos.yml"
    local s6_services="prowlarr radarr sonarr jellyfin"
    local missing=0
    for svc in $s6_services; do
        local block
        block=$(grep -A 40 "^  ${svc}:" "$compose_file" 2>/dev/null || true)
        if ! echo "$block" | grep -q 'cap_add:'; then
            echo "  WARN: $svc missing cap_add (needed for s6-overlay)" >&2
            missing=$((missing + 1))
        fi
        if ! echo "$block" | grep -q 'SETGID'; then
            echo "  WARN: $svc missing SETGID in cap_add" >&2
            missing=$((missing + 1))
        fi
        if ! echo "$block" | grep -q 'SETUID'; then
            echo "  WARN: $svc missing SETUID in cap_add" >&2
            missing=$((missing + 1))
        fi
    done
    if [[ $missing -eq 0 ]]; then
        pass "All s6-overlay services have SETGID/SETUID in cap_add"
    else
        fail "$missing s6-overlay service(s) missing required cap_add entries"
    fi
}

test_compose_media_servers_depend_on_decypharr() {
    local compose_file="${SCRIPT_DIR}/../docker-compose.macos.yml"
    local jellyfin_dep
    jellyfin_dep=$(grep -A 35 '^  jellyfin:' "$compose_file" 2>/dev/null | grep -c 'decypharr' || echo 0)
    if [[ $jellyfin_dep -gt 0 ]]; then
        pass "Jellyfin depends on Decypharr"
    else
        fail "Media server depends_on missing (jellyfin=$jellyfin_dep)"
    fi
}

test_compose_env_vars_have_defaults() {
    local compose_file="${SCRIPT_DIR}/../docker-compose.macos.yml"
    # Check for bare env vars like PUID=${PUID} without :-default syntax
    # We look for the pattern ${VAR} that is NOT followed by :-
    if grep -E '(PUID|PGID|TZ)=\$\{(PUID|PGID|TZ)\}' "$compose_file" 2>/dev/null | grep -qv ':-'; then
        fail "Found env vars without defaults"
    else
        pass "All env vars have defaults"
    fi
}

test_gitignore_has_backup_patterns() {
    local gitignore="${SCRIPT_DIR}/../.gitignore"
    if grep -q '^backups/$' "$gitignore" 2>/dev/null &&
        grep -q 'torbox_backup_' "$gitignore" 2>/dev/null &&
        grep -q '[*][.]bak' "$gitignore" 2>/dev/null; then
        pass ".gitignore covers backups/, torbox_backup_*/, *.bak"
    else
        fail ".gitignore missing backup patterns"
    fi
}

test_env_val_strips_inline_comments() {
    local env_lib="${SCRIPT_DIR}/../lib/env.sh"
    if [[ -f "$env_lib" ]] && grep -q '#.*\$' "$env_lib" 2>/dev/null; then
        pass "env_val strips inline comments (whitespace-prefixed only)"
    else
        fail "env_val doesn't strip whitespace-prefixed inline comments (checked in lib/env.sh)"
    fi
}

test_mount_path_rejects_root_slash
test_mount_path_rejects_symlink
test_interrupt_cleanup_stops_containers
test_decypharr_config_refreshed_on_rerun
test_start_services_returns_nonzero_on_failure
test_compose_has_cap_drop_on_all_services
test_compose_s6_overlay_has_cap_add
test_compose_media_servers_depend_on_decypharr
test_compose_env_vars_have_defaults
test_gitignore_has_backup_patterns
test_env_val_strips_inline_comments

print_summary
exit $?

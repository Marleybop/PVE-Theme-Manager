#!/usr/bin/env bash
#
# PVE Theme Manager
# Manage CSS themes for Proxmox VE via TUI or CLI
#
# Author: Marleybop
# License: MIT
#
set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly VERSION="2.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
readonly CONFIG_DIR="/root/.pve-theme-manager"
readonly BACKUP_DIR="${CONFIG_DIR}/backups"
readonly STATE_FILE="${CONFIG_DIR}/state.json"
readonly LOG_FILE="/var/log/pve-theme-manager.log"
readonly PVE_INDEX="/usr/share/pve-manager/index.html.tpl"
readonly PVE_IMAGES="/usr/share/pve-manager/images"
readonly THEME_MARKER_START="<!-- PVE-THEME:"
readonly THEME_MARKER_END="<!-- /PVE-THEME -->"

THEMES_DIR="${SCRIPT_DIR}/themes"
REPO_TARBALL="https://github.com/Marleybop/pve-theme-manager/archive/refs/heads/master.tar.gz"
DRY_RUN=false
NO_RESTART=false

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

log() {
    local level="$1"; shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    printf 'Error: %s\n' "$*" >&2
    log "ERROR" "$*"
    exit 1
}

info() {
    printf '%s\n' "$*"
    log "INFO" "$*"
}

require_root() {
    [[ $(id -u) -eq 0 ]] || die "This script must be run as root"
}

require_proxmox() {
    command -v pveversion &>/dev/null || die "pveversion not found. This doesn't appear to be a Proxmox host"
    [[ -f "$PVE_INDEX" ]] || die "Proxmox index template not found at ${PVE_INDEX}"
}

has_cmd() {
    command -v "$1" &>/dev/null
}

has_jq() {
    has_cmd jq
}

has_whiptail() {
    has_cmd whiptail
}

get_pve_version() {
    pveversion 2>/dev/null | awk '{print $2}' | head -1
}

ensure_dirs() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE" 2>/dev/null || true
}

# =============================================================================
# JSON HELPERS (jq with fallback)
# =============================================================================

json_get() {
    local file="$1" key="$2"
    if has_jq; then
        jq -r ".$key // empty" "$file" 2>/dev/null
    else
        # Fallback: basic grep/sed for simple string values
        grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$file" 2>/dev/null | \
            sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/' | head -1
    fi
}

json_get_array() {
    local file="$1" key="$2"
    if has_jq; then
        jq -r ".$key[]? // empty" "$file" 2>/dev/null
    else
        # Fallback: extract array items (simple single-line arrays only)
        grep -o "\"$key\"[[:space:]]*:[[:space:]]*\[[^]]*\]" "$file" 2>/dev/null | \
            grep -o '"[^"]*"' | sed 's/"//g' | tail -n +2
    fi
}

json_write_state() {
    local theme="$1" timestamp="$2" pve_version="$3"
    cat > "$STATE_FILE" <<EOF
{
  "installed_theme": "${theme}",
  "installed_at": "${timestamp}",
  "pve_version": "${pve_version}"
}
EOF
}

json_clear_state() {
    cat > "$STATE_FILE" <<EOF
{
  "installed_theme": null,
  "installed_at": null,
  "pve_version": null
}
EOF
}

# =============================================================================
# MENU SYSTEM
# =============================================================================

# Show a selection menu, returns selected key via stdout
# Usage: menu_select "Title" "key1" "desc1" "key2" "desc2" ...
menu_select() {
    local title="$1"; shift
    local -a items=("$@")
    local count=$(( ${#items[@]} / 2 ))

    if has_whiptail; then
        local choice
        choice=$(whiptail --clear --title "$title" --menu "Select an option:" \
            20 78 "$count" "${items[@]}" 3>&1 1>&2 2>&3) || true
        printf '%s' "$choice"
    else
        printf '\n=== %s ===\n\n' "$title"
        local i key desc
        for ((i=0; i<${#items[@]}; i+=2)); do
            key="${items[i]}"
            desc="${items[i+1]}"
            printf '  %s) %s\n' "$key" "$desc"
        done
        printf '\n'
        read -rp "Selection: " choice
        printf '%s' "$choice"
    fi
}

# Show a yes/no confirmation
confirm() {
    local message="$1"
    if has_whiptail; then
        whiptail --yesno "$message" 10 60
    else
        read -rp "$message [y/N]: " ans
        [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
    fi
}

# Show a message box
message() {
    local title="$1" body="$2"
    if has_whiptail; then
        whiptail --title "$title" --msgbox "$body" 20 78
    else
        printf '\n=== %s ===\n%s\n' "$title" "$body"
        read -rp "Press Enter to continue..."
    fi
}

# =============================================================================
# THEME OPERATIONS
# =============================================================================

list_themes() {
    [[ -d "$THEMES_DIR" ]] || return 1
    find "$THEMES_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort
}

get_theme_meta() {
    local theme="$1"
    printf '%s/%s/metadata.json' "$THEMES_DIR" "$theme"
}

get_theme_snippet_file() {
    local theme="$1"
    local meta
    meta=$(get_theme_meta "$theme")
    local inject_file
    inject_file=$(json_get "$meta" "inject_file")

    # Check for specified file, then snippet.html, then index.html.tpl
    local theme_dir="${THEMES_DIR}/${theme}"
    if [[ -n "$inject_file" && -f "${theme_dir}/${inject_file}" ]]; then
        printf '%s/%s' "$theme_dir" "$inject_file"
    elif [[ -f "${theme_dir}/snippet.html" ]]; then
        printf '%s/snippet.html' "$theme_dir"
    elif [[ -f "${theme_dir}/index.html.tpl" ]]; then
        printf '%s/index.html.tpl' "$theme_dir"
    else
        return 1
    fi
}

get_theme_info() {
    local theme="$1"
    local meta
    meta=$(get_theme_meta "$theme")
    [[ -f "$meta" ]] || { printf 'Theme metadata not found\n'; return 1; }

    local name desc author version tested
    name=$(json_get "$meta" "name")
    desc=$(json_get "$meta" "description")
    author=$(json_get "$meta" "author")
    version=$(json_get "$meta" "version")
    tested=$(json_get "$meta" "tested_proxmox_versions")

    cat <<EOF
Theme:       ${name:-$theme}
Author:      ${author:-Unknown}
Version:     ${version:-Unknown}
Tested on:   ${tested:-Unknown}

${desc:-No description available}
EOF
}

get_current_theme() {
    [[ -f "$STATE_FILE" ]] || { printf 'none'; return; }
    local theme
    theme=$(json_get "$STATE_FILE" "installed_theme")
    printf '%s' "${theme:-none}"
}

# Remove any existing theme snippet from the index file
remove_theme_snippet() {
    local target="$1"
    local tmp
    tmp=$(mktemp)

    # Remove lines between markers (inclusive)
    awk "
        /${THEME_MARKER_START//\//\\/}/,/${THEME_MARKER_END//\//\\/}/ { next }
        { print }
    " "$target" > "$tmp"

    if [[ -s "$tmp" ]]; then
        cat "$tmp" > "$target"
    fi
    rm -f "$tmp"
}

# Inject theme snippet into index file
inject_snippet() {
    local theme="$1" snippet_file="$2" target="$3"
    local snippet
    snippet=$(<"$snippet_file")

    local marker_start="${THEME_MARKER_START} ${theme} -->"
    local marker_end="$THEME_MARKER_END"

    # First remove any existing theme
    remove_theme_snippet "$target"

    # Build the block to inject
    local block
    block=$(printf '%s\n%s\n%s' "$marker_start" "$snippet" "$marker_end")

    # Inject before </head>
    local tmp
    tmp=$(mktemp)
    awk -v block="$block" '
        /<\/head>/ { print block }
        { print }
    ' "$target" > "$tmp"

    if [[ -s "$tmp" ]]; then
        cat "$tmp" > "$target"
    fi
    rm -f "$tmp"
}

copy_css_files() {
    local theme="$1"
    local meta
    meta=$(get_theme_meta "$theme")
    local theme_dir="${THEMES_DIR}/${theme}"

    local css_file src dest
    while IFS= read -r css_file; do
        [[ -z "$css_file" ]] && continue
        src="${theme_dir}/${css_file}"
        dest="${PVE_IMAGES}/$(basename "$css_file")"

        if [[ ! -f "$src" ]]; then
            die "CSS file not found: $src"
        fi

        if $DRY_RUN; then
            printf '  [+] Copy: %s\n' "$(basename "$css_file")"
        else
            cp "$src" "$dest"
            log "INFO" "Copied $src to $dest"
        fi
    done < <(json_get_array "$meta" "css_files")
}

# Remove CSS files for a theme
remove_theme_css() {
    local theme="$1"
    local meta
    meta=$(get_theme_meta "$theme")

    [[ -f "$meta" ]] || return 0

    local css_file dest
    while IFS= read -r css_file; do
        [[ -z "$css_file" ]] && continue
        dest="${PVE_IMAGES}/$(basename "$css_file")"

        if [[ -f "$dest" ]]; then
            if $DRY_RUN; then
                printf '  [-] Remove: %s\n' "$(basename "$css_file")"
            else
                rm -f "$dest"
                log "INFO" "Removed $dest"
            fi
        fi
    done < <(json_get_array "$meta" "css_files")
}

# Clean up previous theme before installing new one
cleanup_previous_theme() {
    local current
    current=$(get_current_theme)

    if [[ "$current" != "none" && -n "$current" && "$current" != "null" ]]; then
        if $DRY_RUN; then
            printf '\n[Cleanup previous theme: %s]\n' "$current"
        fi
        remove_theme_css "$current"
        if ! $DRY_RUN; then
            remove_theme_snippet "$PVE_INDEX"
        fi
    fi
}

install_theme() {
    local theme="$1"
    local theme_dir="${THEMES_DIR}/${theme}"
    local meta
    meta=$(get_theme_meta "$theme")

    [[ -d "$theme_dir" ]] || die "Theme not found: $theme"
    [[ -f "$meta" ]] || die "Theme metadata not found: $meta"

    local snippet_file
    snippet_file=$(get_theme_snippet_file "$theme") || die "Snippet file not found for theme: $theme"

    if $DRY_RUN; then
        # Clean dry run output for TUI
        printf '[Dry Run: %s]\n' "$theme"
        printf '=====================================\n\n'
    else
        info "Installing theme: $theme"
    fi

    # Create backup before changes
    if ! $DRY_RUN; then
        create_backup "pre-${theme}"
    else
        printf '[Backup]\n'
        printf '  Create backup before changes\n'
    fi

    # Clean up previous theme
    cleanup_previous_theme

    # Copy CSS files
    if $DRY_RUN; then
        printf '\n[Install new theme: %s]\n' "$theme"
    fi
    copy_css_files "$theme"

    # Inject snippet
    if $DRY_RUN; then
        printf '  [+] Inject snippet into index.html.tpl\n'
    else
        inject_snippet "$theme" "$snippet_file" "$PVE_INDEX"
        log "INFO" "Injected snippet for theme $theme"
    fi

    # Update state
    if ! $DRY_RUN; then
        json_write_state "$theme" "$(date -Iseconds)" "$(get_pve_version)"
    fi

    # Restart pveproxy
    if $DRY_RUN; then
        printf '\n[Service]\n'
        printf '  Restart pveproxy\n'
        printf '\n=====================================\n'
        printf 'No changes made (dry run)\n'
    elif $NO_RESTART; then
        info "Skipping pveproxy restart (--no-restart)"
    else
        systemctl restart pveproxy
        info "pveproxy restarted"
    fi

    if ! $DRY_RUN; then
        info "Theme '$theme' installed successfully"
    fi
}

uninstall_theme() {
    local current
    current=$(get_current_theme)

    if [[ "$current" == "none" || -z "$current" || "$current" == "null" ]]; then
        info "No theme currently installed"
        return 0
    fi

    if $DRY_RUN; then
        printf '[Dry Run: Uninstall %s]\n' "$current"
        printf '=====================================\n\n'
        printf '[Backup]\n'
        printf '  Create backup before changes\n'
        printf '\n[Remove theme: %s]\n' "$current"
    else
        info "Uninstalling theme: $current"
        create_backup "pre-uninstall"
    fi

    # Remove CSS files
    remove_theme_css "$current"

    if $DRY_RUN; then
        printf '  [-] Remove snippet from index.html.tpl\n'
    else
        remove_theme_snippet "$PVE_INDEX"
        json_clear_state
    fi

    # Restart pveproxy
    if $DRY_RUN; then
        printf '\n[Service]\n'
        printf '  Restart pveproxy\n'
        printf '\n=====================================\n'
        printf 'No changes made (dry run)\n'
    elif $NO_RESTART; then
        info "Skipping pveproxy restart (--no-restart)"
    else
        systemctl restart pveproxy
        info "pveproxy restarted"
    fi

    if ! $DRY_RUN; then
        info "Theme uninstalled, default Proxmox UI restored"
    fi
}

# =============================================================================
# BACKUP OPERATIONS
# =============================================================================

create_backup() {
    local label="${1:-manual}"
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local backup_name="${timestamp}-${label}"
    local backup_path="${BACKUP_DIR}/${backup_name}"

    mkdir -p "$backup_path"

    # Copy index file
    cp "$PVE_INDEX" "$backup_path/"

    # Write metadata
    cat > "${backup_path}/metadata.json" <<EOF
{
  "timestamp": "${timestamp}",
  "label": "${label}",
  "pve_version": "$(get_pve_version)",
  "files": ["$(basename "$PVE_INDEX")"]
}
EOF

    log "INFO" "Created backup: $backup_name"
    printf '%s' "$backup_name"
}

list_backups() {
    [[ -d "$BACKUP_DIR" ]] || return 0
    find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

restore_backup() {
    local backup_name="$1"
    local backup_path="${BACKUP_DIR}/${backup_name}"

    [[ -d "$backup_path" ]] || die "Backup not found: $backup_name"

    local index_backup="${backup_path}/$(basename "$PVE_INDEX")"
    [[ -f "$index_backup" ]] || die "Index file not found in backup"

    # Clean up current theme's CSS files before restoring
    local current
    current=$(get_current_theme)

    if $DRY_RUN; then
        printf '[Dry Run: Restore %s]\n' "$backup_name"
        printf '=====================================\n\n'
        if [[ "$current" != "none" && -n "$current" && "$current" != "null" ]]; then
            printf '[Remove current theme: %s]\n' "$current"
            remove_theme_css "$current"
        fi
        printf '\n[Restore]\n'
        printf '  Restore index.html.tpl from backup\n'
        printf '\n[Service]\n'
        printf '  Restart pveproxy\n'
        printf '\n=====================================\n'
        printf 'No changes made (dry run)\n'
        return 0
    fi

    # Remove current theme CSS files
    if [[ "$current" != "none" && -n "$current" && "$current" != "null" ]]; then
        remove_theme_css "$current"
    fi

    cp "$index_backup" "$PVE_INDEX"
    json_clear_state

    if ! $NO_RESTART; then
        systemctl restart pveproxy
        info "pveproxy restarted"
    fi

    log "INFO" "Restored backup: $backup_name"
    info "Backup '$backup_name' restored"
}

# =============================================================================
# THEMES DOWNLOAD (for curl installation)
# =============================================================================

ensure_themes_available() {
    # Check if themes exist
    if [[ -d "$THEMES_DIR" ]] && [[ -n "$(list_themes 2>/dev/null)" ]]; then
        return 0
    fi

    log "INFO" "Local themes not found, downloading..."

    local cache_dir="/tmp/pve-theme-manager-cache"
    mkdir -p "$cache_dir"

    local tarball="${cache_dir}/repo.tar.gz"
    if has_cmd curl; then
        curl -fsSL "$REPO_TARBALL" -o "$tarball" || return 1
    elif has_cmd wget; then
        wget -q "$REPO_TARBALL" -O "$tarball" || return 1
    else
        die "Neither curl nor wget available to download themes"
    fi

    rm -rf "${cache_dir}/extracted"
    mkdir -p "${cache_dir}/extracted"
    tar -xzf "$tarball" -C "${cache_dir}/extracted" || die "Failed to extract themes"

    local extracted
    extracted=$(find "${cache_dir}/extracted" -maxdepth 1 -type d -name 'pve-*' | head -1)

    if [[ -n "$extracted" && -d "${extracted}/themes" ]]; then
        THEMES_DIR="${extracted}/themes"
        log "INFO" "Using downloaded themes from $THEMES_DIR"
    else
        die "Themes folder not found in downloaded archive"
    fi
}

# =============================================================================
# TUI FLOWS
# =============================================================================

show_status() {
    local current
    current=$(get_current_theme)
    local pve_version
    pve_version=$(get_pve_version)

    local status_text
    if [[ "$current" == "none" || -z "$current" || "$current" == "null" ]]; then
        status_text="No theme installed (default Proxmox UI)"
    else
        local installed_at=""
        if [[ -f "$STATE_FILE" ]]; then
            installed_at=$(json_get "$STATE_FILE" "installed_at")
        fi
        status_text="Current theme: ${current}"
        [[ -n "$installed_at" ]] && status_text+="\nInstalled: ${installed_at}"
    fi
    status_text+="\nProxmox version: ${pve_version}"
    status_text+="\nThemes directory: ${THEMES_DIR}"

    printf '%b\n' "$status_text"
}

select_theme_menu() {
    local -a themes
    mapfile -t themes < <(list_themes)

    if [[ ${#themes[@]} -eq 0 ]]; then
        message "No Themes" "No themes found in ${THEMES_DIR}"
        return 1
    fi

    local -a items=()
    local t desc
    for t in "${themes[@]}"; do
        desc=$(json_get "$(get_theme_meta "$t")" "description" 2>/dev/null || echo "No description")
        # Truncate description for menu
        desc="${desc:0:50}"
        items+=("$t" "$desc")
    done

    menu_select "Select Theme" "${items[@]}"
}

install_flow() {
    local theme
    theme=$(select_theme_menu) || return 0
    [[ -z "$theme" ]] && return 0

    # Show theme info
    local info_text
    info_text=$(get_theme_info "$theme")

    local action
    action=$(menu_select "Install: $theme" \
        "1" "Install theme" \
        "2" "Preview (dry run)" \
        "3" "Back")

    case "$action" in
        1)
            if confirm "Install theme '$theme'? This will backup current files first."; then
                install_theme "$theme"
                message "Success" "Theme '$theme' installed successfully.\n\nRefresh your browser to see the changes."
            fi
            ;;
        2)
            DRY_RUN=true
            local output
            output=$(install_theme "$theme" 2>&1)
            DRY_RUN=false
            message "Dry Run: $theme" "$output"
            ;;
    esac
}

preview_flow() {
    local theme
    theme=$(select_theme_menu) || return 0
    [[ -z "$theme" ]] && return 0

    local info_text
    info_text=$(get_theme_info "$theme")
    message "Theme: $theme" "$info_text"
}

backup_flow() {
    local action
    action=$(menu_select "Backup Options" \
        "1" "Create backup" \
        "2" "List/restore backups" \
        "3" "Back")

    case "$action" in
        1)
            local name
            name=$(create_backup "manual")
            message "Backup Created" "Backup saved as: $name"
            ;;
        2)
            restore_flow
            ;;
    esac
}

restore_flow() {
    local -a backups
    mapfile -t backups < <(list_backups)

    if [[ ${#backups[@]} -eq 0 ]]; then
        message "No Backups" "No backups found"
        return 0
    fi

    local -a items=()
    local b
    for b in "${backups[@]}"; do
        items+=("$b" "")
    done

    local choice
    choice=$(menu_select "Select Backup" "${items[@]}")
    [[ -z "$choice" ]] && return 0

    if confirm "Restore backup '$choice'? This will overwrite current files."; then
        restore_backup "$choice"
        message "Restored" "Backup '$choice' restored successfully.\n\nRefresh your browser to see the changes."
    fi
}

main_menu() {
    while true; do
        local current
        current=$(get_current_theme)
        local status_line="Current: ${current}"
        [[ "$current" == "none" || -z "$current" || "$current" == "null" ]] && status_line="Current: Default Proxmox UI"

        local choice
        choice=$(menu_select "PVE Theme Manager v${VERSION} - ${status_line}" \
            "1" "Install / Change Theme" \
            "2" "Preview Theme Info" \
            "3" "Uninstall Theme (Reset to Default)" \
            "4" "Backup & Restore" \
            "5" "Status" \
            "6" "About" \
            "7" "Exit")

        case "$choice" in
            1) install_flow ;;
            2) preview_flow ;;
            3)
                if confirm "Uninstall current theme and restore default Proxmox UI?"; then
                    uninstall_theme
                    message "Reset" "Default Proxmox UI restored.\n\nRefresh your browser to see the changes."
                fi
                ;;
            4) backup_flow ;;
            5) message "Status" "$(show_status)" ;;
            6)
                message "About" "PVE Theme Manager v${VERSION}\n\nAuthor: Marleybop\nLicense: MIT\n\nManage CSS themes for Proxmox VE.\nCreates backups before changes.\nSupports dry-run mode.\n\nRepository:\nhttps://github.com/Marleybop/pve-theme-manager"
                ;;
            7|"") exit 0 ;;
        esac
    done
}

# =============================================================================
# CLI INTERFACE
# =============================================================================

print_usage() {
    cat <<EOF
PVE Theme Manager v${VERSION}

Usage: $(basename "$0") [OPTIONS] [COMMAND] [ARGS]

Commands:
  (none)              Launch TUI mode
  status              Show current theme and system info
  list                List available themes
  install <theme>     Install specified theme
  uninstall           Remove theme, restore default UI
  backup              Create manual backup
  restore [name]      Restore backup (latest if no name given)
  info <theme>        Show theme details

Options:
  --dry-run           Preview changes without modifying files
  --no-restart        Skip pveproxy restart after changes
  -h, --help          Show this help message
  -v, --version       Show version

Examples:
  $(basename "$0")                      # Launch TUI
  $(basename "$0") list                 # List themes
  $(basename "$0") install CyberpunkNeon
  $(basename "$0") --dry-run install Dracula
  $(basename "$0") uninstall
  $(basename "$0") status
EOF
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    local cmd=""
    local args=()

    # Parse options
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --no-restart)
                NO_RESTART=true
                shift
                ;;
            -h|--help)
                print_usage
                exit 0
                ;;
            -v|--version)
                printf 'PVE Theme Manager v%s\n' "$VERSION"
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [[ -z "$cmd" ]]; then
                    cmd="$1"
                else
                    args+=("$1")
                fi
                shift
                ;;
        esac
    done

    # System checks
    require_root
    require_proxmox
    ensure_dirs
    ensure_themes_available || true

    log "INFO" "Script started: cmd=$cmd args=${args[*]:-}"

    # Execute command
    case "$cmd" in
        "")
            main_menu
            ;;
        status)
            show_status
            ;;
        list)
            list_themes
            ;;
        install)
            [[ ${#args[@]} -ge 1 ]] || die "Usage: install <theme>"
            install_theme "${args[0]}"
            ;;
        uninstall)
            uninstall_theme
            ;;
        backup)
            local name
            name=$(create_backup "manual")
            info "Backup created: $name"
            ;;
        restore)
            if [[ ${#args[@]} -ge 1 ]]; then
                restore_backup "${args[0]}"
            else
                # Restore latest
                local latest
                latest=$(list_backups | head -1)
                [[ -n "$latest" ]] || die "No backups found"
                restore_backup "$latest"
            fi
            ;;
        info)
            [[ ${#args[@]} -ge 1 ]] || die "Usage: info <theme>"
            get_theme_info "${args[0]}"
            ;;
        *)
            die "Unknown command: $cmd. Use --help for usage."
            ;;
    esac

    log "INFO" "Script finished"
}

main "$@"

#!/bin/bash
# OSGSameCloudService — One-step installer for handheld devices
# Supports: ArkOS, JELOS, Rocknix, muOS, Knulli, Batocera, and generic Linux
#
# Usage:
#   Copy all three client scripts to the device and run: bash osgsc-setup.sh
#   — or —
#   Set OSGSC_REPO_URL and it will download them.

set -euo pipefail

# --- Configuration ---

_detect_repo_url() {
    local remote
    remote=$(git -C "$(dirname "${BASH_SOURCE[0]}")" remote get-url origin 2>/dev/null) || return 1
    remote="${remote%.git}"
    remote="${remote/git@github.com:/https://github.com/}"
    echo "${remote/github.com/raw.githubusercontent.com}/main"
}
REPO_URL="${OSGSC_REPO_URL:-$(_detect_repo_url 2>/dev/null || echo "")}"
INSTALL_DIR="${OSGSC_INSTALL_DIR:-${HOME}/.local/bin}"
CONFIG_DIR="${HOME}/.config/osgsc"

# --- Colors ---

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

info()  { echo -e "  ${CYAN}>>>${NC} $*"; }
ok()    { echo -e "  ${GREEN} ✓ ${NC} $*"; }
warn()  { echo -e "  ${YELLOW} ! ${NC} $*"; }
err()   { echo -e "  ${RED} ✗ ${NC} $*" >&2; }

step_header() {
    local num="$1" total="$2" title="$3"
    echo ""
    echo -e "  ${BOLD}Step ${num}/${total}: ${title}${NC}"
    echo -e "  ${DIM}$(printf '%.0s─' {1..44})${NC}"
}

prompt_yn() {
    local question="$1" default="${2:-n}"
    local hint="[y/N]"
    [ "$default" = "y" ] && hint="[Y/n]"
    echo -ne "  ${question} ${DIM}${hint}${NC}: " >&2
    local ans
    read -r ans
    ans="${ans:-$default}"
    [[ "$ans" =~ ^[yY] ]]
}

prompt_value() {
    local question="$1" default="${2:-}"
    if [ -n "$default" ]; then
        echo -ne "  ${question} ${DIM}[${default}]${NC}: " >&2
    else
        echo -ne "  ${question}: " >&2
    fi
    local val
    read -r val
    echo "${val:-$default}"
}

prompt_secret() {
    local question="$1"
    echo -ne "  ${question}: " >&2
    local val
    read -rs val
    echo "" >&2
    echo "$val"
}

# --- Firmware detection ---

detect_firmware() {
    if [ -f /opt/system/Advanced/Switch\ to\ main\ SD\ for\ Roms.sh ] || \
       grep -qi "arkos" /etc/hostname 2>/dev/null; then
        echo "arkos"
    elif [ -f /etc/os-release ] && grep -qi "jelos" /etc/os-release 2>/dev/null; then
        echo "jelos"
    elif [ -f /etc/os-release ] && grep -qi "rocknix" /etc/os-release 2>/dev/null; then
        echo "rocknix"
    elif [ -d /mnt/mmc/MUOS ] || [ -d /mnt/sdcard/MUOS ]; then
        echo "muos"
    elif [ -f /etc/os-release ] && grep -qi "knulli\|batocera" /etc/os-release 2>/dev/null; then
        echo "batocera"
    else
        echo "generic"
    fi
}

detect_ports_dir() {
    local fw="$1"
    case "$fw" in
        arkos)
            for d in /roms/ports /roms2/ports; do
                [ -d "$d" ] && echo "$d" && return
            done
            echo "/roms/ports"
            ;;
        jelos|rocknix)
            echo "/storage/roms/ports"
            ;;
        muos)
            for d in /mnt/sdcard/MUOS/application /mnt/mmc/MUOS/application; do
                [ -d "$d" ] && echo "$d" && return
            done
            echo "/mnt/sdcard/MUOS/application"
            ;;
        batocera)
            echo "/userdata/roms/ports"
            ;;
        *)
            echo "${HOME}/Apps"
            ;;
    esac
}

# auto-detect save directory
detect_save_dir() {
    local dirs=(
        # Knulli / Batocera
        "/userdata/saves"
        # ArkOS
        "/roms/saves"
        "/roms2/saves"
        # JELOS / Rocknix
        "/storage/roms/saves"
        "/storage/saves"
        # muOS
        "/mnt/mmc/MUOS/save"
        "/mnt/sdcard/MUOS/save"
        # standard RetroArch
        "${HOME}/.config/retroarch/saves"
        "${HOME}/RetroArch/saves"
    )
    for d in "${dirs[@]}"; do
        if [ -d "$d" ]; then
            echo "$d"
            return 0
        fi
    done
    return 1
}

# --- Install functions ---

install_scripts() {
    local source_dir="$1"

    mkdir -p "$INSTALL_DIR"

    if [ -n "$source_dir" ] && [ -f "${source_dir}/osgsc-sync.sh" ]; then
        info "Installing from local files..."
        cp "${source_dir}/osgsc-sync.sh" "${INSTALL_DIR}/osgsc-sync.sh"
        cp "${source_dir}/osgsc-ui.sh" "${INSTALL_DIR}/osgsc-ui.sh"
    elif [ -n "$REPO_URL" ] && command -v curl &>/dev/null; then
        info "Downloading scripts..."
        curl -sfL "${REPO_URL}/client/osgsc-sync.sh" -o "${INSTALL_DIR}/osgsc-sync.sh" || {
            err "Failed to download osgsc-sync.sh from ${REPO_URL}"
            err "Copy the scripts manually to ${INSTALL_DIR}/"
            exit 1
        }
        curl -sfL "${REPO_URL}/client/osgsc-ui.sh" -o "${INSTALL_DIR}/osgsc-ui.sh" || {
            err "Failed to download osgsc-ui.sh"
            exit 1
        }
    elif [ -n "$REPO_URL" ] && command -v wget &>/dev/null; then
        info "Downloading scripts with wget..."
        wget -q "${REPO_URL}/client/osgsc-sync.sh" -O "${INSTALL_DIR}/osgsc-sync.sh" || {
            err "Failed to download osgsc-sync.sh"
            exit 1
        }
        wget -q "${REPO_URL}/client/osgsc-ui.sh" -O "${INSTALL_DIR}/osgsc-ui.sh" || {
            err "Failed to download osgsc-ui.sh"
            exit 1
        }
    else
        if [ -z "$REPO_URL" ]; then
            err "No local scripts found and OSGSC_REPO_URL is not set."
            err "Either copy the scripts next to this installer, or set OSGSC_REPO_URL."
        else
            err "No curl or wget found. Copy the scripts manually to ${INSTALL_DIR}/"
        fi
        exit 1
    fi

    chmod +x "${INSTALL_DIR}/osgsc-sync.sh"
    chmod +x "${INSTALL_DIR}/osgsc-ui.sh"
    ok "Scripts installed to ${INSTALL_DIR}/"
}

create_port_entry() {
    local ports_dir="$1" fw="$2" server="$3" save_dir="$4"
    mkdir -p "$ports_dir"

    local launcher="${ports_dir}/OSGSC Save Sync.sh"
    local sync_script="${INSTALL_DIR}/osgsc-sync.sh"
    local config_file="${CONFIG_DIR}/config"

    # create an auto-sync launcher that works without a terminal UI
    cat > "$launcher" <<'LAUNCHER_HEAD'
#!/bin/bash
# OSGSC Save Sync — auto-sync launcher for Ports menu
# Uploads local saves, then downloads latest from server.

LAUNCHER_HEAD

    cat >> "$launcher" <<LAUNCHER_VARS
CONFIG_FILE="${config_file}"
SYNC_SCRIPT="${sync_script}"
LAUNCHER_VARS

    cat >> "$launcher" <<'LAUNCHER_BODY'

# read config
if [ -f "$CONFIG_FILE" ]; then
    . "$CONFIG_FILE"
fi
SERVER="${SERVER_URL:-}"
SAVEDIR="${SAVE_DIR:-}"

if [ -z "$SERVER" ]; then
    echo "ERROR: No server configured. Run osgsc-setup.sh again." > /tmp/osgsc-sync-status.txt
    exit 1
fi

LOG="/tmp/osgsc-sync-status.txt"

{
    echo "=== OSGSC Save Sync ==="
    echo "Server: $SERVER"
    echo "Save dir: $SAVEDIR"
    echo ""

    echo ">>> Uploading saves..."
    if [ -n "$SAVEDIR" ]; then
        "$SYNC_SCRIPT" upload -s "$SERVER" -d "$SAVEDIR" 2>&1
    else
        "$SYNC_SCRIPT" upload -s "$SERVER" 2>&1
    fi
    echo ""

    echo ">>> Downloading saves..."
    if [ -n "$SAVEDIR" ]; then
        "$SYNC_SCRIPT" download -s "$SERVER" -d "$SAVEDIR" 2>&1
    else
        "$SYNC_SCRIPT" download -s "$SERVER" 2>&1
    fi
    echo ""

    echo "=== Sync complete ==="
    echo "$(date)"
} > "$LOG" 2>&1
LAUNCHER_BODY

    chmod +x "$launcher"
    ok "Created Ports entry: ${launcher}"

    # Batocera/Knulli need a gamelist.xml entry for EmulationStation
    if [ "$fw" = "batocera" ]; then
        local gamelist="${ports_dir}/gamelist.xml"
        local entry_name="OSGSC Save Sync"
        local entry_path="./OSGSC Save Sync.sh"

        if [ -f "$gamelist" ]; then
            if grep -q "OSGSC Save Sync" "$gamelist" 2>/dev/null; then
                ok "gamelist.xml already has OSGSC entry"
                return
            fi
            sed -i "s|</gameList>|\t<game>\n\t\t<path>${entry_path}</path>\n\t\t<name>${entry_name}</name>\n\t</game>\n</gameList>|" "$gamelist"
        else
            cat > "$gamelist" <<GAMELIST
<?xml version="1.0"?>
<gameList>
	<game>
		<path>${entry_path}</path>
		<name>${entry_name}</name>
	</game>
</gameList>
GAMELIST
        fi
        ok "Added to gamelist.xml"
    fi
}

setup_autosync() {
    local server="$1" interval_min="${2:-60}"

    if ! command -v crontab &>/dev/null; then
        warn "crontab not available — skipping auto-sync."
        return
    fi

    local wrapper="${INSTALL_DIR}/osgsc-cron.sh"
    cat > "$wrapper" <<WRAPPER
#!/bin/bash
# auto-generated cron wrapper — uploads saves using stored token
${INSTALL_DIR}/osgsc-sync.sh upload -s "${server}" 2>/dev/null
WRAPPER
    chmod 700 "$wrapper"

    local cron_line="*/${interval_min} * * * * ${wrapper} >> /tmp/osgsc-cron.log 2>&1"

    local existing
    existing=$(crontab -l 2>/dev/null || true)
    if echo "$existing" | grep -qE "osgsc-sync\.sh|osgsc-cron\.sh"; then
        warn "Auto-sync cron entry already exists, skipping."
        return
    fi

    (echo "$existing"; echo "$cron_line") | crontab -
    ok "Auto-sync enabled: uploads every ${interval_min} minutes"
}

configure_account() {
    local server="$1" username="$2" password="$3" action="$4" save_dir="$5"

    local output
    local rc=0
    output=$("${INSTALL_DIR}/osgsc-sync.sh" "$action" -s "$server" -u "$username" -p "$password" 2>&1) || rc=$?

    if [ "$rc" -ne 0 ] || [ -z "$output" ] || echo "$output" | grep -qi "error\|fail"; then
        err "${output:-Connection failed. Is the server running at ${server}?}"
        return 1
    fi

    ok "$output"

    # save config
    mkdir -p "$CONFIG_DIR"
    cat > "${CONFIG_DIR}/config" <<CONF
SERVER_URL="${server}"
SAVE_DIR="${save_dir}"
CONF
    chmod 600 "${CONFIG_DIR}/config" 2>/dev/null || true
}

# --- Main ---

main() {
    echo ""
    echo "  ================================================"
    echo "    OSGSC Save Sync — Device Installer"
    echo "    Cloud saves for RetroArch handhelds"
    echo "  ================================================"

    # detect what we're running on
    local firmware
    firmware=$(detect_firmware)
    local ports_dir
    ports_dir=$(detect_ports_dir "$firmware")
    local this_dir
    this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # ==================================================================
    #  Step 1: Detect environment
    # ==================================================================
    step_header "1" "5" "Detecting environment"

    ok "Firmware: ${firmware}"
    ok "Ports directory: ${ports_dir}"
    ok "Install directory: ${INSTALL_DIR}"

    if ! command -v bash &>/dev/null; then
        err "bash is required"; exit 1
    fi
    ok "bash found"
    if command -v curl &>/dev/null; then
        ok "curl found"
    else
        warn "curl not found — uploads/downloads won't work"
    fi
    if command -v jq &>/dev/null; then
        ok "jq found"
    else
        warn "jq not found — downloads won't work (install with: apt install jq)"
    fi

    # ==================================================================
    #  Step 2: Save directory
    # ==================================================================
    step_header "2" "5" "Save directory"
    echo ""

    local detected_save_dir=""
    if detected_save_dir=$(detect_save_dir); then
        ok "Auto-detected: ${detected_save_dir}"
    fi

    local save_dir
    save_dir=$(prompt_value "Save directory" "${detected_save_dir}")

    if [ -z "$save_dir" ]; then
        err "Save directory is required."
        exit 1
    fi

    if [ ! -d "$save_dir" ]; then
        warn "Directory ${save_dir} does not exist yet."
        if prompt_yn "Create it?" "y"; then
            mkdir -p "$save_dir"
            ok "Created ${save_dir}"
        fi
    else
        # show what's in there
        local count
        count=$(find "$save_dir" -maxdepth 2 -type f \( -name "*.srm" -o -name "*.sav" -o -name "*.state" -o -name "*.rtc" \) 2>/dev/null | wc -l)
        ok "Found ${count} save file(s) in ${save_dir}"
    fi

    # ==================================================================
    #  Step 3: Server configuration
    # ==================================================================
    step_header "3" "5" "Server configuration"
    echo ""

    local server
    server=$(prompt_value "Server URL (e.g. http://192.168.1.50:4444)" "")

    if [ -z "$server" ]; then
        err "Server URL is required."
        exit 1
    fi

    local username
    username=$(prompt_value "Username" "")

    if [ -z "$username" ]; then
        err "Username is required."
        exit 1
    fi

    local password
    password=$(prompt_secret "Password")

    if [ -z "$password" ]; then
        err "Password is required."
        exit 1
    fi

    echo ""
    echo "      1) Log in to existing account"
    echo "      2) Create new account"
    echo ""

    local acct_choice="" action=""
    while true; do
        acct_choice=$(prompt_value "Choose [1 or 2]" "")
        case "$acct_choice" in
            1) action="login"; break;;
            2) action="register"; break;;
            *) echo -e "  ${RED}Please enter 1 or 2.${NC}" >&2;;
        esac
    done

    # ==================================================================
    #  Step 4: Confirm
    # ==================================================================
    step_header "4" "5" "Confirm"
    echo ""

    echo -e "      Firmware:     ${BOLD}${firmware}${NC}"
    echo -e "      Save dir:     ${BOLD}${save_dir}${NC}"
    echo -e "      Server:       ${BOLD}${server}${NC}"
    echo -e "      Username:     ${BOLD}${username}${NC}"
    echo -e "      Account:      ${BOLD}${action}${NC}"
    echo ""

    if ! prompt_yn "Proceed with installation?" "y"; then
        echo ""
        info "Aborted."
        exit 0
    fi

    # ==================================================================
    #  Step 5: Installing
    # ==================================================================
    step_header "5" "5" "Installing"

    # install scripts
    install_scripts "$this_dir"

    # configure account + save config
    if ! configure_account "$server" "$username" "$password" "$action" "$save_dir"; then
        warn "Account setup failed — you can configure later via SSH."
    fi

    # create ports entry (auto-sync, no TUI)
    create_port_entry "$ports_dir" "$firmware" "$server" "$save_dir"

    # ==================================================================
    #  Done
    # ==================================================================
    echo ""
    echo "  ================================================"
    ok "Installation complete!"
    echo ""
    echo "      Launch 'OSGSC Save Sync' from Ports menu"
    echo "      to upload & download saves automatically."
    echo ""
    echo "      Save directory: ${save_dir}"
    echo "      Server: ${server}"
    echo ""
    echo "      To change settings, edit:"
    echo "        ${CONFIG_DIR}/config"
    echo ""
    echo "      Manual sync via SSH:"
    echo "        ${INSTALL_DIR}/osgsc-sync.sh upload -s ${server} -d ${save_dir}"
    echo "        ${INSTALL_DIR}/osgsc-sync.sh download -s ${server} -d ${save_dir}"
    echo ""
    echo "      Interactive UI via SSH:"
    echo "        ${INSTALL_DIR}/osgsc-ui.sh"
    echo "  ================================================"
    echo ""
}

main "$@"

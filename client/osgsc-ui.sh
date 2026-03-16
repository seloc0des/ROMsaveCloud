#!/bin/bash
# OSGSameCloudService — TUI for handheld devices (Anbernic, etc.)
# Provides a dialog-based menu for syncing saves without typing commands.
# Works with dialog, whiptail, or falls back to a plain text menu.
#
# Requires: osgsc-sync.sh in the same directory (or on PATH)

set -euo pipefail

# EmulationStation and some launchers don't set TERM
export TERM="${TERM:-linux}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/osgsc-sync.sh"
CONFIG_DIR="${HOME}/.config/osgsc"
CONFIG_FILE="${CONFIG_DIR}/config"

# --- UI backend detection ---

DIALOG_CMD=""
detect_dialog() {
    if command -v dialog &>/dev/null; then
        DIALOG_CMD="dialog"
    elif command -v whiptail &>/dev/null; then
        DIALOG_CMD="whiptail"
    fi
}

# --- Dialog wrappers ---

# show a menu, return the selected tag via stdout
ui_menu() {
    local title="$1" text="$2"
    shift 2
    # remaining args are tag/item pairs
    if [ -n "$DIALOG_CMD" ]; then
        local choice
        choice=$("$DIALOG_CMD" --clear --title "$title" --menu "$text" 18 60 10 "$@" 3>&1 1>&2 2>&3) || return 1
        echo "$choice"
    else
        # plain text fallback
        echo "" >&2
        echo "=== $title ===" >&2
        echo "$text" >&2
        echo "" >&2
        local i=1
        local -a tags=()
        while [ $# -ge 2 ]; do
            tags+=("$1")
            echo "  $i) $1 — $2" >&2
            shift 2
            i=$((i + 1))
        done
        echo "  0) Cancel" >&2
        echo -n "Choice: " >&2
        local num
        read -r num
        if [ "$num" = "0" ] || [ -z "$num" ]; then
            return 1
        fi
        local idx=$((num - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#tags[@]}" ]; then
            echo "${tags[$idx]}"
        else
            return 1
        fi
    fi
}

ui_inputbox() {
    local title="$1" text="$2" default="${3:-}"
    if [ -n "$DIALOG_CMD" ]; then
        local val
        val=$("$DIALOG_CMD" --clear --title "$title" --inputbox "$text" 10 60 "$default" 3>&1 1>&2 2>&3) || return 1
        echo "$val"
    else
        echo "" >&2
        echo "=== $title ===" >&2
        if [ -n "$default" ]; then
            echo -n "$text [$default]: " >&2
        else
            echo -n "$text: " >&2
        fi
        local val
        read -r val
        echo "${val:-$default}"
    fi
}

ui_passwordbox() {
    local title="$1" text="$2"
    if [ -n "$DIALOG_CMD" ]; then
        local val
        if [ "$DIALOG_CMD" = "dialog" ]; then
            val=$("$DIALOG_CMD" --clear --title "$title" --insecure --passwordbox "$text" 10 60 3>&1 1>&2 2>&3) || return 1
        else
            val=$("$DIALOG_CMD" --title "$title" --passwordbox "$text" 10 60 3>&1 1>&2 2>&3) || return 1
        fi
        echo "$val"
    else
        echo "" >&2
        echo -n "$text: " >&2
        local val
        read -rs val
        echo "" >&2
        echo "$val"
    fi
}

ui_msgbox() {
    local title="$1" text="$2"
    if [ -n "$DIALOG_CMD" ]; then
        "$DIALOG_CMD" --clear --title "$title" --msgbox "$text" 12 60
    else
        echo "" >&2
        echo "=== $title ===" >&2
        echo "$text" >&2
        echo "" >&2
        echo -n "Press Enter to continue..." >&2
        read -r
    fi
}

ui_yesno() {
    local title="$1" text="$2"
    if [ -n "$DIALOG_CMD" ]; then
        "$DIALOG_CMD" --clear --title "$title" --yesno "$text" 10 60
        return $?
    else
        echo "" >&2
        echo "=== $title ===" >&2
        echo -n "$text [y/N]: " >&2
        local ans
        read -r ans
        case "$ans" in
            [yY]*) return 0;;
            *) return 1;;
        esac
    fi
}

# capture command output in a way that works with dialog
ui_run_command() {
    local title="$1"
    shift
    local output
    if [ -n "$DIALOG_CMD" ] && [ "$DIALOG_CMD" = "dialog" ]; then
        output=$("$@" 2>&1) || true
        "$DIALOG_CMD" --clear --title "$title" --msgbox "$output" 20 70
    else
        echo "" >&2
        echo "=== $title ===" >&2
        "$@" 2>&1 || true
        echo "" >&2
        echo -n "Press Enter to continue..." >&2
        read -r
    fi
}

# --- Config management ---

load_config() {
    SERVER_URL=""
    SAVE_DIR=""
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<CONF
SERVER_URL="${SERVER_URL}"
SAVE_DIR="${SAVE_DIR}"
CONF
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}

# --- Screens ---

screen_setup() {
    local server
    server=$(ui_inputbox "Server Setup" "Enter server URL (e.g. http://192.168.1.50:4444)" "$SERVER_URL") || return

    if [ -z "$server" ]; then
        ui_msgbox "Error" "Server URL cannot be empty."
        return
    fi

    SERVER_URL="$server"

    local action
    action=$(ui_menu "Account" "Log in or create a new account?" \
        "login" "Log in to existing account" \
        "register" "Create a new account") || return

    local username password
    username=$(ui_inputbox "Account" "Username") || return
    password=$(ui_passwordbox "Account" "Password") || return

    if [ -z "$username" ] || [ -z "$password" ]; then
        ui_msgbox "Error" "Username and password are required."
        return
    fi

    local output
    local rc=0
    output=$("$SYNC_SCRIPT" "$action" -s "$SERVER_URL" -u "$username" -p "$password" 2>&1) || rc=$?

    if [ "$rc" -ne 0 ] || [ -z "$output" ] || echo "$output" | grep -qi "error\|fail"; then
        ui_msgbox "Error" "${output:-Connection failed. Is the server running?}"
    else
        save_config
        ui_msgbox "Success" "$output"
    fi
}

screen_settings() {
    while true; do
        local choice
        choice=$(ui_menu "Settings" "Current server: ${SERVER_URL:-not set}\nSave dir: ${SAVE_DIR:-auto-detect}" \
            "server" "Change server URL" \
            "savedir" "Set save directory" \
            "login" "Log in / switch account" \
            "register" "Create new account" \
            "back" "Back to main menu") || return

        case "$choice" in
            server)
                local val
                val=$(ui_inputbox "Server URL" "Enter server URL" "$SERVER_URL") || continue
                SERVER_URL="$val"
                save_config
                ;;
            savedir)
                local val
                val=$(ui_inputbox "Save Directory" "Path to RetroArch saves folder\n(leave blank for auto-detect)" "$SAVE_DIR") || continue
                SAVE_DIR="$val"
                save_config
                ;;
            login|register)
                local user pass
                user=$(ui_inputbox "Account" "Username") || continue
                pass=$(ui_passwordbox "Account" "Password") || continue
                if [ -n "$user" ] && [ -n "$pass" ] && [ -n "$SERVER_URL" ]; then
                    local out
                    out=$("$SYNC_SCRIPT" "$choice" -s "$SERVER_URL" -u "$user" -p "$pass" 2>&1) || true
                    ui_msgbox "Result" "$out"
                fi
                ;;
            back) return;;
        esac
    done
}

screen_upload() {
    if [ -z "$SERVER_URL" ]; then
        ui_msgbox "Not configured" "Set up your server first in Settings."
        return
    fi

    local args=(-s "$SERVER_URL")
    [ -n "$SAVE_DIR" ] && args+=(-d "$SAVE_DIR")

    # ask for optional system filter
    if ui_yesno "Upload" "Filter by system/core name?\n(No = upload all saves)"; then
        local sys
        sys=$(ui_inputbox "System" "System name (e.g. gba, snes, psx)") || true
        [ -n "$sys" ] && args+=(-y "$sys")
    fi

    ui_run_command "Uploading saves..." "$SYNC_SCRIPT" upload "${args[@]}"
}

screen_download() {
    if [ -z "$SERVER_URL" ]; then
        ui_msgbox "Not configured" "Set up your server first in Settings."
        return
    fi

    local args=(-s "$SERVER_URL")
    [ -n "$SAVE_DIR" ] && args+=(-d "$SAVE_DIR")

    # optional system filter
    local sys=""
    if ui_yesno "Download" "Filter by system?"; then
        sys=$(ui_inputbox "System" "System name (e.g. gba, snes, psx)") || true
        [ -n "$sys" ] && args+=(-y "$sys")
    fi

    # optional game filter
    if ui_yesno "Download" "Filter by game name?"; then
        local game
        game=$(ui_inputbox "Game" "Game name") || true
        [ -n "$game" ] && args+=(-g "$game")
    fi

    ui_run_command "Downloading saves..." "$SYNC_SCRIPT" download "${args[@]}"
}

screen_list() {
    if [ -z "$SERVER_URL" ]; then
        ui_msgbox "Not configured" "Set up your server first in Settings."
        return
    fi

    local args=(-s "$SERVER_URL")

    if ui_yesno "List" "Filter by system?"; then
        local sys
        sys=$(ui_inputbox "System" "System name") || true
        [ -n "$sys" ] && args+=(-y "$sys")
    fi

    ui_run_command "Saves on server" "$SYNC_SCRIPT" list "${args[@]}"
}

# --- Main loop ---

main() {
    detect_dialog
    load_config

    # first-run: jump straight to setup if no server configured
    if [ -z "$SERVER_URL" ]; then
        ui_msgbox "Welcome" "Welcome to OSGSC Save Sync!\n\nLet's set up your server connection."
        screen_setup
        load_config
    fi

    while true; do
        local choice
        choice=$(ui_menu "OSGSC Save Sync" "Server: ${SERVER_URL:-not set}" \
            "upload" "Upload saves to server" \
            "download" "Download saves from server" \
            "list" "List saves on server" \
            "settings" "Settings" \
            "quit" "Exit") || break

        case "$choice" in
            upload)   screen_upload;;
            download) screen_download;;
            list)     screen_list;;
            settings) screen_settings;;
            quit)     break;;
        esac
    done

    # clear screen on exit if using dialog
    [ -n "$DIALOG_CMD" ] && clear
}

main "$@"

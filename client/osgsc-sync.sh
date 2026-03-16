#!/bin/bash
# OSGSameCloudService sync client for embedded Linux devices
# Works on ArkOS, JELOS, Rocknix, muOS, Knulli, Batocera, and any Linux with bash+curl
# No Python required — just bash, curl, and optionally jq (falls back to grep parsing)
#
# Install: copy this script to your device and chmod +x
# Usage:
#   osgsc-sync.sh register -s http://server:4444 -u user -p pass
#   osgsc-sync.sh login    -s http://server:4444 -u user -p pass
#   osgsc-sync.sh upload   -s http://server:4444 -d /path/to/saves [-y system]
#   osgsc-sync.sh download -s http://server:4444 -d /path/to/saves [-y system] [-g game]
#   osgsc-sync.sh list     -s http://server:4444 [-y system]

set -euo pipefail

CONFIG_DIR="${HOME}/.config/osgsc"
TOKEN_FILE="${CONFIG_DIR}/token"

# known RetroArch save paths on common handheld firmware
guess_save_dir() {
    local dirs=(
        # ArkOS
        "/roms/saves"
        "/roms2/saves"
        # JELOS / Rocknix
        "/storage/roms/saves"
        "/storage/saves"
        # muOS
        "/mnt/mmc/MUOS/save"
        "/mnt/sdcard/MUOS/save"
        # Knulli / Batocera
        "/userdata/saves"
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

# save extensions we care about
SAVE_EXTENSIONS="srm sav state state1 state2 state3 state4 state5 state6 state7 state8 state9 rtc"

# --- JSON helpers (no jq dependency) ---

# extract a value from a flat JSON object: json_get '{"foo":"bar"}' foo -> bar
json_get() {
    local json="$1" key="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".$key // empty"
    else
        # fallback: grep-based extraction for simple flat JSON (busybox compatible)
        echo "$json" | grep -o "\"${key}\" *: *\"[^\"]*\"" | head -1 | sed 's/.*: *"//;s/"$//'
    fi
}

# extract a numeric value
json_get_num() {
    local json="$1" key="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".$key // empty"
    else
        echo "$json" | grep -o "\"${key}\" *: *[0-9]*" | head -1 | sed 's/.*: *//'
    fi
}

# --- Token management ---

normalize_server() {
    # strip trailing slash so http://host:4444 and http://host:4444/ key the same
    echo "${1%/}"
}

save_token() {
    local server token
    server=$(normalize_server "$1")
    token="$2"
    mkdir -p "$CONFIG_DIR"
    echo "${server}|${token}" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
}

load_token() {
    local server
    server=$(normalize_server "$1")
    if [ ! -f "$TOKEN_FILE" ]; then
        echo ""
        return
    fi
    local line
    line=$(grep -F "${server}|" "$TOKEN_FILE" 2>/dev/null | head -1)
    echo "${line#*|}"
}

# --- API helpers ---

api_post_json() {
    local url="$1" data="$2"
    shift 2
    local extra_args=("$@")
    curl -sf -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$data" \
        "${extra_args[@]}" 2>/dev/null
}

api_get() {
    local url="$1" token="$2"
    curl -sf -X GET "$url" \
        -H "Authorization: Bearer ${token}" 2>/dev/null
}

api_upload() {
    local url="$1" token="$2" filepath="$3"
    # copy to a safe temp path — curl -F breaks on commas/semicolons in paths
    local tmpfile="/tmp/osgsc-upload-$$.tmp"
    cp "$filepath" "$tmpfile" 2>/dev/null || return 1
    curl -sf -X POST "$url" \
        -H "Authorization: Bearer ${token}" \
        -F "file=@${tmpfile}" 2>/dev/null
    local rc=$?
    rm -f "$tmpfile"
    return $rc
}

api_download() {
    local url="$1" token="$2" outpath="$3"
    curl -sf -X GET "$url" \
        -H "Authorization: Bearer ${token}" \
        -o "$outpath" 2>/dev/null
}

# --- URL encoding ---

# escape a string for safe embedding in JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    echo "$s"
}

urlencode() {
    local string="$1"
    # try python3 first (pipe to avoid shell injection), fall back to sed
    echo "$string" | python3 -c "import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))" 2>/dev/null \
        || echo "$string" | sed "s/%/%25/g;s/ /%20/g;s/'/%27/g;s/!/%21/g;s/#/%23/g;s/&/%26/g;s/(/%28/g;s/)/%29/g;s/+/%2B/g;s/,/%2C/g;s/;/%3B/g;s/=/%3D/g;s/\[/%5B/g;s/\]/%5D/g"
}

# --- Commands ---

cmd_register() {
    local server="" username="" password=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--server) server="$2"; shift 2;;
            -u|--username) username="$2"; shift 2;;
            -p|--password) password="$2"; shift 2;;
            *) echo "Unknown option: $1" >&2; exit 1;;
        esac
    done
    if [ -z "$server" ] || [ -z "$username" ] || [ -z "$password" ]; then
        echo "Usage: $0 register -s SERVER -u USERNAME -p PASSWORD" >&2; exit 1
    fi

    local esc_user esc_pass
    esc_user=$(json_escape "$username")
    esc_pass=$(json_escape "$password")

    local resp
    resp=$(api_post_json "${server}/api/auth/register" \
        "{\"username\":\"${esc_user}\",\"password\":\"${esc_pass}\"}") || true

    if [ -z "$resp" ]; then
        echo "Error: registration failed. Server may be unreachable or username taken." >&2
        exit 1
    fi

    local token
    token=$(json_get "$resp" "access_token")
    if [ -z "$token" ]; then
        echo "Error: no token in response" >&2
        exit 1
    fi

    save_token "$server" "$token"
    echo "Registered and logged in as '${username}'"
}

cmd_login() {
    local server="" username="" password=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--server) server="$2"; shift 2;;
            -u|--username) username="$2"; shift 2;;
            -p|--password) password="$2"; shift 2;;
            *) echo "Unknown option: $1" >&2; exit 1;;
        esac
    done
    if [ -z "$server" ] || [ -z "$username" ] || [ -z "$password" ]; then
        echo "Usage: $0 login -s SERVER -u USERNAME -p PASSWORD" >&2; exit 1
    fi

    local esc_user esc_pass
    esc_user=$(json_escape "$username")
    esc_pass=$(json_escape "$password")

    local resp
    resp=$(api_post_json "${server}/api/auth/login" \
        "{\"username\":\"${esc_user}\",\"password\":\"${esc_pass}\"}") || true

    if [ -z "$resp" ]; then
        echo "Error: login failed. Check credentials or server URL." >&2
        exit 1
    fi

    local token
    token=$(json_get "$resp" "access_token")
    if [ -z "$token" ]; then
        echo "Error: invalid credentials" >&2
        exit 1
    fi

    save_token "$server" "$token"
    echo "Logged in as '${username}'"
}

cmd_upload() {
    local server="" save_dir="" system="" watch=false interval=300
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--server) server="$2"; shift 2;;
            -d|--save-dir) save_dir="$2"; shift 2;;
            -y|--system) system="$2"; shift 2;;
            -w|--watch) watch=true; shift;;
            -i|--interval) interval="$2"; shift 2;;
            *) echo "Unknown option: $1" >&2; exit 1;;
        esac
    done

    [ -z "$server" ] && { echo "Error: --server required" >&2; exit 1; }

    local token
    token=$(load_token "$server")
    [ -z "$token" ] && { echo "Error: not logged in. Run 'login' first." >&2; exit 1; }

    # auto-detect save directory if not specified
    if [ -z "$save_dir" ]; then
        save_dir=$(guess_save_dir) || {
            echo "Error: could not find RetroArch saves directory. Use --save-dir." >&2
            exit 1
        }
        echo "Auto-detected save directory: ${save_dir}"
    fi

    [ ! -d "$save_dir" ] && { echo "Error: directory not found: ${save_dir}" >&2; exit 1; }

    while true; do
        local count=0
        # find save files
        for ext in $SAVE_EXTENSIONS; do
            while IFS= read -r -d '' filepath; do
                local filename basename game_name sys_name

                filename=$(basename "$filepath")
                basename="${filename%.*}"
                game_name="$basename"

                # detect system from directory structure
                # walk up from the file looking for a dir that's a direct child of save_dir
                local sys_name_detected=""
                local dir_cursor
                dir_cursor=$(dirname "$filepath")
                while [ "$dir_cursor" != "$save_dir" ] && [ "$dir_cursor" != "/" ]; do
                    local dir_parent
                    dir_parent=$(dirname "$dir_cursor")
                    if [ "$dir_parent" = "$save_dir" ]; then
                        sys_name_detected=$(basename "$dir_cursor")
                        break
                    fi
                    dir_cursor="$dir_parent"
                done
                if [ -n "$sys_name_detected" ]; then
                    sys_name="${system:-$sys_name_detected}"
                else
                    sys_name="${system:-unknown}"
                fi

                local encoded_sys encoded_game encoded_file
                encoded_sys=$(urlencode "$sys_name")
                encoded_game=$(urlencode "$game_name")
                encoded_file=$(urlencode "$filename")

                local resp
                resp=$(api_upload \
                    "${server}/api/saves/upload?system_name=${encoded_sys}&game_name=${encoded_game}&file_name=${encoded_file}" \
                    "$token" "$filepath") || true

                if [ -n "$resp" ]; then
                    local ver msg
                    ver=$(json_get_num "$resp" "version")
                    msg=$(json_get "$resp" "message")
                    echo "  [${sys_name}] ${game_name}/${filename} -> v${ver} (${msg})"
                    count=$((count + 1))
                else
                    echo "  [${sys_name}] ${game_name}/${filename} -> FAILED" >&2
                fi
            done < <(find "$save_dir" -name "*.${ext}" -type f -print0 2>/dev/null)
        done

        echo "Processed ${count} file(s)"

        if [ "$watch" = false ]; then
            break
        fi
        echo "Waiting ${interval}s before next sync..."
        sleep "$interval"
    done
}

cmd_download() {
    local server="" save_dir="" system="" game=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--server) server="$2"; shift 2;;
            -d|--save-dir) save_dir="$2"; shift 2;;
            -y|--system) system="$2"; shift 2;;
            -g|--game) game="$2"; shift 2;;
            *) echo "Unknown option: $1" >&2; exit 1;;
        esac
    done

    [ -z "$server" ] && { echo "Error: --server required" >&2; exit 1; }

    local token
    token=$(load_token "$server")
    [ -z "$token" ] && { echo "Error: not logged in. Run 'login' first." >&2; exit 1; }

    if [ -z "$save_dir" ]; then
        save_dir=$(guess_save_dir) || {
            echo "Error: could not find RetroArch saves directory. Use --save-dir." >&2
            exit 1
        }
        echo "Auto-detected save directory: ${save_dir}"
    fi

    # build list query
    local list_url="${server}/api/saves/list"
    local params=""
    [ -n "$system" ] && params="system_name=$(urlencode "$system")"
    [ -n "$game" ] && {
        [ -n "$params" ] && params="${params}&"
        params="${params}game_name=$(urlencode "$game")"
    }
    [ -n "$params" ] && list_url="${list_url}?${params}"

    local resp
    resp=$(api_get "$list_url" "$token") || true
    if [ -z "$resp" ]; then
        echo "Error: failed to fetch save list" >&2
        exit 1
    fi

    # download each save (latest version only)
    # we need jq for this part or a more capable parser
    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' is required for downloads. Install it with your package manager." >&2
        echo "  ArkOS/JELOS: usually pre-installed" >&2
        echo "  Debian/Ubuntu: sudo apt install jq" >&2
        exit 1
    fi

    local count=0
    local save_keys
    # get unique latest saves: group by system+game+filename, take highest version
    save_keys=$(echo "$resp" | jq -r '.saves | group_by(.system_name, .game_name, .file_name) | .[] | sort_by(.version) | last | [.system_name, .game_name, .file_name] | @tsv')

    if [ -z "$save_keys" ]; then
        echo "No saves found on server."
        return
    fi

    while IFS=$'\t' read -r sys_name game_name file_name; do
        local encoded_sys encoded_game encoded_file
        encoded_sys=$(urlencode "$sys_name")
        encoded_game=$(urlencode "$game_name")
        encoded_file=$(urlencode "$file_name")

        # find where this file already exists on disk so we overwrite in place
        # this handles nested dirs like roms/gba/gba/ or roms/gba/
        local out_path=""
        if [ -d "${save_dir}/${sys_name}" ]; then
            local existing
            existing=$(find "${save_dir}/${sys_name}" -name "$file_name" -type f 2>/dev/null | head -1)
            if [ -n "$existing" ]; then
                out_path="$existing"
            else
                out_path="${save_dir}/${sys_name}/${file_name}"
            fi
        else
            # system dir doesn't exist — skip, probably bad data on server
            echo "  [${sys_name}] ${game_name}/${file_name} -> SKIPPED (unknown system)" >&2
            continue
        fi

        local dl_url="${server}/api/saves/download?system_name=${encoded_sys}&game_name=${encoded_game}&file_name=${encoded_file}"

        if api_download "$dl_url" "$token" "$out_path"; then
            echo "  [${sys_name}] ${game_name}/${file_name} -> ${out_path}"
            count=$((count + 1))
        else
            echo "  [${sys_name}] ${game_name}/${file_name} -> FAILED" >&2
        fi
    done <<< "$save_keys"

    echo "Downloaded ${count} file(s)"
}

cmd_list() {
    local server="" system=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -s|--server) server="$2"; shift 2;;
            -y|--system) system="$2"; shift 2;;
            *) echo "Unknown option: $1" >&2; exit 1;;
        esac
    done

    [ -z "$server" ] && { echo "Error: --server required" >&2; exit 1; }

    local token
    token=$(load_token "$server")
    [ -z "$token" ] && { echo "Error: not logged in. Run 'login' first." >&2; exit 1; }

    local list_url="${server}/api/saves/list"
    [ -n "$system" ] && list_url="${list_url}?system_name=$(urlencode "$system")"

    local resp
    resp=$(api_get "$list_url" "$token") || true
    if [ -z "$resp" ]; then
        echo "Error: failed to fetch save list" >&2
        exit 1
    fi

    if command -v jq &>/dev/null; then
        local total
        total=$(echo "$resp" | jq -r '.total')
        if [ "$total" = "0" ]; then
            echo "No saves found."
            return
        fi
        echo "$resp" | jq -r '.saves[] | "  [\(.system_name)] \(.game_name)/\(.file_name)  v\(.version)  \(.file_size/1024 | floor)KB  \(.uploaded_at)"'
        echo ""
        echo "Total: ${total} save(s)"
    else
        # basic fallback without jq
        echo "$resp"
    fi
}

# --- Main ---

show_help() {
    cat <<'HELP'
OSGSameCloudService sync client (bash/curl)

Commands:
  register   Create a new account
  login      Log in to existing account
  upload     Upload save files to server
  download   Download save files from server
  list       List saves on server

Options:
  -s, --server URL     Server URL (required)
  -u, --username USER  Username (register/login)
  -p, --password PASS  Password (register/login)
  -d, --save-dir PATH  RetroArch saves directory (auto-detected if omitted)
  -y, --system NAME    System/core name filter
  -g, --game NAME      Game name filter (download only)
  -w, --watch          Keep syncing on interval (upload only)
  -i, --interval SECS  Watch interval in seconds (default: 300)

Examples:
  osgsc-sync.sh register -s http://192.168.1.50:4444 -u player1 -p mypassword
  osgsc-sync.sh upload -s http://192.168.1.50:4444
  osgsc-sync.sh download -s http://192.168.1.50:4444 -y gba
  osgsc-sync.sh list -s http://192.168.1.50:4444
HELP
}

if [ $# -lt 1 ]; then
    show_help
    exit 1
fi

command="$1"
shift

case "$command" in
    register) cmd_register "$@";;
    login)    cmd_login "$@";;
    upload)   cmd_upload "$@";;
    download) cmd_download "$@";;
    list)     cmd_list "$@";;
    help|-h|--help) show_help;;
    *) echo "Unknown command: ${command}. Run '$0 help' for usage." >&2; exit 1;;
esac

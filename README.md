# OSGSameCloudService

Open source cloud backup service for RetroArch game saves. Sync your `.srm`, `.sav`, and save state files across all your devices — handhelds, PCs, phones.

Built for **Anbernic** and other retro handheld devices running Linux firmware (ArkOS, JELOS, Rocknix, muOS, Knulli, Batocera), plus **Android**, **Linux desktop**, and **Windows**.

## Features

- Upload/download RetroArch save files via REST API
- Organized by system (core) and game name
- Automatic save versioning (keeps last 5 by default)
- Duplicate detection — skips upload if save hasn't changed
- Web UI for browsing and managing saves from any browser
- **On-device TUI** — menu-driven interface for handhelds (dialog/whiptail, falls back to plain text)
- **One-step installer** — auto-detects firmware, installs scripts, creates Ports menu entry
- **Bash sync script** — works on handhelds with `bash` + `curl` (no Python needed; `jq` required only for downloads)
- Python CLI client for desktop use (no extra dependencies)
- Multi-user support with JWT authentication
- Docker deployment for easy self-hosting

---

## Table of Contents

1. [Server Setup](#1-server-setup)
2. [Verify the Server](#2-verify-the-server)
3. [Handheld Device Setup (Anbernic, etc.)](#3-handheld-device-setup-anbernic-etc)
4. [Android Setup (Termux)](#4-android-setup-termux)
5. [Desktop Setup (Linux / Windows)](#5-desktop-setup-linux--windows)
6. [Web UI](#6-web-ui)
7. [Syncing Between Devices](#7-syncing-between-devices)
8. [Configuration Reference](#8-configuration-reference)
9. [Troubleshooting](#9-troubleshooting)
10. [API Reference](#10-api-reference)
11. [Project Structure](#11-project-structure)

---

## 1. Server Setup

The server runs on any machine on your network — a home server, a PC, a Raspberry Pi, a VPS. Your devices will connect to it over your local network (or the internet if you expose it).

### Prerequisites

- **Docker** (recommended): [Install Docker](https://docs.docker.com/engine/install/) — includes Docker Compose
- **OR Python 3.9+** and `pip` if you prefer running without Docker

### Option A: Interactive installer (recommended)

The installer handles everything — secret key generation, `.env` creation, Docker or systemd setup, and firewall configuration.

```bash
# 1. Clone the repo
git clone https://github.com/your-username/OSGSameCloudService.git
cd OSGSameCloudService

# 2. Run the installer
bash install-server.sh
```

The installer will:
1. Detect whether you have Docker or Python available
2. Let you choose: **Docker** (isolated container) or **systemd service** (bare-metal with venv)
3. Generate a secret key and create your `.env` file
4. Build/install and start the server
5. Offer to open the firewall port
6. Print your server URL and management commands

To uninstall later:

```bash
bash install-server.sh --uninstall
```

### Option B: Docker (manual)

```bash
# 1. Clone the repo
git clone https://github.com/your-username/OSGSameCloudService.git
cd OSGSameCloudService

# 2. Create your .env file with a secret key
cp .env.example .env

# Generate a secret key and write it into .env
# Linux / macOS:
SECRET=$(python3 -c "import secrets; print(secrets.token_hex(32))")
sed -i "s/^OSGSC_SECRET_KEY=.*/OSGSC_SECRET_KEY=${SECRET}/" .env

# 3. Start the server
docker compose up -d
```

> **Windows (PowerShell):**
> ```powershell
> $secret = python -c "import secrets; print(secrets.token_hex(32))"
> (Get-Content .env) -replace '^OSGSC_SECRET_KEY=.*', "OSGSC_SECRET_KEY=$secret" | Set-Content .env
> docker compose up -d
> ```

### Option C: Manual (no Docker, no installer)

```bash
# 1. Clone the repo
git clone https://github.com/your-username/OSGSameCloudService.git
cd OSGSameCloudService

# 2. Create a virtual environment (recommended)
python3 -m venv venv
source venv/bin/activate   # Linux/macOS
# venv\Scripts\activate    # Windows PowerShell

# 3. Install dependencies
pip install -r server/requirements.txt

# 4. Set the secret key
export OSGSC_SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")
# Windows: $env:OSGSC_SECRET_KEY = python -c "import secrets; print(secrets.token_hex(32))"

# 5. Start the server
python run_server.py
```

---

## 2. Verify the Server

Once the server is running, confirm it's working:

```bash
# From the server itself
curl http://localhost:4444/api/health
# Expected: {"status":"ok"}

# From another device on your network (replace with your server's IP)
curl http://192.168.1.50:4444/api/health
```

**Find your server's IP address:**

```bash
# Linux
hostname -I | awk '{print $1}'

# macOS
ipconfig getifaddr en0

# Windows (PowerShell)
(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "*Loopback*" }).IPAddress
```

You should also be able to open `http://your-server-ip:4444` in a web browser and see the login page.

> **If the health check fails**, see [Troubleshooting](#9-troubleshooting).

---

## 3. Handheld Device Setup (Anbernic, etc.)

Works on any device with `bash` and `curl` — ArkOS, JELOS, Rocknix, muOS, Knulli, Batocera. No Python required.

### Prerequisites

- Your handheld must be **connected to the same network** as your server (Wi-Fi)
- SSH access to your handheld (see your firmware's documentation)
- `curl` installed (included on all major firmware)
- `jq` installed (included on most firmware; only needed for downloads)

### Step 1: Find your device's IP

On most handhelds, go to **Settings > Network** or **Wi-Fi** to see the IP address. You can also check your router's connected devices list.

### Step 2: Install — choose one method

#### Method A: One-step installer (recommended)

The installer auto-detects your firmware, installs the sync scripts, sets up your account, and creates a **Ports menu entry** so you can launch the save manager from your device's game list.

**From your PC, copy all three scripts and run the installer:**

```bash
# Replace 192.168.1.100 with your handheld's IP
scp client/osgsc-setup.sh client/osgsc-sync.sh client/osgsc-ui.sh root@192.168.1.100:/tmp/
ssh root@192.168.1.100 "bash /tmp/osgsc-setup.sh"
```

**Or, SSH into the device and download directly:**

```bash
mkdir -p /tmp/osgsc && cd /tmp/osgsc
curl -sLO https://raw.githubusercontent.com/your-username/OSGSameCloudService/main/client/osgsc-setup.sh
curl -sLO https://raw.githubusercontent.com/your-username/OSGSameCloudService/main/client/osgsc-sync.sh
curl -sLO https://raw.githubusercontent.com/your-username/OSGSameCloudService/main/client/osgsc-ui.sh
bash osgsc-setup.sh
```

The installer will:
1. Install scripts to `~/.local/bin/`
2. Ask for your server URL and credentials (creates an account or logs in)
3. Create **"OSGSC Save Sync"** in your device's Ports/Apps menu
4. Optionally set up auto-sync via cron

After installation, find **"OSGSC Save Sync"** in your Ports menu. It opens a menu where you can upload, download, list saves, and change settings — no typing commands needed.

#### Method B: Manual script install (sync script only)

If you just want the CLI without the menu UI:

```bash
# From your PC via SCP:
scp client/osgsc-sync.sh root@192.168.1.100:/opt/osgsc-sync.sh
ssh root@192.168.1.100 "chmod +x /opt/osgsc-sync.sh"

# Or download directly on device:
curl -o /opt/osgsc-sync.sh https://raw.githubusercontent.com/your-username/OSGSameCloudService/main/client/osgsc-sync.sh
chmod +x /opt/osgsc-sync.sh
```

#### Method C: Via SD card

Copy `client/osgsc-setup.sh`, `client/osgsc-sync.sh`, and `client/osgsc-ui.sh` to your SD card, insert into handheld, then:

```bash
cd /roms/      # or wherever your SD card mounts
bash osgsc-setup.sh
```

### Step 3: Using the on-device UI

If you used the installer, launch **"OSGSC Save Sync"** from your Ports/Apps menu. The UI provides:

```
┌─────────────────────────────────┐
│     OSGSC Save Sync             │
│  Server: http://192.168.1.50:4444│
│                                 │
│  > Upload saves to server       │
│    Download saves from server   │
│    List saves on server         │
│    Settings                     │
│    Exit                         │
│                                 │
└─────────────────────────────────┘
```

- **Upload** — scans your save directory and uploads everything (auto-detects path)
- **Download** — pulls latest saves from the server to your device
- **List** — shows what saves are stored on the server
- **Settings** — change server URL, save directory, log in with a different account

The UI uses `dialog` or `whiptail` if available (most firmwares have one). If neither is installed, it falls back to a plain text menu that works in any terminal.

### Step 4: Using the CLI directly (optional)

If you prefer the command line or skipped the installer:

```bash
# register an account
/opt/osgsc-sync.sh register -s http://192.168.1.50:4444 -u player1 -p mypassword

# upload saves (auto-detects save directory)
/opt/osgsc-sync.sh upload -s http://192.168.1.50:4444

# specify path and system manually
/opt/osgsc-sync.sh upload -s http://192.168.1.50:4444 -d /roms/saves -y gba

# download saves
/opt/osgsc-sync.sh download -s http://192.168.1.50:4444

# list saves
/opt/osgsc-sync.sh list -s http://192.168.1.50:4444
```

Example output:

```
Auto-detected save directory: /roms/saves
  [gba] PokemonEmerald/PokemonEmerald.srm -> v1 (Save uploaded)
  [snes] SuperMetroid/SuperMetroid.srm -> v1 (Save uploaded)
Processed 2 file(s)
```

> **Note:** The download command requires `jq`. If you get an error:
> ```bash
> sudo apt install jq        # Debian-based (ArkOS, Rocknix)
> opkg install jq             # OpenWrt-based
> ```

### Step 5 (optional): Automatic sync via cron

If you didn't set this up during installation, you can add it manually:

```bash
crontab -e

# add this line (replace server IP):
*/10 * * * * ~/.local/bin/osgsc-sync.sh upload -s http://192.168.1.50:4444 >> /tmp/osgsc.log 2>&1
```

### Known save directories by firmware

| Firmware | Typical Save Path |
|----------|------------------|
| ArkOS | `/roms/saves` or `/roms2/saves` |
| JELOS / Rocknix | `/storage/roms/saves` or `/storage/saves` |
| muOS | `/mnt/mmc/MUOS/save` or `/mnt/sdcard/MUOS/save` |
| Knulli / Batocera | `/userdata/saves` |
| Standard RetroArch | `~/.config/retroarch/saves` |

The script auto-detects these paths. Use `--save-dir` (CLI) or Settings (UI) if yours is different.

### Where the installer puts files

| What | Path |
|------|------|
| Sync script | `~/.local/bin/osgsc-sync.sh` |
| UI script | `~/.local/bin/osgsc-ui.sh` |
| Config | `~/.config/osgsc/config` |
| Auth token | `~/.config/osgsc/token` |
| Ports entry | Firmware-dependent (see table below) |

| Firmware | Ports/Apps Directory |
|----------|---------------------|
| ArkOS | `/roms/ports/` |
| JELOS / Rocknix | `/storage/roms/ports/` |
| muOS | `/mnt/sdcard/MUOS/application/` |
| Knulli / Batocera | `/userdata/roms/ports/` |
| Generic Linux | `~/Apps/` |

---

## 4. Android Setup (Termux)

### Step 1: Install Termux

Install **Termux** from [F-Droid](https://f-droid.org/en/packages/com.termux/) (not the Play Store — that version is outdated).

### Step 2: Install dependencies and download the script

Open Termux and run:

```bash
# update packages and install curl + jq
pkg update && pkg install curl jq

# grant access to your phone's storage
termux-setup-storage

# download the sync script
curl -o ~/osgsc-sync.sh https://raw.githubusercontent.com/your-username/OSGSameCloudService/main/client/osgsc-sync.sh
chmod +x ~/osgsc-sync.sh
```

### Step 3: Register and sync

```bash
# create an account (replace server IP)
~/osgsc-sync.sh register -s http://192.168.1.50:4444 -u player1 -p mypassword

# upload saves
~/osgsc-sync.sh upload -s http://192.168.1.50:4444 -d /storage/emulated/0/RetroArch/saves

# download saves
~/osgsc-sync.sh download -s http://192.168.1.50:4444 -d /storage/emulated/0/RetroArch/saves

# list what's on the server
~/osgsc-sync.sh list -s http://192.168.1.50:4444
```

---

## 5. Desktop Setup (Linux / Windows)

The Python CLI client provides richer output and watch mode. Requires **Python 3.9+** (no extra dependencies — uses only stdlib).

### Linux

```bash
# download just the client script
curl -o ~/osgsc_sync.py https://raw.githubusercontent.com/your-username/OSGSameCloudService/main/client/osgsc_sync.py

# or if you cloned the repo, use it directly from client/osgsc_sync.py

# register
python3 ~/osgsc_sync.py register -s http://192.168.1.50:4444 -u player1 -p mypassword

# upload all saves from default RetroArch directory
python3 ~/osgsc_sync.py upload -s http://192.168.1.50:4444

# upload from a specific directory
python3 ~/osgsc_sync.py upload -s http://192.168.1.50:4444 -d ~/.config/retroarch/saves

# download saves
python3 ~/osgsc_sync.py download -s http://192.168.1.50:4444 -d ~/.config/retroarch/saves

# watch mode — re-sync every 5 minutes automatically
python3 ~/osgsc_sync.py upload -s http://192.168.1.50:4444 --watch --interval 300

# list saves on server
python3 ~/osgsc_sync.py list -s http://192.168.1.50:4444
```

### Windows

1. Make sure [Python 3.9+](https://www.python.org/downloads/) is installed (check "Add to PATH" during install)
2. Download `client/osgsc_sync.py` or clone the repo

```powershell
# register
python osgsc_sync.py register -s http://192.168.1.50:4444 -u player1 -p mypassword

# upload saves (adjust path to your RetroArch saves location)
python osgsc_sync.py upload -s http://192.168.1.50:4444 -d "$env:APPDATA\RetroArch\saves"

# download saves
python osgsc_sync.py download -s http://192.168.1.50:4444 -d "$env:APPDATA\RetroArch\saves"

# list saves
python osgsc_sync.py list -s http://192.168.1.50:4444
```

> **Tip:** You can also use the bash script on Windows via WSL or Git Bash.

---

## 6. Web UI

Open `http://your-server-ip:4444` in any web browser on any device. The web UI lets you:

1. **Register / login** — create an account or sign in
2. **Upload saves** — drag and drop `.srm`, `.sav`, or `.state` files, or click to browse. Fill in the system name (e.g., `gba`, `snes`) and game name before uploading.
3. **Browse saves** — filter by system or search by game name
4. **Download saves** — click Download on any save to get the file
5. **Delete saves** — remove saves you no longer need

Works on mobile browsers — useful for managing saves from your phone without installing anything.

---

## 7. Syncing Between Devices

Here's a typical workflow for keeping saves in sync across multiple devices:

### Example: Play on Anbernic, continue on PC

1. **On your Anbernic:** Upload your saves after a play session
   ```bash
   /opt/osgsc-sync.sh upload -s http://192.168.1.50:4444
   ```

2. **On your PC:** Download the latest saves
   ```bash
   python3 osgsc_sync.py download -s http://192.168.1.50:4444 -d ~/.config/retroarch/saves
   ```

3. **Play on your PC**, then upload when done:
   ```bash
   python3 osgsc_sync.py upload -s http://192.168.1.50:4444 -d ~/.config/retroarch/saves
   ```

4. **Back on your Anbernic:** Download the updated saves
   ```bash
   /opt/osgsc-sync.sh download -s http://192.168.1.50:4444
   ```

### Tips

- **Duplicate detection:** If a save file hasn't changed since the last upload, it's skipped automatically — no wasted bandwidth.
- **Versioning:** The server keeps the last 5 versions of each save by default. If you overwrite a save by accident, you can download an older version via the web UI or API.
- **Multiple users:** Each user has their own save storage. Create separate accounts for family members using different usernames.
- **Watch mode (desktop):** Use `--watch --interval 300` with the Python client to auto-upload every 5 minutes while you play.
- **Cron (handhelds):** Set up a cron job for background syncing (see [Step 6 in handheld setup](#step-6-optional-automatic-sync-via-cron)).

---

## 8. Configuration Reference

All server configuration is via environment variables (set in `.env` for Docker, or `export` for manual):

| Variable | Default | Description |
|----------|---------|-------------|
| `OSGSC_SECRET_KEY` | (random) | JWT signing key. **Set this for production** — without it, a random key is generated on each restart, invalidating all login tokens. |
| `OSGSC_DATA_DIR` | `./data` | Where saves and the database are stored |
| `OSGSC_HOST` | `0.0.0.0` | Server bind address |
| `OSGSC_PORT` | `4444` | Server port |
| `OSGSC_MAX_SAVE_SIZE_MB` | `50` | Max upload size per file in MB |
| `OSGSC_MAX_VERSIONS` | `5` | Number of versions to keep per save file |
| `OSGSC_TOKEN_EXPIRE_MINUTES` | `1440` | Login token lifetime in minutes (default: 24 hours) |
| `OSGSC_ENV` | `production` | Set to `development` for auto-reload during development |
| `OSGSC_CORS_ORIGINS` | (none) | Comma-separated list of allowed CORS origins (e.g., `https://my-domain.com`) |

### Production Notes

- **Always set `OSGSC_SECRET_KEY`** — generate one with `python3 -c "import secrets; print(secrets.token_hex(32))"` and put it in your `.env` file.
- **Use a reverse proxy** (nginx, Caddy) with HTTPS if exposing this service to the internet. Over a home LAN, HTTP is fine.
- **Back up your data** — save files and the database are stored in the Docker volume `osgsc-data`. Use `docker compose cp osgsc:/data ./backup` to create a backup.
- **Updating** — pull the latest code and rebuild:
  ```bash
  git pull
  docker compose up -d --build
  ```

---

## 9. Troubleshooting

### "Connection refused" or server not reachable

- **Is the server running?**
  ```bash
  docker compose ps          # Docker
  # or check if the process is running
  curl http://localhost:4444/api/health
  ```
- **Firewall:** Make sure port 4444 is open on your server
  ```bash
  # Ubuntu/Debian
  sudo ufw allow 4444/tcp
  # or check with
  sudo ufw status
  ```
- **Wrong IP:** Double-check your server's IP address with `hostname -I`

### "Invalid credentials" on login

- Passwords must be at least **8 characters**
- Usernames are case-sensitive
- If you forgot your password, register a new account (there's no password reset yet)

### "Not logged in" error on upload/download

- Your login token may have expired (default: 24 hours). Run `login` again:
  ```bash
  /opt/osgsc-sync.sh login -s http://192.168.1.50:4444 -u player1 -p mypassword
  ```

### "Could not find RetroArch saves directory"

- The auto-detection checks common firmware paths. Use `--save-dir` to specify yours manually:
  ```bash
  /opt/osgsc-sync.sh upload -s http://192.168.1.50:4444 -d /path/to/your/saves
  ```
- Check where RetroArch stores saves: in RetroArch, go to **Settings > Directory > Savefile Directory**

### "`jq` is required for downloads"

- Install `jq` on your device:
  ```bash
  sudo apt install jq        # Debian-based (ArkOS, Rocknix, Ubuntu)
  opkg install jq             # OpenWrt-based
  pkg install jq              # Termux (Android)
  ```
- Upload, login, register, and list commands work without `jq` — only download needs it.

### Saves not showing up after upload

- Check the server logs:
  ```bash
  docker compose logs --tail 50    # Docker
  ```
- Verify your saves are in a recognized format (`.srm`, `.sav`, `.state`, `.rtc`, etc.)
- Check that the save directory you specified actually contains files

### Docker container won't start

- Check logs: `docker compose logs`
- Make sure port 4444 isn't already in use: `ss -tlnp | grep 4444`
- Verify your `.env` file exists and has `OSGSC_SECRET_KEY` set

---

## 10. API Reference

All endpoints are under `/api/`. Authentication uses Bearer tokens in the `Authorization` header.

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| POST | `/api/auth/register` | No | Create account. Body: `{"username": "...", "password": "..."}` |
| POST | `/api/auth/login` | No | Login. Body: `{"username": "...", "password": "..."}` |
| GET | `/api/health` | No | Health check |
| POST | `/api/saves/upload?system_name=...&game_name=...` | Yes | Upload a save file (multipart form) |
| GET | `/api/saves/list?system_name=...&game_name=...` | Yes | List saves (filters optional) |
| GET | `/api/saves/download?system_name=...&game_name=...&file_name=...` | Yes | Download a save file |
| DELETE | `/api/saves/delete?system_name=...&game_name=...&file_name=...&version=...` | Yes | Delete a save (omit `version` to delete all versions) |
| GET | `/api/saves/systems` | Yes | List your systems |
| GET | `/api/saves/games?system_name=...` | Yes | List games for a system |

Interactive API docs are available at `http://your-server:4444/docs` (Swagger UI, provided by FastAPI).

---

## 11. Project Structure

```
OSGSameCloudService/
├── server/              # FastAPI backend
│   ├── app.py           # app setup, CORS, static files
│   ├── auth.py          # JWT authentication
│   ├── config.py        # env-based configuration
│   ├── database.py      # SQLite setup and connection
│   ├── models.py        # request/response schemas
│   ├── routes_auth.py   # register + login endpoints
│   ├── routes_saves.py  # save CRUD endpoints
│   └── requirements.txt # Python dependencies
├── client/
│   ├── osgsc-setup.sh   # one-step installer for handhelds
│   ├── osgsc-ui.sh      # TUI menu for handhelds (dialog/whiptail)
│   ├── osgsc-sync.sh    # bash sync client (handhelds, any Linux)
│   └── osgsc_sync.py    # Python client (desktop)
├── web/
│   └── index.html       # web UI (single page app)
├── install-server.sh    # interactive server installer
├── docker-compose.yml   # Docker deployment
├── Dockerfile
├── run_server.py        # manual run entry point
├── .env.example         # example environment config
├── LICENSE              # MIT
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).

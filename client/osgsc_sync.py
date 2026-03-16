#!/usr/bin/env python3
"""
OSGSameCloudService - Cross-platform CLI sync client.
Works on Linux, Windows, Android (Termux), and any Python 3.9+ environment.

Usage:
    python osgsc_sync.py register --server URL --username USER --password PASS
    python osgsc_sync.py login    --server URL --username USER --password PASS
    python osgsc_sync.py upload   --server URL --save-dir /path/to/saves [--system snes] [--watch]
    python osgsc_sync.py download --server URL --save-dir /path/to/saves [--system snes] [--game "Game Name"]
    python osgsc_sync.py list     --server URL [--system snes]
"""
import argparse
import hashlib
import json
import os
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
from pathlib import Path
from typing import Dict, List, Optional, Union

# default RetroArch save locations by platform
DEFAULT_SAVE_DIRS = {
    "linux": Path.home() / ".config" / "retroarch" / "saves",
    "android": Path("/storage/emulated/0/RetroArch/saves"),
    "win32": Path.home() / "AppData" / "Roaming" / "RetroArch" / "saves",
}

CONFIG_DIR = Path.home() / ".config" / "osgsc"
TOKEN_FILE = CONFIG_DIR / "token.json"

# common RetroArch save extensions
SAVE_EXTENSIONS = {".srm", ".sav", ".state", ".state1", ".state2", ".state3",
                   ".state4", ".state5", ".state6", ".state7", ".state8",
                   ".state9", ".rtc", ".cht", ".bps", ".ups", ".ips"}


class APIError(Exception):
    """Raised when an API request fails."""
    def __init__(self, message):
        # type: (str) -> None
        super().__init__(message)


def _normalize_server(server):
    # type: (str) -> str
    """Strip trailing slash so http://host:4444 and http://host:4444/ key the same."""
    return server.rstrip("/")


def save_token(server, token, username):
    # type: (str, str, str) -> None
    server = _normalize_server(server)
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    data = {}  # type: Dict[str, dict]
    if TOKEN_FILE.exists():
        data = json.loads(TOKEN_FILE.read_text())
    data[server] = {"token": token, "username": username}
    TOKEN_FILE.write_text(json.dumps(data, indent=2))
    try:
        os.chmod(str(TOKEN_FILE), 0o600)
    except OSError:
        pass


def load_token(server):
    # type: (str) -> Optional[str]
    server = _normalize_server(server)
    if not TOKEN_FILE.exists():
        return None
    data = json.loads(TOKEN_FILE.read_text())
    entry = data.get(server)
    return entry["token"] if entry else None


def api_request(server, endpoint, method="GET", data=None, token=None,
                file_path=None, query=None):
    # type: (str, str, str, Optional[dict], Optional[str], Optional[Path], Optional[dict]) -> Union[dict, bytes]
    """Make an HTTP request. Uses only stdlib for max portability."""
    url = "{0}{1}".format(server.rstrip("/"), endpoint)
    if query:
        url += "?" + urllib.parse.urlencode(query)

    headers = {}
    if token:
        headers["Authorization"] = "Bearer {0}".format(token)

    body = None

    if file_path:
        # multipart upload
        boundary = "----OSGSCBoundary" + hashlib.md5(str(time.time()).encode()).hexdigest()
        headers["Content-Type"] = "multipart/form-data; boundary={0}".format(boundary)
        file_data = file_path.read_bytes()
        # sanitize filename for Content-Disposition header — strip anything
        # that could break the header (quotes, backslashes, control chars)
        safe_name = file_path.name.replace("\\", "_").replace('"', "_")
        safe_name = "".join(c for c in safe_name if c.isprintable() and c not in "\r\n")
        body = (
            "--{0}\r\n"
            "Content-Disposition: form-data; name=\"file\"; filename=\"{1}\"\r\n"
            "Content-Type: application/octet-stream\r\n\r\n"
        ).format(boundary, safe_name).encode() + file_data + "\r\n--{0}--\r\n".format(boundary).encode()
    elif data:
        headers["Content-Type"] = "application/json"
        body = json.dumps(data).encode()

    req = urllib.request.Request(url, data=body, headers=headers, method=method)

    try:
        with urllib.request.urlopen(req) as resp:
            content = resp.read()
            content_type = resp.headers.get("Content-Type", "")
            if "application/json" in content_type:
                return json.loads(content)
            return content
    except urllib.error.HTTPError as e:
        error_body = e.read().decode()
        try:
            detail = json.loads(error_body).get("detail", error_body)
        except (json.JSONDecodeError, ValueError):
            detail = error_body
        raise APIError("Error {0}: {1}".format(e.code, detail))
    except urllib.error.URLError as e:
        raise APIError("Connection error: {0}".format(e.reason))


def cmd_register(args):
    try:
        result = api_request(args.server, "/api/auth/register", method="POST",
                             data={"username": args.username, "password": args.password})
    except APIError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
    save_token(args.server, result["access_token"], args.username)
    print("Registered and logged in as '{0}'".format(args.username))


def cmd_login(args):
    try:
        result = api_request(args.server, "/api/auth/login", method="POST",
                             data={"username": args.username, "password": args.password})
    except APIError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)
    save_token(args.server, result["access_token"], args.username)
    print("Logged in as '{0}'".format(args.username))


def detect_system_from_path(save_dir, file_path):
    # type: (Path, Path) -> str
    """Try to infer the system/core name from the directory structure."""
    try:
        relative = file_path.relative_to(save_dir)
        parts = relative.parts
        if len(parts) > 1:
            return parts[0]
    except ValueError:
        pass
    return "unknown"


def find_save_files(save_dir):
    # type: (Path) -> List[Path]
    """Recursively find all save files."""
    saves = []
    for ext in SAVE_EXTENSIONS:
        saves.extend(save_dir.rglob("*{0}".format(ext)))
    return sorted(saves)


def cmd_upload(args):
    token = load_token(args.server)
    if not token:
        print("Not logged in. Run 'login' first.", file=sys.stderr)
        sys.exit(1)

    save_dir = Path(args.save_dir) if args.save_dir else DEFAULT_SAVE_DIRS.get(sys.platform)
    if not save_dir or not save_dir.exists():
        print("Save directory not found: {0}".format(save_dir), file=sys.stderr)
        sys.exit(1)

    while True:
        try:
            files = find_save_files(save_dir)
            if not files:
                print("No save files found in {0}".format(save_dir))
            else:
                uploaded = 0
                for f in files:
                    system = args.system or detect_system_from_path(save_dir, f)
                    game = f.stem
                    query = {"system_name": system, "game_name": game}
                    result = api_request(args.server, "/api/saves/upload", method="POST",
                                         token=token, file_path=f, query=query)
                    status_msg = result.get("message", "done")
                    ver = result.get("version", "?")
                    print("  [{0}] {1}/{2} -> v{3} ({4})".format(system, game, f.name, ver, status_msg))
                    uploaded += 1
                print("Processed {0} file(s)".format(uploaded))
        except APIError as e:
            print(str(e), file=sys.stderr)
            if not args.watch:
                sys.exit(1)
            # in watch mode, log the error and retry next cycle

        if not args.watch:
            break
        print("\nWaiting {0}s before next sync...".format(args.interval))
        time.sleep(args.interval)


def cmd_download(args):
    token = load_token(args.server)
    if not token:
        print("Not logged in. Run 'login' first.", file=sys.stderr)
        sys.exit(1)

    save_dir = Path(args.save_dir) if args.save_dir else DEFAULT_SAVE_DIRS.get(sys.platform)
    if not save_dir:
        print("Could not determine save directory. Use --save-dir.", file=sys.stderr)
        sys.exit(1)

    query = {}
    if args.system:
        query["system_name"] = args.system
    if args.game:
        query["game_name"] = args.game

    try:
        result = api_request(args.server, "/api/saves/list", method="GET", token=token, query=query)
    except APIError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)

    if not isinstance(result.get("saves"), list):
        print("Invalid response from server", file=sys.stderr)
        sys.exit(1)

    # only grab the latest version of each file
    latest = {}  # type: Dict[tuple, dict]
    for s in result["saves"]:
        key = (s["system_name"], s["game_name"], s["file_name"])
        if key not in latest or s["version"] > latest[key]["version"]:
            latest[key] = s

    if not latest:
        print("No saves found on server.")
        return

    downloaded = 0
    for (system, game, fname), meta in latest.items():
        dl_query = {"system_name": system, "game_name": game, "file_name": fname}
        try:
            content = api_request(args.server, "/api/saves/download", method="GET",
                                  token=token, query=dl_query)
        except APIError as e:
            print("  [{0}] {1}/{2} - download failed: {3}".format(system, game, fname, e),
                  file=sys.stderr)
            continue

        out_dir = save_dir / system / game
        try:
            out_dir.mkdir(parents=True, exist_ok=True)
        except OSError as e:
            print("Failed to create directory {0}: {1}".format(out_dir, e), file=sys.stderr)
            continue

        out_path = out_dir / fname

        if out_path.exists():
            local_hash = hashlib.sha256(out_path.read_bytes()).hexdigest()
            if local_hash == meta["checksum"]:
                print("  [{0}] {1}/{2} - already up to date".format(system, game, fname))
                continue

        try:
            out_path.write_bytes(content)
        except OSError as e:
            print("Failed to write {0}: {1}".format(out_path, e), file=sys.stderr)
            continue

        print("  [{0}] {1}/{2} -> {3}".format(system, game, fname, out_path))
        downloaded += 1

    print("Downloaded {0} file(s)".format(downloaded))


def cmd_list(args):
    token = load_token(args.server)
    if not token:
        print("Not logged in. Run 'login' first.", file=sys.stderr)
        sys.exit(1)

    query = {}
    if args.system:
        query["system_name"] = args.system

    try:
        result = api_request(args.server, "/api/saves/list", method="GET", token=token, query=query)
    except APIError as e:
        print(str(e), file=sys.stderr)
        sys.exit(1)

    if not result.get("saves"):
        print("No saves found.")
        return

    current_system = None
    for s in result["saves"]:
        if s["system_name"] != current_system:
            current_system = s["system_name"]
            print("\n[{0}]".format(current_system))
        size_kb = s["file_size"] / 1024
        print("  {0}/{1}  v{2}  {3:.1f}KB  {4}".format(
            s["game_name"], s["file_name"], s["version"], size_kb, s["uploaded_at"]))

    print("\nTotal: {0} save(s)".format(result["total"]))


def main():
    parser = argparse.ArgumentParser(
        prog="osgsc-sync",
        description="OSGSameCloudService - RetroArch save file sync client",
    )
    parser.add_argument("--server", "-s", default=os.getenv("OSGSC_SERVER", "http://localhost:4444"),
                        help="Server URL (default: $OSGSC_SERVER or http://localhost:4444)")

    subs = parser.add_subparsers(dest="command")

    # register
    reg = subs.add_parser("register", help="Create a new account")
    reg.add_argument("--username", "-u", required=True)
    reg.add_argument("--password", "-p", required=True)

    # login
    log = subs.add_parser("login", help="Log in to an existing account")
    log.add_argument("--username", "-u", required=True)
    log.add_argument("--password", "-p", required=True)

    # upload
    up = subs.add_parser("upload", help="Upload save files to the server")
    up.add_argument("--save-dir", "-d", help="Path to RetroArch saves directory")
    up.add_argument("--system", help="Override system/core name")
    up.add_argument("--watch", "-w", action="store_true", help="Keep watching for changes")
    up.add_argument("--interval", type=int, default=300, help="Watch interval in seconds (default: 300)")

    # download
    dl = subs.add_parser("download", help="Download save files from the server")
    dl.add_argument("--save-dir", "-d", help="Path to RetroArch saves directory")
    dl.add_argument("--system", help="Filter by system name")
    dl.add_argument("--game", help="Filter by game name")

    # list
    ls = subs.add_parser("list", help="List saves on the server")
    ls.add_argument("--system", help="Filter by system name")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        sys.exit(1)

    commands = {
        "register": cmd_register,
        "login": cmd_login,
        "upload": cmd_upload,
        "download": cmd_download,
        "list": cmd_list,
    }
    commands[args.command](args)


if __name__ == "__main__":
    main()

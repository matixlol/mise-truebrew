#!/usr/bin/env python3
"""Exercise search caching across real mise processes against a local API fixture."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from socketserver import TCPServer


PLUGIN_DIR = Path(__file__).resolve().parent.parent
MISE = os.environ.get("MISE_BIN", "mise")
FORMULAE = [
    {"name": "tb-cache-alpha", "desc": "Alpha fixture", "versions": {"stable": "1.0"}},
    {"name": "tb-cache-beta", "desc": "Beta fixture", "versions": {"stable": "1.0"}},
]
requests = []
index_status = 200
index_body = json.dumps(FORMULAE).encode()


class API(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if self.path == "/api/formula.json":
            status, body = index_status, index_body
        else:
            formula = next(
                (f for f in FORMULAE if self.path == f"/api/formula/{f['name']}.json"),
                None,
            )
            status, body = (200, json.dumps(formula).encode()) if formula else (404, b"{}")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


class Server(ThreadingHTTPServer):
    def server_bind(self):
        # A loopback-only fixture does not need reverse DNS.
        TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address


def run(*args, check=True):
    result = subprocess.run(
        [MISE, *args], env=env, cwd=work, text=True, capture_output=True, timeout=60
    )
    if check:
        assert result.returncode == 0, result.stdout + result.stderr
    return result.stdout + result.stderr


def search(query, expected):
    # Force the hook to run: mise's own per-query cache must not hide downloads.
    shutil.rmtree(work / "mise-cache", ignore_errors=True)
    output = run("search", query)
    assert f"truebrew:{expected}" in output, output
    return output


def downloads():
    return requests.count("/api/formula.json")


with tempfile.TemporaryDirectory(prefix="truebrew-search-") as tmp:
    work = Path(tmp)
    plugin = work / "plugin"
    plugin.mkdir()
    for directory in ("hooks", "lib"):
        shutil.copytree(PLUGIN_DIR / directory, plugin / directory)
    shutil.copy2(PLUGIN_DIR / "metadata.lua", plugin)
    server = Server(("127.0.0.1", 0), API)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    helper = plugin / "lib/truebrew.lua"
    helper.write_text(helper.read_text().replace(
        '"https://formulae.brew.sh/api"',
        f'"http://127.0.0.1:{server.server_port}/api"',
    ))
    env = os.environ.copy()
    env.update(
        MISE_NO_CONFIG="1",
        MISE_DATA_DIR=str(work / "mise-data"),
        MISE_CACHE_DIR=str(work / "mise-cache"),
        MISE_CONFIG_DIR=str(work / "mise-config"),
        TRUEBREW_ROOT=str(work / "truebrew root's cache"),
    )
    try:
        run("plugin", "link", "truebrew", str(plugin))
        search("tb-cache-al", "tb-cache-alpha")
        assert downloads() == 1, "cold search should download the index once"
        output = search("tb-cache-be", "tb-cache-beta")
        assert downloads() == 1, "a different query in a new process downloaded the index again"
        assert "downloading formulae index" not in output
        cache = Path(env["TRUEBREW_ROOT"]) / "cache/meta/formula-index.json"
        cached = json.loads(cache.read_text())
        assert cached["formulae"] == [
            {"name": f["name"], "desc": f["desc"]} for f in FORMULAE
        ], "cache should retain just search metadata"

        index_status = 503
        search("tb-cache-al", "tb-cache-alpha")
        assert downloads() == 1, "fresh cache should work while the index API is unavailable"

        # Expired cache must refresh, and a failed refresh must leave it intact.
        cached["updated_at"] -= 24 * 60 * 60
        cache.write_text(json.dumps(cached))
        previous = cache.read_bytes()
        shutil.rmtree(work / "mise-cache", ignore_errors=True)
        count = downloads()
        run("search", "tb-cache-be", check=False)
        assert downloads() > count, "expired cache should attempt a refresh"
        assert cache.read_bytes() == previous, "failed refresh overwrote the cache"
        index_status = 200
        count = downloads()
        output = search("tb-cache-be", "tb-cache-beta")
        assert downloads() == count + 1, "failed refresh must be retried"
        assert "downloading formulae index" in output

        # Both malformed JSON and a valid JSON document of the wrong shape
        # should be repaired rather than producing empty search results.
        for broken in ("{partial", '{"updated_at": "invalid", "formulae": []}'):
            count = downloads()
            cache.write_text(broken)
            search("tb-cache-al", "tb-cache-alpha")
            assert downloads() == count + 1, "corrupt cache should be replaced"

        # A malformed API response cannot replace an expired but complete cache.
        cached = json.loads(cache.read_text())
        cached["updated_at"] = 0
        cache.write_text(json.dumps(cached))
        previous = cache.read_bytes()
        for invalid in (b"{partial", b"{}", b"[]"):
            count = downloads()
            index_body = invalid
            shutil.rmtree(work / "mise-cache", ignore_errors=True)
            run("search", "tb-cache-al", check=False)
            assert downloads() == count + 1
            assert cache.read_bytes() == previous, "invalid API response poisoned the cache"
        index_body = json.dumps(FORMULAE).encode()
        search("tb-cache-al", "tb-cache-alpha")
        assert not list(cache.parent.glob("formula-index.json.*")), "temporary cache files leaked"

        # Without an explicit root, use the existing XDG data directory convention.
        del env["TRUEBREW_ROOT"]
        env["XDG_DATA_HOME"] = str(work / "xdg-data")
        count = downloads()
        search("tb-cache-be", "tb-cache-beta")
        search("tb-cache-al", "tb-cache-alpha")
        assert downloads() == count + 1
        assert (work / "xdg-data/mise-truebrew/cache/meta/formula-index.json").is_file()

        # Search still returns fetched results when the cache directory cannot
        # be created (use a file as the root so this also works when run as root).
        blocked = work / "blocked-root"
        blocked.write_text("not a directory")
        env["TRUEBREW_ROOT"] = str(blocked)
        count = downloads()
        output = search("tb-cache-be", "tb-cache-beta")
        assert downloads() == count + 1
        assert "could not cache formulae index" in output
        print("OK: cross-process reuse, expiry, corruption, failed refreshes, and cache paths")
    finally:
        server.shutdown()
        server.server_close()

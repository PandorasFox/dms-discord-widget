#!/usr/bin/env python3
"""Discord IPC bridge for DankMaterialShell Discord Voice plugin.

Connects to Discord's local Unix socket IPC, handles authentication,
subscribes to voice events, and exposes state + controls via a JSON-lines
Unix socket that the QML plugin connects to with DankSocket.

Dependencies: Python 3.10+ stdlib only.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import socket
import struct
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

logging.basicConfig(
    level=logging.INFO,
    format="[discord-bridge] %(levelname)s: %(message)s",
    stream=sys.stderr,
)
log = logging.getLogger("discord-bridge")

# Discord StreamKit public client ID (no secret needed).
DEFAULT_CLIENT_ID = "207646673902501888"
OAUTH_SCOPES = ["rpc", "rpc.voice.read", "rpc.voice.write"]
TOKEN_EXCHANGE_URL = "https://streamkit.discord.com/overlay/token"

# How often the background loop retries reaching Discord while unauthenticated.
RECONNECT_INTERVAL = 5.0

# Discord IPC opcodes.
OP_HANDSHAKE = 0
OP_FRAME = 1
OP_CLOSE = 2
OP_PING = 3
OP_PONG = 4


# ---------------------------------------------------------------------------
# Discord IPC (binary-framed Unix socket)
# ---------------------------------------------------------------------------

class DiscordIPC:
    """Low-level binary-framed communication with Discord's local IPC."""

    def __init__(self) -> None:
        self.reader: asyncio.StreamReader | None = None
        self.writer: asyncio.StreamWriter | None = None
        self._nonce: int = 0

    # -- connection --

    @staticmethod
    def _candidate_paths() -> list[str]:
        """Return candidate Discord IPC socket paths in priority order."""
        paths: list[str] = []
        env_dirs: list[str] = []

        if xdg := os.environ.get("XDG_RUNTIME_DIR"):
            env_dirs.append(xdg)
            # Flatpak
            flatpak = os.path.join(xdg, "app", "com.discordapp.Discord")
            if os.path.isdir(flatpak):
                env_dirs.append(flatpak)

        if snap := os.environ.get("SNAP_USER_DATA"):
            env_dirs.append(os.path.join(snap, ".config"))

        for var in ("TMPDIR", "TMP", "TEMP"):
            if d := os.environ.get(var):
                env_dirs.append(d)

        env_dirs.append("/tmp")

        for d in env_dirs:
            for i in range(10):
                paths.append(os.path.join(d, f"discord-ipc-{i}"))

        return paths

    async def connect(self) -> bool:
        """Try to connect to Discord's IPC socket.  Returns True on success."""
        for path in self._candidate_paths():
            if not os.path.exists(path):
                continue
            try:
                r, w = await asyncio.open_unix_connection(path)
                self.reader, self.writer = r, w
                log.info("Connected to Discord IPC at %s", path)
                return True
            except (OSError, ConnectionRefusedError):
                continue
        return False

    def close(self) -> None:
        if self.writer:
            try:
                self.writer.close()
            except Exception:
                pass
            self.writer = None
            self.reader = None

    @property
    def connected(self) -> bool:
        return self.writer is not None and not self.writer.is_closing()

    # -- framing --

    async def send_frame(self, opcode: int, payload: dict[str, Any]) -> None:
        """Send a binary-framed message to Discord."""
        data = json.dumps(payload).encode("utf-8")
        header = struct.pack("<II", opcode, len(data))
        assert self.writer is not None
        self.writer.write(header + data)
        await self.writer.drain()

    async def recv_frame(self) -> tuple[int, dict[str, Any]]:
        """Receive a binary-framed message from Discord."""
        assert self.reader is not None
        header = await self.reader.readexactly(8)
        opcode, length = struct.unpack("<II", header)
        data = await self.reader.readexactly(length)
        payload = json.loads(data.decode("utf-8"))
        return opcode, payload

    # -- protocol helpers --

    def _next_nonce(self) -> str:
        self._nonce += 1
        return str(self._nonce)

    async def handshake(self, client_id: str) -> dict[str, Any]:
        """Send HANDSHAKE, return the READY payload."""
        await self.send_frame(OP_HANDSHAKE, {"v": 1, "client_id": client_id})
        op, data = await self.recv_frame()
        if op == OP_CLOSE:
            raise ConnectionError(f"Discord closed connection: {data}")
        if data.get("evt") != "READY":
            raise ConnectionError(f"Expected READY, got: {data}")
        return data

    async def authorize(self, client_id: str, scopes: list[str]) -> str:
        """AUTHORIZE -> returns OAuth code.  Discord shows consent UI."""
        nonce = self._next_nonce()
        await self.send_frame(OP_FRAME, {
            "cmd": "AUTHORIZE",
            "args": {
                "client_id": client_id,
                "scopes": scopes,
                "prompt": "none",
            },
            "nonce": nonce,
        })
        return nonce

    async def authenticate(self, access_token: str) -> str:
        """AUTHENTICATE with an access token.  Returns nonce."""
        nonce = self._next_nonce()
        await self.send_frame(OP_FRAME, {
            "cmd": "AUTHENTICATE",
            "args": {"access_token": access_token},
            "nonce": nonce,
        })
        return nonce

    async def subscribe(self, evt: str, args: dict[str, Any] | None = None) -> str:
        """SUBSCRIBE to a Discord event.  Returns nonce."""
        nonce = self._next_nonce()
        payload: dict[str, Any] = {"cmd": "SUBSCRIBE", "evt": evt, "nonce": nonce}
        if args:
            payload["args"] = args
        await self.send_frame(OP_FRAME, payload)
        return nonce

    async def unsubscribe(self, evt: str, args: dict[str, Any] | None = None) -> str:
        """UNSUBSCRIBE from a Discord event.  Returns nonce."""
        nonce = self._next_nonce()
        payload: dict[str, Any] = {"cmd": "UNSUBSCRIBE", "evt": evt, "nonce": nonce}
        if args:
            payload["args"] = args
        await self.send_frame(OP_FRAME, payload)
        return nonce


# ---------------------------------------------------------------------------
# Token management
# ---------------------------------------------------------------------------

class TokenManager:
    """OAuth token caching and exchange via StreamKit endpoint."""

    def __init__(self, cache_dir: str | None = None) -> None:
        if cache_dir is None:
            xdg_cache = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))
            cache_dir = os.path.join(xdg_cache, "DankMaterialShell")
        self._cache_path = os.path.join(cache_dir, "discord_token.json")
        self.access_token: str | None = None

    def load(self) -> str | None:
        """Load cached access token from disk."""
        try:
            # Files written by older plugin versions used umask defaults.
            os.chmod(self._cache_path, 0o600)
            with open(self._cache_path) as f:
                data = json.load(f)
                self.access_token = data.get("access_token")
                return self.access_token
        except (FileNotFoundError, json.JSONDecodeError, KeyError):
            return None

    def save(self, token: str) -> None:
        """Save access token to disk (owner-readable only)."""
        self.access_token = token
        os.makedirs(os.path.dirname(self._cache_path), exist_ok=True)
        fd = os.open(self._cache_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"access_token": token}, f)

    def clear(self) -> None:
        """Remove cached token."""
        self.access_token = None
        try:
            os.unlink(self._cache_path)
        except FileNotFoundError:
            pass

    @staticmethod
    def exchange_code(code: str) -> str:
        """Exchange OAuth code for access token via StreamKit endpoint."""
        body = json.dumps({"code": code}).encode("utf-8")
        req = urllib.request.Request(
            TOKEN_EXCHANGE_URL,
            data=body,
            headers={
                "Content-Type": "application/json",
                "User-Agent": "DankMaterialShell/1.0",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return data["access_token"]


# ---------------------------------------------------------------------------
# Bridge server (JSON-lines over Unix socket for QML DankSocket)
# ---------------------------------------------------------------------------

class BridgeServer:
    """Unix socket server that speaks JSON-lines to QML plugin instances.

    Supports multiple concurrent clients (one per monitor/widget instance).
    Broadcasts state to all, accepts commands from any.
    """

    def __init__(self, socket_path: str) -> None:
        self.socket_path = socket_path
        self._server: asyncio.AbstractServer | None = None
        self._clients: set[asyncio.StreamWriter] = set()
        self._on_command: Any = None  # callback: async (dict) -> None
        self._on_client: Any = None  # callback: async (StreamWriter) -> None

    async def start(self, on_command: Any, on_client: Any = None) -> None:
        self._on_command = on_command
        self._on_client = on_client
        # Remove stale socket file.
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        self._server = await asyncio.start_unix_server(
            self._handle_client, path=self.socket_path
        )
        os.chmod(self.socket_path, 0o600)
        log.info("Bridge server listening on %s", self.socket_path)

    async def _handle_client(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        self._clients.add(writer)
        log.info("QML client connected (total: %d)", len(self._clients))
        await self._send_one(writer, {"type": "ready"})
        if self._on_client:
            await self._on_client(writer)

        try:
            while True:
                line = await reader.readline()
                if not line:
                    break
                try:
                    msg = json.loads(line.decode("utf-8").strip())
                    if self._on_command:
                        await self._on_command(msg)
                except json.JSONDecodeError:
                    # Don't echo the raw line: commands can carry the token.
                    log.warning("Bad JSON from QML (%d bytes)", len(line))
        except (ConnectionResetError, asyncio.IncompleteReadError):
            pass
        finally:
            self._clients.discard(writer)
            try:
                writer.close()
            except Exception:
                pass
            log.info("QML client disconnected (total: %d)", len(self._clients))

    async def send_to(self, writer: asyncio.StreamWriter, msg: dict[str, Any]) -> None:
        """Send a JSON-line message to a single client."""
        await self._send_one(writer, msg)

    async def _send_one(self, writer: asyncio.StreamWriter, msg: dict[str, Any]) -> None:
        """Send a JSON-line message to a single client."""
        try:
            data = json.dumps(msg, separators=(",", ":")) + "\n"
            writer.write(data.encode("utf-8"))
            await writer.drain()
        except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
            self._clients.discard(writer)

    async def send(self, msg: dict[str, Any]) -> None:
        """Broadcast a JSON-line message to all connected clients."""
        dead: list[asyncio.StreamWriter] = []
        data = json.dumps(msg, separators=(",", ":")) + "\n"
        encoded = data.encode("utf-8")
        for writer in list(self._clients):
            if writer.is_closing():
                dead.append(writer)
                continue
            try:
                writer.write(encoded)
                await writer.drain()
            except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError):
                dead.append(writer)
        for w in dead:
            self._clients.discard(w)

    @property
    def has_client(self) -> bool:
        return len(self._clients) > 0

    async def stop(self) -> None:
        for writer in list(self._clients):
            try:
                writer.close()
            except Exception:
                pass
        self._clients.clear()
        if self._server:
            self._server.close()
            await self._server.wait_closed()
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------------
# Main bridge coordinator
# ---------------------------------------------------------------------------

class DiscordBridge:
    """Coordinates Discord IPC, token management, and the QML bridge server."""

    def __init__(self, socket_path: str, client_id: str = DEFAULT_CLIENT_ID) -> None:
        self.client_id = client_id
        self.discord = DiscordIPC()
        self.tokens = TokenManager()
        self.server = BridgeServer(socket_path)
        self.authenticated = False
        self._discord_connected: bool = False
        self.current_user: dict[str, Any] = {}
        self.current_channel_id: str | None = None
        self.current_channel: dict[str, Any] | None = None
        self.voice_users: dict[str, dict[str, Any]] = {}
        self.voice_settings: dict[str, Any] = {"mute": False, "deaf": False}
        self._pending: dict[str, str] = {}  # nonce -> command name
        self._reauth_attempted = False
        self._shutdown = False
        self._discord_task: asyncio.Task[None] | None = None

    # -- main entry --

    async def run(self) -> None:
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, lambda: asyncio.ensure_future(self.shutdown()))

        await self.server.start(self._handle_qml_command, self._on_client_connected)
        log.info("Bridge running, waiting for QML client...")

        reconnect_task = asyncio.create_task(self._reconnect_loop())

        # Keep running until shutdown.
        while not self._shutdown:
            await asyncio.sleep(1)

        reconnect_task.cancel()

    async def shutdown(self) -> None:
        log.info("Shutting down...")
        self._shutdown = True
        self.discord.close()
        await self.server.stop()

    async def _reconnect_loop(self) -> None:
        """Keep trying to reach Discord in the background.

        The widget/daemon commonly starts before Discord is running (e.g. at
        login), or Discord gets restarted underneath us. Without this, the
        first connect attempt fails and the user is left having to click
        "Authorize" once Discord finally appears. Instead, whenever a client
        is attached, we poll to reach Discord: if a cached token exists we
        auto-authenticate; otherwise we stay connected and wait for the user
        to authorize (fresh authorization needs Discord's consent UI, which
        must not be triggered unprompted).

        `_do_connect_flow(quiet=True)` is idempotent, so calling it every
        interval is safe.
        """
        while not self._shutdown:
            await asyncio.sleep(RECONNECT_INTERVAL)
            if self._shutdown or not self.server.has_client:
                continue
            if self.discord.connected and self.authenticated:
                continue
            # Auth already in flight; let it resolve before retrying.
            pending = self._pending.values()
            if "AUTHENTICATE" in pending or "AUTHORIZE" in pending:
                continue
            try:
                await self._do_connect_flow(quiet=True)
            except Exception as e:
                # Never downgrade this to debug: a silently swallowed
                # exception here disables automatic re-authentication
                # entirely, and the only symptom is the user having to click
                # "Authorize" after every boot.
                log.warning("Background reconnect attempt failed: %r", e)

    async def _on_client_connected(self, writer: asyncio.StreamWriter) -> None:
        """Replay current state to a client that connected after startup.

        Clients (bar widgets, the daemon) come and go as monitors sleep and
        wake; without a replay a late-joining client would show stale state
        until the next Discord event happened to fire.
        """
        await self.server.send_to(writer, {
            "type": "discord_status",
            "connected": self._discord_connected,
        })
        if not self.authenticated:
            return
        await self.server.send_to(writer, {
            "type": "auth_complete",
            "user": self.current_user,
            "access_token": self.tokens.access_token or "",
        })
        if self.current_channel:
            await self.server.send_to(writer, {
                "type": "voice_channel",
                "channel": self.current_channel,
            })
            await self.server.send_to(writer, {
                "type": "voice_state",
                "users": list(self.voice_users.values()),
            })
        await self.server.send_to(writer, {
            "type": "voice_settings",
            "mute": self.voice_settings.get("mute", False),
            "deaf": self.voice_settings.get("deaf", False),
        })

    # -- Discord connection --

    async def _set_discord_connected(self, connected: bool) -> None:
        if self._discord_connected == connected:
            return
        self._discord_connected = connected
        await self.server.send({"type": "discord_status", "connected": connected})

    async def _connect_discord(self, quiet: bool = False) -> bool:
        """Connect and handshake with Discord.  Returns True on success.

        When `quiet` is set (background reconnect attempts), failures are not
        broadcast to QML: Discord simply isn't up yet, and surfacing an error
        on every retry would spam the widget's log.
        """
        if not await self.discord.connect():
            await self._set_discord_connected(False)
            if not quiet:
                await self.server.send({"type": "error", "error": "Discord not running or IPC unavailable"})
            return False
        try:
            await self.discord.handshake(self.client_id)
            log.info("Discord handshake complete")
            await self._set_discord_connected(True)
            return True
        except Exception as e:
            log.error("Handshake failed: %s", e)
            self.discord.close()
            await self._set_discord_connected(False)
            if not quiet:
                await self.server.send({"type": "error", "error": f"Handshake failed: {e}"})
            return False

    async def _discord_read_loop(self) -> None:
        """Read frames from Discord and dispatch events."""
        try:
            while self.discord.connected and not self._shutdown:
                try:
                    op, data = await self.discord.recv_frame()
                except asyncio.IncompleteReadError:
                    break
                except Exception as e:
                    log.error("Discord read error: %s", e)
                    break

                if op == OP_CLOSE:
                    log.warning("Discord closed connection: %s", data)
                    break
                elif op == OP_PING:
                    await self.discord.send_frame(OP_PONG, data)
                    continue
                elif op == OP_PONG:
                    continue

                # OP_FRAME: could be a command response or a dispatched event.
                await self._handle_discord_message(data)
        except Exception as e:
            log.error("Discord read loop error: %s", e)
        finally:
            self.discord.close()
            await self._set_discord_connected(False)
            self.authenticated = False
            self.current_user = {}
            self.current_channel_id = None
            self.current_channel = None
            self.voice_users.clear()
            self.voice_settings = {"mute": False, "deaf": False}
            await self.server.send({"type": "disconnected", "reason": "Discord connection lost"})
            log.info("Discord disconnected")

    async def _handle_discord_message(self, data: dict[str, Any]) -> None:
        """Handle a single message from Discord (response or dispatch)."""
        nonce = data.get("nonce")
        cmd = data.get("cmd", "")
        evt = data.get("evt")

        # Check for errors.
        if evt == "ERROR":
            error_data = data.get("data", {})
            message = error_data.get("message", "Unknown error")
            log.error("Discord error: %s", message)

            # If this error is the response to a pending AUTHENTICATE, the
            # cached token is bad (expired/revoked). Clear it and try a
            # silent re-authorization: AUTHORIZE is sent with prompt "none",
            # so Discord re-issues a code without any consent UI as long as
            # the user previously approved these scopes. Only fall back to
            # the manual authorize prompt if that also fails.
            pending_cmd = self._pending.pop(nonce, None) if nonce else None
            if pending_cmd == "AUTHENTICATE":
                log.info("Authentication failed; clearing cached token")
                self.tokens.clear()
                self.authenticated = False
                if not self._reauth_attempted and self.discord.connected:
                    self._reauth_attempted = True
                    log.info("Attempting silent re-authorization")
                    reauth_nonce = await self.discord.authorize(
                        self.client_id, OAUTH_SCOPES
                    )
                    self._pending[reauth_nonce] = "AUTHORIZE"
                    return
                # auth_error already implies "needs re-authorization"; the
                # QML handler clears the saved token and flips the UI into
                # the authorize-prompt state. Don't follow with
                # auth_required, which would wipe the error message.
                await self.server.send({"type": "auth_error", "error": message})
                return

            if pending_cmd == "AUTHORIZE":
                # Failed authorize (silent or user-initiated): surface it as
                # an auth error so the UI shows the authorize prompt and
                # clears any stale saved token.
                await self.server.send({"type": "auth_error", "error": message})
                return

            await self.server.send({"type": "error", "error": message})
            return

        # Command responses (have nonce).
        if nonce and nonce in self._pending:
            pending_cmd = self._pending.pop(nonce)
            await self._handle_command_response(pending_cmd, data)
            return

        # Dispatched events (evt field, cmd == "DISPATCH").
        if cmd == "DISPATCH" and evt:
            await self._handle_dispatch(evt, data.get("data", {}))

    async def _handle_command_response(self, cmd_name: str, data: dict[str, Any]) -> None:
        """Handle a response to a command we sent."""
        response_data = data.get("data", {})

        if cmd_name == "AUTHORIZE":
            code = response_data.get("code")
            if not code:
                await self.server.send({"type": "auth_error", "error": "Authorization denied or failed"})
                return
            # Exchange code for token.
            try:
                token = await asyncio.get_running_loop().run_in_executor(
                    None, TokenManager.exchange_code, code
                )
                self.tokens.save(token)
                # Now authenticate with the token.
                nonce = await self.discord.authenticate(token)
                self._pending[nonce] = "AUTHENTICATE"
            except Exception as e:
                log.error("Token exchange failed: %s", e)
                await self.server.send({"type": "auth_error", "error": f"Token exchange failed: {e}"})

        elif cmd_name == "AUTHENTICATE":
            user = response_data.get("user", {})
            self.authenticated = True
            self._reauth_attempted = False
            self.current_user = {
                "id": user.get("id", ""),
                "username": user.get("username", ""),
                "avatar": user.get("avatar", ""),
            }
            token = self.tokens.access_token or ""
            await self.server.send({
                "type": "auth_complete",
                "user": self.current_user,
                "access_token": token,
            })
            log.info("Authenticated as %s", user.get("username", "?"))
            # Subscribe to server-level voice events.
            await self._subscribe_server_events()
            # Check if already in a voice channel.
            await self._send_discord_command("GET_SELECTED_VOICE_CHANNEL")

        elif cmd_name == "GET_SELECTED_VOICE_CHANNEL":
            if response_data and response_data.get("id"):
                channel_id = response_data["id"]
                channel_name = response_data.get("name", "")
                guild_id = response_data.get("guild_id", "")
                await self._on_voice_channel_join(channel_id, channel_name, guild_id, response_data)
            else:
                await self._on_voice_channel_leave()

        elif cmd_name in ("GET_VOICE_SETTINGS", "SET_VOICE_SETTINGS"):
            self.voice_settings = {
                "mute": response_data.get("mute", False),
                "deaf": response_data.get("deaf", False),
            }
            await self.server.send({
                "type": "voice_settings",
                **self.voice_settings,
            })

    async def _send_discord_command(
        self, cmd: str, args: dict[str, Any] | None = None
    ) -> None:
        """Send a command to Discord, tracking the nonce for response matching."""
        nonce_str = self.discord._next_nonce()
        payload: dict[str, Any] = {"cmd": cmd, "nonce": str(nonce_str)}
        if args:
            payload["args"] = args
        self._pending[str(nonce_str)] = cmd
        await self.discord.send_frame(OP_FRAME, payload)

    # -- event subscriptions --

    async def _subscribe_server_events(self) -> None:
        """Subscribe to server-level events after authentication."""
        nonce = await self.discord.subscribe("VOICE_CHANNEL_SELECT")
        self._pending[nonce] = "SUB_VOICE_CHANNEL_SELECT"

        nonce = await self.discord.subscribe("VOICE_SETTINGS_UPDATE")
        self._pending[nonce] = "SUB_VOICE_SETTINGS_UPDATE"

    async def _subscribe_channel_events(self, channel_id: str) -> None:
        """Subscribe to voice events for a specific channel."""
        for evt in (
            "VOICE_STATE_CREATE",
            "VOICE_STATE_UPDATE",
            "VOICE_STATE_DELETE",
            "SPEAKING_START",
            "SPEAKING_STOP",
        ):
            nonce = await self.discord.subscribe(evt, {"channel_id": channel_id})
            self._pending[nonce] = f"SUB_{evt}"

    async def _unsubscribe_channel_events(self, channel_id: str) -> None:
        """Unsubscribe from voice events for a specific channel."""
        for evt in (
            "VOICE_STATE_CREATE",
            "VOICE_STATE_UPDATE",
            "VOICE_STATE_DELETE",
            "SPEAKING_START",
            "SPEAKING_STOP",
        ):
            try:
                nonce = await self.discord.unsubscribe(evt, {"channel_id": channel_id})
                self._pending[nonce] = f"UNSUB_{evt}"
            except Exception:
                pass

    # -- voice state management --

    async def _on_voice_channel_join(
        self, channel_id: str, channel_name: str, guild_id: str,
        channel_data: dict[str, Any] | None = None
    ) -> None:
        """Handle joining a voice channel."""
        # Unsubscribe from previous channel if any.
        if self.current_channel_id and self.current_channel_id != channel_id:
            await self._unsubscribe_channel_events(self.current_channel_id)

        self.current_channel_id = channel_id
        self.current_channel = {
            "id": channel_id,
            "name": channel_name,
            "guild_id": guild_id,
        }
        self.voice_users.clear()

        await self.server.send({
            "type": "voice_channel",
            "channel": self.current_channel,
        })

        # Parse initial voice states if provided.
        if channel_data and "voice_states" in channel_data:
            for vs in channel_data["voice_states"]:
                user = vs.get("user", {})
                voice = vs.get("voice_state", {})
                uid = user.get("id", "")
                if uid:
                    self.voice_users[uid] = {
                        "id": uid,
                        "username": user.get("username", ""),
                        "avatar": user.get("avatar", ""),
                        "nick": vs.get("nick", "") or user.get("username", ""),
                        "mute": voice.get("mute", False),
                        "self_mute": voice.get("self_mute", False),
                        "deaf": voice.get("deaf", False),
                        "self_deaf": voice.get("self_deaf", False),
                        "speaking": False,
                    }
            await self._send_voice_state()

        # Subscribe to this channel's events.
        await self._subscribe_channel_events(channel_id)

        # Also fetch current voice settings.
        await self._send_discord_command("GET_VOICE_SETTINGS")

    async def _on_voice_channel_leave(self) -> None:
        """Handle leaving a voice channel."""
        if self.current_channel_id:
            await self._unsubscribe_channel_events(self.current_channel_id)
        self.current_channel_id = None
        self.current_channel = None
        self.voice_users.clear()
        await self.server.send({"type": "voice_channel", "channel": None})

    async def _send_voice_state(self) -> None:
        """Send full voice state to QML."""
        users = list(self.voice_users.values())
        await self.server.send({"type": "voice_state", "users": users})

    # -- dispatch handler --

    async def _handle_dispatch(self, evt: str, data: dict[str, Any]) -> None:
        """Handle a DISPATCH event from Discord."""

        if evt == "VOICE_CHANNEL_SELECT":
            channel_id = data.get("channel_id")
            guild_id = data.get("guild_id", "")
            if channel_id:
                # Fetch channel details.
                await self._send_discord_command(
                    "GET_SELECTED_VOICE_CHANNEL"
                )
            else:
                await self._on_voice_channel_leave()

        elif evt == "VOICE_STATE_CREATE":
            user = data.get("user", {})
            voice = data.get("voice_state", {})
            uid = user.get("id", "")
            if uid:
                self.voice_users[uid] = {
                    "id": uid,
                    "username": user.get("username", ""),
                    "avatar": user.get("avatar", ""),
                    "nick": data.get("nick", "") or user.get("username", ""),
                    "mute": voice.get("mute", False),
                    "self_mute": voice.get("self_mute", False),
                    "deaf": voice.get("deaf", False),
                    "self_deaf": voice.get("self_deaf", False),
                    "speaking": False,
                }
                await self._send_voice_state()

        elif evt == "VOICE_STATE_UPDATE":
            user = data.get("user", {})
            voice = data.get("voice_state", {})
            uid = user.get("id", "")
            if uid and uid in self.voice_users:
                entry = self.voice_users[uid]
                entry["username"] = user.get("username", entry["username"])
                entry["avatar"] = user.get("avatar", entry["avatar"])
                entry["nick"] = data.get("nick", "") or user.get("username", entry["username"])
                entry["mute"] = voice.get("mute", entry["mute"])
                entry["self_mute"] = voice.get("self_mute", entry["self_mute"])
                entry["deaf"] = voice.get("deaf", entry["deaf"])
                entry["self_deaf"] = voice.get("self_deaf", entry["self_deaf"])
                await self._send_voice_state()

        elif evt == "VOICE_STATE_DELETE":
            user = data.get("user", {})
            uid = user.get("id", "")
            if uid and uid in self.voice_users:
                del self.voice_users[uid]
                await self._send_voice_state()

        elif evt == "SPEAKING_START":
            uid = data.get("user_id", "")
            if uid and uid in self.voice_users:
                self.voice_users[uid]["speaking"] = True
            await self.server.send({"type": "speaking", "user_id": uid, "speaking": True})

        elif evt == "SPEAKING_STOP":
            uid = data.get("user_id", "")
            if uid and uid in self.voice_users:
                self.voice_users[uid]["speaking"] = False
            await self.server.send({"type": "speaking", "user_id": uid, "speaking": False})

        elif evt == "VOICE_SETTINGS_UPDATE":
            self.voice_settings = {
                "mute": data.get("mute", False),
                "deaf": data.get("deaf", False),
            }
            await self.server.send({
                "type": "voice_settings",
                **self.voice_settings,
            })

    # -- QML command handler --

    async def _handle_qml_command(self, msg: dict[str, Any]) -> None:
        """Handle a command from the QML plugin."""
        cmd = msg.get("cmd", "")

        if cmd == "connect":
            asyncio.ensure_future(self._do_connect_flow())

        elif cmd == "authorize":
            if not self.discord.connected:
                if not await self._connect_discord():
                    return

            if self._discord_task is None or self._discord_task.done():
                self._discord_task = asyncio.create_task(self._discord_read_loop())

            # A token minted from explicit user consent that still fails to
            # authenticate is a real error; don't silently retry it.
            self._reauth_attempted = True
            nonce = await self.discord.authorize(self.client_id, OAUTH_SCOPES)
            self._pending[nonce] = "AUTHORIZE"

        elif cmd == "authenticate":
            token = self.tokens.load() or ""
            if not token:
                await self.server.send({"type": "auth_required"})
                return
            if not self.discord.connected:
                if not await self._connect_discord():
                    return
            nonce = await self.discord.authenticate(token)
            self._pending[nonce] = "AUTHENTICATE"

        elif cmd == "set_voice_settings":
            if not self.authenticated:
                return
            args: dict[str, Any] = {}
            if "mute" in msg:
                args["mute"] = msg["mute"]
            if "deaf" in msg:
                args["deaf"] = msg["deaf"]
            if args:
                await self._send_discord_command("SET_VOICE_SETTINGS", args)

        elif cmd == "get_voice_settings":
            if self.authenticated:
                await self._send_discord_command("GET_VOICE_SETTINGS")

        elif cmd == "shutdown":
            await self.shutdown()

    async def _do_connect_flow(self, quiet: bool = False) -> None:
        """Full connection flow: connect, then try cached token or request auth.

        Idempotent: every client (daemon and each bar widget) sends `connect`
        when it attaches, so repeat calls while already connected or mid-auth
        must not tear down or duplicate anything.

        `quiet` is used by the background reconnect loop: Discord-not-running
        failures stay silent, and a missing token doesn't re-broadcast
        `auth_required` (which the widget already shows).
        """
        if self.discord.connected:
            if self.authenticated or "AUTHENTICATE" in self._pending.values():
                # Already connected (or auth in flight); new clients get
                # state via the connection replay.
                return
        elif not await self._connect_discord(quiet=quiet):
            return

        # Start reading from Discord in background (only one loop).
        if self._discord_task is None or self._discord_task.done():
            self._discord_task = asyncio.create_task(self._discord_read_loop())

        # Try cached token.
        token = self.tokens.load()
        if token:
            nonce = await self.discord.authenticate(token)
            self._pending[nonce] = "AUTHENTICATE"
        elif not quiet:
            await self.server.send({"type": "auth_required"})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def another_instance_running(socket_path: str) -> bool:
    """True if a live bridge already accepts connections on socket_path.

    Multiple QML components (daemon surface plus one widget per monitor) may
    all try to spawn the bridge; only the first may own the socket, the rest
    must exit instead of unlinking and stealing it.
    """
    if not os.path.exists(socket_path):
        return False
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(1.0)
    try:
        probe.connect(socket_path)
        return True
    except OSError:
        return False  # stale socket file; safe to take over
    finally:
        probe.close()


def main() -> None:
    if len(sys.argv) < 2:
        xdg_runtime = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
        socket_path = os.path.join(xdg_runtime, "dms-discord-voice.sock")
    else:
        socket_path = sys.argv[1]

    client_id = sys.argv[2] if len(sys.argv) > 2 else DEFAULT_CLIENT_ID

    if another_instance_running(socket_path):
        log.info("Another bridge already owns %s; exiting", socket_path)
        sys.exit(0)

    bridge = DiscordBridge(socket_path, client_id)
    asyncio.run(bridge.run())


if __name__ == "__main__":
    main()

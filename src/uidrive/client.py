"""The agent's line protocol (PROTOCOL.md): one request line out, one JSON reply line back, over a
stream socket that the caller's `connect` opens (usbmux, TCP or a Unix socket)."""

import json
import socket
import time
from typing import Callable


class UidriveError(Exception):
    """Base of every uidrive exception."""


class AgentDown(UidriveError):
    """Nothing listens on the agent's port: the app isn't running, or runs without the agent."""


class AgentClosed(UidriveError):
    """The connection ended before a full reply line, as when the app exits mid-request."""


class AgentTimeout(UidriveError):
    """No full reply line before the deadline."""


class AgentError(UidriveError):
    """The agent replied with an error; `str(e)` is its text."""


class Interrupted(UidriveError):
    """`interrupt()` returned a truthy value before the reply came; `.value` holds it."""

    def __init__(self, value: object):
        super().__init__(value)
        self.value = value


def request(line: str, connect: Callable[[float], socket.socket], timeout: float = 10,
            interrupt: Callable[[], object] | None = None) -> dict:
    """The agent's reply to `line`.

    `connect(timeout)` opens the connection; its exceptions propagate unchanged. `interrupt` is
    polled while the reply is awaited, for a caller that knows none can come (a debugger stopped
    the app). `timeout` covers the connect too."""
    if "\n" in line:
        raise ValueError(f"a request is one line: {line!r}")
    verb = line.split(" ", 1)[0]
    closed = f"the agent closed the connection on `{verb}`"
    deadline = time.monotonic() + timeout
    buf = b""
    with connect(timeout) as sock:
        # On a Unix socket, a peer that exits before reading the request gives a broken pipe or a
        # reset instead of an EOF.
        try:
            sock.sendall(line.encode() + b"\n")
        except ConnectionError:
            raise AgentClosed(closed) from None
        while not buf.endswith(b"\n"):
            if interrupt is not None and (value := interrupt()):
                raise Interrupted(value)
            left = deadline - time.monotonic()
            if left <= 0:
                raise AgentTimeout(f"no reply to `{verb}` within {timeout:g}s")
            sock.settimeout(min(0.2, left))
            try:
                chunk = sock.recv(65536)
            except socket.timeout:
                continue
            except ConnectionError:
                break
            if not chunk:
                break
            buf += chunk
    if not buf.endswith(b"\n"):
        raise AgentClosed(closed)
    reply = json.loads(buf)
    if "error" in reply:
        raise AgentError(reply["error"])
    return reply


def gesture_line(paths: list[list[tuple[float, float, int]]], window: int | None = None) -> str:
    """The `gesture` request: one path of `(x, y, t)` keyframes per finger, `t` in ms from the
    gesture's start. `window` None -> no window index; the agent picks the window."""
    return "gesture " + json.dumps({"fingers": paths} | ({"window": window} if window is not None else {}),
                                   separators=(",", ":"))

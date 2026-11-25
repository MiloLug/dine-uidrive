"""uidrive's command line: the agent's source dir, a launch with the agent injected, one request to
the agent, a screenshot. The device commands use tunneld's first device."""

import argparse
import asyncio
import contextlib
import json
import math
import sys

from pymobiledevice3.dtx.exceptions import DTXNSCodingError, DTXNsError, DTXProtocolError
from pymobiledevice3.exceptions import PyMobileDevice3Exception, TunneldConnectionError
from pymobiledevice3.tunneld import api as tunneld

from . import agent_src, client, ios

# Above `ios.launch`'s own bound on the DVT launch.
LAUNCH_TIMEOUT = 90
SCREENSHOT_TIMEOUT = 30
START_TUNNELD = "(start it: pymobiledevice3 remote tunneld)"


class Failed(Exception):
    """A failure whose message is the whole error line."""


def on_device(fn, timeout: float):
    """`fn(rsd)` against tunneld's first device, the whole call bounded by `timeout`."""
    async def call():
        try:
            rsds = await tunneld.get_tunneld_devices()
        except TunneldConnectionError:
            raise Failed(f"tunneld isn't reachable {START_TUNNELD}") from None
        if not rsds:
            raise Failed(f"tunneld has no device {START_TUNNELD}")
        try:
            return await fn(rsds[0])
        finally:
            for rsd in rsds:
                with contextlib.suppress(Exception):
                    await rsd.close()

    async def bounded():
        deadline = asyncio.timeout(timeout)
        try:
            async with deadline:
                return await call()
        except TimeoutError as e:
            if deadline.expired():
                raise TimeoutError(f"the device didn't answer within {timeout:g}s") from None
            if not str(e):
                raise TimeoutError("the device didn't answer in time") from None
            raise
    return asyncio.run(bounded())


def agent_src_cmd(args) -> None:
    print(agent_src())


def ask(args) -> None:
    reply = client.request(args.line, lambda timeout: ios.connect(args.port, timeout), args.timeout)
    print(json.dumps(reply, ensure_ascii=False))


def launch(args) -> None:
    async def run(rsd):
        try:
            return await ios.launch(rsd, args.bundle_id, port=args.port, dylib=args.dylib,
                                    suspended=args.suspended, inject=not args.no_inject)
        except AssertionError as e:
            if str(e):
                raise
            return 0  # DVT's launch asserts on a zero pid, with no text
    pid = on_device(run, LAUNCH_TIMEOUT)
    if not pid:
        raise Failed(f"the device returned no pid for {args.bundle_id}")
    print(f"launched {args.bundle_id} pid {pid}")


def screenshot(args) -> None:
    png = on_device(ios.screenshot, SCREENSHOT_TIMEOUT)
    with open(args.path, "wb") as f:
        f.write(png)
    print(args.path)


def seconds(text: str) -> float:
    value = float(text)
    if not 0 < value < math.inf:
        raise argparse.ArgumentTypeError(f"not a positive number of seconds: {text}")
    return value


def port(text: str) -> int:
    value = int(text)
    if not 0 < value < 65536:
        raise argparse.ArgumentTypeError(f"not a TCP port: {text}")
    return value


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="uidrive", description="In-process UI automation for iOS apps.")
    sub = p.add_subparsers(required=True, metavar="COMMAND")

    s = sub.add_parser("agent-src", help="print the agent's CMake source dir")
    s.set_defaults(run=agent_src_cmd)

    s = sub.add_parser("launch", help="launch an installed app with the agent injected; print its pid")
    s.add_argument("bundle_id", metavar="BUNDLE_ID")
    s.add_argument("--port", type=port, default=ios.DEFAULT_PORT, help="the agent's port (default %(default)s)")
    s.add_argument("--dylib", default=ios.DEFAULT_DYLIB,
                   help="the agent's path inside the .app bundle (default %(default)s)")
    s.add_argument("--suspended", action="store_true", help="start the app suspended, for a debugger")
    s.add_argument("--no-inject", action="store_true", help="launch without the agent")
    s.set_defaults(run=launch)

    s = sub.add_parser("ask", help="send the agent one request line; print its JSON reply")
    s.add_argument("line", metavar="LINE", help="the request, e.g. 'ls' (PROTOCOL.md)")
    s.add_argument("--port", type=port, default=ios.DEFAULT_PORT, help="the agent's port (default %(default)s)")
    s.add_argument("--timeout", type=seconds, default=10, help="seconds to wait for the reply (default %(default)s)")
    s.set_defaults(run=ask)

    s = sub.add_parser("screenshot", help="save the screen as a PNG; print its path")
    s.add_argument("path", metavar="PATH")
    s.set_defaults(run=screenshot)
    return p


def main(argv: list[str] | None = None) -> int:
    """Exit status: 0 done, 1 failed (one `uidrive: …` line on stderr), 2 bad arguments."""
    args = parser().parse_args(argv)
    try:
        args.run(args)
    except Failed as e:
        print(f"uidrive: {e}", file=sys.stderr)
        return 1
    except (client.UidriveError, PyMobileDevice3Exception, DTXNsError, DTXProtocolError, DTXNSCodingError,
            EOFError, OSError, ValueError) as e:
        print(f"uidrive: {type(e).__name__}" + (f": {e}" if str(e) else ""), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

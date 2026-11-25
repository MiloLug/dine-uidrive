"""iOS transport: a usbmux connection to the agent's port, a DVT launch that injects the agent, and a
DVT screenshot. `rsd` is a pymobiledevice3 RemoteServiceDiscovery (tunneld) or lockdown client."""

import asyncio
import socket
from pathlib import PurePosixPath

from pymobiledevice3 import usbmux
from pymobiledevice3.exceptions import ConnectionFailedError, ConnectionFailedToUsbmuxdError
from pymobiledevice3.services.dvt.instruments.dvt_provider import DvtProvider
from pymobiledevice3.services.dvt.instruments.process_control import ProcessControl
from pymobiledevice3.services.dvt.instruments.screenshot import Screenshot
from pymobiledevice3.services.installation_proxy import InstallationProxyService

from .client import AgentDown, AgentTimeout, UidriveError

DEFAULT_PORT = 47802
DEFAULT_DYLIB = "libuidrive.dylib"


class NoDevice(UidriveError):
    """usbmuxd lists no device."""


class UsbmuxUnreachable(UidriveError):
    """usbmuxd itself can't be reached."""


class NotInstalled(UidriveError):
    """No user app with this bundle ID is installed; `str(e)` is the ID."""


def connect(port: int = DEFAULT_PORT, timeout: float = 10) -> socket.socket:
    """A blocking socket to `port` on the first usbmux device. For `client.request`, bind the port:
    `lambda t: connect(port, t)`."""
    async def open_():
        device = await usbmux.select_device()
        if device is None:
            raise NoDevice("no device on usbmux")
        return await device.connect(port)
    try:
        sock = asyncio.run(asyncio.wait_for(open_(), timeout))
    except ConnectionFailedToUsbmuxdError:  # subclasses ConnectionFailedError, so it goes first
        raise UsbmuxUnreachable("usbmuxd isn't reachable") from None
    except ConnectionFailedError:
        raise AgentDown(f"nothing listens on port {port}") from None
    except TimeoutError:
        raise AgentTimeout(f"no usbmux connection to port {port} within {timeout:g}s") from None
    sock.setblocking(True)
    return sock


def launch_env(bundle_path: str, dylib: str, port: int, env: dict[str, str] | None = None) -> dict[str, str]:
    """`env` plus the variables that make dyld load `dylib` (a path inside the `.app` bundle at
    `bundle_path`) and the agent serve `port`."""
    path = PurePosixPath(dylib)
    if not path.parts or path.is_absolute() or ".." in path.parts:
        raise ValueError(f"the dylib must be a path inside the bundle: {dylib!r}")
    return {**(env or {}), "DYLD_INSERT_LIBRARIES": f"{bundle_path.rstrip('/')}/{dylib}",
            "UIDRIVE_PORT": str(port)}


async def bundle_path(rsd, bundle_id: str) -> str:
    """The installed `.app` dir of the user app `bundle_id`."""
    async with InstallationProxyService(rsd) as ip:
        apps = await ip.get_apps(application_type="User")
    if bundle_id not in apps:
        raise NotInstalled(bundle_id)
    return apps[bundle_id]["Path"]


async def launch(rsd, bundle_id: str, *, port: int = DEFAULT_PORT, dylib: str = DEFAULT_DYLIB,
                 env: dict[str, str] | None = None, suspended: bool = False, inject: bool = True) -> int:
    """Launch `bundle_id` through DVT, killing a running instance first; returns the pid.

    The app must be debuggable (get-task-allow): dyld ignores `DYLD_INSERT_LIBRARIES` otherwise.
    `inject=False` launches with `env` alone. DVT's and asyncio's errors propagate unchanged."""
    env = launch_env(await bundle_path(rsd, bundle_id), dylib, port, env) if inject else dict(env or {})
    async with DvtProvider(rsd) as dvt, ProcessControl(dvt) as pc:
        return await asyncio.wait_for(pc.launch(bundle_id, kill_existing=True, start_suspended=suspended,
                                                environment=env), 60)


async def screenshot(rsd) -> bytes:
    """The screen as PNG bytes."""
    async with DvtProvider(rsd) as dvt, Screenshot(dvt) as shot:
        return await shot.get_screenshot()

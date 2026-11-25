import asyncio
import socket

import pytest
from pymobiledevice3.exceptions import ConnectionFailedError, ConnectionFailedToUsbmuxdError

import uidrive.ios as ios
from uidrive.client import AgentDown, AgentTimeout
from uidrive.ios import NoDevice, NotInstalled, UsbmuxUnreachable, connect, launch, launch_env, screenshot

BUNDLE = "/private/var/containers/Bundle/Application/X/Dine.app"


def test_launch_env_points_at_the_bundle_dylib():
    env = launch_env(BUNDLE + "/", "dev/libuidrive.dylib", 47802)
    assert env["DYLD_INSERT_LIBRARIES"] == BUNDLE + "/dev/libuidrive.dylib"
    assert env["UIDRIVE_PORT"] == "47802"


def test_launch_env_keeps_the_callers_env():
    assert launch_env(BUNDLE, "libuidrive.dylib", 1, {"A": "b"}) == {
        "A": "b", "DYLD_INSERT_LIBRARIES": BUNDLE + "/libuidrive.dylib", "UIDRIVE_PORT": "1"}


@pytest.mark.parametrize("dylib", ["/x.dylib", "../x.dylib", "dev/../../x.dylib", "", "."])
def test_launch_env_refuses_paths_outside_the_bundle(dylib):
    with pytest.raises(ValueError):
        launch_env(BUNDLE, dylib, 1)


def test_launch_env_takes_dots_inside_a_name():
    assert launch_env(BUNDLE, "dev/a..b.dylib", 1)["DYLD_INSERT_LIBRARIES"] == BUNDLE + "/dev/a..b.dylib"


class Fakes:
    """Async-context-manager stand-ins for the services `launch` and `screenshot` open."""

    def __init__(self, apps):
        self.apps = apps
        self.proxy_opened = False
        self.launched = None
        fakes = self

        class Proxy:
            def __init__(self, rsd):
                fakes.proxy_opened = True

            async def __aenter__(self):
                return self

            async def __aexit__(self, *exc):
                return False

            async def get_apps(self, application_type="Any"):
                assert application_type == "User"
                return fakes.apps

        class Dvt:
            def __init__(self, rsd):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *exc):
                return False

        class Control(Dvt):
            async def launch(self, bundle_id, **kwargs):
                fakes.launched = (bundle_id, kwargs)
                return 42

        class Shot(Dvt):
            async def get_screenshot(self):
                return b"\x89PNG"

        self.Proxy, self.Dvt, self.Control, self.Shot = Proxy, Dvt, Control, Shot


@pytest.fixture
def fakes(monkeypatch):
    f = Fakes({"b.id": {"Path": BUNDLE}})
    monkeypatch.setattr(ios, "InstallationProxyService", f.Proxy)
    monkeypatch.setattr(ios, "DvtProvider", f.Dvt)
    monkeypatch.setattr(ios, "ProcessControl", f.Control)
    monkeypatch.setattr(ios, "Screenshot", f.Shot)
    return f


def test_launch_injects(fakes):
    assert asyncio.run(launch(object(), "b.id", port=5000, dylib="dev/libuidrive.dylib", env={"A": "b"})) == 42
    bundle_id, kwargs = fakes.launched
    assert bundle_id == "b.id"
    assert kwargs["environment"] == {"A": "b", "DYLD_INSERT_LIBRARIES": BUNDLE + "/dev/libuidrive.dylib",
                                     "UIDRIVE_PORT": "5000"}
    assert kwargs["kill_existing"] is True
    assert kwargs["start_suspended"] is False


def test_launch_without_inject(fakes):
    asyncio.run(launch(object(), "b.id", inject=False, suspended=True))
    assert fakes.launched[1]["environment"] == {}
    assert fakes.launched[1]["start_suspended"] is True
    assert not fakes.proxy_opened


def test_launch_of_a_missing_bundle(fakes):
    fakes.apps = {}
    with pytest.raises(NotInstalled):
        asyncio.run(launch(object(), "b.id"))
    assert fakes.launched is None


def test_screenshot_returns_the_png(fakes):
    assert asyncio.run(screenshot(object())) == b"\x89PNG"


class Device:
    def __init__(self, connect):
        self.connect = connect


def selecting(device=None, error=None):
    async def select_device():
        if error:
            raise error
        return device
    return select_device


def test_connect_maps_errors(monkeypatch):
    monkeypatch.setattr(ios.usbmux, "select_device", selecting(None))
    with pytest.raises(NoDevice):
        connect(47802, 5)

    async def refused(port):
        raise ConnectionFailedError()
    monkeypatch.setattr(ios.usbmux, "select_device", selecting(Device(refused)))
    with pytest.raises(AgentDown):
        connect(47802, 5)


def test_connect_without_usbmuxd(monkeypatch):
    # A subclass of ConnectionFailedError, so it must not end up as AgentDown.
    monkeypatch.setattr(ios.usbmux, "select_device", selecting(error=ConnectionFailedToUsbmuxdError()))
    with pytest.raises(UsbmuxUnreachable):
        connect(47802, 5)


def test_connect_timeout(monkeypatch):
    async def hangs(port):
        await asyncio.sleep(10)
    monkeypatch.setattr(ios.usbmux, "select_device", selecting(Device(hangs)))
    with pytest.raises(AgentTimeout):
        connect(47802, 0.2)


def test_connect_returns_a_blocking_socket_to_the_port(monkeypatch):
    ours, theirs = socket.socketpair()
    ours.setblocking(False)
    ports = []

    async def opens(port):
        ports.append(port)
        return ours
    monkeypatch.setattr(ios.usbmux, "select_device", selecting(Device(opens)))
    with connect(1234, 5) as sock, theirs:
        assert sock is ours
        assert sock.getblocking()
    assert ports == [1234]

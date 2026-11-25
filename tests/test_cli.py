import asyncio
import socket
import threading
from types import SimpleNamespace

import pytest
from pymobiledevice3.dtx.exceptions import DTXNsError, DTXProtocolError
from pymobiledevice3.exceptions import BadDevError, DvtException, TunneldConnectionError

import uidrive.__main__ as cli
from uidrive import agent_src
from uidrive.__main__ import main
from uidrive.ios import NotInstalled


@pytest.fixture(autouse=True)
def offline(monkeypatch):
    """No test reaches the phone: the real usbmux and tunneld calls fail the test."""
    def connect(port, timeout):
        pytest.fail("real usbmux connect")

    async def get_tunneld_devices():
        pytest.fail("real tunneld lookup")
    monkeypatch.setattr("uidrive.ios.connect", connect)
    monkeypatch.setattr("pymobiledevice3.tunneld.api.get_tunneld_devices", get_tunneld_devices)


@pytest.fixture
def agent(monkeypatch):
    """`agent(reply)` replaces `uidrive.ios.connect` with a fake whose peer reads one line into
    `agent.got`, sends `reply` and closes; `agent.connects` records each `(port, timeout)`."""
    peers = []

    def make(reply: bytes):
        ours, theirs = socket.socketpair()
        peers.append(theirs)

        def peer():
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = theirs.recv(100)
                if not chunk:
                    return
                buf += chunk
            make.got = buf
            theirs.sendall(reply)
            theirs.close()
        threading.Thread(target=peer, daemon=True).start()

        def connect(port, timeout):
            make.connects.append((port, timeout))
            return ours
        monkeypatch.setattr("uidrive.ios.connect", connect)

    make.connects = []
    yield make
    for theirs in peers:
        theirs.close()


class Rsd:
    closed = False

    async def close(self):
        self.closed = True


class BadRsd(Rsd):
    async def close(self):
        raise ConnectionResetError("reset")


@pytest.fixture
def tunneld(monkeypatch):
    """`tunneld(*rsds)` makes `get_tunneld_devices` return them; `tunneld(exc)` makes it raise."""
    def make(*result):
        async def get_tunneld_devices():
            if result and isinstance(result[0], BaseException):
                raise result[0]
            return list(result)
        monkeypatch.setattr("pymobiledevice3.tunneld.api.get_tunneld_devices", get_tunneld_devices)
    return make


def test_agent_src_prints_the_dir(capsys):
    assert main(["agent-src"]) == 0
    assert capsys.readouterr().out == f"{agent_src()}\n"


def test_ask_prints_the_reply(agent, capsys):
    agent(b'{"ok": true}\n')
    assert main(["ask", "ls"]) == 0
    assert capsys.readouterr().out == '{"ok": true}\n'
    assert agent.got == b"ls\n"
    assert agent.connects == [(47802, 10)]


def test_ask_connects_to_the_given_port(agent, capsys):
    agent(b'{"ok": true}\n')
    assert main(["ask", "--port", "5000", "--timeout", "3", "settle 300"]) == 0
    assert agent.connects == [(5000, 3)]
    assert agent.got == b"settle 300\n"


@pytest.mark.parametrize("timeout", ["nan", "inf", "0", "-1"])
def test_ask_timeout_must_be_positive(timeout, capsys):
    with pytest.raises(SystemExit) as e:
        main(["ask", "--timeout", timeout, "ls"])
    assert e.value.code == 2
    assert "not a positive number of seconds" in capsys.readouterr().err


@pytest.mark.parametrize("command", [["ask", "ls"], ["launch", "b.id"]])
@pytest.mark.parametrize("value", ["0", "-1", "65536"])
def test_port_must_be_a_tcp_port(command, value, capsys):
    with pytest.raises(SystemExit) as e:
        main([*command, "--port", value])
    assert e.value.code == 2
    assert "not a TCP port" in capsys.readouterr().err


def test_ask_keeps_non_ascii_labels(agent, capsys):
    agent('{"labels": [[true, "say \\"hi\\" é"]]}\n'.encode())
    assert main(["ask", "ls"]) == 0
    assert capsys.readouterr().out == '{"labels": [[true, "say \\"hi\\" é"]]}\n'


def test_ask_error_exits_1(agent, capsys):
    agent(b'{"error": "x"}\n')
    assert main(["ask", "ls"]) == 1
    out = capsys.readouterr()
    assert out.out == ""
    assert out.err == "uidrive: AgentError: x\n"


def test_ask_of_two_lines_exits_1(capsys):
    assert main(["ask", "ls\nls"]) == 1
    assert capsys.readouterr().err == "uidrive: ValueError: a request is one line: 'ls\\nls'\n"


def test_ask_usbmux_error_exits_1(monkeypatch, capsys):
    def connect(port, timeout):
        raise BadDevError("gone")
    monkeypatch.setattr("uidrive.ios.connect", connect)
    assert main(["ask", "ls"]) == 1
    assert capsys.readouterr().err == "uidrive: BadDevError: gone\n"


def test_launch_prints_the_pid(tunneld, monkeypatch, capsys):
    rsd, other = Rsd(), Rsd()
    tunneld(rsd, other)
    calls = []

    async def launch(rsd_, bundle_id, **kwargs):
        calls.append((rsd_, bundle_id, kwargs))
        return 123
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id"]) == 0
    assert capsys.readouterr().out == "launched b.id pid 123\n"
    assert calls == [(rsd, "b.id", {"port": 47802, "dylib": "libuidrive.dylib", "suspended": False,
                                     "inject": True})]
    assert rsd.closed and other.closed


def test_launch_options(tunneld, monkeypatch, capsys):
    tunneld(Rsd())
    calls = []

    async def launch(rsd_, bundle_id, **kwargs):
        calls.append(kwargs)
        return 1
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id", "--port", "5000", "--dylib", "dev/x.dylib", "--suspended",
                 "--no-inject"]) == 0
    assert calls == [{"port": 5000, "dylib": "dev/x.dylib", "suspended": True, "inject": False}]


def test_launch_of_a_missing_app_exits_1(tunneld, monkeypatch, capsys):
    rsd = Rsd()
    tunneld(rsd)

    async def launch(rsd_, bundle_id, **kwargs):
        raise NotInstalled(bundle_id)
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id"]) == 1
    assert capsys.readouterr().err == "uidrive: NotInstalled: b.id\n"
    assert rsd.closed


def test_a_launch_without_a_pid_exits_1(tunneld, monkeypatch, capsys):
    tunneld(Rsd())

    async def launch(rsd_, bundle_id, **kwargs):
        raise AssertionError  # as DVT's bare `assert result`; an `assert` here would get pytest's text
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id"]) == 1
    assert capsys.readouterr().err == "uidrive: the device returned no pid for b.id\n"


def test_an_assert_with_text_is_not_a_missing_pid(tunneld, monkeypatch):
    tunneld(Rsd())

    async def launch(rsd_, bundle_id, **kwargs):
        raise AssertionError("bad DTX frame")
    monkeypatch.setattr("uidrive.ios.launch", launch)
    with pytest.raises(AssertionError, match="bad DTX frame"):
        main(["launch", "b.id"])


def test_a_zero_pid_exits_1(tunneld, monkeypatch, capsys):
    tunneld(Rsd())

    async def launch(rsd_, bundle_id, **kwargs):
        return 0
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id"]) == 1
    assert capsys.readouterr().err == "uidrive: the device returned no pid for b.id\n"


def test_a_failing_close_keeps_the_error_and_closes_the_rest(tunneld, monkeypatch, capsys):
    rsd = Rsd()
    tunneld(BadRsd(), rsd)

    async def launch(rsd_, bundle_id, **kwargs):
        raise NotInstalled(bundle_id)
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id"]) == 1
    assert capsys.readouterr().err == "uidrive: NotInstalled: b.id\n"
    assert rsd.closed


def test_no_tunneld_device_exits_1(tunneld, capsys, tmp_path):
    tunneld()
    assert main(["screenshot", str(tmp_path / "x.png")]) == 1
    assert capsys.readouterr().err == "uidrive: tunneld has no device (start it: pymobiledevice3 remote tunneld)\n"


def test_tunneld_down_exits_1(tunneld, capsys):
    tunneld(TunneldConnectionError())
    assert main(["launch", "b.id"]) == 1
    assert capsys.readouterr().err == "uidrive: tunneld isn't reachable (start it: pymobiledevice3 remote tunneld)\n"


@pytest.mark.parametrize("command, call, bound", [(["launch", "b.id"], "launch", "LAUNCH_TIMEOUT"),
                                                   (["screenshot", "x.png"], "screenshot", "SCREENSHOT_TIMEOUT")])
def test_a_device_call_that_never_returns_ends(command, call, bound, tunneld, monkeypatch, capsys, tmp_path):
    rsd = Rsd()
    tunneld(rsd)

    async def hangs(*args, **kwargs):
        await asyncio.sleep(5)
    monkeypatch.setattr(f"uidrive.ios.{call}", hangs)
    monkeypatch.setattr(cli, bound, 0.2)
    monkeypatch.chdir(tmp_path)
    assert main(command) == 1
    assert capsys.readouterr().err == "uidrive: TimeoutError: the device didn't answer within 0.2s\n"
    assert rsd.closed


def test_a_timeout_without_text_is_named(tunneld, monkeypatch, capsys):
    tunneld(Rsd())

    async def launch(rsd_, bundle_id, **kwargs):
        raise TimeoutError
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id"]) == 1
    assert capsys.readouterr().err == "uidrive: TimeoutError: the device didn't answer in time\n"


def test_a_timeout_with_text_keeps_it(tunneld, monkeypatch, capsys):
    tunneld(Rsd())

    async def launch(rsd_, bundle_id, **kwargs):
        raise TimeoutError("x")
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id"]) == 1
    assert capsys.readouterr().err == "uidrive: TimeoutError: x\n"


def test_an_empty_error_prints_its_class(tunneld, monkeypatch, capsys):
    tunneld(Rsd())

    async def launch(rsd_, bundle_id, **kwargs):
        raise DvtException
    monkeypatch.setattr("uidrive.ios.launch", launch)
    assert main(["launch", "b.id"]) == 1
    assert capsys.readouterr().err == "uidrive: DvtException\n"


@pytest.mark.parametrize("error, line", [
    (DTXNsError(SimpleNamespace(domain="D", code=1, user_info=None)), "uidrive: DTXNsError: D (code 1, user_info=None)\n"),
    (DTXProtocolError("bad frame"), "uidrive: DTXProtocolError: bad frame\n"),
    (asyncio.IncompleteReadError(b"", 4), "uidrive: IncompleteReadError: 0 bytes read on a total of 4 expected bytes\n"),
])
def test_dtx_errors_exit_1(error, line, tunneld, monkeypatch, capsys, tmp_path):
    tunneld(Rsd())

    async def screenshot(rsd_):
        raise error
    monkeypatch.setattr("uidrive.ios.screenshot", screenshot)
    assert main(["screenshot", str(tmp_path / "s.png")]) == 1
    assert capsys.readouterr().err == line


def test_screenshot_writes_the_png(tunneld, monkeypatch, capsys, tmp_path):
    rsd = Rsd()
    tunneld(rsd)

    async def screenshot(rsd_):
        return b"\x89PNG"
    monkeypatch.setattr("uidrive.ios.screenshot", screenshot)
    path = tmp_path / "s.png"
    assert main(["screenshot", str(path)]) == 0
    assert path.read_bytes() == b"\x89PNG"
    assert capsys.readouterr().out == f"{path}\n"
    assert rsd.closed


def test_a_failed_write_exits_1(tunneld, monkeypatch, capsys, tmp_path):
    tunneld(Rsd())

    async def screenshot(rsd_):
        return b"\x89PNG"
    monkeypatch.setattr("uidrive.ios.screenshot", screenshot)
    path = tmp_path / "no/s.png"
    assert main(["screenshot", str(path)]) == 1
    assert capsys.readouterr().err == f"uidrive: FileNotFoundError: [Errno 2] No such file or directory: '{path}'\n"


def test_a_command_is_required(capsys):
    with pytest.raises(SystemExit) as e:
        main([])
    assert e.value.code == 2

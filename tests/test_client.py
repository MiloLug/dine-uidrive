import select
import socket
import threading
import time

import pytest

from uidrive.client import KEYS, AgentClosed, AgentDown, AgentError, AgentTimeout, Interrupted, gesture_line, request


@pytest.fixture
def serve():
    """`serve(reply)` makes a connect() whose peer reads one line into `serve.got`, then sends `reply`
    and closes (None: never answers)."""
    peers = []

    def make(reply: bytes | None):
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
            if reply is not None:
                theirs.sendall(reply)
                theirs.close()
        threading.Thread(target=peer, daemon=True).start()
        return lambda timeout: ours

    yield make
    for theirs in peers:
        theirs.close()


def test_reply_and_request_line(serve):
    assert request("ls", serve(b'{"labels": [[true, "art"]]}\n'), 5) == {"labels": [[True, "art"]]}
    assert serve.got == b"ls\n"


def test_error_reply_raises_agent_error(serve):
    with pytest.raises(AgentError) as e:
        request('activate 1 "x"', serve(b'{"error": "the screen changed"}\n'), 5)
    assert str(e.value) == "the screen changed"


def test_closed_without_reply(serve):
    with pytest.raises(AgentClosed):
        request("ls", serve(b""), 5)


def test_cut_reply_is_closed(serve):
    with pytest.raises(AgentClosed):
        request("ls", serve(b'{"labels": ['), 5)


def test_peer_gone_before_the_request_is_closed():
    ours, theirs = socket.socketpair()
    theirs.close()
    with pytest.raises(AgentClosed):
        request("ls", lambda timeout: ours, 5)


def test_peer_gone_with_the_request_unread_is_closed():
    # On a Unix socket the request left unread turns the peer's close into a reset, not an EOF.
    ours, theirs = socket.socketpair()

    def peer():
        select.select([theirs], [], [])
        theirs.close()
    threading.Thread(target=peer, daemon=True).start()
    with pytest.raises(AgentClosed):
        request("ls", lambda timeout: ours, 5)


def test_interrupt_ends_the_wait(serve):
    stops = iter([None, None, "stopped at X"])
    with pytest.raises(Interrupted) as e:
        request("settle 3000", serve(None), 5, interrupt=lambda: next(stops))
    assert e.value.value == "stopped at X"


def test_interrupt_errors_propagate(serve):
    def interrupt():
        raise ConnectionRefusedError("the caller's own error")
    with pytest.raises(ConnectionRefusedError, match="the caller's own error"):
        request("settle 3000", serve(None), 5, interrupt=interrupt)


def test_timeout(serve):
    start = time.monotonic()
    with pytest.raises(AgentTimeout):
        request("settle 3000", serve(None), 0.3)
    assert time.monotonic() - start < 1


def test_line_with_newline_is_refused():
    def connect(timeout):
        raise AssertionError("connect was called")
    with pytest.raises(ValueError, match="one line"):
        request("ls\nls", connect, 5)


def test_connect_errors_propagate():
    def connect(timeout):
        raise AgentDown("nothing on the port")
    with pytest.raises(AgentDown, match="nothing on the port"):
        request("ls", connect, 5)


def test_gesture_line():
    assert gesture_line([[(1, 2, 0), (3, 4, 60)]]) == 'gesture {"fingers":[[[1,2,0],[3,4,60]]]}'
    assert gesture_line([[(1, 2, 0), (3, 4, 60)]], window=2) == 'gesture {"fingers":[[[1,2,0],[3,4,60]]],"window":2}'


def test_keys_table():
    assert KEYS["return"] == 40
    assert KEYS["a"] == 4
    assert KEYS["z"] == 29
    assert KEYS["1"] == 30
    assert KEYS["0"] == 39
    assert KEYS["up"] == 82

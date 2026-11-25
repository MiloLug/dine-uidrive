# uidrive

uidrive drives an iOS app's UI from a computer. An agent dylib, injected into the app when it
launches, makes real touches, drags, multi-finger gestures and hardware key presses through UIKit's
own event queue, and reads and activates the app's accessibility elements. A Python package
launches the app with the agent and talks to it through usbmux. It needs no XCTest, no runner app,
no Mac and no change to the app's code; Apple's XCUITest needs XCTest, a second runner app and a
Mac.

```console
$ uidrive ask windows
{"windows": [{"frame": [0, 0, 390, 844], "key": true, "level": 0, "class": "UIWindow", "ctx": 1065072099, "hidden": false}]}
$ uidrive ask 'touch down 0 56.333333333333336 69'
{"ctx": 1065072099, "window": "UIWindow", "ok": true}
$ uidrive ask 'touch up 0 56.333333333333336 69'
{"ctx": 1065072099, "window": "UIWindow", "ok": true}
```

The two `touch` requests are a finger tap on a button, which opened the button's screen.
[PROTOCOL.md](PROTOCOL.md) is the wire format; [docs/design.md](docs/design.md) is the design and
the device results behind it.

## Requirements

- An app you build and sign for development (with the get-task-allow entitlement): dyld takes
  `DYLD_INSERT_LIBRARIES` only in such an app, so release, TestFlight and App Store builds can't
  load the agent.
- An iOS SDK and a CMake toolchain file that compiles Objective-C++ (C++20, ARC) for arm64 iOS and
  links a shared library; CMake 3.20 or later and Ninja. uidrive's CMake project sets no compiler,
  SDK or linker of its own. On Linux, xtool (`xtool sdk install`) provides the SDK; the tested
  toolchain sets `CMAKE_SYSTEM_NAME` `iOS`, the SDK as sysroot, clang with an
  `arm64-apple-ios<version>` target, and xtool's `ld64.lld` as the linker for executables and shared
  libraries. On a Mac, CMake's own iOS support (`-DCMAKE_SYSTEM_NAME=iOS`) may stand in for the
  toolchain file (untested).
- Python 3.12 or later. pymobiledevice3 11.31 or later comes with the package.
- The phone in Developer Mode, with the developer disk image mounted
  (`pymobiledevice3 mounter auto-mount`).
- For `launch` and `screenshot`, pymobiledevice3's tunneld running as root, since it creates a
  tunnel interface (`sudo pymobiledevice3 remote tunneld`). `ask` goes through usbmux only.

Tested setup: iPhone 13 on iOS 27.2, pymobiledevice3 11.32.0, the agent built on Linux with clang
and xtool's `ld64.lld`, the app signed and installed by xtool.

## Install

```sh
uv add "uidrive @ git+https://github.com/MiloLug/dine-uidrive.git"
```

The package holds the Python client, the `uidrive` command and the agent's sources, so the dylib
you build matches the client. `uv add` puts `uidrive` in the project's `.venv`: run the commands
below with that environment activated, or prefix them with `uv run`.

## Build the agent

```sh
cmake -S "$(uidrive agent-src)" -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=/path/to/ios.toolchain.cmake
cmake --build build
```

This writes `build/libuidrive.dylib` (install name `@rpath/libuidrive.dylib`). It links UIKit,
Foundation and CoreGraphics; the private symbols it uses are looked up at run time, so it links no
private framework. xtool's `ld64.lld` 21 prints `This version of lld does not support linking for
platform iOS. Proceed at your own risk.`; the dylib it links loads on the tested phone.

## Put it in the app

Copy `libuidrive.dylib` anywhere inside the `.app` before the app is signed, so it is signed with
the app: iOS loads only code signed by the app's team. xtool signs a loose dylib it finds in the
bundle (checked with xtool only). With xtool, put the dylib in a directory of its own and list that
directory under `resources:` in `xtool.yml`:

```yaml
resources:
  - agent   # lands in the bundle as agent/libuidrive.dylib
```

Leave the directory empty in release builds: they can't load the agent.

## Launch the app with the agent

```sh
uidrive launch BUNDLE_ID --dylib agent/libuidrive.dylib
```

It prints `launched BUNDLE_ID pid N`. `launch` kills a running instance of the app, then starts it
through DVT with `DYLD_INSERT_LIBRARIES` set to the dylib's path in the installed bundle and
`UIDRIVE_PORT` set to the agent's port (47802; `--port` changes it). BUNDLE_ID is the ID the app
is installed under: xtool with a free Apple ID installed the tested app as
`XTL-<team ID>.<bundle ID>`. An ID that isn't installed gives `uidrive: NotInstalled: <id>`.

The agent logs `uidrive: injected into <process>` and `uidrive: listening on 127.0.0.1:47802`
(os_log subsystem `uidrive`), and removes both variables from the app's environment.

## Talk to the agent

```sh
uidrive ask ls
uidrive ask 'activate 3 "Settings"'
uidrive ask 'gesture {"fingers":[[[100,400,0],[300,400,250]]]}'
uidrive ask 'key down 40'
uidrive ask 'key up 40'
```

One request line, one JSON reply line on stdout. `ask` waits 10 s for the reply; a `gesture`
replies after it has played, so give `--timeout` above the gesture's length. The verbs:

- accessibility, no touch: `ls` (the screen's labels, values and frames), `activate`, `insert`,
  `back`, `action`, `appearance`, `settle`;
- real input: `touch` (one finger's down, move, up or cancel), `gesture` (timed paths for up to 10
  fingers, played inside the app), `key` (a HID keyboard usage), and `windows`.

PROTOCOL.md has each verb's grammar, replies and errors, and which window an event goes to. An
error reply exits 1 with one line on stderr:

```console
$ uidrive ask 'touch up 3 1 1'
uidrive: AgentError: finger 3 is not down
```

## From Python

```python
from uidrive import client, ios

def connect(timeout):
    return ios.connect(ios.DEFAULT_PORT, timeout)

screen = client.request("ls", connect)
client.request(client.gesture_line([[(100, 400, 0), (300, 400, 250)]]), connect, timeout=15)
```

`client.request(line, connect, timeout, interrupt)` sends one line over the socket `connect`
opens: usbmux through `ios.connect`, or any TCP or Unix socket. Pass a function of the timeout, as
above: `ios.connect` itself takes the port first. Both block, and `ios.connect` runs its own event
loop, so call them outside a running one (from async code, through `asyncio.to_thread`).
`client.gesture_line(paths, window)` builds a `gesture` request from `(x, y, t)` keyframes per
finger; `client.KEYS` maps key names (`return`, `tab`, `left`, `a` to `z`, `0` to `9`, …) to
usages. `ios.launch(rsd, bundle_id, …)` and
`ios.screenshot(rsd)` are coroutines on a pymobiledevice3 service provider. uidrive's exceptions
derive from `client.UidriveError`, except `ValueError` for a request of more than one line, a
dylib path outside the bundle and a reply that isn't JSON; pymobiledevice3's pass through. The
docstrings say when each is raised.

## Command line

- `uidrive agent-src`: the agent's CMake source dir inside the installed package.
- `uidrive launch BUNDLE_ID [--port N] [--dylib PATH] [--suspended] [--no-inject]`: launch with the
  agent; print the pid.
- `uidrive ask LINE [--port N] [--timeout S]`: one request; print the reply.
- `uidrive screenshot PATH`: save the screen as a PNG.

`uidrive <command> --help` has the options. Exit status: 0 done, 1 failed (one `uidrive: …` line on
stderr), 2 bad arguments.

## How it works

The dylib's constructor runs when dyld loads it. With `UIDRIVE_PORT` set, it turns the app's
accessibility on (SwiftUI builds the tree `ls` reads only while it is on) and serves
`127.0.0.1:UIDRIVE_PORT` on its own thread, one request per connection. Touches are IOHID digitizer
events and keys IOHID keyboard events, handed to `-[UIApplication _enqueueHIDEvent:]`; UIKit
delivers them on the main thread as it delivers a finger's or a hardware keyboard's, so gesture
recognizers, scroll views and the software keyboard take them. Each event names the window it goes
to (PROTOCOL.md, "Window routing").

## Limits

- Only an app launched by `uidrive launch` (or `ios.launch`) has the agent. An app started from the
  home screen runs without it, and `ask` prints `uidrive: AgentDown: nothing listens on port 47802`.
- A `--dylib` path the bundle lacks doesn't stop the app: it starts and runs without the agent, and
  dyld logs nothing at the default log level.
- Seen once, cause unknown: a launch got a process iOS had prewarmed (`ActivePrewarm=1`) without the
  two variables, so no agent answered. The next launch had the agent.
- No system gestures (Home indicator, Control Center, Notification Center): the events go into the
  app's own queue. Gestures inside the app, edge swipes included, work.
- The app's accessibility is on whenever the agent serves; there is no switch to leave it off.
- The touch and key verbs use private IOKit, BackBoardServices and UIKit symbols. A missing one
  makes those verbs reply `missing: <names>`; the other verbs keep working.
- Measured only on an iPhone 13 with iOS 27.2, in portrait. Other iOS versions (below 17
  included), iPads, landscape and the simulator are untested; the client reaches only devices. Two
  fingers were measured with `touch`; a two-finger `gesture` wasn't run on a device.
- A key types what the keyboard layout UIKit picks gives it, and that layout varied between
  launches; a key after the app hid the keyboard may type nothing (PROTOCOL.md, `key` and "Keys").
  Of the modifiers, only shift was measured; key repeat wasn't.
- The agent serves one connection at a time, so a request waits for a gesture before it to finish.
- The agent binds its port without `SO_REUSEPORT`: give apps that run with the agent at the same
  time their own ports (`--port` of `launch` and `ask`).
- `ask` uses usbmux's first device and `launch` and `screenshot` tunneld's first: with two phones
  attached they can reach different ones.
- The agent's port has no authentication: any process that reaches `127.0.0.1:UIDRIVE_PORT` on the
  phone, or the port over usbmux, can drive the app.

## Credits

- WebKit's [`Tools/WebKitTestRunner/ios/HIDEventGenerator.mm`](https://github.com/WebKit/WebKit/blob/main/Tools/WebKitTestRunner/ios/HIDEventGenerator.mm)
  (BSD license): the layout of the touch and key events. The declarations are retyped; no code is
  copied.
- [KIF](https://github.com/kif-framework/KIF): driving an app's UI from inside its own process.

## License

MIT, see [LICENSE](LICENSE).

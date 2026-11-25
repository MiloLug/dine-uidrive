# uidrive: design

In-process UI automation for iOS apps: an agent dylib injected at launch, and a Python client
that launches the app with it and talks to it. It synthesizes real touches through UIKit's own
HID event path, so taps, drags, scrolls, gesture recognizers and the software keyboard behave as
under a finger. No XCTest, no runner app, no Mac, and no code in the app under test.

Status: built 2026-11-25, measured on an iPhone 13 with iOS 27.2 (Device results). First consumer:
Dine, an Android app runner for iOS, whose phone checks drive its UI through uidrive.
[README.md](../README.md) says how to build and use it; [PROTOCOL.md](../PROTOCOL.md) is the wire
format.

## Why

An app's accessibility tree lets a tool find elements and run their actions, but it can't make a
`UITouch`: drags, a real touch on a field, two fingers, scrolls against a child, edge swipes and
keyboard typing need real input. Apple's route (XCUITest) needs a second runner app, which costs
one of a free Apple ID's three app IDs, and a Mac-side toolchain.

The automation:

- makes real touches;
- needs no change to the app's code;
- is a tool of its own, not tied to Dine, so other projects can use it. It lives in its own repo,
  `github.com/MiloLug/dine-uidrive` (MIT).

## Goals

- An agent dylib that any debuggable (get-task-allow) iOS app loads through
  `DYLD_INSERT_LIBRARIES`, with no link-time or source dependency in the app.
- Accessibility verbs, which act without a touch: `ls` (the walk), `activate` (an element's
  action), `insert` (text into a field), `back`, `action`, `appearance`, `settle`.
- Real input: touches (one or more fingers, single events and timed multi-finger gestures played
  inside the app), hardware-keyboard key events, a window list and element frames.
- Verb names say how a verb acts, for a person and for an AI: a finger or a keyboard (`tap`,
  `drag`, `press` in Dine's `dbg ui`; `touch`, `gesture`, `key` on the wire), or accessibility
  (`activate`, `insert`, `back`, `action`).
- A Python package (`uidrive`): transport-agnostic request client, iOS usbmux connection, launch
  with injection through DVT, screenshot, and a CLI for standalone use.
- The wire protocol, written down in the repo (`PROTOCOL.md`), owned by uidrive.

## Non-goals

- iOS's own system gestures (Home indicator swipe, Control Center, Notification Center): the
  system handles them before the app sees a touch.
- Release, TestFlight or App Store builds: dyld ignores `DYLD_INSERT_LIBRARIES` without
  get-task-allow.
- Apps the user doesn't build or re-sign: patching a load command into another IPA is a possible
  later feature.
- Android-side automation; Dine's lldb, syslog, waits and smoke runner stay in Dine.
- Jailbroken devices and the simulator (untested; the client reaches only devices, through usbmux
  and tunneld).

## Anti-goals

- Any uidrive code, header or call in an app's sources or link line.
- Two agents in one app, or a consumer with its own iOS agent or client (Dine uses uidrive's).
- A crash in the app when a private API is missing on some iOS version: the request fails with an
  error that names the missing symbol instead.

## Constraints

- Built from Linux: clang cross-compile with an iOS SDK and a toolchain the consumer passes; no
  Xcode. uidrive's CMake carries no toolchain of its own.
- Signing: iOS loads only code signed by the app's team. The dylib ships inside the app bundle and
  is signed with it (xtool signs a loose dylib in the bundle: Device results, injection).
- Private API: IOKit `IOHIDEventCreateDigitizerEvent`, `IOHIDEventCreateDigitizerFingerEvent`,
  `IOHIDEventCreateKeyboardEvent`, `IOHIDEventSetIntegerValue`, `IOHIDEventSetFloatValue`,
  `IOHIDEventAppendEvent` (IOKit is public on iOS, the functions are not in its headers);
  BackBoardServices `BKSHIDEventSetDigitizerInfo`; UIKit `-[UIApplication _enqueueHIDEvent:]`,
  `-[UIWindow _contextId]`, `-[UIWindow firstResponder]`,
  `+[UIWindow allWindowsIncludingInternalWindows:onlyVisibleWindows:]`; libAccessibility
  `_AXSApplicationAccessibilitySetEnabled`. All looked up at run time (`dlopen`/`dlsym`,
  `respondsToSelector:`, the objc runtime), never linked.
- Dine's device: iPhone 13, iOS 27.2, free Apple ID; Dine's minimum iOS is 17.4.
- Credit: the touch and key event layout follows WebKit's
  `Tools/WebKitTestRunner/ios/HIDEventGenerator.mm` (BSD); declarations are retyped, no code is
  copied. README credits WebKit and KIF.

## Approaches considered

Scope:

- A. A touch-only dylib next to an accessibility agent linked into the app. Two agents, two ports,
  and the app still links one.
- **B. One injected agent for every verb (chosen).** The app links nothing; a client talks to it as
  fast as to an agent linked into the app, since either runs in-process.

Loading the agent:

- **`DYLD_INSERT_LIBRARIES` at launch, dylib in the bundle (chosen).** No source or binary change;
  works for any debuggable app the client launches; an icon launch has no agent.
- lldb `dlopen` after attach: the file must be in the bundle anyway, adds lldb as a dependency.
- Load command patched into the binary before signing: loads on icon launches too and fits
  foreign IPAs, but needs a hook between xtool's build and sign. Later, for other projects.

Touch synthesis: IOHID events into `_enqueueHIDEvent:` (WebKit's way), measured on the phone
(Device results). KIF's way (hand-built `UITouch`s through `-[UIApplication sendEvent:]`) is the
fallback only if a future iOS removes the HID route; it skips UIKit's own hit test and isn't built.

Where uidrive lives: its own repo, not a directory of Dine.

How Dine depends on it: a uv git source in Dine's `tools` dependency group, locked to a commit in
`uv.lock`. The Python package carries the agent's sources, so that one pin covers client and dylib.
For a change that spans both repos, the group points at a local checkout instead (a uv path source
with `editable = true`), so every Dine process, subagent and the debug server imports it through
`.venv`. Rejected: a submodule (a second copy inside Dine), an environment variable naming the
checkout (every shell and tool that runs Dine's commands would need it).

## Design

### Repo layout

- `src/uidrive/agent/`: the agent (ObjC++, C++20, ARC), split into the server, the accessibility
  verbs, real input, and the gesture planner (plain C++). Its `CMakeLists.txt` builds target
  `uidrive`, `SHARED`, output `libuidrive.dylib`, install name `@rpath/libuidrive.dylib`, hidden
  visibility, linking UIKit, Foundation and CoreGraphics. Shipped as package data;
  `uidrive agent-src` prints its dir.
- `src/uidrive/` Python: `client` (one request line out, one JSON line back, over a `connect`
  callable; errors as exceptions; the `gesture` line builder; key names), `ios` (usbmux connect to a
  port; launch through DVT with `DYLD_INSERT_LIBRARIES=<bundle path>/<dylib path in bundle>` and
  `UIDRIVE_PORT`, the bundle path from installation_proxy; screenshot through DVT), and the CLI
  (`agent-src`, `launch`, `ask`, `screenshot`).
- `PROTOCOL.md`, `README.md`, `tests/` (pytest: the client against a socket peer, `ios` and the CLI
  against fakes of pymobiledevice3's services; the agent itself is checked on a device through a
  consumer).
- `pyproject.toml`: uv build backend, Python 3.12 or later, `pymobiledevice3` 11.31 or later.

### Agent

- Starts from a constructor: logs `uidrive: injected into <process>` (os_log subsystem `uidrive`)
  and removes `DYLD_INSERT_LIBRARIES` and `UIDRIVE_PORT` from its environment, so processes the app
  starts don't load it again. With a valid `UIDRIVE_PORT` it turns app accessibility on and serves
  127.0.0.1:`UIDRIVE_PORT` on its own thread, one request per connection. No port, no server.
- Accessibility verbs: `ls`, `activate N "LABEL"`, `insert N ["LABEL","TEXT"]`, `back`,
  `action "NAME"`, `appearance light|dark|system`, `settle MS`. `ls` and `settle` reply with
  `frames` too (screen points, `[x, y, w, h]`, same order as `labels`). dine-atl's gtk agent takes
  the same names.
- `windows`: every window, internal ones included: class, level, key, context id, hidden, frame.
- `touch down|move|up|cancel FINGER X Y [WIN]`: one finger's event, the same verb shape as
  dine-atl's gtk agent, so a check written for one target reads the same on the other. Fingers down
  at the same time go into one hand event, each with its own identifier.
- `gesture {JSON}`: timed multi-finger paths played inside the app (the agent thread sleeps, each
  event goes to the main queue), so speeds and flings come out as a finger's. The reply comes after
  the last event is queued.
- Which window a touch goes to: the topmost visible window that takes events and hit-tests the
  point (`hitTest:withEvent:` from the highest level down), so a key on the software keyboard
  reaches `UIRemoteKeyboardWindow` and a button above the keyboard reaches the app's window; an
  explicit window index overrides it. Every event names a window: UIKit drops one with context id 0
  (Device results 2).
- `key down|up USAGE [MODIFIERS]`: keyboard HID events (usage page 7), each modifier its own key
  event, laid out as WebKit sends them. While the key window's first responder takes text, the
  events name the first window of the touch routing order (the keyboard's while it shows); for any
  other first responder they name the key window. A key's `up` goes where its `down` went (Device
  results 4).
- A missing private symbol: the touch and key verbs reply `{"error": "missing: …"}`; the rest keeps
  working.

### Dine's side

- Build: Dine's `build-ios-dev.sh`, after it empties the dev payload dir, builds the agent from
  `uidrive agent-src` with Dine's toolchain into that dir, which the app bundles as
  `dev/libuidrive.dylib`; a release build's dir stays empty. The dylib's log format string is a dev
  marker, so Dine's bundle checks catch a dev bundle without the agent and a release bundle with it.
- Launch: Dine launches through `uidrive.ios.launch` with that dylib and port 47802, unless
  `DINE_RELEASE=1`. A release install launched without the flag still starts, since a missing
  inserted file doesn't stop the app (Device results 6).
- Client: Dine's debug server reaches the agent through `uidrive.client` and `uidrive.ios.connect`
  and keeps only what is Dine's: label matching, the stopped-app check, its error wording.
- `dbg ui` verbs: real input `tap <label|#N|@X,Y>` (a finger tap at the element's centre or a
  point), `drag <from> <to> [--ms N]` (a short `--ms` is a swipe or fling), `press <key>` (`key`
  down, then up; names from `uidrive.client.KEYS`); accessibility `activate <label|#N>`,
  `insert <label|#N> <text>`, `back`, `action <name>`; and `ls`, `windows`, `appearance`,
  `screenshot`. Text goes into a field with `insert` (`insertText:`, no key events); Return in a
  field is `press return`.
- Dine's phone smoke checks use real input: finger taps, a back swipe, a list scroll, and Return in
  a field.

## Device results (iPhone 13, iOS 27.2)

Injection, in Dine's own build and launch path: the constructor logs `uidrive: injected into
Dine`, the agent answers on port 47802, and the app's syslog shows no dyld, code-signing or AMFI
error.
The bundle's dylib, signed by xtool at install, loads.

1. Accessibility: the agent turns it on whenever it starts serving, with no option to leave it off.
   Turned on from the constructor alone, with nothing else in the app enabling it, `ls` lists
   SwiftUI's labels: Dine's launcher right after launch, and the next screen after an `activate`.
2. Window choice by hit test: a key on the keyboard, and a control above it, each with no window
   index. A window here is a `UIWindow`. An app shows several at once, stacked by level: its own
   window, the software keyboard's `UIRemoteKeyboardWindow` (the keyboard's own process draws into
   it), `UITextEffectsWindow`, and windows for alerts. iOS normally picks the window a finger lands
   on before the app sees the touch. A synthesized touch skips that step, so it has to name the
   window itself, by the window's context id.
   Settled, measured on Dine's AtlView "text" app with the keyboard up, no window index: the
   top-down hit test sent a key ("g") to `UIRemoteKeyboardWindow`, which typed it; the `show` button
   above the keyboard to the app's window, which ran its click; an empty point to the app's window,
   with no effect. Context id 0 (UIKit's own choice) failed: UIKit dropped every event (`Found no
   UIEvent, so dispatching backing event of type directly to application: 11; contextId: 0x0`), so
   the agent always names the window. The AX hit test and keyboard-frame candidates weren't needed.
3. Two fingers at once (identifiers, one hand event), and a fling (velocity) on a scroll view.
   Settled: two `touch down`s at (100,400) and (290,400) drew two pointers in the multitouch test
   app run by ATL, with finger child index and identity = finger + 2 and mask 0 on the finger that
   doesn't change. On ATL's list (scroll offset 153 pt at entry), an 80 ms `gesture` drag of 400 pt
   kept scrolling after the reply and stopped at offset 3463 pt; a 1000 ms one stood at 584-585 pt
   from the first poll after its reply on: UIKit takes the speed.
4. Hardware key events through `_enqueueHIDEvent:`: Tab, an arrow, Return, a letter in a field.
   Settled: `IOHIDEventCreateKeyboardEvent` events into `_enqueueHIDEvent:` work, so the `key` verb
   ships and Dine's `dbg ui press return` presses Return in a field. The context id decides: with
   the software keyboard up on ATL's text field, a key naming the app's window (WebKit's choice) or
   none was dropped, and one naming `UIRemoteKeyboardWindow` typed "a", shift+a "A", Backspace
   deleted, Left moved the caret, Tab moved the focus to the next field and Return ran the field's
   action (`text action enter 0 key 0`, then `key 1`); the keyboard stayed up. A focused field that
   shows no keyboard typed only through `UITextEffectsWindow`. With no text field focused (ATL's widgets
   screen), only the key window delivered (`t` and Return as Android key events);
   `UITextEffectsWindow` swallowed them. The routing rule built on this is in PROTOCOL.md, "Keys".
   After `back` hid the keyboard while Java kept a field's focus, no window's key typed into it. A
   finger tap on the return key also runs the action.
5. `UITextEffectsWindow`: whether anything there takes touches.
   Settled: with the keyboard up it covers the screen at level 1 with a context id, and its hit
   test took neither point tried (empty area, a button), so routing passed it by. A touch sent to
   it by window index at an empty point reached the app's window (UIKit's log), with no effect.
6. A launch whose `DYLD_INSERT_LIBRARIES` names a file the bundle lacks. Settled: the app starts and
   runs without the agent (nothing listens on the port), and dyld logs nothing at the default
   syslog level (measured on a dev build, with a dylib name the bundle lacks).

Not measured: landscape, other iOS versions, iPads, the simulator, a two-finger `gesture` (two
fingers ran through `touch`), modifiers other than shift, key repeat.

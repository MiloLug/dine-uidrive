# uidrive wire protocol

The uidrive agent runs inside the app and answers one request line with one JSON line. This file is
the contract between the agent and its clients. `uidrive.client.request` speaks it from Python;
`README.md` covers building the agent, putting it in an app and launching the app with it.

## Transport

- TCP on `127.0.0.1`, on the port in the app's `UIDRIVE_PORT` at launch (1 to 65535). With no
  valid port the agent doesn't serve. On iOS a host reaches the port through usbmux
  (`uidrive.ios.connect`).
- One request per connection: the client sends one UTF-8 line ending in `\n`; the agent sends one
  JSON object and `\n`, then closes the connection.
- The agent serves connections one at a time, in order, with a listen backlog of 8. A request
  waits for the one before it, a gesture's playback included.
- Reading a request or sending a reply gives up after 5 s without progress.

## Replies

- Success: `{"ok": true, …}`, or the verb's own fields (`ls`, `settle`, `windows`).
- A failure the agent can name: `{"error": "<text>"}`.
- `touch`, `gesture`, `key` and `windows` answer every line whose first word is their verb; a
  malformed one gets an `error`. For `ls`, `activate`, `insert`, `back`, `action`, `appearance` and
  `settle`, a line that doesn't parse closes the connection unanswered, and so does an unknown verb.
- A reply holding NaN or infinity becomes `{"error": "the reply holds a value JSON can't carry"}`.

## The walk and element indexes

`ls` walks the key window: accessibility elements and subviews, depth first, each object once, at
most 5000 objects. It keeps the objects with a non-empty accessibility label whose frame meets the
screen, and skips hidden views, views with alpha below 0.01 and subtrees marked accessibility
hidden. The agent turns app accessibility on when it starts serving, because SwiftUI builds the
tree the walk reads only while it is on.

An element's index N is its place in the agent's last walk. `ls` and every poll of `settle` walk,
and so do `back`, `action`, `appearance`, and a `touch down` with no finger down or a `gesture` that
passes its checks.
`activate` and `insert` take N with the label the client saw, and refuse with
`the screen changed since the last ls` when element N of the last walk has another label.

## Points

Screen points, origin top left: the space of `ls` frames and `windows` frames. `touch` and
`gesture` refuse a point outside the screen (0 to its width, 0 to its height, edges included). The
event carries the point rounded to whole points.

## Accessibility verbs

These act without a touch. All but `ls` and `settle` queue their action on the main thread and
reply without waiting for it, so a breakpoint the action hits can't block the reply; `settle`
reports the action's result.

### `ls`

```
{"labels": [[isElement, label], …], "values": [value or null, …], "frames": [[x, y, w, h], …]}
```

Three lists in walk order. `isElement` is the object's `isAccessibilityElement`. `value` is its
`accessibilityValue` when that is a non-empty string; a text field's value is its text and its
label is its hint. `frames` are `accessibilityFrame`s in screen points; a frame with an infinite
side is cut to its part on screen.

### `activate N "LABEL"`

LABEL is a JSON string. Element N's `accessibilityActivate` runs. When it declines, an enabled
`UIControl` gets the actions a tap sends (`touchUpInside` and `primaryActionTriggered`, each action
once). When that doesn't apply either, the topmost alert's enabled action titled LABEL runs as a tap
runs it: the alert dismisses, then the action's handler runs. Reply `{"ok": true}`. Result: whether
one of the three acted.

### `insert N ["LABEL", "TEXT"]`

A JSON array of two strings. Element N becomes the first responder if it takes text input
(`UITextInput`), then TEXT goes in through `insertText:`, with no key events. Reply
`{"ok": true}`, or the same error as `activate`. Result: whether the text went in.

### `back`

The accessibility escape (VoiceOver's back gesture). Starting from the walked elements, last
first, then from the presented view controllers' views, top first, the agent climbs through
accessibility containers and responders to the first object whose `accessibilityPerformEscape`
returns true; a navigation controller pops. Reply `{"ok": true}`. Result: that object's class name,
or null when none escaped.

### `action "NAME"`

The first accessibility custom action named NAME, searched the way `back` climbs. Reply
`{"ok": true}`. Result: the action's return value, or null when no action has the name.

### `appearance light|dark|system`

Sets the key window's `overrideUserInterfaceStyle` (`system` is unspecified). Reply
`{"ok": true}`. Result: true.

### `settle MS`

MS in decimal digits, capped at 10000. The agent walks every 100 ms until the settle rule holds or
MS pass:

- the last action has run (activate, insert, back, action, appearance, a touch sequence's last
  `up` or `cancel`, or a gesture's last event);
- no view controller transition runs;
- the labels equal the previous poll's, so the first poll never settles;
- the labels differ from those when the action was asked for, or 300 ms have passed.

```
{"labels": …, "values": …, "frames": …, "settled": bool, "ran": bool, "result": … or null}
```

`labels`, `values` and `frames` are the last poll's walk, as `ls` gives them. `settled` says whether
the rule held, `ran` whether the action has run, `result` is the action's result. Until the first
action is asked for, nothing has run and `settle` waits the full MS.

## Real input

`touch` and `gesture` send IOHID digitizer events, and `key` keyboard events, into UIKit's event
queue (`-[UIApplication _enqueueHIDEvent:]`), laid out as WebKit's `HIDEventGenerator` lays them
out. UIKit delivers them on the main thread as it delivers a finger's or a hardware keyboard's. On
iOS 27.2 a tap at a point, the interactive left-edge pop, a list scroll and a fling (UIKit takes the
gesture's speed), a `UIGestureRecognizer`, software keyboard keys, and two fingers down at once (two
`touch down`s) work this way.

Each event is a hand event with one child per finger it carries; a child's index and identity are
FINGER + 2. A finger that changes gets a mask: Touch and Identity when it goes down or lifts,
Position and Attribute when it moves, Cancel on a cancel. Fingers that stay down and don't change
ride along with mask 0.

The private symbols these verbs use are looked up when the first one runs. When one is missing,
the verbs that need it reply `missing: <names>`; the other verbs keep working. `touch` and `gesture`
need `IOHIDEventCreateDigitizerEvent`, `IOHIDEventCreateDigitizerFingerEvent`,
`IOHIDEventSetIntegerValue`, `IOHIDEventSetFloatValue` and `IOHIDEventAppendEvent`; `key` needs
`IOHIDEventCreateKeyboardEvent` and `-[UIWindow firstResponder]`; all three need
`BKSHIDEventSetDigitizerInfo`, `-[UIApplication _enqueueHIDEvent:]` and `-[UIWindow _contextId]`.

### `windows`

```
{"windows": [{"class": str, "level": float, "key": bool, "ctx": int, "hidden": bool, "frame": [x, y, w, h]}, …]}
```

Every window of the app, the keyboard's and other internal ones included, visible or not, in
UIKit's order. A window's place in this list is the WIN of `touch` and the `window` of `gesture`.
`ctx` is its context id, 0 when it has none.

### `touch down|move|up|cancel FINGER X Y [WIN]`

One finger's event. FINGER is 0 to 9, X and Y are finite numbers, WIN is an index from `windows`.

- `down` puts FINGER down at X, Y; `move` moves it there; `up` lifts it there. `cancel` cancels
  every finger that is down; its FINGER must be one of them, and its X, Y (on screen, as always)
  are where the event puts that finger.
- The event carries every finger down after it, plus the fingers it lifts or cancels.
- The `down` that starts a touch (no finger down) picks the window: WIN, else the window routing
  below. Later events go to the same window; a WIN on them must name it.
- Reply `{"ok": true, "window": "<class>", "ctx": <context id>}` once the event is queued for the
  main thread, which hands it to UIKit; the reply doesn't wait for UIKit to deliver it.

Errors:

```
usage: touch down|move|up|cancel FINGER X Y [WIN]
bad finger F: 0 to 9
bad point X Y: X and Y are finite numbers
bad window W: an index from windows
missing: <names>
finger F is already down
finger F is not down
the point X,Y is off screen
no window W: there are N
no window takes the point X,Y
window W has no context id
fingers are down in <class>; window W is another one
IOHID made no event
```

### `gesture {JSON}`

Timed paths for 1 to 10 fingers, played inside the app:

```
gesture {"fingers": [[[x, y, t], …], …], "window": N}
```

- Path i is finger i. Each path has 2 to 1000 keyframes `[x, y, t]`, all finite numbers; t is in
  ms from the gesture's start, 0 to 10000, never decreasing, and the last t comes after the first.
- `window` is optional, an index from `windows`; without it the window routing below picks the
  window at the first path's first point.
- A finger goes down at its first keyframe and lifts at its last, moving on straight lines between
  keyframes. After the down, where keyframes share a t, the last of them counts.
- Playback instants: every 16 ms from 0, plus every keyframe's t. At each instant the agent sends
  one event for the fingers that go down or move, if any did. At a finger's last keyframe it moves
  the finger to that point first (when it isn't there), then sends a second event that lifts it.
- The agent's thread sleeps until each instant and then queues the event on the main thread, so
  the app sees the path's speed.
- Reply `{"ok": true, "window": "<class>", "ctx": <context id>}` after the last event is queued:
  the client waits for the gesture's length.

Errors: `bad gesture: <why>` for the JSON's shape, its numbers, times and points, and more than 10
fingers; `missing: <names>`; `fingers from touch are down: touch up or cancel them first`; and the
window errors of `touch`.

### `key down|up USAGE [MODIFIERS]`

A hardware keyboard key goes down or up. USAGE is a HID usage on the Keyboard/Keypad page (7), 1
to 255: `a` is 4, Return 40, Escape 41, Backspace 42, Tab 43, the arrows 79 to 82
(`uidrive.client.KEYS` names them). MODIFIERS is a `UIKeyModifierFlags` sum: shift 131072
(`1<<17`), control 262144, option 524288, command 1048576; default 0.

- As WebKit sends modifiers, each one is its own key event: on `down` the modifiers go down before
  the key, on `up` they lift after it.
- A usage types what the hardware keyboard layout UIKit picks gives it; on the test phone that was
  Spanish ISO in some launches and US in another (usage 51 typed `;`). `KEYS`' letters assume a
  QWERTY layout.
- Which window the events name: see "Keys" under the window routing below.
- Settle: a `down` records the screen an action starts from, an `up` marks the action as run.
- Reply `{"ok": true}` once the events are queued for the main thread.

Errors:

```
usage: key down|up USAGE [MODIFIERS]
bad usage U: a HID usage on page 7, 1 to 255
bad modifiers M: shift 131072, control 262144, option 524288, command 1048576, or their sum
missing: <names>
no key window
the window <class> has no context id
IOHID made no event
```

## Window routing

An app shows several windows at once, stacked by level: its own window, the software keyboard's
`UIRemoteKeyboardWindow` (the keyboard's process draws into it), `UITextEffectsWindow`, and windows
for alerts. For a real finger, the system picks the window before the app sees the touch. A
synthesized event names its window by context id instead.

Without a WIN or `window`, the agent takes the windows that are not hidden, have alpha above 0.01,
take user interaction and have a context id, from the highest level down, and within a level the
later window first. The first whose `hitTest:withEvent:` returns a view for the point gets the
touch; when none does, the reply is `no window takes the point X,Y`.

Every event carries a context id: UIKit drops an event with id 0 instead of picking a window
for it.

On iOS 27.2, with the software keyboard up:

- A key's point routes to `UIRemoteKeyboardWindow` and types. The keyboard types only for a touch
  carrying that window's context id; with the app window's id it logs
  `Touch event for active input modality has no provenance` and types nothing.
- A control above the keyboard, and empty app area, route to the app's window: the control acts,
  the empty point does nothing. The keyboard logs the same `no provenance` line for these touches,
  without harm.
- `UITextEffectsWindow` covers the screen at level 1, but its hit test took neither an empty point
  nor a button's, so the routing passed it by. A touch sent to it by WIN reached the app's window
  through UIKit.

### Keys

Key events carry a context id as well. When the key window's first responder takes text
(`UIKeyInput`), they name the first window of the routing order above: the keyboard's, unless
the app shows a window that takes events above it. UIKit hands a text field's keys to the keyboard
and drops them when they name the app's window. Any other first responder gets them through the
key window. A key's `up` goes to the window its `down` went to. On iOS 27.2:

- With the software keyboard up, keys go to `UIRemoteKeyboardWindow` and type into the field; the
  software keyboard stays up. Tab moves the focus to the next field, Left moves the caret,
  Backspace deletes, and Return runs the field's return action.
- A focused field that shows no keyboard takes its keys through `UITextEffectsWindow`.
- With no text field focused, the first responder gets `pressesBegan:` and `pressesEnded:`.
- A key naming `UITextEffectsWindow` while no text field has the focus reaches the keyboard and goes
  no further.
- After the app hides the keyboard while its field keeps the app's focus (ATL's Back, or Home and
  back), no window's key types into that field, and `key` still replies `ok`.

## dine-atl's gtk agent

dine-atl's gtk build (Android Translation Layer on Linux) carries an agent with this request and
reply shape and the same verb names, so a check reads the same against both. Its differences:

- Transport: a Unix socket at the path in `ATL_DBG_AGENT`, with no read or write timeout; a request
  line is at most 4095 bytes.
- `ls` and `settle` give `labels` with no `values` or `frames`. The labels are the shown text of
  the app window, then of the other toplevels.
- `activate` gives a view a tap at its centre through Java's dispatch, an EditText GTK's focus, and
  a dialog's button or row its activation.
- `insert` also takes `["LABEL", "TEXT", KEYVAL, KEYCODE]`: that key follows the text in one
  request. A space before a `,` or the `]` of its array closes the connection unanswered;
  `json.dumps`'s `["a", "b"]` and the compact `["a","b"]` both work.
- `back` is Android's Back, with no accessibility escape.
- `settle 0` closes unanswered, and every action's result is a bool.
- `touch down|move|up|cancel SEQ X Y`: SEQ is any integer naming the pointer (0 is the mouse), X and
  Y are pixels in the app window, and there is no WIN. The event runs before the reply,
  `{"ok": true, "claimed": bool}`, where `claimed` says whether the gesture is Java's.
- `key down|up KEYVAL KEYCODE [STATE]`: a GDK keyval, a hardware keycode and `GdkModifierType`
  bits; reply `{"ok": true, "handled": bool}`.
- Two more verbs: `at N "LABEL"` gives element N's centre, `{"x", "y"}` in app window pixels, and
  `state N "LABEL"` gives `{"sensitive", "focused"}`.
- No `action`, `appearance`, `windows` or `gesture`. A malformed `touch` or `key` closes the
  connection unanswered.

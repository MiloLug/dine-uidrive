// The gesture verb's checks and its plan of hand events, in plain C++.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <set>
#include <string>
#include <vector>

namespace uidrive::gesture {

// IOHID digitizer event mask bits.
enum : uint32_t {
  kRange = 1u << 0,
  kTouch = 1u << 1,
  kPosition = 1u << 2,
  kIdentity = 1u << 5,
  kAttribute = 1u << 6,
  kCancel = 1u << 7,
};
constexpr uint32_t kDownUp = kTouch | kIdentity;
constexpr uint32_t kMoved = kPosition | kAttribute;

constexpr double kMaxMs = 10000;
constexpr double kGridMs = 16;
constexpr size_t kMaxFingers = 10;
constexpr size_t kMaxKeyframes = 1000;

struct Key {
  double x, y, t;
};
using Path = std::vector<Key>;

// One finger child of a hand event. `down`: its range and touch after this event.
struct Finger {
  int finger;
  double x, y;
  uint32_t mask;
  bool down;
};

struct Event {
  double t;
  std::vector<Finger> fingers;
};

// Empty when the paths can be played on a screen of width w and height h, else why not.
inline std::string Check(const std::vector<Path> &paths, double w, double h) {
  if (paths.empty() || paths.size() > kMaxFingers) return "1 to 10 fingers";
  for (size_t i = 0; i < paths.size(); i++) {
    const Path &p = paths[i];
    std::string f = "finger " + std::to_string(i);
    if (p.size() < 2 || p.size() > kMaxKeyframes) return f + " needs 2 to 1000 keyframes";
    for (size_t k = 0; k < p.size(); k++) {
      const Key &key = p[k];
      if (!std::isfinite(key.x) || !std::isfinite(key.y) || !std::isfinite(key.t)) return f + ": a number isn't finite";
      if (key.t < 0 || key.t > kMaxMs) return f + ": t must be 0 to 10000 ms";
      if (k && key.t < p[k - 1].t) return f + ": t goes back";
      if (key.x < 0 || key.y < 0 || key.x > w || key.y > h) return f + ": a point is off screen";
    }
    if (p.back().t <= p.front().t) return f + ": its last t must come after its first";
  }
  return "";
}

// Where a finger is at t, inside its path's time span: on the line between the keyframes around t;
// of keyframes sharing a time, the last one counts.
inline Key At(const Path &p, double t) {
  if (t >= p.back().t) return p.back();
  size_t j = 0;
  while (j + 1 < p.size() && p[j + 1].t <= t) j++;
  const Key &a = p[j], &b = p[j + 1];
  double r = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1;
  return {a.x + (b.x - a.x) * r, a.y + (b.y - a.y) * r, t};
}

// A lift is an event of its own after the move to the end point: a finger moves, then lifts where it
// stopped.
inline std::vector<Event> Plan(const std::vector<Path> &paths) {
  std::set<double> instants;
  double end = 0;
  for (const Path &p : paths) {
    for (const Key &k : p) instants.insert(k.t);
    end = std::max(end, p.back().t);
  }
  for (double t = 0; t <= end; t += kGridMs) instants.insert(t);

  struct State {
    bool down = false;
    double x = 0, y = 0;
  };
  std::vector<State> state(paths.size());
  std::vector<Event> events;
  for (double t : instants) {
    Event moves{t, {}}, ups{t, {}};
    bool changed = false;
    std::vector<size_t> lifting;
    for (size_t i = 0; i < paths.size(); i++) {
      const Path &p = paths[i];
      State &s = state[i];
      int finger = static_cast<int>(i);
      if (!s.down && t == p.front().t) {
        s = {true, p.front().x, p.front().y};
        moves.fingers.push_back({finger, s.x, s.y, kDownUp, true});
        changed = true;
        continue;
      }
      if (!s.down) continue;
      Key at = At(p, t);
      uint32_t mask = 0;
      if (at.x != s.x || at.y != s.y) {
        s.x = at.x;
        s.y = at.y;
        mask = kMoved;
        changed = true;
      }
      moves.fingers.push_back({finger, s.x, s.y, mask, true});
      if (t >= p.back().t) lifting.push_back(i);
    }
    if (changed) events.push_back(moves);
    if (lifting.empty()) continue;
    for (size_t i = 0; i < paths.size(); i++) {
      State &s = state[i];
      if (!s.down) continue;
      bool lifts = std::find(lifting.begin(), lifting.end(), i) != lifting.end();
      ups.fingers.push_back({static_cast<int>(i), s.x, s.y, lifts ? kDownUp : 0, !lifts});
      if (lifts) s.down = false;
    }
    events.push_back(ups);
  }
  return events;
}

}  // namespace uidrive::gesture

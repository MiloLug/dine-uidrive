// Real input: IOHID digitizer events into UIKit's event queue, the window list and touch routing.
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <xlocale.h>

#include <chrono>
#include <thread>

#include "agent.h"
#include "gesture.h"

namespace uidrive {
namespace {

using gesture::Finger;
typedef struct __IOHIDEvent *IOHIDEventRef;

enum : uint32_t {
  kFieldMajorRadius = 0xB0014,
  kFieldMinorRadius = 0xB0015,
  kFieldIsDisplayIntegrated = 0xB0019,
  kFieldQualityRadiiAccuracy = 0xB001A,
};

// Private API, looked up once: a missing piece makes touch and gesture fail with its name instead of
// crashing the app.
struct Hid {
  IOHIDEventRef (*digitizer)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, uint32_t, uint32_t, double, double,
                             double, double, double, boolean_t, boolean_t, uint32_t);
  IOHIDEventRef (*finger)(CFAllocatorRef, uint64_t, uint32_t, uint32_t, uint32_t, double, double, double, double, double,
                          boolean_t, boolean_t, uint32_t);
  void (*setInt)(IOHIDEventRef, uint32_t, CFIndex);
  void (*setFloat)(IOHIDEventRef, uint32_t, double);
  void (*append)(IOHIDEventRef, IOHIDEventRef, uint32_t);
  void (*digitizerInfo)(IOHIDEventRef, uint32_t, uint8_t, uint8_t, CFStringRef, CFTimeInterval, float);
  NSString *missing;
};

const Hid &HidApi() {
  static Hid api = [] {
    Hid h = {};
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW);
    void *bbs = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
    NSMutableArray *missing = [NSMutableArray array];
    auto sym = [&](void *lib, const char *name) {
      void *p = lib ? dlsym(lib, name) : nullptr;
      if (!p) [missing addObject:@(name)];
      return p;
    };
    h.digitizer = (decltype(h.digitizer))sym(iokit, "IOHIDEventCreateDigitizerEvent");
    h.finger = (decltype(h.finger))sym(iokit, "IOHIDEventCreateDigitizerFingerEvent");
    h.setInt = (decltype(h.setInt))sym(iokit, "IOHIDEventSetIntegerValue");
    h.setFloat = (decltype(h.setFloat))sym(iokit, "IOHIDEventSetFloatValue");
    h.append = (decltype(h.append))sym(iokit, "IOHIDEventAppendEvent");
    h.digitizerInfo = (decltype(h.digitizerInfo))sym(bbs, "BKSHIDEventSetDigitizerInfo");
    // No message to UIKit classes here: it would run their +initialize on the serve thread, possibly
    // before UIApplicationMain.
    auto method = [&](const char *cls, const char *sel, NSString *name) {
      Class c = objc_getClass(cls);
      if (!c || !class_getInstanceMethod(c, sel_registerName(sel))) [missing addObject:name];
    };
    method("UIApplication", "_enqueueHIDEvent:", @"-[UIApplication _enqueueHIDEvent:]");
    method("UIWindow", "_contextId", @"-[UIWindow _contextId]");
    h.missing = missing.count ? [missing componentsJoinedByString:@", "] : nil;
    return h;
  }();
  return api;
}

// A hand event with one finger child per entry, laid out as WebKit's HIDEventGenerator builds it;
// finger ids start at 2, as WebKit's do.
IOHIDEventRef HandEvent(const std::vector<Finger> &fingers) {
  const Hid &h = HidApi();
  uint64_t now = mach_absolute_time();
  uint32_t mask = 0;
  bool touching = false;
  for (const Finger &f : fingers) {
    mask |= f.mask;
    touching |= f.down;
  }
  IOHIDEventRef hand = h.digitizer(kCFAllocatorDefault, now, 3 /* hand */, 0, 0, mask, 0, 0, 0, 0, 0, 0, false, touching, 0);
  if (!hand) return nullptr;
  h.setInt(hand, kFieldIsDisplayIntegrated, 1);
  for (const Finger &f : fingers) {
    uint32_t id = (uint32_t)f.finger + 2;
    IOHIDEventRef child = h.finger(kCFAllocatorDefault, now, id, id, f.mask, round(f.x), round(f.y), 0, 0, 0, f.down,
                                   f.down, 0);
    if (!child) {
      CFRelease(hand);
      return nullptr;
    }
    h.setFloat(child, kFieldMajorRadius, 5);
    h.setFloat(child, kFieldMinorRadius, 5);
    h.setFloat(child, kFieldQualityRadiiAccuracy, 0);
    h.append(hand, child, 0);
    CFRelease(child);
  }
  return hand;
}

// Main thread; takes ownership of the event. UIKit drops an event whose context id is 0 rather than
// pick a window for it, so every event names one.
void Enqueue(IOHIDEventRef ev, uint32_t ctx) {
  HidApi().digitizerInfo(ev, ctx, 0, 0, nullptr, 0, 0);
  ((void (*)(id, SEL, IOHIDEventRef))objc_msgSend)(UIApplication.sharedApplication,
                                                   NSSelectorFromString(@"_enqueueHIDEvent:"), ev);
  CFRelease(ev);
}

CGRect ScreenBounds() {
  UIWindow *w = KeyWindow() ?: AllWindows().firstObject;
  return w ? w.screen.bounds : CGRectZero;
}

bool OnScreen(CGPoint p, CGRect screen) {
  return p.x >= 0 && p.y >= 0 && p.x <= screen.size.width && p.y <= screen.size.height;
}

// The topmost visible window whose hit test takes the screen point, in UIKit's stacking order.
UIWindow *Route(CGPoint p) {
  NSArray<UIWindow *> *windows = [AllWindows().reverseObjectEnumerator.allObjects
      sortedArrayWithOptions:NSSortStable
             usingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
               if (a.windowLevel == b.windowLevel) return NSOrderedSame;
               return a.windowLevel > b.windowLevel ? NSOrderedAscending : NSOrderedDescending;
             }];
  for (UIWindow *w in windows) {
    if (w.hidden || w.alpha <= 0.01 || !ContextId(w)) continue;
    @try {
      if ([w hitTest:[w convertPoint:p fromCoordinateSpace:w.screen.coordinateSpace] withEvent:nil]) return w;
    } @catch (NSException *) {
    }
  }
  return nil;
}

struct Target {
  uint32_t ctx;
  NSString *cls;
  NSString *error;
};

// Main thread. win < 0: the window the point routes to.
Target PickWindow(NSInteger win, CGPoint p) {
  NSArray<UIWindow *> *windows = AllWindows();
  UIWindow *w = nil;
  if (win >= (NSInteger)windows.count)
    return {0, nil, [NSString stringWithFormat:@"no window %ld: there are %lu", (long)win, (unsigned long)windows.count]};
  w = win >= 0 ? windows[win] : Route(p);
  if (!w) return {0, nil, [NSString stringWithFormat:@"no window takes the point %g,%g", p.x, p.y]};
  uint32_t ctx = ContextId(w);
  if (!ctx) return {0, nil, [NSString stringWithFormat:@"window %ld has no context id", (long)win]};
  return {ctx, NSStringFromClass(w.class), nil};
}

void Fail(int fd, NSString *error) { Reply(fd, @{@"error": error}); }

// A finite number in C notation, whatever locale the app set.
bool Number(NSString *s, double *out) {
  const char *c = s.UTF8String;
  char *end = nullptr;
  *out = strtod_l(c, &end, LC_C_LOCALE);
  return *c && *end == '\0' && isfinite(*out);
}

bool JsonNumber(id n, double *out) {
  if (![n isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)n) == CFBooleanGetTypeID()) return false;
  *out = [n doubleValue];
  return isfinite(*out);
}

// Serve thread only: the fingers `touch` holds down, and the window they went down in.
struct {
  bool down;
  double x, y;
} gFingers[gesture::kMaxFingers];
uint32_t gCtx;
NSString *gWindowClass;

bool AnyFingerDown() {
  for (const auto &f : gFingers)
    if (f.down) return true;
  return false;
}

enum Phase { kDown, kMove, kUp, kCancel };

void Touch(int fd, NSArray<NSString *> *words) {
  NSUInteger phase = words.count >= 2 ? [@[@"down", @"move", @"up", @"cancel"] indexOfObject:words[1]] : NSNotFound;
  if (words.count < 5 || words.count > 6 || phase == NSNotFound)
    return Fail(fd, @"usage: touch down|move|up|cancel FINGER X Y [WIN]");
  NSString *fw = words[2];
  if (fw.length != 1 || [fw characterAtIndex:0] < '0' || [fw characterAtIndex:0] > '9')
    return Fail(fd, [NSString stringWithFormat:@"bad finger %@: 0 to 9", fw]);
  int finger = fw.intValue;
  double x, y;
  if (!Number(words[3], &x) || !Number(words[4], &y))
    return Fail(fd, [NSString stringWithFormat:@"bad point %@ %@: X and Y are finite numbers", words[3], words[4]]);
  NSInteger win = -1;
  if (words.count == 6) {
    if (!Digits(words[5])) return Fail(fd, [NSString stringWithFormat:@"bad window %@: an index from windows", words[5]]);
    win = words[5].integerValue;
  }
  const Hid &h = HidApi();
  if (h.missing) return Fail(fd, [@"missing: " stringByAppendingString:h.missing]);
  if (phase == kDown && gFingers[finger].down)
    return Fail(fd, [NSString stringWithFormat:@"finger %d is already down", finger]);
  if (phase != kDown && !gFingers[finger].down)
    return Fail(fd, [NSString stringWithFormat:@"finger %d is not down", finger]);

  std::vector<Finger> fingers;
  bool othersDown = false;
  for (int i = 0; i < (int)gesture::kMaxFingers; i++) {
    if (i == finger) {
      uint32_t mask = phase == kMove ? gesture::kMoved : phase == kCancel ? gesture::kCancel : gesture::kDownUp;
      fingers.push_back({i, x, y, mask, phase == kDown || phase == kMove});
    } else if (gFingers[i].down) {
      othersDown = true;
      fingers.push_back({i, gFingers[i].x, gFingers[i].y, phase == kCancel ? gesture::kCancel : 0, phase != kCancel});
    }
  }
  bool first = phase == kDown && !othersDown;
  bool last = phase == kCancel || (phase == kUp && !othersDown);
  IOHIDEventRef ev = HandEvent(fingers);
  if (!ev) return Fail(fd, @"IOHID made no event");

  __block uint32_t ctx = gCtx;
  __block NSString *cls = gWindowClass, *error = nil;
  CGPoint p = CGPointMake(x, y);
  OnMain(^{
    if (!OnScreen(p, ScreenBounds())) {
      error = [NSString stringWithFormat:@"the point %g,%g is off screen", x, y];
      return;
    }
    if (first) {
      Target t = PickWindow(win, p);
      if (t.error) {
        error = t.error;
        return;
      }
      ctx = t.ctx;
      cls = t.cls;
      ActionAsked();
    } else if (win >= 0) {
      NSArray<UIWindow *> *windows = AllWindows();
      if (win >= (NSInteger)windows.count || ContextId(windows[win]) != ctx) {
        error = [NSString stringWithFormat:@"fingers are down in %@; window %ld is another one", cls, (long)win];
        return;
      }
    }
    // Queued, not run here: the reply never waits on UIKit's handling of the event.
    uint32_t target = ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
      Enqueue(ev, target);
      if (last) ActionRan(@YES);
    });
  });
  if (error) {
    CFRelease(ev);
    return Fail(fd, error);
  }

  if (phase == kCancel)
    for (auto &f : gFingers) f.down = false;
  else
    gFingers[finger] = {phase != kUp, x, y};
  gCtx = ctx;
  gWindowClass = cls;
  Reply(fd, @{@"ok": @YES, @"window": cls, @"ctx": @(ctx)});
}

void Gesture(int fd, NSString *json) {
  NSDictionary *obj = json ? [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0
                                                               error:nil]
                           : nil;
  if (![obj isKindOfClass:NSDictionary.class]) return Fail(fd, @"bad gesture: not a JSON object");
  for (NSString *key in obj)
    if (![key isEqual:@"fingers"] && ![key isEqual:@"window"])
      return Fail(fd, [NSString stringWithFormat:@"bad gesture: unknown key %@", key]);
  NSArray *paths = obj[@"fingers"];
  if (![paths isKindOfClass:NSArray.class]) return Fail(fd, @"bad gesture: no fingers array");
  std::vector<gesture::Path> fingers;
  for (NSArray *path in paths) {
    if (![path isKindOfClass:NSArray.class]) return Fail(fd, @"bad gesture: a finger isn't an array of keyframes");
    gesture::Path keys;
    for (NSArray *key in path) {
      gesture::Key k;
      if (![key isKindOfClass:NSArray.class] || key.count != 3 || !JsonNumber(key[0], &k.x) || !JsonNumber(key[1], &k.y) ||
          !JsonNumber(key[2], &k.t))
        return Fail(fd, @"bad gesture: a keyframe isn't [x, y, t] in finite numbers");
      keys.push_back(k);
    }
    fingers.push_back(keys);
  }
  NSInteger win = -1;
  if (id w = obj[@"window"]) {
    double v;
    if (!JsonNumber(w, &v) || v < 0 || v != floor(v) || v > 1e8)
      return Fail(fd, @"bad gesture: window is an index from windows");
    win = (NSInteger)v;
  }
  const Hid &h = HidApi();
  if (h.missing) return Fail(fd, [@"missing: " stringByAppendingString:h.missing]);
  if (AnyFingerDown()) return Fail(fd, @"fingers from touch are down: touch up or cancel them first");

  __block uint32_t ctx = 0;
  __block NSString *cls = nil, *error = nil;
  OnMain(^{
    CGRect screen = ScreenBounds();
    std::string why = gesture::Check(fingers, screen.size.width, screen.size.height);
    if (!why.empty()) {
      error = [@"bad gesture: " stringByAppendingString:@(why.c_str())];
      return;
    }
    Target t = PickWindow(win, CGPointMake(fingers[0][0].x, fingers[0][0].y));
    if (t.error) {
      error = t.error;
      return;
    }
    ctx = t.ctx;
    cls = t.cls;
    ActionAsked();
  });
  if (error) return Fail(fd, error);

  // Absolute deadlines, so the time spent building and queueing events doesn't add up into the speed.
  auto start = std::chrono::steady_clock::now();
  uint32_t target = ctx;
  for (const gesture::Event &e : gesture::Plan(fingers)) {
    std::this_thread::sleep_until(start + std::chrono::duration<double, std::milli>(e.t));
    IOHIDEventRef ev = HandEvent(e.fingers);
    if (ev) dispatch_async(dispatch_get_main_queue(), ^{ Enqueue(ev, target); });
  }
  OnMain(^{ ActionRan(@YES); });
  Reply(fd, @{@"ok": @YES, @"window": cls, @"ctx": @(ctx)});
}

void Windows(int fd) {
  __block NSMutableArray *rows = [NSMutableArray array];
  OnMain(^{
    for (UIWindow *w in AllWindows()) {
      CGRect f = w.frame;
      [rows addObject:@{
        @"class": NSStringFromClass(w.class),
        @"level": @(w.windowLevel),
        @"key": @(w.isKeyWindow),
        @"ctx": @(ContextId(w)),
        @"hidden": @(w.hidden),
        @"frame": @[@(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height)],
      }];
    }
  });
  Reply(fd, @{@"windows": rows});
}

}  // namespace

NSArray<UIWindow *> *AllWindows() {
  SEL all = NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:");
  if ([UIWindow respondsToSelector:all])
    return ((NSArray * (*)(id, SEL, BOOL, BOOL)) objc_msgSend)(UIWindow.class, all, YES, NO);
  NSMutableArray *windows = [NSMutableArray array];
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    if ([scene isKindOfClass:UIWindowScene.class]) [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
  return windows;
}

uint32_t ContextId(UIWindow *window) {
  SEL sel = NSSelectorFromString(@"_contextId");
  return [window respondsToSelector:sel] ? ((uint32_t (*)(id, SEL))objc_msgSend)(window, sel) : 0;
}

bool HandleTouch(int fd, NSString *line) {
  NSArray<NSString *> *words = [line componentsSeparatedByString:@" "];
  if ([words[0] isEqualToString:@"windows"])
    words.count == 1 ? Windows(fd) : Fail(fd, @"usage: windows");
  else if ([words[0] isEqualToString:@"touch"])
    Touch(fd, words);
  else if ([words[0] isEqualToString:@"gesture"])
    Gesture(fd, words.count > 1 ? [line substringFromIndex:words[0].length + 1] : nil);
  else
    return false;
  return true;
}

}  // namespace uidrive

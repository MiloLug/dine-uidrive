// The accessibility walk and the verbs that act without a touch.
#include <math.h>
#include <objc/message.h>
#include <unistd.h>

#include "agent.h"

namespace uidrive {
namespace {

// Main thread only.
NSArray *gItems;   // elements of the last walk
NSArray *gLabels;  // their [isElement, label] pairs
NSArray *gValues;  // their accessibilityValue strings, NSNull for none
NSArray *gFrames;  // their accessibilityFrame, [x, y, w, h] in screen points
NSArray *gBefore;  // gLabels when the last action was asked for
id gResult;        // nil until that action ran; back without a handler: NSNull

// Accessibility elements and subviews, depth first, each object once, skipping what VoiceOver can't
// reach: hidden subtrees and elements off screen (a pushed-over screen stays in the hierarchy). A
// getter that throws (SwiftUI's _UIButtonBarButton does) only skips that element.
void Walk() {
  NSMutableArray *items = [NSMutableArray array], *labels = [NSMutableArray array], *values = [NSMutableArray array],
                 *frames = [NSMutableArray array];
  NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
  NSMutableArray *stack = [NSMutableArray array];
  UIWindow *window = KeyWindow();
  CGRect screen = window.screen.bounds;
  if (window) [stack addObject:window];
  while (stack.count && seen.count < 5000) {
    id e = stack.lastObject;
    [stack removeLastObject];
    if ([seen containsObject:e]) continue;
    [seen addObject:e];
    if ([e isKindOfClass:UIView.class] && (((UIView *)e).hidden || ((UIView *)e).alpha < 0.01)) continue;
    @try {
      if ([e accessibilityElementsHidden]) continue;
      NSString *label = [e accessibilityLabel];
      CGRect f = [label isKindOfClass:NSString.class] && label.length ? [e accessibilityFrame] : CGRectNull;
      if (!CGRectIsEmpty(CGRectIntersection(f, screen))) {
        [items addObject:e];
        [labels addObject:@[@([e isAccessibilityElement]), label]];
        id value = [e accessibilityValue];
        [values addObject:[value isKindOfClass:NSString.class] && [value length] ? value : NSNull.null];
        // JSON can't carry an infinite side; the part on screen it can.
        if (!isfinite(f.origin.x) || !isfinite(f.origin.y) || !isfinite(f.size.width) || !isfinite(f.size.height))
          f = CGRectIntersection(f, screen);
        [frames addObject:@[@(f.origin.x), @(f.origin.y), @(f.size.width), @(f.size.height)]];
      }
      NSArray *children = [e accessibilityElements];
      if ([children isKindOfClass:NSArray.class]) [stack addObjectsFromArray:children];
    } @catch (NSException *) {
    }
    if ([e isKindOfClass:UIView.class]) [stack addObjectsFromArray:((UIView *)e).subviews];
  }
  gItems = items;
  gLabels = labels;
  gValues = values;
  gFrames = frames;
}

bool Transitioning(UIViewController *vc) {
  if (!vc) return false;
  if (vc.transitionCoordinator) return true;
  for (UIViewController *child in vc.childViewControllers)
    if (Transitioning(child)) return true;
  return Transitioning(vc.presentedViewController);
}

// Where back and action climb from: the walked elements, last first (content comes last in the walk,
// the nav bar is a sibling above it), then the presented controllers' views, top first, for screens
// without labels (an alert's chain skips the view it is presented over).
NSArray *ClimbStarts() {
  NSMutableArray *starts = [gItems.reverseObjectEnumerator.allObjects mutableCopy];
  NSUInteger end = starts.count;
  for (UIViewController *vc = KeyWindow().rootViewController; vc; vc = vc.presentedViewController)
    if (vc.view) [starts insertObject:vc.view atIndex:end];
  return starts;
}

// Up through containers and responders; a navigation controller pops.
id Escape() {
  for (id start in ClimbStarts()) {
    id c = start;
    for (int k = 0; c && k < 40; k++) {
      id up = nil;
      @try {
        if ([c accessibilityPerformEscape]) return NSStringFromClass([c class]);
        up = [c accessibilityContainer];
      } @catch (NSException *) {
      }
      c = up ?: ([c respondsToSelector:@selector(nextResponder)] ? [c nextResponder] : nil);
    }
  }
  return NSNull.null;
}

id RunAction(NSString *name) {
  for (id start in ClimbStarts()) {
    id c = start;
    for (int k = 0; c && k < 40; k++) {
      id up = nil;
      @try {
        for (UIAccessibilityCustomAction *action in [c accessibilityCustomActions]) {
          if (![action.name isEqualToString:name]) continue;
          if (action.actionHandler) return @(action.actionHandler(action));
          return @(((BOOL (*)(id, SEL, id))objc_msgSend)(action.target, action.selector, action));
        }
        up = [c accessibilityContainer];
      } @catch (NSException *) {
      }
      c = up ?: ([c respondsToSelector:@selector(nextResponder)] ? [c nextResponder] : nil);
    }
  }
  return NSNull.null;
}

// UIKit controls decline accessibilityActivate too (VoiceOver touches them): send what a tap sends.
// One mask, so an action registered for both events runs once.
BOOL ActivateControl(id item) {
  if (![item isKindOfClass:UIControl.class] || !((UIControl *)item).enabled) return NO;
  [(UIControl *)item sendActionsForControlEvents:UIControlEventTouchUpInside | UIControlEventPrimaryActionTriggered];
  return YES;
}

// UIAlertController's action views decline accessibilityActivate (VoiceOver touches their activation
// point instead), so the topmost alert's enabled action with that title runs as a tap runs it: the
// alert dismisses, then the handler (private, through KVC) runs.
BOOL ActivateAlertAction(NSString *label) {
  UIViewController *top = KeyWindow().rootViewController;
  while (top.presentedViewController) top = top.presentedViewController;
  if (![top isKindOfClass:UIAlertController.class] || top.isBeingDismissed) return NO;
  for (UIAlertAction *action in ((UIAlertController *)top).actions) {
    if (!action.enabled || ![action.title isEqualToString:label]) continue;
    void (^handler)(UIAlertAction *) = nil;
    @try {
      handler = [action valueForKey:@"handler"];
    } @catch (NSException *) {
    }
    [top.presentingViewController dismissViewControllerAnimated:YES completion:^{
      if (handler) handler(action);
    }];
    return YES;
  }
  return NO;
}

// The action runs on main with no wait for it, so a breakpoint it hits can't block the reply.
void Activate(int fd, NSInteger n, NSString *label) {
  __block BOOL ok = NO;
  OnMain(^{
    if (n < 0 || n >= (NSInteger)gLabels.count || ![gLabels[n][1] isEqualToString:label]) return;
    ok = YES;
    id item = gItems[n];
    gBefore = gLabels;
    gResult = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      gResult = @([item accessibilityActivate] || ActivateControl(item) || ActivateAlertAction(label));
    });
  });
  Reply(fd, ok ? @{@"ok": @YES} : @{@"error": @"the screen changed since the last ls"});
}

void Insert(int fd, NSInteger n, NSString *label, NSString *text) {
  __block BOOL ok = NO;
  OnMain(^{
    if (n < 0 || n >= (NSInteger)gLabels.count || ![gLabels[n][1] isEqualToString:label]) return;
    ok = YES;
    id item = gItems[n];
    gBefore = gLabels;
    gResult = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      BOOL inserted = [item isKindOfClass:UIResponder.class] && [item conformsToProtocol:@protocol(UITextInput)] &&
                      ([item isFirstResponder] || [item becomeFirstResponder]);
      if (inserted) [(id<UITextInput>)item insertText:text];
      gResult = @(inserted);
    });
  });
  Reply(fd, ok ? @{@"ok": @YES} : @{@"error": @"the screen changed since the last ls"});
}

// Back, action and appearance: asked for on the current screen; the reply doesn't wait for the run.
void AskAndRun(int fd, id (^run)(void)) {
  OnMain(^{
    ActionAsked();
    dispatch_async(dispatch_get_main_queue(), ^{ gResult = run(); });
  });
  Reply(fd, @{@"ok": @YES});
}

// The minimum wait when the screen looks unchanged: a push can start a frame or two after the
// activation.
void Settle(int fd, NSInteger ms) {
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  __block NSArray *labels = nil, *before = nil, *values = nil, *frames = nil;
  __block id result = nil;
  __block BOOL moving = NO;
  NSArray *prev = nil;
  BOOL settled = NO;
  for (;;) {
    OnMain(^{
      Walk();
      labels = gLabels;
      values = gValues;
      frames = gFrames;
      before = gBefore;
      result = gResult;
      moving = Transitioning(KeyWindow().rootViewController);
    });
    CFAbsoluteTime elapsed = CFAbsoluteTimeGetCurrent() - start;
    if (result && !moving && [labels isEqual:prev] && (![labels isEqual:before] || elapsed >= 0.3)) {
      settled = YES;
      break;
    }
    if (elapsed * 1000 >= ms) break;
    prev = labels;
    usleep(100000);
  }
  Reply(fd, @{@"labels": labels ?: @[], @"values": values ?: @[], @"frames": frames ?: @[], @"settled": @(settled),
              @"ran": @(result != nil), @"result": result ?: NSNull.null});
}

void Ls(int fd) {
  __block NSArray *labels, *values, *frames;
  OnMain(^{
    Walk();
    labels = gLabels;
    values = gValues;
    frames = gFrames;
  });
  Reply(fd, @{@"labels": labels, @"values": values, @"frames": frames});
}

id Json(NSArray<NSString *> *words, NSUInteger from) {
  NSString *json = [[words subarrayWithRange:NSMakeRange(from, words.count - from)] componentsJoinedByString:@" "];
  return [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding]
                                         options:NSJSONReadingFragmentsAllowed
                                           error:nil];
}

}  // namespace

UIWindow *KeyWindow() {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow *window in ((UIWindowScene *)scene).windows)
      if (window.isKeyWindow) return window;
  }
  return nil;
}

void ActionAsked() {
  Walk();
  gBefore = gLabels;
  gResult = nil;
}

void ActionRan(id result) { gResult = result; }

bool Digits(NSString *s) {
  static NSCharacterSet *other = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
  return s.length > 0 && s.length < 9 && [s rangeOfCharacterFromSet:other].location == NSNotFound;
}

bool HandleAx(int fd, NSString *line) {
  NSArray<NSString *> *words = [line componentsSeparatedByString:@" "];
  NSString *verb = words[0];
  if ([verb isEqualToString:@"ls"]) {
    words.count == 1 ? Ls(fd) : Fail(fd, @"usage: ls");
  } else if ([verb isEqualToString:@"back"]) {
    words.count == 1 ? AskAndRun(fd, ^id { return Escape(); }) : Fail(fd, @"usage: back");
  } else if ([verb isEqualToString:@"appearance"]) {
    NSDictionary *styles = @{@"light": @(UIUserInterfaceStyleLight), @"dark": @(UIUserInterfaceStyleDark),
                             @"system": @(UIUserInterfaceStyleUnspecified)};
    NSNumber *style = words.count == 2 ? styles[words[1]] : nil;
    if (style)
      AskAndRun(fd, ^id {
        KeyWindow().overrideUserInterfaceStyle = (UIUserInterfaceStyle)style.integerValue;
        return @YES;
      });
    else
      Fail(fd, @"usage: appearance light|dark|system");
  } else if ([verb isEqualToString:@"settle"]) {
    if (words.count == 2 && Digits(words[1]))
      Settle(fd, MIN(words[1].integerValue, 10000));
    else
      Fail(fd, @"usage: settle MS");
  } else if ([verb isEqualToString:@"action"]) {
    id name = words.count >= 2 ? Json(words, 1) : nil;
    if ([name isKindOfClass:NSString.class])
      AskAndRun(fd, ^id { return RunAction(name); });
    else
      Fail(fd, @"usage: action \"NAME\"");
  } else if ([verb isEqualToString:@"activate"]) {
    id label = words.count >= 3 && Digits(words[1]) ? Json(words, 2) : nil;
    if ([label isKindOfClass:NSString.class])
      Activate(fd, words[1].integerValue, label);
    else
      Fail(fd, @"usage: activate N \"LABEL\"");
  } else if ([verb isEqualToString:@"insert"]) {
    id pair = words.count >= 3 && Digits(words[1]) ? Json(words, 2) : nil;
    if ([pair isKindOfClass:NSArray.class] && [pair count] == 2 && [pair[0] isKindOfClass:NSString.class] &&
        [pair[1] isKindOfClass:NSString.class])
      Insert(fd, words[1].integerValue, pair[0], pair[1]);
    else
      Fail(fd, @"usage: insert N [\"LABEL\", \"TEXT\"]");
  } else {
    return false;
  }
  return true;
}

}  // namespace uidrive

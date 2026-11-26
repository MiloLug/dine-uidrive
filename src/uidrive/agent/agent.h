// Declarations shared by the agent's files. Unless a name says otherwise, UIKit work runs on main.
#pragma once

#import <UIKit/UIKit.h>
#include <os/log.h>

namespace uidrive {

os_log_t Log();

// From the serve thread only: dispatch_sync on main deadlocks when called on main.
void OnMain(void (^block)(void));

// One JSON line, then the caller closes the connection.
void Reply(int fd, NSDictionary *obj);
void Fail(int fd, NSString *error);

UIWindow *KeyWindow();
// Every window, internal ones (the keyboard's) included, in UIKit's order.
NSArray<UIWindow *> *AllWindows();
// 0 when the window has none or UIKit lacks the selector.
uint32_t ContextId(UIWindow *window);

// Settle bookkeeping, main thread only. ActionAsked walks and records the labels the action starts
// from; settle waits until ActionRan gives the action's result.
void ActionAsked();
void ActionRan(id result);

// An index or a count: 1 to 8 ASCII digits.
bool Digits(NSString *s);

// Each returns whether the line's first word is one of its verbs, and replies to every line it takes.
bool HandleAx(int fd, NSString *line);
bool HandleTouch(int fd, NSString *line);

}  // namespace uidrive

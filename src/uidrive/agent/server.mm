// Load-time start, the TCP server on 127.0.0.1:$UIDRIVE_PORT, and request dispatch.
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "agent.h"

namespace uidrive {

os_log_t Log() {
  static os_log_t log = os_log_create("uidrive", "agent");
  return log;
}

void OnMain(void (^block)(void)) { dispatch_sync(dispatch_get_main_queue(), block); }

void Reply(int fd, NSDictionary *obj) {
  // NSJSONSerialization throws on NaN or infinity, which would end the app.
  if (![NSJSONSerialization isValidJSONObject:obj]) obj = @{@"error": @"the reply holds a value JSON can't carry"};
  NSMutableData *data = [[NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] mutableCopy];
  [data appendBytes:"\n" length:1];
  for (size_t off = 0; off < data.length;) {
    ssize_t n = send(fd, (const char *)data.bytes + off, data.length - off, 0);
    if (n <= 0) return;
    off += (size_t)n;
  }
}

namespace {

// Of any length: activate and insert carry whole labels and texts, gesture its paths.
NSString *ReadLine(int fd) {
  NSMutableData *line = [NSMutableData data];
  char buf[4096];
  for (;;) {
    ssize_t n = recv(fd, buf, sizeof buf, 0);
    if (n <= 0) return nil;
    auto end = static_cast<const char *>(memchr(buf, '\n', static_cast<size_t>(n)));
    [line appendBytes:buf length:end ? static_cast<NSUInteger>(end - buf) : static_cast<NSUInteger>(n)];
    if (end) return [[NSString alloc] initWithData:line encoding:NSUTF8StringEncoding];
  }
}

void Handle(int fd) {
  NSString *line = ReadLine(fd);
  if (!line.length) return;
  if (!HandleAx(fd, line)) HandleTouch(fd, line);
}

void *Serve(void *arg) {
  int port = (int)(intptr_t)arg;
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  sockaddr_in addr = {};
  addr.sin_len = sizeof addr;
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, (sockaddr *)&addr, sizeof addr) != 0 || listen(fd, 8) != 0) {
    os_log_error(Log(), "uidrive: can't listen on 127.0.0.1:%d: %{public}s", port, strerror(errno));
    close(fd);
    return nullptr;
  }
  os_log(Log(), "uidrive: listening on 127.0.0.1:%d", port);
  for (;;) {
    int c = accept(fd, nullptr, nullptr);
    if (c < 0) {
      if (errno == EINTR || errno == ECONNABORTED) continue;
      os_log_error(Log(), "uidrive: accept: %{public}s", strerror(errno));
      return nullptr;
    }
    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    timeval timeout = {5, 0};
    setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof timeout);
    @autoreleasepool {
      Handle(c);
    }
    close(c);
  }
}

int Port(const char *env) {
  if (!env || !*env) return 0;
  char *end = nullptr;
  long port = strtol(env, &end, 10);
  return *end == '\0' && port >= 1 && port <= 65535 ? (int)port : 0;
}

// SwiftUI builds the accessibility tree `ls` walks only while app accessibility is on, and iOS can
// leave it off for a new launch.
void EnableAccessibility() {
  using SetEnabled = void (*)(int);
  const char *from = "a loaded library";
  auto set = (SetEnabled)dlsym(RTLD_DEFAULT, "_AXSApplicationAccessibilitySetEnabled");
  if (!set) {
    from = "/usr/lib/libAccessibility.dylib";
    void *lib = dlopen(from, RTLD_NOW);
    set = lib ? (SetEnabled)dlsym(lib, "_AXSApplicationAccessibilitySetEnabled") : nullptr;
  }
  if (!set) {
    os_log_error(Log(), "uidrive: no _AXSApplicationAccessibilitySetEnabled; ls may miss SwiftUI's labels");
    return;
  }
  set(1);
  os_log(Log(), "uidrive: accessibility on (_AXSApplicationAccessibilitySetEnabled from %{public}s)", from);
}

__attribute__((constructor)) void UidriveLoaded() {
  // Consumers find the dylib in a bundle by this exact format string: keep it stable.
  os_log(Log(), "uidrive: injected into %{public}s", getprogname());
  int port = Port(getenv("UIDRIVE_PORT"));
  // Processes the app starts would load the agent again and try to bind the same port.
  unsetenv("DYLD_INSERT_LIBRARIES");
  unsetenv("UIDRIVE_PORT");
  if (!port) {
    os_log(Log(), "uidrive: no UIDRIVE_PORT, not serving");
    return;
  }
  EnableAccessibility();
  pthread_t thread;
  if (pthread_create(&thread, nullptr, Serve, (void *)(intptr_t)port) == 0) pthread_detach(thread);
}

}  // namespace
}  // namespace uidrive

#import "PoltergeistMultiView.h"

// Flutter 3.47's FlutterEngine keeps multi-view behind the private
// -enableMultiView, which asserts that no view controller is attached yet:
// it is meant for apps whose every window comes from Flutter's own
// (experimental, master-channel) windowing API. Here the app's window, the
// implicit view, exists first, and NSAssert is live in the shipped engine,
// so the method would raise. The flag it sets is all that decides what
// -addViewController: does with the next controller (a fresh view id instead
// of the implicit one), so this sets that flag directly. Key-value coding
// finds the ivar by name; an engine that renamed or dropped it raises, which
// reads as "no extra windows". Reassess on every Flutter upgrade, like the
// accessibility guard beside this file.
BOOL PoltergeistEnableMultiView(FlutterEngine *engine) {
  @try {
    [engine setValue:@YES forKey:@"multiViewEnabled"];
    return [[engine valueForKey:@"multiViewEnabled"] boolValue];
  } @catch (NSException *exception) {
    NSLog(@"Poltergeist: no multi-view switch on this engine (%@)",
          exception.reason);
    return NO;
  }
}

#import "PoltergeistFlutterViewController.h"

// Ported from Séance (app/seance_app/macos/Runner/SeanceFlutterViewController.m
// at 15d0fdd; docs/PORTS.md). Flutter exposes these Objective-C selectors at
// runtime, but not in its public headers. Séance's native regression script
// (scripts/test-macos-accessibility.sh) exercises this boundary against the
// bundled engine; see Séance's docs/macos-accessibility-crash.md for the
// lifetime defect. Reassess on every Flutter upgrade.
@interface FlutterViewController (PoltergeistAccessibilityLifecycle)
- (void)notifySemanticsEnabledChanged;
@end

@interface FlutterEngine (PoltergeistAccessibilityLifecycle)
@property(nonatomic, readonly) BOOL semanticsEnabled;
@end

@interface NSView (PoltergeistAccessibilityLifecycle)
- (void)setPlatformNode:(void *)node;
@end

@implementation PoltergeistFlutterViewController

- (void)notifySemanticsEnabledChanged {
  if (!self.engine.semanticsEnabled) {
    [self invalidateAccessibilityTextFields];
  }
  [super notifySemanticsEnabledChanged];
}

- (void)dealloc {
  [self invalidateAccessibilityTextFields];
}

- (void)invalidateAccessibilityTextFields {
  if (!self.viewLoaded) {
    return;
  }
  Class textFieldClass = NSClassFromString(@"FlutterTextField");
  if (!textFieldClass ||
      ![textFieldClass instancesRespondToSelector:@selector(setPlatformNode:)]) {
    return;
  }

  // Flutter 3.47.3 destroys AccessibilityBridge::tree_ before id_wrapper_map_.
  // Detaching one native field can reenter AppKit while a sibling still points
  // through its delegate into the freed tree. Snapshot without querying any
  // accessibility data, then invalidate every field before the first detach.
  // The engine normally calls this same setter one field at a time.
  NSMutableArray<NSView *> *pending = [NSMutableArray arrayWithObject:self.view];
  NSMutableArray<NSView *> *fields = [NSMutableArray array];
  while (pending.count != 0) {
    NSView *view = pending.lastObject;
    [pending removeLastObject];
    if ([view isKindOfClass:textFieldClass]) {
      [fields addObject:view];
    }
    [pending addObjectsFromArray:view.subviews];
  }
  for (NSView *field in fields) {
    [field setPlatformNode:NULL];
  }
}

@end

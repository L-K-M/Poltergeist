#import "PoltergeistFlutterViewController.h"
#import <IOKit/hidsystem/IOLLEvent.h>

// Flutter marks shortcuts received by its text input plugin so an unhandled
// event can continue to the native menus. These selectors are runtime-only;
// the native keyboard regression checks them against the bundled engine.
@interface NSEvent (PoltergeistKeyEquivalent)
- (BOOL)isKeyEquivalent;
- (void)markAsKeyEquivalent;
@end

static NSEvent* PoltergeistNormalizeCommandModifier(NSEvent* event) {
  const NSEventModifierFlags flags = event.modifierFlags;
  const NSEventModifierFlags commandSides =
      NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK;
  if (!(flags & NSEventModifierFlagCommand) || (flags & commandSides)) {
    // Identity matters to Flutter's detection of redispatched events.
    return event;
  }

  // Tools such as Easydict send Command+C with only the aggregate Command
  // flag. Flutter 3.47 synchronizes modifiers from the left/right bits and
  // otherwise delivers a plain c, replacing the pane's range selection.
  // Supply a deterministic side only when the source did not specify one.
  // Flutter releases it when the next event no longer carries Command.
  NSEvent* normalized =
      [NSEvent keyEventWithType:event.type
                      location:event.locationInWindow
                 modifierFlags:flags | NX_DEVICELCMDKEYMASK
                     timestamp:event.timestamp
                  windowNumber:event.windowNumber
                       context:nil
                    characters:event.characters ?: @""
   charactersIgnoringModifiers:event.charactersIgnoringModifiers ?: @""
                     isARepeat:event.isARepeat
                       keyCode:event.keyCode];
  if (normalized == nil) {
    return event;
  }
  if ([event respondsToSelector:@selector(isKeyEquivalent)] &&
      [event isKeyEquivalent] &&
      [normalized respondsToSelector:@selector(markAsKeyEquivalent)]) {
    [normalized markAsKeyEquivalent];
  }
  return normalized;
}

// Ported from Séance (app/seance_app/macos/Runner/SeanceFlutterViewController.m
// at 15d0fdd; docs/PORTS.md). Flutter exposes these Objective-C selectors at
// runtime, but not in its public headers. Séance's native regression script
// (scripts/test-macos-accessibility.sh) exercises this boundary against the
// bundled engine; see Séance's docs/macos-accessibility-crash.md for the
// lifetime defect. Reassess on every Flutter upgrade.
@interface FlutterViewController (PoltergeistAccessibilityLifecycle)
- (void)notifySemanticsEnabledChanged;
- (void)updateSemantics:(const void*)update;
@end

@interface FlutterEngine (PoltergeistAccessibilityLifecycle)
@property(nonatomic, readonly) BOOL semanticsEnabled;
- (nullable FlutterViewController*)viewControllerForIdentifier:
    (FlutterViewIdentifier)viewIdentifier;
@end

// The head of the embedder's FlutterSemanticsUpdate2 (embedder.h), through
// the view id its last field carries. The struct is ABI-stable and sized:
// a producer too old to fill the field says so in struct_size.
typedef struct {
  size_t struct_size;
  size_t node_count;
  void** nodes;
  size_t custom_action_count;
  void** custom_actions;
  int64_t view_id;
} PoltergeistSemanticsUpdate;

// The view an update is for; the implicit view when the producer is too old
// to say.
static int64_t PoltergeistSemanticsUpdateViewId(const void* update) {
  const PoltergeistSemanticsUpdate* head = update;
  if (head->struct_size < offsetof(PoltergeistSemanticsUpdate, view_id) +
                              sizeof(head->view_id)) {
    return 0;
  }
  return head->view_id;
}

@interface NSView (PoltergeistAccessibilityLifecycle)
- (void)setPlatformNode:(void *)node;
@end

@implementation PoltergeistFlutterViewController

- (void)keyDown:(NSEvent*)event {
  [super keyDown:PoltergeistNormalizeCommandModifier(event)];
}

- (void)keyUp:(NSEvent*)event {
  [super keyUp:PoltergeistNormalizeCommandModifier(event)];
}

- (void)notifySemanticsEnabledChanged {
  if (!self.engine.semanticsEnabled) {
    [self invalidateAccessibilityTextFields];
  }
  [super notifySemanticsEnabledChanged];
}

// Flutter 3.47's macOS engine hands every view's semantics update to the
// implicit view's controller (FlutterEngine.mm: "This callback only supports
// single-view"), although each update names its view. Every view controller
// is this class, so each routes updates for another view to that view's
// controller, whose own call then lands here with its own id. The
// accessibility actions coming back carry no view at all; Dart routes those
// by node (lib/services/semantics_view_routing.dart). Reassess on every
// Flutter upgrade, like the guard below.
- (void)updateSemantics:(const void*)update {
  const int64_t viewId = PoltergeistSemanticsUpdateViewId(update);
  if (viewId == self.viewIdentifier) {
    [super updateSemantics:update];
    return;
  }
  FlutterViewController* target = [self.engine viewControllerForIdentifier:viewId];
  if (target == nil || target == self) {
    // The window closed after its frame: nothing shows the tree.
    return;
  }
  // A controller made after semantics were enabled has no accessibility
  // bridge yet; this creates it (a no-op when it has one).
  [target notifySemanticsEnabledChanged];
  [target updateSemantics:update];
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

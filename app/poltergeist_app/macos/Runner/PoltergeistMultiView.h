#import <FlutterMacOS/FlutterMacOS.h>

NS_ASSUME_NONNULL_BEGIN

/// Lets [engine] take view controllers beyond its implicit view, one per
/// extra workspace window (00 D39; WorkspaceWindows.swift). NO when this
/// engine has no such switch, and no window may then be added: without it,
/// a second FlutterViewController on the engine replaces the implicit view
/// instead of joining it.
BOOL PoltergeistEnableMultiView(FlutterEngine *engine);

NS_ASSUME_NONNULL_END

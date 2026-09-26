#import <FlutterMacOS/FlutterMacOS.h>

NS_ASSUME_NONNULL_BEGIN

/// Preserves injected Command shortcuts and invalidates native text fields
/// before Flutter tears down their accessibility tree (ported from Séance's
/// SeanceFlutterViewController, docs/PORTS.md).
@interface PoltergeistFlutterViewController : FlutterViewController
@end

NS_ASSUME_NONNULL_END

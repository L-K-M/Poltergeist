# macOS injected Command shortcuts

Easydict can simulate Command+C after a mouse selection to retrieve selected
text. A live trace of the reported Shift-click failure found 20 C key-down/up
pairs from Easydict, all carrying aggregate Command (`0x100000`) without a
left/right Command bit. Quitting Easydict stopped the failure. No clipboard
contents were needed to establish the source.

Flutter 3.47 synchronizes its keyboard state from side-specific modifier
bits. Aggregate-only Command disappears, so the pane sees a plain c and
type-ahead replaces the selected range. The related upstream report is
[flutter/flutter#184571](https://github.com/flutter/flutter/issues/184571).
Easydict documents its simulated-copy fallback in its
[FAQ](https://github.com/tisfeng/Easydict/wiki/FAQ).

## Compatibility boundary

`PoltergeistFlutterViewController` normalizes only key-down/up events with
aggregate Command and neither Command side. It supplies left Command as a
deterministic fallback. Physical left/right Command events, ordinary typing,
and modifier-change events remain unchanged. There is no per-window key
state: Flutter's shared keyboard manager reconciles the next event's flags.
The main, settings, and additional workspace windows use this controller.

Events that need no normalization retain object identity because Flutter
uses it to detect redispatch. A normalized event preserves its key metadata
and Flutter's runtime `isKeyEquivalent` marker, needed for unhandled native
menu shortcuts while a text field has focus. Reassess this compatibility
layer and the marker selectors on every Flutter upgrade.

## Native regression

Run `FLUTTER_ROOT=/path/to/flutter bash scripts/test-macos-keyboard.sh` on
macOS after caching the macOS release engine. CI runs it after the macOS
client build. `--stock-engine` bypasses the app controller and should fail
the aggregate-only Command+C assertion on the affected Flutter version.

The fixture exercises the real Flutter controller, keyboard manager, and
native responders. Its framework replies are captured in the test process.
It does not start the Dart application, open a window, or post input to the
system. This boundary cannot be reproduced by widget tests that start with
an already-translated Dart key event.

For release smoke testing, enable Easydict's affected selection behavior,
select a file, and Shift-click another. The range must remain selected and
no c badge may appear. Check physical Copy/Paste, plain c and uppercase C
type-ahead, key repeat, a text field, and another workspace window as well.
The automated fixture does not replace that live application check.

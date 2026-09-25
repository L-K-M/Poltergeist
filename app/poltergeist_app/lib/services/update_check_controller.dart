// The D19 link-only update check's app-side owner (00 D19/D23,
// 07 §3.10, 01 §6): once per launch the checker asks GitHub for
// Poltergeist's latest release tag — a plain GET of the static endpoint,
// no version string, platform hint, or identifier on the wire — and the
// response is compared locally. The banner it feeds only ever links to
// the releases page; nothing here downloads or installs an update.
import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Session state for the update check: [update] is the banner's content
/// (null means "nothing to show" — up to date, check failed, dismissed,
/// or opted out), and [enabled] is the persisted opt-out. Every failure
/// mode reads as "no banner"; the check is best-effort by contract.
class UpdateCheckController extends ChangeNotifier {
  UpdateCheckController({
    UpdateChecker? checker,
    bool enabled = true,
    // The persist sink stays private to the controller.
    Future<void> Function(bool enabled)? onEnabledChanged,
  }) : _checker = checker ?? UpdateChecker(repo: poltergeistUpdateRepo),
       // ignore: prefer_initializing_formals
       _enabled = enabled,
       // ignore: prefer_initializing_formals
       _onEnabledChanged = onEnabledChanged;

  final UpdateChecker _checker;
  final Future<void> Function(bool enabled)? _onEnabledChanged;
  bool _enabled;
  UpdateInfo? _update;

  /// The opt-out setting (default ON per D19/D23).
  bool get enabled => _enabled;

  /// The newer release to banner, or null when there is nothing to say.
  UpdateInfo? get update => _update;

  /// Compare [currentVersion] against GitHub's latest release tag.
  /// Opted-out, offline, rate-limited, and up-to-date all land as
  /// "no banner" — the check never surfaces an error.
  Future<void> checkForUpdate(String currentVersion) async {
    if (!_enabled) return;
    final info = await _checker.check(currentVersion);
    if (info == null || identical(info, _update)) return;
    _update = info;
    notifyListeners();
  }

  /// The menu's Check for Updates… (10 §8): the user asked, so it runs
  /// even while the launch check is turned off, and a newer release
  /// lands in Alerts exactly as the launch check's would. Returns that
  /// release, or null: the checker answers null both when this is the
  /// latest version and when GitHub could not be reached, so a caller
  /// must not claim either.
  Future<UpdateInfo?> checkNow(String currentVersion) async {
    final info = await _checker.check(currentVersion);
    if (info != null && !identical(info, _update)) {
      _update = info;
      notifyListeners();
    }
    return info;
  }

  /// The settings toggle's persist path: the write lands before the
  /// field commits, so a failed save rethrows for the caller's
  /// revert idiom and the in-memory flag never diverges from disk.
  /// Opting out clears a banner already showing this session.
  Future<void> setEnabled(bool value) async {
    if (value == _enabled) return;
    await _onEnabledChanged?.call(value);
    _enabled = value;
    if (!value) _update = null;
    notifyListeners();
  }

  /// Dismiss the banner for this session — a fresh launch re-checks.
  void dismiss() {
    if (_update == null) return;
    _update = null;
    notifyListeners();
  }
}

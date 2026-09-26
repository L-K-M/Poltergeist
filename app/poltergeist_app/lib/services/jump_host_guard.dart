import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart' show basicLocaleListResolution;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';

/// Throws the typed refusal when [config] routes through a jump host.
///
/// The pinned opener carries `jumpHostId` but has no ProxyJump executor
/// (D10 lands it after v1.0), so it would dial the destination directly.
/// For a server Séance reaches through a bastion that is not a degraded
/// connection but a different one: it skips the network path the route
/// exists for, can reach another machine that answers to the same name,
/// and would pin that machine's host key and hand it credentials. Such a
/// server is not connectable until the fast-follow (01 §4, differentiator
/// 8), so every path that hands the engine a config checks here first and
/// says why, rather than failing later as an unreachable host (X-05).
/// Retire this once the pin executes jump hosts.
///
/// The message is ARB copy resolved without a BuildContext, with the
/// locale resolution the MaterialApp applies: the pane's diagnostic line
/// and a failed task row both render it verbatim. [operation] is the
/// caller's own engine operation label.
void refuseJumpHostRoute(ServerConfig config, {required String operation}) {
  if (config.jumpHostId == null) return;
  throw RemoteFileException(
    kind: RemoteFileErrorKind.unsupported,
    operation: operation,
    message: lookupAppLocalizations(
      basicLocaleListResolution(
        PlatformDispatcher.instance.locales,
        AppLocalizations.supportedLocales,
      ),
    ).connectionJumpHostUnsupported,
  );
}

// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Poltergeist';

  @override
  String get menuFile => 'File';

  @override
  String get menuEdit => 'Edit';

  @override
  String get menuView => 'View';

  @override
  String get menuGo => 'Go';

  @override
  String get menuCommands => 'Commands';

  @override
  String get menuWindow => 'Window';

  @override
  String get menuHelp => 'Help';

  @override
  String get paneAName => 'Pane A';

  @override
  String get paneBName => 'Pane B';

  @override
  String get paneNoEngine => 'Browsing is unavailable right now.';

  @override
  String get paneNoLocation => 'This pane has no location open.';

  @override
  String get resizePanes => 'Resize panes';

  @override
  String paneRatioPercent(int value) {
    return '$value%';
  }

  @override
  String get readyStatus => 'Ready';

  @override
  String get hostKeyUnknownTitle => 'Unknown host key';

  @override
  String get hostKeyChangedTitle => 'HOST KEY CHANGED';

  @override
  String hostKeyChangedWarning(String host) {
    return 'The key for $host does not match the one you previously trusted. This can mean a man-in-the-middle attack. Only continue if you know why the key changed.';
  }

  @override
  String hostKeyEndpoint(String host, int port) {
    return '$host:$port';
  }

  @override
  String get hostKeyFingerprintLabel => 'Fingerprint';

  @override
  String get hostKeyNewLabel => 'New key';

  @override
  String get hostKeyPreviousLabel => 'Previously trusted';

  @override
  String get hostKeyCancel => 'Cancel';

  @override
  String get hostKeyTrustConnect => 'Trust and connect';

  @override
  String get hostKeyTrustNewKey => 'Trust the new key';

  @override
  String get keyboardAuthTitle => 'Authentication';

  @override
  String get keyboardSubmit => 'Submit';

  @override
  String get keyboardCancel => 'Cancel';

  @override
  String get keyboardShowAnswer => 'Show answer';

  @override
  String get keyboardHideAnswer => 'Hide answer';

  @override
  String get credentialTitle => 'Authentication required';

  @override
  String credentialEndpoint(String username, String host, int port) {
    return '$username@$host:$port';
  }

  @override
  String get credentialPasswordField => 'Password';

  @override
  String get credentialKeyFileField => 'Key file';

  @override
  String get credentialKeyFileRequired => 'Choose a key file.';

  @override
  String get credentialPassphraseField => 'Passphrase';

  @override
  String get credentialSaveInVault => 'Save in vault';

  @override
  String get credentialConnect => 'Connect';

  @override
  String get credentialCancel => 'Cancel';

  @override
  String get credentialVaultUnavailable =>
      'Saved secrets are unavailable. Unlock or restore your system credential store, then retry — or enter the secret below.';

  @override
  String get credentialKeyFileUnreadable =>
      'The file could not be read as text.';

  @override
  String credentialKeyFileReadError(String error) {
    return 'Could not read the key file: $error';
  }

  @override
  String get connectionStateConnecting => 'Connecting…';

  @override
  String get connectionStateReconnecting => 'Reconnecting…';

  @override
  String get connectionFailedTitle => 'Connection failed';

  @override
  String get connectionBlockedTitle => 'Connection blocked';

  @override
  String get connectionDisconnectedTitle => 'Disconnected';

  @override
  String get connectionLogTitle => 'Connection log';

  @override
  String get connectionLogCopy => 'Copy';

  @override
  String get connectionLogEmpty => '(no log captured)';

  @override
  String get connectionRetry => 'Retry';

  @override
  String get vaultSaveFailed =>
      'Could not save the secret to the vault. The connection will continue.';

  @override
  String get sshImportTitle => 'Import servers from ssh config';

  @override
  String get sshImportLoading => 'Reading ssh config…';

  @override
  String sshImportLoadFailed(String path) {
    return 'Could not read $path.';
  }

  @override
  String get sshImportRetry => 'Try Again';

  @override
  String sshImportEmpty(String path) {
    return 'No importable hosts were found in $path.';
  }

  @override
  String get sshImportColumnImport => 'Import';

  @override
  String get sshImportColumnHost => 'Host';

  @override
  String get sshImportColumnEndpoint => 'Endpoint';

  @override
  String get sshImportColumnUser => 'User';

  @override
  String get sshImportColumnAuth => 'Auth';

  @override
  String get sshImportColumnNotes => 'Notes';

  @override
  String get sshImportAuthPassword => 'Password';

  @override
  String sshImportAuthKey(String path) {
    return 'Key: $path';
  }

  @override
  String sshImportDuplicateExisting(String label) {
    return 'Duplicate of bookmark “$label”';
  }

  @override
  String sshImportDuplicateEarlier(String alias) {
    return 'Duplicate of “$alias” in this import';
  }

  @override
  String get sshImportLimitProxyJump =>
      'Won’t behave as in ssh: ProxyJump — connects directly, not through the jump host';

  @override
  String get sshImportLimitProxyCommand =>
      'Won’t behave as in ssh: ProxyCommand — never executed';

  @override
  String get sshImportLimitMatch =>
      'Won’t behave as in ssh: Match blocks are ignored; settings may differ';

  @override
  String get sshImportLimitHostInclude =>
      'Won’t behave as in ssh: Include inside this host block is not applied';

  @override
  String get sshImportLimitInvalidPort => 'Cannot import: port outside 1–65535';

  @override
  String get sshImportLimitWildcardDefaults =>
      'Won’t behave as in ssh: defaults from a top-level or Host * block are not inherited';

  @override
  String get sshImportUnresolvedIncludes => 'Unresolved includes';

  @override
  String sshImportNoteCycle(String path) {
    return '$path: include loop skipped';
  }

  @override
  String sshImportNoteDepth(String path) {
    return '$path: nested beyond the depth limit';
  }

  @override
  String sshImportNoteUnreadable(String path) {
    return '$path: could not be read';
  }

  @override
  String get sshImportCancel => 'Cancel';

  @override
  String get sshImportAction => 'Import';

  @override
  String sshImportActionCount(int count) {
    return 'Import $count';
  }

  @override
  String sshImportRowSemantics(String alias) {
    return 'Import $alias';
  }

  @override
  String get sshImportCommandLabel => 'Import from ssh config…';

  @override
  String sshImportImported(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Imported $count favorites',
      one: 'Imported 1 favorite',
    );
    return '$_temp0';
  }

  @override
  String get sshImportFavoritesLoadFailed =>
      'Could not read the favorites file.';

  @override
  String get sshImportFavoritesSaveFailed =>
      'Could not save the imported favorites.';

  @override
  String get probeStatusUnknown => 'Reachability unknown';

  @override
  String get probeStatusOnline => 'Reachable';

  @override
  String get probeStatusOffline => 'Unreachable';

  @override
  String get connectionStateConnected => 'Connected';

  @override
  String get connectionStateNotConnected => 'Not connected';

  @override
  String get connectionsLoading => 'Loading servers';

  @override
  String get connectionsLoadFailed => 'Could not read the favorites file.';

  @override
  String get connectionsBlockedWarning =>
      'Blocked until you review the host key at the next connection attempt.';

  @override
  String get connectionsReviewHostKey => 'Review host key…';

  @override
  String connectionsPaneFailure(String pane, String message) {
    return 'Pane $pane failed: $message';
  }

  @override
  String get sidebarConnectionsSection => 'Connections';

  @override
  String get sidebarUngroupedSection => 'Favorites';

  @override
  String get sidebarEmptyFavorites =>
      'No favorites yet. Save a location as a favorite to see it here.';

  @override
  String get sidebarOpen => 'Open';

  @override
  String get sidebarOpenInNewTab => 'Open in New Tab';

  @override
  String get sidebarOpenInOtherPane => 'Open in Other Pane';

  @override
  String get sidebarRename => 'Rename…';

  @override
  String get sidebarRenameTitle => 'Rename Favorite';

  @override
  String get sidebarRenameFieldLabel => 'Name';

  @override
  String get sidebarMoveToGroup => 'Move to Group';

  @override
  String get sidebarNoGroup => 'No Group';

  @override
  String get sidebarNewGroup => 'New Group…';

  @override
  String get sidebarNewGroupTitle => 'New Group';

  @override
  String get sidebarGroupFieldLabel => 'Group name';

  @override
  String get sidebarDelete => 'Delete';

  @override
  String get sidebarDeleteTitle => 'Delete Favorite';

  @override
  String sidebarDeleteBody(String label) {
    return 'Delete \"$label\" from favorites? This cannot be undone.';
  }

  @override
  String get sidebarActionFailed =>
      'That change couldn\'t be saved. Try again.';

  @override
  String get sidebarDisconnect => 'Disconnect';

  @override
  String get sidebarKindWorkspace => 'Workspace';

  @override
  String get sidebarKindSavedSync => 'Saved sync';

  @override
  String get sidebarWorkspaceUpdate => 'Update Workspace';

  @override
  String get sidebarSyncLater =>
      'Opening saved-sync favorites isn\'t available yet — the sync preview arrives in a later milestone.';

  @override
  String get viewToggleSidebarLabel => 'Show/Hide Sidebar';

  @override
  String get paneOpeningHome => 'Opening home…';

  @override
  String paneConnectingTo(String label) {
    return 'Connecting to $label…';
  }

  @override
  String get paneEmptyFolder => 'This folder is empty.';

  @override
  String get paneDropHintLocal => 'Drop files here to copy them';

  @override
  String get paneDropHintRemote => 'Drop files here to upload them';

  @override
  String dropMoveTo(String dir) {
    return 'Move to $dir';
  }

  @override
  String dropCopyTo(String dir) {
    return 'Copy to $dir';
  }

  @override
  String dropUploadTo(String dir) {
    return 'Upload to $dir';
  }

  @override
  String dropDownloadTo(String dir) {
    return 'Download to $dir';
  }

  @override
  String dropItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String paneItemCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0';
  }

  @override
  String paneLoadingFolder(String name) {
    return 'Loading $name — Esc cancels';
  }

  @override
  String get paneCancelLoading => 'Cancel loading';

  @override
  String get paneConnectCancel => 'Cancel';

  @override
  String paneTypeAheadBadge(String buffer) {
    return 'Names starting with \"$buffer\"';
  }

  @override
  String get paneErrorNotFound => 'The folder could not be found.';

  @override
  String get paneErrorPermissionDenied =>
      'You don\'t have permission to open this folder.';

  @override
  String get paneErrorUnsupported => 'This operation is not supported here.';

  @override
  String get paneErrorDisconnected => 'The connection was closed.';

  @override
  String get paneErrorConflict => 'The item changed while being opened.';

  @override
  String get paneErrorCancelled => 'The operation was cancelled.';

  @override
  String get paneErrorOther => 'The folder could not be opened.';

  @override
  String get paneFaultConnectionOpen =>
      'The connection to this server could not be opened.';

  @override
  String get paneFaultLocalOpen =>
      'The local file browser could not be opened.';

  @override
  String get paneFaultListFolder => 'This folder could not be listed.';

  @override
  String get paneFaultInvalidPath =>
      'That is not a folder path this pane can open. Use an absolute path, ~, or a name in this folder.';

  @override
  String get paneFaultRenameNameEmpty => 'Enter a name.';

  @override
  String get paneFaultRenameNameSeparator => 'A name cannot contain “/”.';

  @override
  String get paneFaultRenameNameInvalid => 'That name is not allowed here.';

  @override
  String get paneFaultRenameTargetGone =>
      'The item is no longer in this folder.';

  @override
  String get paneFaultOpenFile => 'The file could not be opened.';

  @override
  String paneConnectionLost(String label) {
    return 'Connection to $label lost — reconnecting…';
  }

  @override
  String paneConnectionRecoveryFailed(String label) {
    return 'Connection to $label could not be restored.';
  }

  @override
  String get paneConnectionLostCancel => 'Cancel';

  @override
  String paneRestoredOffline(String label) {
    return 'Session restored — $label is offline.';
  }

  @override
  String get paneReconnect => 'Reconnect';

  @override
  String get paneNoticeOpenRemoteUnavailable =>
      'Remote files can\'t be opened in place yet — Poltergeist will download and open them in a later milestone.';

  @override
  String get paneNoticeEditLater =>
      'Editing files in Poltergeist isn\'t available yet — the editor arrives in a later milestone.';

  @override
  String get paneNoticeTransferLater =>
      'Transferring to the other pane isn\'t available yet — the transfer queue arrives in a later milestone.';

  @override
  String get paneNoticeDismiss => 'Dismiss';

  @override
  String paneDateToday(String time) {
    return 'Today at $time';
  }

  @override
  String paneDateYesterday(String time) {
    return 'Yesterday at $time';
  }

  @override
  String paneRowSemantics(
    String name,
    String kind,
    String size,
    String modified,
  ) {
    return '$name, $kind, $size, $modified';
  }

  @override
  String paneRowSemanticsFlagged(
    String name,
    String kind,
    String size,
    String modified,
  ) {
    return '$name, $kind, $size, $modified — name not valid UTF-8';
  }

  @override
  String get paneFlaggedNameTooltip =>
      'Name is not valid UTF-8 — shown approximately';

  @override
  String get paneRowKindFile => 'file';

  @override
  String get paneRowKindDirectory => 'folder';

  @override
  String get paneRowKindSymbolicLink => 'symbolic link';

  @override
  String get paneRowKindOther => 'item';

  @override
  String get goBackLabel => 'Back';

  @override
  String get goEditPathLabel => 'Edit Path';

  @override
  String get goEnclosingLabel => 'Parent Folder';

  @override
  String get goForwardLabel => 'Forward';

  @override
  String get goOpenLabel => 'Open';

  @override
  String get fileRenameLabel => 'Rename';

  @override
  String get fileGetInfoLabel => 'Get Info';

  @override
  String get paneRenameFieldLabel => 'Rename';

  @override
  String get goToFolderLabel => 'Go to Folder…';

  @override
  String get viewRefreshLabel => 'Refresh';

  @override
  String get paneFocusLeftLabel => 'Focus Left Pane';

  @override
  String get paneFocusRightLabel => 'Focus Right Pane';

  @override
  String get paneSwapFocusLabel => 'Swap Pane Focus';

  @override
  String get editSelectAllLabel => 'Select All';

  @override
  String get editInvertSelectionLabel => 'Invert Selection';

  @override
  String get selectionQuickSelectLabel => 'Quick Select';

  @override
  String get quickSelectFieldLabel => 'Quick Select';

  @override
  String get quickSelectFieldHint => 'name fragment or *.ext';

  @override
  String get quickSelectAddLabel => 'Add';

  @override
  String get quickSelectRemoveLabel => 'Remove';

  @override
  String get viewFilterLabel => 'Filter';

  @override
  String get paneFilterFieldLabel => 'Filter';

  @override
  String get paneFilterFieldHint => 'name contains';

  @override
  String paneFilterCount(int visible, int total) {
    return '$visible of $total';
  }

  @override
  String get paneFilterClear => 'Clear';

  @override
  String paneFilterNoMatch(String query) {
    return 'No items match \"$query\"';
  }

  @override
  String get panePathFieldLabel => 'Path';

  @override
  String get panePathFieldHint => '/path, ~, or a name in this folder';

  @override
  String get tabStripLabel => 'Tabs';

  @override
  String get tabNewLabel => 'New Tab';

  @override
  String get tabCloseLabel => 'Close Tab';

  @override
  String get tabReopenClosedLabel => 'Reopen Closed Tab';

  @override
  String get tabNextLabel => 'Next Tab';

  @override
  String get tabPreviousLabel => 'Previous Tab';

  @override
  String get tabLauncherTitle => 'Launcher';

  @override
  String tabTooltipRemote(String server, String path) {
    return '$server — $path';
  }

  @override
  String get tabCloseConfirmTitle => 'Close Tab?';

  @override
  String tabCloseConfirmBody(String tab) {
    return '\"$tab\" has work in progress:';
  }

  @override
  String get tabCloseTriggerNavigation => 'A navigation is still in flight.';

  @override
  String get tabCloseTriggerInlineRename => 'An inline rename is in progress.';

  @override
  String get tabCloseTriggerFolderSize =>
      'A folder-size computation is running.';

  @override
  String get tabCloseTriggerApplyToEnclosed =>
      'An apply-to-enclosed-items change is running.';

  @override
  String get tabCloseTriggerSyncAnchor => 'The tab anchors a sync pair.';

  @override
  String get tabCloseConfirmCancel => 'Cancel';

  @override
  String get tabCloseConfirmClose => 'Close';

  @override
  String get viewToggleSecondPaneLabel => 'Show/Hide Second Pane';

  @override
  String get viewToggleSyncBrowsingLabel => 'Sync Browsing';

  @override
  String get syncBrowsingChip => 'Sync browsing';

  @override
  String get syncBrowsingSuspended => 'Sync browsing suspended';

  @override
  String syncBrowsingSuspendedMissing(String name, String side) {
    return 'Sync browsing suspended — \"$name\" missing on $side';
  }

  @override
  String get syncBrowsingSuspendedOutside =>
      'Sync browsing suspended — outside the anchor subtree';

  @override
  String get syncBrowsingSideLeft => 'left';

  @override
  String get syncBrowsingSideRight => 'right';

  @override
  String get quickConnectTitle => 'Quick Connect';

  @override
  String get quickConnectAddressLabel => 'Server address';

  @override
  String get quickConnectAddressHint =>
      'user@host:port or sftp://user@host/path';

  @override
  String get quickConnectConnect => 'Connect';

  @override
  String quickConnectHintPort(String port, String host) {
    return '$port → port; use sftp://$host/$port for a folder named $port';
  }

  @override
  String quickConnectHintPath(String token) {
    return '$token is out of the port range, so it connects on port 22 and opens a folder named $token.';
  }

  @override
  String get quickConnectHintIpv6 =>
      'The host holds more than one colon. Wrap the IPv6 address in [ ], for example user@[2001:db8::1].';

  @override
  String get quickConnectPasswordStripped =>
      'A pasted password was removed. It is never stored — enter it when prompted.';

  @override
  String get quickConnectEmptyError =>
      'Enter a server address, for example user@host.';

  @override
  String get quickConnectMissingHostError =>
      'Enter a host after the @, for example user@host.';

  @override
  String get quickConnectInvalidPortError =>
      'The port in this address is not valid. Use 1–65535.';

  @override
  String get quickConnectUnsupportedSchemeError =>
      'Only sftp:// addresses are supported here.';

  @override
  String get saveFavoriteTitle => 'Save as favorite…';

  @override
  String get saveFavoriteNameLabel => 'Name';

  @override
  String get saveFavoriteSave => 'Save';

  @override
  String get saveFavoriteFailed => 'Could not save the favorite. Try again.';

  @override
  String get paneNoticeSaveFavoriteLater =>
      'Saving favorites isn\'t available yet — the sidebar arrives in a later milestone.';

  @override
  String get paneNoticePathCopied => 'Path copied to clipboard.';

  @override
  String get infoPanelLabel => 'Info';

  @override
  String get infoPanelClose => 'Close info panel';

  @override
  String get infoPanelEmpty => 'Select an item to inspect it.';

  @override
  String infoPanelSelectedCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items selected',
      one: '1 item selected',
    );
    return '$_temp0';
  }

  @override
  String get infoPanelKind => 'Kind';

  @override
  String get infoPanelSize => 'Size';

  @override
  String get infoPanelCalculateSize => 'Calculate';

  @override
  String get infoPanelCancelSize => 'Cancel';

  @override
  String infoPanelSizeProgress(String size, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$size so far — $_temp0';
  }

  @override
  String infoPanelSizeResult(String size, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$size — $_temp0';
  }

  @override
  String infoPanelSizePartial(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items could not be measured',
      one: '1 item could not be measured',
    );
    return '$_temp0';
  }

  @override
  String get infoPanelSizeFailed => 'Could not measure';

  @override
  String get infoPanelModified => 'Modified';

  @override
  String get infoPanelAccessed => 'Accessed';

  @override
  String get infoPanelPermissions => 'Permissions';

  @override
  String infoPanelPermissionsValue(String symbolic, String octal) {
    return '$symbolic ($octal)';
  }

  @override
  String get infoPanelOwner => 'Owner';

  @override
  String get infoPanelGroup => 'Group';

  @override
  String get infoPanelPath => 'Path';

  @override
  String get infoPanelCopyPath => 'Copy path';

  @override
  String get infoPanelPermOctal => 'Octal';

  @override
  String get infoPanelPermInvalid => 'Use four octal digits (0000–7777).';

  @override
  String get infoPanelPermOwner => 'Owner';

  @override
  String get infoPanelPermGroup => 'Group';

  @override
  String get infoPanelPermOthers => 'Others';

  @override
  String get infoPanelPermRead => 'Read';

  @override
  String get infoPanelPermWrite => 'Write';

  @override
  String get infoPanelPermExecute => 'Execute';

  @override
  String infoPanelPermCell(String who, String what) {
    return '$who $what';
  }

  @override
  String get infoPanelPermBlockedName =>
      'The name is not valid UTF-8 — it can\'t be sent to the server.';

  @override
  String get infoPanelPermBlockedLink =>
      'A symbolic link\'s permissions can\'t be changed.';

  @override
  String get infoPanelPermBlockedUnsupported =>
      'This filesystem can\'t change permissions.';

  @override
  String get infoPanelApplyPermissions => 'Apply';

  @override
  String get infoPanelApplyEnclosed => 'Apply to enclosed items…';

  @override
  String get infoPanelPermErrorUnsupported =>
      'This filesystem can\'t change permissions.';

  @override
  String get infoPanelPermErrorDenied =>
      'Permission denied — you may not own this item.';

  @override
  String get infoPanelPermErrorNotFound => 'The item no longer exists.';

  @override
  String get infoPanelPermError => 'The change could not be completed.';

  @override
  String get infoPanelEnclosedTitle => 'Apply to enclosed items?';

  @override
  String infoPanelEnclosedCounting(String name) {
    return 'Counting the items inside “$name”…';
  }

  @override
  String infoPanelEnclosedBody(String octal, String name) {
    return 'Apply $octal to “$name” and the items inside it?';
  }

  @override
  String infoPanelEnclosedBodyCounted(String octal, String name, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Apply $octal to “$name” and the $count items inside it?',
      one: 'Apply $octal to “$name” and the 1 item inside it?',
      zero: 'Apply $octal to “$name”? It has no changeable items inside.',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedFlaggedCounted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Includes $count items with undecodable names — they will be skipped.',
      one: 'Includes 1 item with an undecodable name — it will be skipped.',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedLinksCounted(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Includes $count symbolic links — they will be skipped.',
      one: 'Includes 1 symbolic link — it will be skipped.',
    );
    return '$_temp0';
  }

  @override
  String get infoPanelEnclosedIncomplete =>
      'The count was incomplete — items with undecodable names and symbolic links will be skipped, and some folders could not be read.';

  @override
  String get infoPanelEnclosedCancel => 'Cancel';

  @override
  String get infoPanelEnclosedApply => 'Apply';

  @override
  String infoPanelEnclosedProgress(String octal, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items changed',
      one: '1 item changed',
    );
    return 'Applying $octal… $_temp0';
  }

  @override
  String infoPanelEnclosedDone(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items changed',
      one: '1 item changed',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedCancelled(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items changed',
      one: '1 item changed',
    );
    return 'Cancelled — $_temp0';
  }

  @override
  String get infoPanelEnclosedFailed => 'Could not finish';

  @override
  String infoPanelEnclosedSkipped(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items skipped — names not valid UTF-8',
      one: '1 item skipped — name not valid UTF-8',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedLinks(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count symbolic links skipped',
      one: '1 symbolic link skipped',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedUnreadable(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count folders could not be read',
      one: '1 folder could not be read',
    );
    return '$_temp0';
  }

  @override
  String infoPanelEnclosedRefused(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items refused the change',
      one: '1 item refused the change',
    );
    return '$_temp0';
  }

  @override
  String get menuWorkspaces => 'Workspaces';

  @override
  String get workspaceSaveCommand => 'Save Workspace…';

  @override
  String get workspaceSaveTitle => 'Save Workspace';

  @override
  String get workspaceNameField => 'Workspace name';

  @override
  String get workspaceSaveAction => 'Save';

  @override
  String get workspaceSaveCancel => 'Cancel';

  @override
  String workspaceSavedToast(String name) {
    return 'Workspace \"$name\" saved';
  }

  @override
  String workspaceOpenedToast(String name) {
    return 'Workspace \"$name\" opened';
  }

  @override
  String get workspaceUndoAction => 'Undo';

  @override
  String get workspaceMenuEmpty => 'No Saved Workspaces';

  @override
  String get viewToggleActivityPanelLabel => 'Show/Hide Activity';

  @override
  String get queueTogglePauseLabel => 'Pause/Resume Transfers';

  @override
  String get activityTabActivity => 'Activity';

  @override
  String get activityTabHistory => 'History';

  @override
  String get queuePauseTooltip =>
      'Pause stops new transfers; current files finish';

  @override
  String get queueResumeTooltip => 'Resume the transfer queue';

  @override
  String get activityBandwidthButton => 'Bandwidth';

  @override
  String get activityBandwidthUnlimited => '∞';

  @override
  String get activityClearCompleted => 'Clear completed';

  @override
  String get activityClosePanel => 'Close panel';

  @override
  String get activityEmpty => 'No transfers in progress.';

  @override
  String get activityHistoryEmpty => 'No transfer history yet.';

  @override
  String get activityHistoryFilter => 'Filter history';

  @override
  String get activityHistoryClear => 'Clear History';

  @override
  String activityRestoredBanner(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers from your last session are paused',
      one: '1 transfer from your last session is paused',
    );
    return '$_temp0';
  }

  @override
  String get activityRestoredResume => 'Resume';

  @override
  String get activityRestoredDiscard => 'Discard';

  @override
  String get activityCancelTask => 'Cancel';

  @override
  String get activityRetryTask => 'Retry';

  @override
  String get activityRemoveTask => 'Remove';

  @override
  String get activityRevealInPane => 'Reveal in pane';

  @override
  String get activityCopyError => 'Copy error';

  @override
  String get activityTaskRemoteUnavailable =>
      'Remote transfers aren\'t available yet — this build moves local files only.';

  @override
  String get activitySkipItem => 'Skip';

  @override
  String get activityCancelItem => 'Cancel';

  @override
  String get activityExpandTask => 'Show files';

  @override
  String get activityCollapseTask => 'Hide files';

  @override
  String activityConflictsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items need answers',
      one: '1 item needs an answer',
    );
    return '$_temp0';
  }

  @override
  String get conflictResolve => 'Resolve…';

  @override
  String conflictDialogTitle(String name, String destination) {
    return '$name already exists in $destination';
  }

  @override
  String conflictExistingLine(String details) {
    return 'Existing: $details';
  }

  @override
  String conflictReplacingLine(String details) {
    return 'Replacing it with: $details';
  }

  @override
  String get conflictVerbReplace => 'Replace';

  @override
  String get conflictVerbReplaceIfNewer => 'Replace if newer';

  @override
  String get conflictVerbKeepBoth => 'Keep both';

  @override
  String get conflictVerbSkip => 'Skip';

  @override
  String get conflictVerbMerge => 'Merge';

  @override
  String get conflictStop => 'Stop';

  @override
  String get conflictNotNow => 'Not now';

  @override
  String conflictApplyToAll(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count remaining conflicts',
      one: '1 remaining conflict',
    );
    return 'Apply to all $_temp0 in this task';
  }

  @override
  String get quitConfirmTitle => 'Quit while transfers are running?';

  @override
  String quitConfirmBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers are running',
      one: '1 transfer is running',
    );
    return '$_temp0.';
  }

  @override
  String quitConfirmBodyRemaining(int count, String remaining) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transfers are running',
      one: '1 transfer is running',
    );
    return '$_temp0 ($remaining remaining so far).';
  }

  @override
  String get quitConfirmRestartNote =>
      'Files in progress restart from the beginning next launch.';

  @override
  String get quitPauseAndQuit => 'Pause and Quit';

  @override
  String get quitCancelTransfersAndQuit => 'Cancel Transfers and Quit';

  @override
  String get quitKeepTransferring => 'Keep Transferring';

  @override
  String get quitFlushFailedTitle => 'Transfer state could not be saved';

  @override
  String quitFlushFailedBody(String error) {
    return 'Saving the transfer journal failed: $error. The window stayed open so queued and in-flight transfers are not lost — quit again to retry.';
  }

  @override
  String get quitFlushFailedDismiss => 'Dismiss';

  @override
  String get transferStateQueued => 'Queued';

  @override
  String get transferStateScanning => 'Scanning…';

  @override
  String get transferStateRunning => 'Running';

  @override
  String get transferStatePaused => 'Paused';

  @override
  String get transferStateCompleted => 'Completed';

  @override
  String get transferStateFailed => 'Failed';

  @override
  String get transferStateCancelled => 'Cancelled';

  @override
  String get transferItemPending => 'Waiting';

  @override
  String get transferItemConflict => 'Needs an answer';

  @override
  String get transferItemSkipped => 'Skipped';

  @override
  String get activityTaskRouteLocal => 'This computer';

  @override
  String activityTaskTitleMulti(int count, String destination) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return '$_temp0 to $destination';
  }

  @override
  String activityTaskTitleDelete(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    return 'Delete $_temp0';
  }

  @override
  String get activityDeleteTrashed => 'Moved to trash';

  @override
  String get activityDeletePermanent => 'Deleted permanently';

  @override
  String activityFooterTotals(
    String done,
    String total,
    String bytes,
    String totalBytes,
  ) {
    return '$done of $total items · $bytes of $totalBytes so far';
  }

  @override
  String activityRowSemantics(String label, String state) {
    return '$label, $state';
  }

  @override
  String statusTransferChip(String rate, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count tasks',
      one: '$count task',
    );
    return '$rate · $_temp0';
  }

  @override
  String statusLimitChip(String down, String up) {
    return 'Limited: ↓$down ↑$up';
  }

  @override
  String get bandwidthPopoverTitle => 'Bandwidth limits';

  @override
  String get bandwidthDownLabel => 'Download';

  @override
  String get bandwidthUpLabel => 'Upload';

  @override
  String get bandwidthOff => 'Off';

  @override
  String get bandwidthCustom => 'Custom…';

  @override
  String get bandwidthCustomHint => 'e.g. 2 MB/s';

  @override
  String bandwidthInvalid(String max) {
    return 'Enter a rate like 500 KB/s (up to $max)';
  }

  @override
  String get bandwidthSet => 'Set';

  @override
  String get historyVerbCopy => 'Copy';

  @override
  String get historyVerbMove => 'Move';

  @override
  String get historyVerbDelete => 'Delete';

  @override
  String get resizeActivityPanel => 'Resize activity panel';

  @override
  String activityPanelHeightPx(int value) {
    return '$value px';
  }

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsBackupCommand => 'Back up bookmarks…';

  @override
  String get settingsCommand => 'Settings…';

  @override
  String get settingsGeneralSection => 'General';

  @override
  String get updateCheckEnabledLabel => 'Check for updates';

  @override
  String get updateCheckEnabledSubtitle =>
      'Checks GitHub on launch and only links to the release page — it never downloads anything.';

  @override
  String updateBannerText(String version) {
    return 'Poltergeist $version is available.';
  }

  @override
  String get updateViewRelease => 'View release';

  @override
  String get updateDismissTooltip => 'Dismiss';

  @override
  String get backupTitle => 'Bookmark backup';

  @override
  String get backupIntro =>
      'Back up bookmarks, end-to-end encrypted, through a Séance sync server. Nothing readable ever leaves this device.';

  @override
  String get backupModeSeparate =>
      'Separate backup account — a new account just for Poltergeist, on the same server. Works with every Séance version.';

  @override
  String backupModeShared(String version) {
    return 'Shared Séance account — bookmarks live alongside your Séance data, and your Séance servers appear as bookmark sources. This app will hold your Séance encryption passphrase and could read everything in the account, including saved passwords. Requires Séance $version or newer on all devices.';
  }

  @override
  String backupFleetCheckbox(String version) {
    return 'Every device that runs Séance with this account has version $version or newer.';
  }

  @override
  String get backupFleetHelper =>
      'Older Séance versions misread Poltergeist\'s records — update them everywhere before turning this on, and never add an older Séance to this account afterwards: the risk does not end at setup.';

  @override
  String get backupSharedPinDisclosure =>
      'Séance devices accept synced host-key pins without a conflict warning — including pins this app pushes.';

  @override
  String get backupRegistrationClosed =>
      'This server has registration closed. If you run it: temporarily set SEANCE_OPEN_REGISTRATION=1, create the account, then close it again — while it is open, anyone who can reach the server can register, so close it as soon as you are done. If someone else runs it, ask them to create an account for you.';

  @override
  String get backupPassphraseCallout =>
      'The encryption passphrase never leaves your devices and cannot be recovered. Losing it means losing the backup.';

  @override
  String get backupPassphraseCheckFailed =>
      'The encryption passphrase could not decrypt this account\'s records. The passphrase may be wrong, the record may be corrupt, or it may use a newer schema.';

  @override
  String get backupPaused =>
      'Backup paused until the passphrase is verified against the account\'s existing data.';

  @override
  String get backupPausedWayOutShared =>
      'Open Séance on any device signed into this account and add or edit a server, then sync — backup resumes automatically.';

  @override
  String get backupPausedWayOutSeparate =>
      'Open Poltergeist on another device signed into this account and add or edit a bookmark, then sync.';

  @override
  String get backupKdfRefusal =>
      'The sync server returned weaker password-hashing parameters than Poltergeist accepts — refusing to derive your key (possible downgrade attack).';

  @override
  String get backupServerUrlField => 'Sync server URL';

  @override
  String get backupUsernameField => 'Username';

  @override
  String get backupAccountPasswordField => 'Account password';

  @override
  String get backupAccountPasswordHelper =>
      'Authenticates with the sync server.';

  @override
  String get backupEncryptionPassphraseField => 'Encryption passphrase';

  @override
  String get backupEncryptionPassphraseHelper =>
      'Encrypts the backup; use it on every device.';

  @override
  String get backupConfirmPassphraseField => 'Confirm encryption passphrase';

  @override
  String get backupLoginTab => 'Log in';

  @override
  String get backupRegisterTab => 'Register';

  @override
  String get backupContinue => 'Continue';

  @override
  String get backupCancel => 'Cancel';

  @override
  String get backupClose => 'Close';

  @override
  String get backupRegistering => 'Registering…';

  @override
  String get backupLoggingIn => 'Logging in…';

  @override
  String backupEnrollFailed(String error) {
    return 'Failed: $error';
  }

  @override
  String get backupValidationUrl => 'Enter a valid HTTP or HTTPS server URL.';

  @override
  String get backupValidationUrlCredentials =>
      'Server URL must not include embedded credentials.';

  @override
  String get backupValidationUsername => 'Enter a username.';

  @override
  String get backupValidationPassword => 'Enter the sync account password.';

  @override
  String get backupValidationPassphrase => 'Enter the encryption passphrase.';

  @override
  String get backupValidationConfirm =>
      'Confirm the encryption passphrase before registering.';

  @override
  String get backupValidationMismatch => 'Encryption passphrases do not match.';

  @override
  String get backupEnrolledModeSeparate => 'Separate backup account';

  @override
  String get backupEnrolledModeShared => 'Shared Séance account';

  @override
  String backupEnrolledSummary(String username, String server) {
    return '$username on $server';
  }

  @override
  String get backupNow => 'Back up now';

  @override
  String get backupSyncing => 'Backing up…';

  @override
  String get backupNeverSynced => 'Not backed up yet.';

  @override
  String get backupLastSyncedJustNow => 'Last backed up just now';

  @override
  String backupLastSyncedMinutesAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last backed up $count min ago',
      one: 'Last backed up 1 min ago',
    );
    return '$_temp0';
  }

  @override
  String backupLastSyncedHoursAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last backed up $count hours ago',
      one: 'Last backed up 1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String backupLastSyncedDaysAgo(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Last backed up $count days ago',
      one: 'Last backed up 1 day ago',
    );
    return '$_temp0';
  }

  @override
  String backupSyncFailed(String error) {
    return 'Backup failed: $error';
  }

  @override
  String get backupDeadAccount =>
      'The server rejected this device\'s sign-in — the backup account may have been deleted. Bookmarks stay safe on this device and nothing is pushed until you sign in again.';

  @override
  String backupTripwireWarning(String id) {
    return 'A synced record ($id) could not be read after it decrypted — it may have been written by an older Séance version, be corrupt, or use a newer schema. Once the stale device is patched or removed, re-save the affected bookmark to restore it.';
  }

  @override
  String backupPinConflictWarning(String locator) {
    return 'A synced host key for $locator conflicts with the key this device trusts. This can mean a man-in-the-middle attack.';
  }

  @override
  String get backupPinAcceptSynced => 'Use synced key';

  @override
  String get backupPinKeepLocal => 'Keep local key';

  @override
  String get backupStoreQuarantined =>
      'The local backup record store was unreadable and has been rebuilt — deleted bookmarks may reappear, and pending edits will re-upload on the next backup.';

  @override
  String get backupDeleteAccount => 'Delete backup account…';

  @override
  String get backupDeleteAccountTitle => 'Delete backup account';

  @override
  String backupDeleteAccountBody(String username, String server) {
    return 'This deletes the account $username on $server and every backup stored on it. This cannot be undone.';
  }

  @override
  String backupDeleteConfirmHint(String username) {
    return 'Type $username to confirm.';
  }

  @override
  String get backupDeleteConfirm => 'Delete account';

  @override
  String backupDeleteFailed(String error) {
    return 'Could not delete the account: $error';
  }

  @override
  String get backupSignOut => 'Sign out on this device';

  @override
  String get backupSignOutBody =>
      'This device forgets its sign-in. The account and its data stay on the server.';

  @override
  String get backupSwitchToShared => 'Switch to shared account…';

  @override
  String get backupSwitchTitle => 'Switch to shared account';

  @override
  String get backupSwitchWorking => 'Switching…';

  @override
  String get backupSwitchConflictTitle => 'Resolve host-key conflicts';

  @override
  String backupSwitchConflictBody(String locator) {
    return 'The shared account holds a different host key for $locator. Keeping this device\'s key pushes it to every device on the account — only keep it if you are sure it is the right key.';
  }

  @override
  String get backupSwitchAdoptFleet => 'Use shared key';

  @override
  String get backupSwitchDone =>
      'Switched to the shared account. Bookmarks and host-key pins push on the next backup.';

  @override
  String backupSwitchFailed(String error) {
    return 'The switch could not finish: $error';
  }

  @override
  String get backupDeleteSeparateAfterSwitch =>
      'Also delete the separate backup account…';

  @override
  String backupDeleteSeparateBody(String username, String server) {
    return 'The separate backup account $username on $server still exists — its sign-in was kept while the switch proved out. Delete it now, or keep it.';
  }

  @override
  String get backupDeleteSeparateDecline => 'Keep it';

  @override
  String get backupDeleteSeparateLaterNote =>
      'Removing it later requires re-enrolling into it first.';

  @override
  String get backupDeleteSeparateDone =>
      'The separate backup account was deleted.';

  @override
  String backupDeleteSeparateFailed(String error) {
    return 'Could not delete the separate account: $error';
  }

  @override
  String get fileEditBuiltInLabel => 'Edit in Poltergeist';

  @override
  String get editorDiscardTitle => 'Discard unsaved changes?';

  @override
  String get editorDiscardBody =>
      'Changes not saved to the local copy will be lost.';

  @override
  String get editorDiscardKeep => 'Keep editing';

  @override
  String get editorDiscardConfirm => 'Discard';

  @override
  String get editorFindTooltip => 'Find';

  @override
  String get editorSaveLocallyTooltip => 'Save locally';

  @override
  String get editorSaveAndUploadTooltip => 'Save and upload';

  @override
  String get editorFindHint => 'Find in file';

  @override
  String get editorMatchCaseTooltip => 'Match case';

  @override
  String get editorPreviousMatchTooltip => 'Previous match';

  @override
  String get editorNextMatchTooltip => 'Next match';

  @override
  String get editorCloseSearchTooltip => 'Close search';

  @override
  String get editorNoMatches => 'No matches';

  @override
  String editorMatchCount(int current, int total) {
    return '$current/$total';
  }

  @override
  String editorMatchCountCapped(int current, int total) {
    return '$current/$total+';
  }

  @override
  String editorStatusClean(int lines, int bytes) {
    return '$lines lines · $bytes bytes';
  }

  @override
  String editorStatusDirty(int lines, int bytes) {
    return '$lines lines · $bytes bytes · Unsaved';
  }

  @override
  String get editorSavedUploadedDirty =>
      'Uploaded the saved version; newer edits remain unsaved.';

  @override
  String get editorSavedUploaded => 'Saved and uploaded.';

  @override
  String get editorSavedLocallyNotUploaded => 'Saved locally; not uploaded.';

  @override
  String get editorSavedLocally => 'Saved locally.';

  @override
  String get editorCheckoutUnavailable =>
      'The checkout store is unavailable; remote files cannot be edited.';

  @override
  String get editorConflictTitle => 'Remote file changed';

  @override
  String editorConflictBody(String name, String server) {
    return '“$name” changed (or was deleted) on $server after it was opened locally. Overwrite the remote version?';
  }

  @override
  String get editorConflictCancel => 'Cancel';

  @override
  String get editorConflictOverwrite => 'Overwrite Remote Version';

  @override
  String get fileOpenWithLabel => 'Open With';

  @override
  String get openWithBuiltInLabel => 'Built-in text editor';

  @override
  String get openWithSystemDefaultLabel => 'System default';

  @override
  String get openWithOtherLabel => 'Other…';

  @override
  String get openWithConfigureLabel => 'Configure Editors…';

  @override
  String get editorPickDialogTitle => 'Choose an editor application';

  @override
  String openWithPickedTitle(String name, String editor) {
    return 'Open “$name” with $editor?';
  }

  @override
  String openWithRememberForExtension(String editor, String extension) {
    return 'Always use $editor for .$extension files';
  }

  @override
  String get openWithCancel => 'Cancel';

  @override
  String get openWithConfirmOpen => 'Open';

  @override
  String checkoutDirtyUploadPrompt(String name) {
    return '“$name” changed locally. Upload it?';
  }

  @override
  String get checkoutDirtyUploadAction => 'Upload';

  @override
  String checkoutUploadSucceeded(String name) {
    return 'Uploaded $name';
  }

  @override
  String checkoutLocalEditsBanner(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files have local edits from a previous session.',
      one: '1 file has local edits from a previous session.',
    );
    return '$_temp0';
  }

  @override
  String get checkoutLocalEditsReview => 'Review…';

  @override
  String checkoutLocalEditsTitle(String server) {
    return 'Local edits — $server';
  }

  @override
  String get checkoutLocalEditsEmpty => 'No local edits for this server.';

  @override
  String get checkoutLocalEditsDirty => 'Modified locally';

  @override
  String get checkoutLocalEditsMissing => 'Local file missing';

  @override
  String get checkoutLocalEditsRecoveredRecord => 'Recovered';

  @override
  String get checkoutLocalEditsRecoveredSection => 'Recovered files';

  @override
  String get checkoutLocalEditsRecoveredHint =>
      'Recovered files can\'t upload from here — upload the file through a pane when you\'re done.';

  @override
  String get checkoutLocalEditsOpen => 'Open';

  @override
  String get checkoutLocalEditsUpload => 'Upload';

  @override
  String get checkoutLocalEditsDiscard => 'Discard…';

  @override
  String get checkoutLocalEditsConnectToUpload => 'Connect to upload';

  @override
  String get checkoutLocalEditsDiscardTitle => 'Discard local copy?';

  @override
  String get checkoutLocalEditsDiscardBody =>
      'Any changes not uploaded to the server are deleted.';

  @override
  String get checkoutLocalEditsDiscardCancel => 'Cancel';

  @override
  String get checkoutLocalEditsDiscardConfirm => 'Discard';

  @override
  String get checkoutLocalEditsClose => 'Close';

  @override
  String get sidebarLocalEdits => 'Local Edits…';

  @override
  String get editorSettingsClose => 'Close';

  @override
  String get editorDefaultLabel => 'Default editor';

  @override
  String get editorBuiltInOption => 'Built-in editor';

  @override
  String get editorSystemDefaultOption => 'System default';

  @override
  String editorNameOtherPlatform(String name) {
    return '$name (another platform)';
  }

  @override
  String get editorListLabel => 'External editors';

  @override
  String get editorEmptyState => 'No external editors configured.';

  @override
  String get editorAddLabel => 'Add Editor…';

  @override
  String get editorEditLabel => 'Edit…';

  @override
  String get editorRemoveLabel => 'Remove';

  @override
  String editorRemoveTitle(String name) {
    return 'Remove $name?';
  }

  @override
  String get editorRemoveBody =>
      'The application is only removed from Poltergeist settings.';

  @override
  String get editorRemoveDefaultBody =>
      'This is the current default. Removing it resets the default to System default.';

  @override
  String get editorEditTitle => 'Edit external editor';

  @override
  String get editorAddTitle => 'Add external editor';

  @override
  String get editorNameFieldLabel => 'Display name';

  @override
  String get editorExtensionsFieldLabel =>
      'Accepted file extensions (optional)';

  @override
  String get editorExtensionsFieldHint => 'dart, json, yaml, tar.gz';

  @override
  String get editorExtensionsFieldHelper =>
      'Leave blank to show this editor for every file.';

  @override
  String get editorDialogCancel => 'Cancel';

  @override
  String get editorDialogSave => 'Save';

  @override
  String get filePreviewLabel => 'Quick Look';

  @override
  String get filePreviewLabelNeutral => 'Preview';

  @override
  String get viewTogglePreviewLabel => 'Show/Hide Preview';

  @override
  String get previewPanelLabel => 'Preview';

  @override
  String get previewPanelClose => 'Close preview';

  @override
  String get previewPanelEmpty => 'Nothing to preview';

  @override
  String get previewPressSpace => 'Press Space to download a preview.';

  @override
  String get previewDownloadLabel => 'Download';

  @override
  String get previewCancelLabel => 'Cancel';

  @override
  String get previewDismissLabel => 'Dismiss';

  @override
  String previewDownloadConfirm(String size, String name) {
    return 'Download $size to preview “$name”?';
  }

  @override
  String get previewDownloadingLabel => 'Downloading preview';

  @override
  String previewDownloadProgress(String transferred, String total) {
    return '$transferred of $total';
  }

  @override
  String previewDownloadingNamed(String name, String progress) {
    return 'Downloading $name — $progress';
  }

  @override
  String previewGatePrompt(String transferred) {
    return '$transferred downloaded so far. Keep going?';
  }

  @override
  String get previewKeepDownloadingLabel => 'Keep downloading';

  @override
  String get previewDownloadFailed => 'The preview download failed.';

  @override
  String get previewDownloadCancelled => 'The preview download was cancelled.';

  @override
  String get previewRefusalOverCacheCap =>
      'This file is larger than the preview cache allows.';

  @override
  String get previewRefusalOverKindCap => 'This file is too large to preview.';

  @override
  String get previewRefusalNotText => 'This file isn\'t UTF-8 text.';

  @override
  String get previewRefusalMissing => 'This file no longer exists.';

  @override
  String get previewOpenLabel => 'Open';

  @override
  String get previewOpenWithLabel => 'Open With…';

  @override
  String get previewOpenInEditorLabel => 'Open in editor';

  @override
  String get previewTruncatedLabel => 'Preview truncated';

  @override
  String previewImageLabel(String name) {
    return 'Preview of $name';
  }

  @override
  String previewImageDimensions(int width, int height) {
    return '$width × $height pixels';
  }

  @override
  String previewSelectionSummary(int count, String size, int unknown) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items',
      one: '1 item',
    );
    String _temp1 = intl.Intl.pluralLogic(
      unknown,
      locale: localeName,
      other: ' · $unknown size unknown',
      zero: '',
    );
    return '$_temp0 · $size$_temp1';
  }

  @override
  String previewPdfPageRange(int shown, int total) {
    return 'Page 1–$shown of $total';
  }

  @override
  String previewPdfPageLabel(int page, int total) {
    return 'Page $page of $total';
  }

  @override
  String get previewPdfFailed => 'Couldn\'t render this PDF.';

  @override
  String get previewSettingsSectionTitle => 'Preview & downloads';

  @override
  String get previewCacheLimitLabel => 'Preview cache limit';

  @override
  String get previewClearCacheLabel => 'Clear Preview Cache';

  @override
  String previewCacheCleared(int mib) {
    return 'Cleared $mib MiB of cached previews.';
  }

  @override
  String get previewThresholdLabel => 'Confirm downloads larger than';

  @override
  String get previewMiBSuffix => 'MiB';

  @override
  String syncTabTitle(String name) {
    return 'Sync: $name';
  }

  @override
  String syncScanning(int leftCount, int rightCount) {
    return 'Scanning… left $leftCount entries · right $rightCount entries';
  }

  @override
  String get syncCancel => 'Cancel';

  @override
  String get syncPause => 'Pause';

  @override
  String get syncResume => 'Resume';

  @override
  String get syncModeLabel => 'Mode';

  @override
  String get syncModeUpdate => 'Update';

  @override
  String get syncModeMirror => 'Mirror';

  @override
  String get syncModeAdditive => 'Additive';

  @override
  String syncHeaderCopyNew(int count, String bytes) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copy $count new files ($bytes)',
      one: 'Copy $count new file ($bytes)',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderCreateFolders(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'create $count folders',
      one: 'create $count folder',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderUpdateFiles(int count) {
    return 'update $count';
  }

  @override
  String syncHeaderOnDestination(String destination) {
    return 'on $destination.';
  }

  @override
  String get syncHeaderBothSides => 'both sides';

  @override
  String syncHeaderCreateOnly(int count, String destination) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Create $count folders on $destination.',
      one: 'Create $count folder on $destination.',
    );
    return '$_temp0';
  }

  @override
  String get syncHeaderNothingDeleted => 'Nothing will be deleted.';

  @override
  String syncHeaderDeleteTrash(int count, String side, String trashLocation) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count files on $side (moved to trash at $trashLocation).',
      one: 'Delete $count file on $side (moved to trash at $trashLocation).',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderDeletePermanent(int count, String side) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count files on $side permanently.',
      one: 'Delete $count file on $side permanently.',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderReplaceTrash(int count, String side, String trashLocation) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Replace $count files of a different kind on $side (previous versions moved to trash at $trashLocation).',
      one:
          'Replace $count file of a different kind on $side (previous version moved to trash at $trashLocation).',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderReplacePermanent(int count, String side) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          'Replace $count files of a different kind on $side (previous versions deleted permanently).',
      one:
          'Replace $count file of a different kind on $side (previous version deleted permanently).',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderRemoveEmptyFolders(int count, String side) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Remove $count empty folders on $side.',
      one: 'Remove $count empty folder on $side.',
    );
    return '$_temp0';
  }

  @override
  String syncHeaderConflicts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count conflicts need a decision.',
      one: '$count conflict needs a decision.',
    );
    return '$_temp0';
  }

  @override
  String get syncHeaderNothingToDo => 'Both sides match. Nothing to do.';

  @override
  String get syncHeaderSizeOnlyNotice =>
      'Timestamps are unreliable on at least one side — comparing by size only.';

  @override
  String syncWarningsTitle(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count scan warnings',
      one: '$count scan warning',
    );
    return '$_temp0';
  }

  @override
  String syncFilterAll(int count) {
    return 'All ($count)';
  }

  @override
  String syncFilterNew(int count) {
    return 'New ($count)';
  }

  @override
  String syncFilterUpdates(int count) {
    return 'Updates ($count)';
  }

  @override
  String syncFilterDeletes(int count) {
    return 'Deletes ($count)';
  }

  @override
  String syncFilterConflicts(int count) {
    return 'Conflicts ($count)';
  }

  @override
  String syncFilterSkipped(int count) {
    return 'Skipped ($count)';
  }

  @override
  String get syncFilterFieldHint => 'Filter items';

  @override
  String get syncFilterOnlyActions => 'Only show actions';

  @override
  String get syncReasonOnlyHere => 'only exists here';

  @override
  String syncReasonNewerHere(String sourceAge, String destinationAge) {
    return 'newer here ($sourceAge vs $destinationAge)';
  }

  @override
  String syncReasonSizesDiffer(String leftSize, String rightSize) {
    return 'sizes differ ($leftSize vs $rightSize)';
  }

  @override
  String get syncReasonContentsDiffer => 'contents differ';

  @override
  String get syncReasonBothChanged => 'changed on both sides';

  @override
  String syncReasonTypeDiffers(String leftKind, String rightKind) {
    return 'type differs ($leftKind here, $rightKind there)';
  }

  @override
  String get syncReasonExcluded => 'excluded by rule';

  @override
  String get syncReasonCaseCollision => 'names differ only by case';

  @override
  String get syncReasonNormalizationCollision =>
      'names differ only by Unicode form';

  @override
  String get syncReasonInvalidName => 'name invalid on Windows';

  @override
  String get syncReasonScanError => 'couldn\'t scan — subtree excluded';

  @override
  String get syncReasonEqual => 'identical';

  @override
  String get syncReasonSymlink => 'symbolic link — skipped';

  @override
  String get syncKindFile => 'file';

  @override
  String get syncKindFolder => 'folder';

  @override
  String get syncKindSymlink => 'symbolic link';

  @override
  String get syncKindOther => 'other';

  @override
  String get syncSideLeft => 'left';

  @override
  String get syncSideRight => 'right';

  @override
  String get syncOverrideSkip => 'Skip';

  @override
  String get syncOverrideCopyLeftToRight => 'Copy left → right';

  @override
  String get syncOverrideCopyRightToLeft => 'Copy right → left';

  @override
  String get syncOverrideDelete => 'Delete';

  @override
  String get syncOverrideReset => 'Reset to suggested';

  @override
  String syncOverrideSkippedTypeDiffers(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count type-differs rows skipped — replacing a different kind stays a per-item choice',
      one:
          '$count type-differs row skipped — replacing a different kind stays a per-item choice',
    );
    return '$_temp0';
  }

  @override
  String get syncResolveConflictsLabel => 'Resolve conflicts:';

  @override
  String get syncResolveNewerWins => 'Newer wins';

  @override
  String get syncResolveKeepLeft => 'Keep left';

  @override
  String get syncResolveKeepRight => 'Keep right';

  @override
  String get syncResolveSkipAll => 'Skip all';

  @override
  String get syncSaveAsFavorite => 'Save as Favorite…';

  @override
  String syncRunCopyFiles(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copy $count Files',
      one: 'Copy 1 File',
    );
    return '$_temp0';
  }

  @override
  String syncRunCopyPart(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Copy $count',
      one: 'Copy 1',
    );
    return '$_temp0';
  }

  @override
  String syncRunCreateFolders(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Create $count Folders',
      one: 'Create $count Folder',
    );
    return '$_temp0';
  }

  @override
  String syncRunDeletePart(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Delete $count',
      one: 'Delete 1',
    );
    return '$_temp0';
  }

  @override
  String get syncRunNothingToDo => 'Nothing to Do';

  @override
  String syncHeavySuggestion(String name, int count) {
    return '$name is $count of these files — exclude?';
  }

  @override
  String get syncDeleteConfirmTitle => 'Confirm deletions';

  @override
  String syncDeleteConfirmFraction(
    int count,
    int total,
    String side,
    String pct,
  ) {
    return 'This will delete $count of $total files on $side — more than $pct of that side. Type DELETE to continue.';
  }

  @override
  String syncDeleteConfirmFloor(int count, int total, String side) {
    return 'This will delete $count of $total files on $side — 90 % or more of that side. Type DELETE to continue.';
  }

  @override
  String get syncDeleteConfirmFieldHint => 'DELETE';

  @override
  String get syncDeleteConfirmHalf => 'half';

  @override
  String get syncDeleteConfirmButton => 'Delete';

  @override
  String get syncMaxDeleteTitle => 'Too many deletions';

  @override
  String syncMaxDeleteBody(int count, String side, int cap) {
    return 'This plan would delete $count files on $side — over the $cap-file cap. Run stays disabled rather than silently diverging the destination. Raise the cap in the pair\'s rules to run it.';
  }

  @override
  String get syncMaxDeleteSaveAdjust => 'Save as Favorite & Adjust Rules…';

  @override
  String get syncRetryFailed => 'Retry Failed';

  @override
  String get syncRestoreTrashed => 'Restore Trashed Files…';

  @override
  String get syncCopyReport => 'Copy Report';

  @override
  String get syncCopyRsyncCommand => 'Copy as rsync Command';

  @override
  String get syncCopiedRsyncCommand => 'Copied rsync command';

  @override
  String get syncCopiedRsyncCommandPermanent =>
      'Copied rsync command — deletions are permanent when pasted';

  @override
  String get syncRsyncCopyFailed =>
      'Couldn\'t copy the rsync command — clipboard unavailable';

  @override
  String get syncHeavySuggestionAccept => 'Exclude';

  @override
  String get syncRestoreDialogTitle => 'Restore Trashed Files';

  @override
  String syncRestoreSummary(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count files will be restored from trash.',
      one: '$count file will be restored from trash.',
    );
    return '$_temp0';
  }

  @override
  String get syncRestoreButton => 'Restore';

  @override
  String syncRestoreResult(int restored, int skipped) {
    String _temp0 = intl.Intl.pluralLogic(
      restored,
      locale: localeName,
      other: 'Restored $restored files',
      one: 'Restored $restored file',
    );
    String _temp1 = intl.Intl.pluralLogic(
      skipped,
      locale: localeName,
      other: ' — $skipped skipped',
      one: ' — $skipped skipped',
      zero: '',
    );
    return '$_temp0$_temp1';
  }

  @override
  String get syncDirectionLeftToRight => 'Left to right';

  @override
  String get syncDirectionRightToLeft => 'Right to left';

  @override
  String get syncDirectionBothWays => 'Both ways';

  @override
  String get syncEditorOptionsSection => 'Options';

  @override
  String get syncEditorTitle => 'Sync pair';

  @override
  String get syncEditorNameLabel => 'Name';

  @override
  String get syncEditorDeletionsLabel => 'Deletions';

  @override
  String get syncEditorDeletionsNone => 'Never delete';

  @override
  String get syncEditorDeletionsTrash => 'Move to trash';

  @override
  String get syncEditorDeletionsPermanent => 'Delete permanently';

  @override
  String get syncEditorBackupsLabel => 'Overwrite backups';

  @override
  String get syncEditorBackupsTrash => 'Keep in trash';

  @override
  String get syncEditorBackupsNone => 'None';

  @override
  String get syncEditorComparisonLabel => 'Compare by';

  @override
  String get syncEditorComparisonSizeMtime => 'Size and modification time';

  @override
  String get syncEditorComparisonSizeOnly => 'Size only';

  @override
  String get syncEditorComparisonContentHash => 'Content hash';

  @override
  String get syncEditorConflictLabel => 'Conflicts';

  @override
  String get syncEditorConflictAsk => 'Ask each time';

  @override
  String get syncEditorConflictNewerWins => 'Newer wins';

  @override
  String get syncEditorConflictKeepLeft => 'Keep left';

  @override
  String get syncEditorConflictKeepRight => 'Keep right';

  @override
  String get syncEditorConflictSkip => 'Skip';

  @override
  String get syncEditorMaxDeleteLabel => 'Deletion cap (maxDelete)';

  @override
  String get syncEditorFractionWarnLabel => 'Typed-confirmation threshold';

  @override
  String get syncEditorExcludeLabel => 'Exclude rules';

  @override
  String get syncEditorIncludeHidden => 'Include hidden files';

  @override
  String get syncEditorTrashLeftLabel => 'Left trash path';

  @override
  String get syncEditorTrashRightLabel => 'Right trash path';

  @override
  String get syncEditorPathHint => '/path';

  @override
  String get syncEditorMtimeToleranceLabel =>
      'Modification-time tolerance (seconds)';

  @override
  String get syncEditorPreserveMtime => 'Preserve modification times';

  @override
  String get syncEditorConcurrencyLabel => 'Transfer concurrency';

  @override
  String get syncEditorCaseLeftLabel => 'Left case sensitivity';

  @override
  String get syncEditorCaseRightLabel => 'Right case sensitivity';

  @override
  String get syncEditorCaseAuto => 'Detect automatically';

  @override
  String get syncEditorCaseSensitive => 'Case-sensitive';

  @override
  String get syncEditorCaseInsensitive => 'Case-insensitive';

  @override
  String get syncEditorSave => 'Save';

  @override
  String get syncEditorSaveAndRescan => 'Save & Rescan';

  @override
  String get syncNewSavedSync => 'New Saved Sync…';

  @override
  String syncPairLabel(String left, String right) {
    return '$left ⇄ $right';
  }

  @override
  String get syncSynchronizePanes => 'Synchronize Panes';

  @override
  String get syncRescan => 'Rescan';

  @override
  String syncScanFailed(String error) {
    return 'The scan could not complete — $error';
  }

  @override
  String get syncRemoteUnavailable =>
      'Remote sync pairs aren\'t available yet — remote filesystems arrive with the engine-protocol transfer verbs.';

  @override
  String syncRunFailed(String error) {
    return 'The run failed — $error';
  }

  @override
  String syncSummaryCounts(int done, int failed, int skipped) {
    String _temp0 = intl.Intl.pluralLogic(
      done,
      locale: localeName,
      other: '$done done',
      one: '$done done',
    );
    String _temp1 = intl.Intl.pluralLogic(
      failed,
      locale: localeName,
      other: '$failed failed',
      one: '$failed failed',
    );
    String _temp2 = intl.Intl.pluralLogic(
      skipped,
      locale: localeName,
      other: '$skipped skipped',
      one: '$skipped skipped',
    );
    return '$_temp0 · $_temp1 · $_temp2';
  }

  @override
  String get syncPairLocalLabel => 'local';

  @override
  String syncSavedFavoriteToast(String name) {
    return 'Saved sync \"$name\" added to favorites';
  }

  @override
  String get quickOpenCommandLabel => 'Quick Open…';

  @override
  String get quickOpenTitle => 'Quick Open';

  @override
  String get quickOpenFieldHint => 'Type a command or location';

  @override
  String get quickOpenHintMacos =>
      'Enter runs · ⌥Enter opens in the other pane · ⌘Enter opens in a new tab · Esc closes';

  @override
  String get quickOpenHint =>
      'Enter runs · Alt+Enter opens in the other pane · Ctrl+Enter opens in a new tab · Esc closes';

  @override
  String get quickOpenSectionCommands => 'Commands';

  @override
  String get quickOpenSectionFavorites => 'Favorites';

  @override
  String get quickOpenSectionRecents => 'Recents';

  @override
  String quickOpenNoMatches(String query) {
    return 'No matches for “$query”';
  }

  @override
  String quickOpenRowSemantics(String label, String section) {
    return '$label, $section';
  }

  @override
  String quickOpenMenuPath(String menu, String label) {
    return '$menu ▸ $label';
  }

  @override
  String get quickOpenRecentUnavailable => 'This server is no longer available';

  @override
  String get commandDisabledNoBack => 'No earlier location';

  @override
  String get commandDisabledNoForward => 'No later location';

  @override
  String get commandDisabledNoListing => 'Requires a browsed folder';

  @override
  String get commandDisabledNoSelection => 'Requires a selected item';

  @override
  String get commandDisabledNoPreview => 'Previews are unavailable';

  @override
  String get commandDisabledNoSidebar => 'Requires the sidebar';

  @override
  String get commandDisabledSyncAnchors =>
      'Requires browsed folders on both panes';

  @override
  String get commandDisabledNoTab => 'Requires an open tab';

  @override
  String get commandDisabledNoClosedTab => 'No recently closed tab';

  @override
  String get commandDisabledMultipleTabs => 'Requires at least two tabs';

  @override
  String get commandDisabledNoQueue => 'Requires the transfer queue';

  @override
  String get commandDisabledNoPlan => 'Requires an open sync plan';

  @override
  String get commandDisabledNoBookmarks => 'Requires saved favorites';

  @override
  String get commandDisabledBusy =>
      'Unavailable while another command is running';

  @override
  String get commandDisabledNoEditors =>
      'Requires a configured external editor';

  @override
  String get commandDisabledNoWorkspaces => 'No saved workspaces';

  @override
  String get sidebarImportSshConfig => 'Import from ssh config…';

  @override
  String get sidebarCatalogSection => 'Séance servers';

  @override
  String get sidebarCatalogUngrouped => 'Ungrouped';

  @override
  String get sidebarCatalogEmpty =>
      'No servers on this account yet. Add one in Séance and sync to see it here.';

  @override
  String get sidebarCatalogNoMatches => 'No servers match the filter.';

  @override
  String get sidebarCatalogFilter => 'Filter servers';

  @override
  String sidebarCatalogFilterCount(int matches, int total) {
    return '$matches of $total';
  }

  @override
  String sidebarCatalogFilterCountOpenFirst(int matches, int total) {
    return '$matches of $total · ↵ opens the first';
  }

  @override
  String get sidebarCatalogFilterClear => 'Clear filter';

  @override
  String get sidebarCatalogSyncNow => 'Sync now';

  @override
  String get sidebarCatalogSyncing => 'Syncing…';

  @override
  String sidebarCatalogSyncFailed(String error) {
    return 'Last sync failed: $error';
  }

  @override
  String panePathSegmentGoTo(String segment) {
    return 'Go to $segment';
  }

  @override
  String sidebarSectionSemantics(String title, String count) {
    return '$title, $count';
  }
}

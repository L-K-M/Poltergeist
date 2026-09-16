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
  String get connectionsTitle => 'Connections';

  @override
  String get connectionsLoading => 'Loading servers';

  @override
  String get connectionsEmpty => 'No servers yet.';

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
  String get paneOpeningHome => 'Opening home…';

  @override
  String paneConnectingTo(String label) {
    return 'Connecting to $label…';
  }

  @override
  String get paneEmptyFolder => 'This folder is empty.';

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
  String get connectionsOpenInPane => 'Open in Pane';

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
}

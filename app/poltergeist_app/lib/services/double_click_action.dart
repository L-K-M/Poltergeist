/// The persisted "Double-click action" preference (02 §2.6 —
/// Transmit's default-behavior-as-preference): what the Open verb
/// does to a FILE under every activation gesture (double-click,
/// ⌘↓/⌘O on macOS, Enter on Windows/Linux). Folders never consult it —
/// they always navigate.
///
/// Read at every file open by [PaneController.openEntry] through the
/// tab's live `doubleClickAction` field; the owning strip stamps the
/// setting on its tabs. The Settings > Editing dropdown (06 §8) is the
/// write surface once it lands; persistence lives in `AppPreferences`.
enum DoubleClickAction {
  /// Open — the default. Local files launch in the OS default
  /// application through the engine's shell-open seam; remote files
  /// answer the unavailable notice (managed checkout is 06's).
  open,

  /// Edit in Poltergeist — the value is registered and persisted now;
  /// choosing it surfaces the not-yet notice (the editor is 06's).
  edit,

  /// Transfer to other pane — registered and persisted now; choosing
  /// it surfaces the not-yet notice (the transfer queue is M4's).
  transfer,

  /// Do nothing — a file activation is exactly that: inert.
  nothing,
}

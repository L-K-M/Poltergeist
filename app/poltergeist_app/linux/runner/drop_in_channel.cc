#include "drop_in_channel.h"

#include <cstring>

#include <gtk/gtk.h>

// A GTK drop destination on an extra window's view, the way desktop_drop
// makes the main window's: file URIs from any app, and plain text for the
// sources that offer paths as a string. GTK has no enter signal, so the
// first motion of a drag reports "entered". GTK emits "drag-leave" just
// before "drag-drop" too, so a drop arrives after its "exited"; the Dart
// side takes a drop on its own. Only local paths are reported: a remote URI
// is nothing a pane could copy from.

namespace {

constexpr char kChannelName[] = "poltergeist/dropin";

// WindowDropInMethod and WindowDropInKey in Dart.
constexpr char kEnteredMethod[] = "entered";
constexpr char kUpdatedMethod[] = "updated";
constexpr char kExitedMethod[] = "exited";
constexpr char kDroppedMethod[] = "dropped";
constexpr char kViewIdKey[] = "viewId";
constexpr char kPositionKey[] = "position";
constexpr char kPathsKey[] = "paths";

// Where the engine keeps its channel, which every extra view shares.
constexpr char kEngineDataKey[] = "poltergeist-drop-in";

struct ViewDropIn {
  FlMethodChannel* channel;  // Owned by the engine.
  int64_t view_id;
  // Between a drag's first motion over the view and its leave.
  gboolean hovering;
  // KDE sends a motion as the window takes focus after a drop from
  // another app, with no drag behind it (desktop_drop's workaround).
  gboolean ignore_next_motion;
  gboolean is_kde;
};

FlValue* arguments(ViewDropIn* self) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(map, kViewIdKey, fl_value_new_int(self->view_id));
  return map;
}

void set_position(FlValue* map, gint x, gint y) {
  const double point[] = {static_cast<double>(x), static_cast<double>(y)};
  fl_value_set_string_take(map, kPositionKey,
                           fl_value_new_float_list(point, 2));
}

void send(ViewDropIn* self, const char* method, FlValue* map) {
  fl_method_channel_invoke_method(self->channel, method, map, nullptr, nullptr,
                                  nullptr);
  fl_value_unref(map);
}

gboolean on_drag_motion(GtkWidget* widget, GdkDragContext* context, gint x,
                        gint y, guint time, gpointer user_data) {
  auto* self = static_cast<ViewDropIn*>(user_data);
  if (self->ignore_next_motion) {
    self->ignore_next_motion = FALSE;
    return FALSE;
  }
  FlValue* map = arguments(self);
  set_position(map, x, y);
  send(self, self->hovering ? kUpdatedMethod : kEnteredMethod, map);
  self->hovering = TRUE;
  // GTK_DEST_DEFAULT_MOTION answers the source.
  return FALSE;
}

void on_drag_leave(GtkWidget* widget, GdkDragContext* context, guint time,
                   gpointer user_data) {
  auto* self = static_cast<ViewDropIn*>(user_data);
  if (!self->hovering) return;
  self->hovering = FALSE;
  send(self, kExitedMethod, arguments(self));
}

// The local path an item names, or nullptr: a file URI, or an absolute
// path as a plain-text source offers it.
gchar* local_path(const gchar* item) {
  if (item == nullptr || item[0] == '\0') return nullptr;
  if (item[0] == '/') return g_strdup(item);
  if (!g_str_has_prefix(item, "file:")) return nullptr;
  return g_filename_from_uri(item, nullptr, nullptr);
}

void on_drag_data_received(GtkWidget* widget, GdkDragContext* context, gint x,
                           gint y, GtkSelectionData* data, guint info,
                           guint time, gpointer user_data) {
  auto* self = static_cast<ViewDropIn*>(user_data);
  self->hovering = FALSE;
  g_auto(GStrv) uris = gtk_selection_data_get_uris(data);
  if (uris == nullptr) {
    g_autofree gchar* text =
        reinterpret_cast<gchar*>(gtk_selection_data_get_text(data));
    if (text != nullptr) uris = g_strsplit_set(text, "\r\n", -1);
  }

  FlValue* paths = fl_value_new_list();
  for (gchar** item = uris; item != nullptr && *item != nullptr; item++) {
    g_autofree gchar* path = local_path(g_strstrip(*item));
    if (path != nullptr) fl_value_append_take(paths, fl_value_new_string(path));
  }
  FlValue* map = arguments(self);
  set_position(map, x, y);
  fl_value_set_string_take(map, kPathsKey, paths);
  send(self, kDroppedMethod, map);
}

gboolean on_focus_in(GtkWidget* widget, GdkEventFocus* event,
                     gpointer user_data) {
  auto* self = static_cast<ViewDropIn*>(user_data);
  if (self->is_kde) self->ignore_next_motion = TRUE;
  return FALSE;
}

gboolean is_kde_session() {
  const gchar* desktop = g_getenv("XDG_CURRENT_DESKTOP");
  if (desktop == nullptr) return FALSE;
  g_autofree gchar* lower = g_ascii_strdown(desktop, -1);
  return strcmp(lower, "kde") == 0 || strcmp(lower, "plasma") == 0;
}

FlMethodChannel* engine_channel(FlEngine* engine) {
  auto* channel = static_cast<FlMethodChannel*>(
      g_object_get_data(G_OBJECT(engine), kEngineDataKey));
  if (channel != nullptr) return channel;
  // Nothing calls in: the channel only reports.
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel = fl_method_channel_new(fl_engine_get_binary_messenger(engine),
                                  kChannelName, FL_METHOD_CODEC(codec));
  g_object_set_data_full(G_OBJECT(engine), kEngineDataKey, channel,
                         g_object_unref);
  return channel;
}

}  // namespace

void drop_in_channel_add_view(FlView* view) {
  const int64_t view_id = fl_view_get_id(view);
  if (view_id < 0) return;
  auto* self = g_new0(ViewDropIn, 1);
  self->channel = engine_channel(fl_view_get_engine(view));
  self->view_id = view_id;
  self->is_kde = is_kde_session();
  g_object_set_data_full(G_OBJECT(view), kEngineDataKey, self, g_free);

  // Copies only: a drop from another app carries no move the app could
  // honour (00 D14).
  static GtkTargetEntry text_target = {const_cast<gchar*>("STRING"),
                                       GTK_TARGET_OTHER_APP, 0};
  GtkWidget* widget = GTK_WIDGET(view);
  gtk_drag_dest_set(widget, GTK_DEST_DEFAULT_ALL, &text_target, 1,
                    GDK_ACTION_COPY);
  gtk_drag_dest_add_uri_targets(widget);
  g_signal_connect(widget, "drag-motion", G_CALLBACK(on_drag_motion), self);
  g_signal_connect(widget, "drag-leave", G_CALLBACK(on_drag_leave), self);
  g_signal_connect(widget, "drag-data-received",
                   G_CALLBACK(on_drag_data_received), self);
  g_signal_connect(widget, "focus-in-event", G_CALLBACK(on_focus_in), self);
}

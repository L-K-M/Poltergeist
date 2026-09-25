#include "drag_out_channel.h"

#include <cstring>

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <gtk/gtk.h>

// The Linux side of `poltergeist/dragout` (protocol: the library doc of
// lib/services/os_drag_out.dart). Dart decides what to drag; this file
// only turns a `startDrag` request into a GTK drag session that serves
// `text/uri-list`, and reports the session's end.
//
// GTK needs the press that began the gesture to start a drag, and by the
// time Dart asks (the pointer has left the window) that event is long
// gone, so an emission hook keeps a copy of the last primary press on
// this window. Starting the session also takes the pointer grab, which
// swallows the real button release: Flutter's embedder would then still
// believe the button is down and drop the next press. So before the
// session starts, a synthesized release at the current pointer position
// goes through gtk_main_do_event, the same route a real one takes.
//
// Deletes never happen here (D15): "drag-data-delete" is not handled, so
// a destination that picked MOVE moves the file itself (file managers
// do) and nothing is ever unlinked on its behalf.

namespace {

constexpr char kChannelName[] = "poltergeist/dragout";

struct DragOutChannel {
  FlMethodChannel* channel;
  GtkWidget* view;
  // Copy of the last primary press on this window, or nullptr.
  GdkEvent* last_press;
  gulong press_hook;
  guint press_signal;
  // The running session, if any.
  gchar* session_id;
  gchar** uris;
  GdkDragContext* context;
  gboolean failed;
};

FlValue* refusal(const gchar* reason, const gchar* message) {
  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "started", fl_value_new_bool(FALSE));
  fl_value_set_string_take(result, "reason", fl_value_new_string(reason));
  if (message != nullptr) {
    fl_value_set_string_take(result, "message", fl_value_new_string(message));
  }
  return result;
}

void respond(FlMethodCall* call, FlValue* result) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(call, response, nullptr);
  fl_value_unref(result);
}

const gchar* string_at(FlValue* map, const gchar* key) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

// A [x, y] list (Dart doubles) as two numbers; FALSE when malformed.
gboolean point_at(FlValue* map, const gchar* key, double* x, double* y) {
  FlValue* value = fl_value_lookup_string(map, key);
  if (value == nullptr) return FALSE;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT_LIST &&
      fl_value_get_length(value) == 2) {
    const double* data = fl_value_get_float_list(value);
    *x = data[0];
    *y = data[1];
    return TRUE;
  }
  if (fl_value_get_type(value) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(value) != 2) {
    return FALSE;
  }
  FlValue* first = fl_value_get_list_value(value, 0);
  FlValue* second = fl_value_get_list_value(value, 1);
  if (fl_value_get_type(first) != FL_VALUE_TYPE_FLOAT ||
      fl_value_get_type(second) != FL_VALUE_TYPE_FLOAT) {
    return FALSE;
  }
  *x = fl_value_get_float(first);
  *y = fl_value_get_float(second);
  return TRUE;
}

void clear_session(DragOutChannel* self) {
  g_clear_pointer(&self->session_id, g_free);
  g_clear_pointer(&self->uris, g_strfreev);
  g_clear_object(&self->context);
  self->failed = FALSE;
}

gboolean on_button_press_hook(GSignalInvocationHint* hint,
                              guint n_params,
                              const GValue* params,
                              gpointer user_data) {
  auto* self = static_cast<DragOutChannel*>(user_data);
  if (n_params < 2 || !G_VALUE_HOLDS(&params[0], GTK_TYPE_WIDGET)) {
    return TRUE;
  }
  GtkWidget* widget = GTK_WIDGET(g_value_get_object(&params[0]));
  auto* event = static_cast<GdkEvent*>(g_value_get_boxed(&params[1]));
  if (event == nullptr || event->type != GDK_BUTTON_PRESS ||
      event->button.button != GDK_BUTTON_PRIMARY) {
    return TRUE;
  }
  if (gtk_widget_get_toplevel(widget) != gtk_widget_get_toplevel(self->view)) {
    return TRUE;
  }
  g_clear_pointer(&self->last_press, gdk_event_free);
  self->last_press = gdk_event_copy(event);
  // Keep the hook installed.
  return TRUE;
}

// Ends the embedder's view of the press (see the file comment).
void synthesize_release(DragOutChannel* self, GdkDevice* pointer) {
  GdkEvent* release = gdk_event_copy(self->last_press);
  release->type = GDK_BUTTON_RELEASE;
  GdkWindow* window = release->button.window;
  double x = release->button.x;
  double y = release->button.y;
  if (window != nullptr) {
    gdk_window_get_device_position_double(window, pointer, &x, &y, nullptr);
  }
  double root_x = release->button.x_root;
  double root_y = release->button.y_root;
  gdk_device_get_position_double(pointer, nullptr, &root_x, &root_y);
  release->button.x = x;
  release->button.y = y;
  release->button.x_root = root_x;
  release->button.y_root = root_y;
  release->button.state =
      static_cast<GdkModifierType>(release->button.state | GDK_BUTTON1_MASK);
  gtk_main_do_event(release);
  gdk_event_free(release);
}

void set_icon(GdkDragContext* context, GtkWidget* view, FlValue* args) {
  FlValue* image = fl_value_lookup_string(args, "image");
  double anchor_x = 0;
  double anchor_y = 0;
  if (image == nullptr ||
      fl_value_get_type(image) != FL_VALUE_TYPE_UINT8_LIST ||
      !point_at(args, "imageAnchor", &anchor_x, &anchor_y)) {
    gtk_drag_set_icon_default(context);
    return;
  }
  g_autoptr(GdkPixbufLoader) loader = gdk_pixbuf_loader_new();
  gboolean loaded =
      gdk_pixbuf_loader_write(loader, fl_value_get_uint8_list(image),
                              fl_value_get_length(image), nullptr) &&
      gdk_pixbuf_loader_close(loader, nullptr);
  GdkPixbuf* pixbuf = loaded ? gdk_pixbuf_loader_get_pixbuf(loader) : nullptr;
  if (pixbuf == nullptr) {
    gtk_drag_set_icon_default(context);
    return;
  }
  // The PNG is rendered at Flutter's device pixel ratio, which on Linux
  // is the widget's scale factor.
  const int scale = gtk_widget_get_scale_factor(view);
  cairo_surface_t* surface = gdk_cairo_surface_create_from_pixbuf(
      pixbuf, scale, gtk_widget_get_window(view));
  // GTK puts the pointer at the surface's (0, 0): shift by the anchor.
  cairo_surface_set_device_offset(surface, -anchor_x * scale,
                                  -anchor_y * scale);
  gtk_drag_set_icon_surface(context, surface);
  cairo_surface_destroy(surface);
}

void start_drag(DragOutChannel* self, FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  if (fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    respond(call, refusal("failed", "startDrag expects a map"));
    return;
  }
  const gchar* session_id = string_at(args, "sessionId");
  FlValue* items = fl_value_lookup_string(args, "items");
  if (session_id == nullptr || items == nullptr ||
      fl_value_get_type(items) != FL_VALUE_TYPE_LIST ||
      fl_value_get_length(items) == 0) {
    respond(call, refusal("failed", "startDrag needs a sessionId and items"));
    return;
  }
  if (self->session_id != nullptr) {
    respond(call, refusal("busy", nullptr));
    return;
  }

  g_autoptr(GPtrArray) uris = g_ptr_array_new_with_free_func(g_free);
  for (size_t i = 0; i < fl_value_get_length(items); i++) {
    FlValue* item = fl_value_get_list_value(items, i);
    const gchar* kind = fl_value_get_type(item) == FL_VALUE_TYPE_MAP
                            ? string_at(item, "kind")
                            : nullptr;
    const gchar* path = kind == nullptr ? nullptr : string_at(item, "path");
    // Only local files travel on Linux: no promise standard exists.
    if (g_strcmp0(kind, "file") != 0 || path == nullptr) {
      respond(call, refusal("unsupportedItems", nullptr));
      return;
    }
    g_autoptr(GError) error = nullptr;
    gchar* uri = g_filename_to_uri(path, nullptr, &error);
    if (uri == nullptr) {
      respond(call, refusal("failed", error->message));
      return;
    }
    g_ptr_array_add(uris, uri);
  }
  g_ptr_array_add(uris, nullptr);

  if (self->last_press == nullptr) {
    respond(call, refusal("noPointerEvent", nullptr));
    return;
  }
  GdkDevice* pointer = gdk_event_get_device(self->last_press);
  GdkWindow* window = gtk_widget_get_window(self->view);
  GdkModifierType mask = static_cast<GdkModifierType>(0);
  if (pointer == nullptr || window == nullptr) {
    respond(call, refusal("noPointerEvent", nullptr));
    return;
  }
  gdk_window_get_device_position_double(window, pointer, nullptr, nullptr,
                                        &mask);
  if ((mask & GDK_BUTTON1_MASK) == 0) {
    respond(call, refusal("buttonReleased", nullptr));
    return;
  }

  // Never an ask or a delete: copy, move, and link at most (D15).
  int actions = 0;
  FlValue* operations = fl_value_lookup_string(args, "allowedOperations");
  if (operations != nullptr &&
      fl_value_get_type(operations) == FL_VALUE_TYPE_LIST) {
    for (size_t i = 0; i < fl_value_get_length(operations); i++) {
      FlValue* operation = fl_value_get_list_value(operations, i);
      if (fl_value_get_type(operation) != FL_VALUE_TYPE_STRING) continue;
      const gchar* name = fl_value_get_string(operation);
      if (g_strcmp0(name, "copy") == 0) actions |= GDK_ACTION_COPY;
      if (g_strcmp0(name, "move") == 0) actions |= GDK_ACTION_MOVE;
      if (g_strcmp0(name, "link") == 0) actions |= GDK_ACTION_LINK;
    }
  }
  if (actions == 0) actions = GDK_ACTION_COPY;

  synthesize_release(self, pointer);

  GtkTargetList* targets = gtk_target_list_new(nullptr, 0);
  gtk_target_list_add_uri_targets(targets, 0);
  GdkDragContext* context = gtk_drag_begin_with_coordinates(
      self->view, targets, static_cast<GdkDragAction>(actions),
      GDK_BUTTON_PRIMARY, self->last_press, -1, -1);
  gtk_target_list_unref(targets);
  if (context == nullptr) {
    respond(call, refusal("failed", "gtk_drag_begin refused the drag"));
    return;
  }
  set_icon(context, self->view, args);

  self->session_id = g_strdup(session_id);
  self->uris = reinterpret_cast<gchar**>(g_ptr_array_free(
      static_cast<GPtrArray*>(g_steal_pointer(&uris)), FALSE));
  self->context = GDK_DRAG_CONTEXT(g_object_ref(context));
  self->failed = FALSE;

  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "started", fl_value_new_bool(TRUE));
  respond(call, result);
}

void method_call_cb(FlMethodChannel* channel,
                    FlMethodCall* call,
                    gpointer user_data) {
  auto* self = static_cast<DragOutChannel*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "startDrag") == 0) {
    start_drag(self, call);
    return;
  }
  if (strcmp(method, "promiseProgress") == 0) {
    // Linux serves no promises; progress has nowhere to go.
    fl_method_call_respond_success(call, nullptr, nullptr);
    return;
  }
  fl_method_call_respond_not_implemented(call, nullptr);
}

void on_drag_data_get(GtkWidget* widget,
                      GdkDragContext* context,
                      GtkSelectionData* data,
                      guint info,
                      guint time,
                      gpointer user_data) {
  auto* self = static_cast<DragOutChannel*>(user_data);
  if (context != self->context || self->uris == nullptr) return;
  gtk_selection_data_set_uris(data, self->uris);
}

gboolean on_drag_failed(GtkWidget* widget,
                        GdkDragContext* context,
                        GtkDragResult result,
                        gpointer user_data) {
  auto* self = static_cast<DragOutChannel*>(user_data);
  if (context == self->context) self->failed = TRUE;
  // Let GTK run its snap-back animation.
  return FALSE;
}

void on_drag_end(GtkWidget* widget,
                 GdkDragContext* context,
                 gpointer user_data) {
  auto* self = static_cast<DragOutChannel*>(user_data);
  if (context != self->context || self->session_id == nullptr) return;
  const gchar* operation = "none";
  if (!self->failed) {
    const GdkDragAction action = gdk_drag_context_get_selected_action(context);
    if (action & GDK_ACTION_MOVE) {
      operation = "move";
    } else if (action & GDK_ACTION_LINK) {
      operation = "link";
    } else if (action & GDK_ACTION_COPY) {
      operation = "copy";
    }
  }
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "sessionId",
                           fl_value_new_string(self->session_id));
  fl_value_set_string_take(args, "operation", fl_value_new_string(operation));
  fl_method_channel_invoke_method(self->channel, "sessionEnded", args, nullptr,
                                  nullptr, nullptr);
  clear_session(self);
}

void on_view_destroy(GtkWidget* widget, gpointer user_data) {
  auto* self = static_cast<DragOutChannel*>(user_data);
  g_signal_remove_emission_hook(self->press_signal, self->press_hook);
  fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                            nullptr);
  clear_session(self);
  g_clear_pointer(&self->last_press, gdk_event_free);
  g_clear_object(&self->channel);
  g_free(self);
}

}  // namespace

void drag_out_channel_register(FlView* view) {
  auto* self = g_new0(DragOutChannel, 1);
  self->view = GTK_WIDGET(view);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), kChannelName,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb,
                                            self, nullptr);
  self->press_signal = g_signal_lookup("button-press-event", GTK_TYPE_WIDGET);
  self->press_hook = g_signal_add_emission_hook(
      self->press_signal, 0, on_button_press_hook, self, nullptr);
  g_signal_connect(view, "drag-data-get", G_CALLBACK(on_drag_data_get), self);
  g_signal_connect(view, "drag-failed", G_CALLBACK(on_drag_failed), self);
  g_signal_connect(view, "drag-end", G_CALLBACK(on_drag_end), self);
  g_signal_connect(view, "destroy", G_CALLBACK(on_view_destroy), self);
}

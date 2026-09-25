#include "workspace_windows.h"

#include <cstring>

#include "window_title.h"

namespace {

constexpr char kChannel[] = "poltergeist/windows";

// WindowHostMethod, WindowHostEvent, and WindowHostKey in Dart.
constexpr char kIsAvailableMethod[] = "isAvailable";
constexpr char kCreateMethod[] = "create";
constexpr char kDestroyMethod[] = "destroy";
constexpr char kActivateMethod[] = "activate";
constexpr char kHideMethod[] = "hide";
constexpr char kIsFullScreenMethod[] = "isFullScreen";
constexpr char kSetFullScreenMethod[] = "setFullScreen";
constexpr char kActivatedEvent[] = "activated";
constexpr char kCloseRequestedEvent[] = "closeRequested";
constexpr char kViewIdKey[] = "viewId";
constexpr char kFullScreenKey[] = "fullScreen";

constexpr char kBadArgsError[] = "BAD_ARGS";
constexpr char kCreateFailedError[] = "CREATE_FAILED";

constexpr char kWindowTitle[] = "Poltergeist";

// The workspace's minimum content size (_minimumContentSize in
// lib/services/desktop_window_lifecycle.dart), which window_manager applies
// to the main window.
constexpr int kMinimumWidth = 720;
constexpr int kMinimumHeight = 480;

// The engine's implicit view: the main window.
constexpr int64_t kMainViewId = 0;

constexpr char kHostDataKey[] = "poltergeist-workspace-windows";
constexpr char kWindowDataKey[] = "poltergeist-workspace-window";

struct WorkspaceWindowsHost {
  GtkApplication* application;  // Not owned.
  GtkWindow* main_window;       // Not owned; owns this host.
  FlEngine* engine;
  FlMethodChannel* channel;
  // View id (gint64*, owned) -> its extra window (GTK owns the toplevel).
  GHashTable* windows;
};

// One extra window's signal context; freed with the window.
struct ExtraWindow {
  WorkspaceWindowsHost* host;
  int64_t view_id;
};

void send_event(WorkspaceWindowsHost* host, const char* event,
                int64_t view_id) {
  g_autoptr(FlValue) arguments = fl_value_new_map();
  fl_value_set_string_take(arguments, kViewIdKey, fl_value_new_int(view_id));
  fl_method_channel_invoke_method(host->channel, event, arguments, nullptr,
                                  nullptr, nullptr);
}

GtkWindow* window_for(WorkspaceWindowsHost* host, int64_t view_id) {
  if (view_id == kMainViewId) {
    return host->main_window;
  }
  return GTK_WINDOW(g_hash_table_lookup(host->windows, &view_id));
}

// The close button, the window menu, Alt+F4: Dart decides, and destroys the
// window once its widgets are gone (or quits, for the last window).
gboolean window_delete_cb(GtkWidget* widget, GdkEvent* event,
                          gpointer user_data) {
  auto* window = static_cast<ExtraWindow*>(user_data);
  send_event(window->host, kCloseRequestedEvent, window->view_id);
  return TRUE;
}

gboolean window_focus_cb(GtkWidget* widget, GdkEvent* event,
                         gpointer user_data) {
  auto* window = static_cast<ExtraWindow*>(user_data);
  send_event(window->host, kActivatedEvent, window->view_id);
  return FALSE;
}

gboolean main_window_focus_cb(GtkWidget* widget, GdkEvent* event,
                              gpointer user_data) {
  send_event(static_cast<WorkspaceWindowsHost*>(user_data), kActivatedEvent,
             kMainViewId);
  return FALSE;
}

void window_destroyed_cb(GtkWidget* widget, gpointer user_data) {
  auto* window = static_cast<ExtraWindow*>(user_data);
  g_hash_table_remove(window->host->windows, &window->view_id);
}

// Shown on its first frame, like the main window, so it never flashes the
// view's background before Flutter has drawn.
void first_frame_cb(FlView* view, gpointer user_data) {
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  gtk_widget_show(toplevel);
  gtk_window_present(GTK_WINDOW(toplevel));
}

FlMethodResponse* create_window(WorkspaceWindowsHost* host) {
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(host->application));
  window_title_apply(window, kWindowTitle);
  // The main window's size: a new window looks like the one it came from.
  gint width = 0;
  gint height = 0;
  gtk_window_get_size(host->main_window, &width, &height);
  gtk_window_set_default_size(window, width, height);

  FlView* view = fl_view_new_for_engine(host->engine);
  // Transparent, like the main window, so the GTK background (which follows
  // the desktop's light/dark theme) shows through during a resize.
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#00000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_set_size_request(GTK_WIDGET(view), kMinimumWidth, kMinimumHeight);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  const int64_t view_id = fl_view_get_id(view);
  if (view_id < 0) {
    gtk_widget_destroy(GTK_WIDGET(window));
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        kCreateFailedError, "the engine gave the view no id", nullptr));
  }

  auto* context = g_new(ExtraWindow, 1);
  context->host = host;
  context->view_id = view_id;
  g_object_set_data_full(G_OBJECT(window), kWindowDataKey, context, g_free);
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_cb),
                   context);
  g_signal_connect(window, "focus-in-event", G_CALLBACK(window_focus_cb),
                   context);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroyed_cb),
                   context);
  g_signal_connect(view, "first-frame", G_CALLBACK(first_frame_cb), nullptr);

  auto* key = g_new(gint64, 1);
  *key = view_id;
  g_hash_table_insert(host->windows, key, window);

  gtk_widget_realize(GTK_WIDGET(view));
  gtk_widget_grab_focus(GTK_WIDGET(view));
  return FL_METHOD_RESPONSE(
      fl_method_success_response_new(fl_value_new_int(view_id)));
}

// The view id argument every other method carries, or -1.
int64_t view_id_argument(FlMethodCall* call) {
  FlValue* arguments = fl_method_call_get_args(call);
  if (arguments == nullptr ||
      fl_value_get_type(arguments) != FL_VALUE_TYPE_MAP) {
    return -1;
  }
  FlValue* view_id = fl_value_lookup_string(arguments, kViewIdKey);
  if (view_id == nullptr || fl_value_get_type(view_id) != FL_VALUE_TYPE_INT) {
    return -1;
  }
  return fl_value_get_int(view_id);
}

bool is_full_screen(GtkWindow* window) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(window));
  return gdk_window != nullptr &&
         (gdk_window_get_state(gdk_window) & GDK_WINDOW_STATE_FULLSCREEN) != 0;
}

FlMethodResponse* handle(WorkspaceWindowsHost* host, FlMethodCall* call) {
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, kIsAvailableMethod) == 0) {
    return FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(TRUE)));
  }
  if (strcmp(method, kCreateMethod) == 0) {
    return create_window(host);
  }

  const bool known = strcmp(method, kDestroyMethod) == 0 ||
                     strcmp(method, kActivateMethod) == 0 ||
                     strcmp(method, kHideMethod) == 0 ||
                     strcmp(method, kIsFullScreenMethod) == 0 ||
                     strcmp(method, kSetFullScreenMethod) == 0;
  if (!known) {
    return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  GtkWindow* window = window_for(host, view_id_argument(call));
  if (window == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        kBadArgsError, "no window has that view id", nullptr));
  }

  if (strcmp(method, kDestroyMethod) == 0) {
    // The main window's view cannot leave the engine; window_manager
    // destroys that window, as the app quits.
    if (window != host->main_window) {
      gtk_widget_destroy(GTK_WIDGET(window));
    }
  } else if (strcmp(method, kActivateMethod) == 0) {
    // Shows it again if it was hidden, and raises it either way.
    gtk_window_present(window);
  } else if (strcmp(method, kHideMethod) == 0) {
    gtk_widget_hide(GTK_WIDGET(window));
  } else if (strcmp(method, kIsFullScreenMethod) == 0) {
    return FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(is_full_screen(window))));
  } else {
    FlValue* arguments = fl_method_call_get_args(call);
    FlValue* full_screen = fl_value_lookup_string(arguments, kFullScreenKey);
    if (full_screen == nullptr ||
        fl_value_get_type(full_screen) != FL_VALUE_TYPE_BOOL) {
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          kBadArgsError, "setFullScreen needs a fullScreen bool", nullptr));
    }
    if (fl_value_get_bool(full_screen)) {
      gtk_window_fullscreen(window);
    } else {
      gtk_window_unfullscreen(window);
    }
  }
  return FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                    gpointer user_data) {
  auto* host = static_cast<WorkspaceWindowsHost*>(user_data);
  g_autoptr(FlMethodResponse) response = handle(host, call);
  fl_method_call_respond(call, response, nullptr);
}

void host_free(gpointer data) {
  auto* host = static_cast<WorkspaceWindowsHost*>(data);
  // The extra windows go with the main one. Collected first: each destroy
  // removes its own entry.
  GList* windows = g_hash_table_get_values(host->windows);
  for (GList* link = windows; link != nullptr; link = link->next) {
    gtk_widget_destroy(GTK_WIDGET(link->data));
  }
  g_list_free(windows);
  g_hash_table_destroy(host->windows);
  fl_method_channel_set_method_call_handler(host->channel, nullptr, nullptr,
                                            nullptr);
  g_clear_object(&host->channel);
  g_clear_object(&host->engine);
  g_free(host);
}

}  // namespace

void workspace_windows_install(GtkApplication* application,
                               GtkWindow* main_window,
                               FlView* main_view) {
  auto* host = g_new0(WorkspaceWindowsHost, 1);
  host->application = application;
  host->main_window = main_window;
  host->engine = FL_ENGINE(g_object_ref(fl_view_get_engine(main_view)));
  host->windows =
      g_hash_table_new_full(g_int64_hash, g_int64_equal, g_free, nullptr);

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  host->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(host->engine), kChannel,
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(host->channel, method_call_cb,
                                            host, nullptr);
  g_signal_connect(main_window, "focus-in-event",
                   G_CALLBACK(main_window_focus_cb), host);

  g_object_set_data_full(G_OBJECT(main_window), kHostDataKey, host,
                         host_free);
}

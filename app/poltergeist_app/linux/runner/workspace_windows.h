#ifndef RUNNER_WORKSPACE_WINDOWS_H_
#define RUNNER_WORKSPACE_WINDOWS_H_

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The workspace windows' host (00 D39): serves "poltergeist/windows" on the
// app's engine (the protocol is the library doc of
// lib/services/workspace_windows/window_host.dart).
//
// Every extra window is a GTK window holding an FlView made for the app's
// running engine (fl_view_new_for_engine), so it renders in the same isolate
// as the main window and shares its state. Closing one only reports
// "closeRequested"; Dart drops the window's widgets and then asks for
// "destroy", which removes the view from the engine. Unlike a second engine
// (the Settings window), a view can go without disposing an engine, so
// nothing here trips over the EGL display the engines share.
//
// Owned by [main_window]: the extra windows are destroyed with it, as the
// app quits.
void workspace_windows_install(GtkApplication* application,
                               GtkWindow* main_window,
                               FlView* main_view);

#endif  // RUNNER_WORKSPACE_WINDOWS_H_

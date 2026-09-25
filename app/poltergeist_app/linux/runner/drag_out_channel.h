#ifndef RUNNER_DRAG_OUT_CHANNEL_H_
#define RUNNER_DRAG_OUT_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// OS drag-out's Linux backend (00 D14's 2026-09-25 amendment): serves the
// `poltergeist/dragout` channel documented in
// lib/services/os_drag_out.dart. A GTK drag source on the Flutter view
// carrying local items as `text/uri-list`; remote items (file promises)
// are refused, since Linux has no promise standard the file managers
// share. Lives as long as the view.
void drag_out_channel_register(FlView* view);

#endif  // RUNNER_DRAG_OUT_CHANNEL_H_

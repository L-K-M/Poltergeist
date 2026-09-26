#ifndef RUNNER_DROP_IN_CHANNEL_H_
#define RUNNER_DROP_IN_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Files dropped from other apps onto an extra workspace window (00 D39):
// reports the drags over |view| on "poltergeist/dropin", each tagged with
// the view's id (the protocol is the library doc of
// lib/services/window_drop_in.dart). desktop_drop serves the main window's
// view only, and says nothing of which view a drag is over.
//
// Lives as long as the view.
void drop_in_channel_add_view(FlView* view);

#endif  // RUNNER_DROP_IN_CHANNEL_H_

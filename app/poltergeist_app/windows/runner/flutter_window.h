#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "drag_out.h"
#include "trash_operations.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // OS drag-out (00 D14's 2026-09-25 amendment). Declared after the
  // controller so it is destroyed first: its channel lives on the
  // engine's messenger.
  std::unique_ptr<DragOut> drag_out_;

  // The D15 trash channel (03 §7.1). Declaration order is teardown
  // order in reverse: trash_channel_ is destroyed first (no new work is
  // accepted), then trash_operations_ (the STA worker drains its queue
  // and joins), then flutter_controller_ (the engine they report to
  // stays alive until every result has completed).
  std::unique_ptr<TrashOperations> trash_operations_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      trash_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

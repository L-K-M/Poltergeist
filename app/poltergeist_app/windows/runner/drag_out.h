#ifndef RUNNER_DRAG_OUT_H_
#define RUNNER_DRAG_OUT_H_

#include <windows.h>

#include <ole2.h>

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>

#include <memory>
#include <optional>
#include <string>

#include <wrl/client.h>

// OS drag-out's Windows backend (00 D14's 2026-09-25 amendment): serves
// the `poltergeist/dragout` channel documented in
// lib/services/os_drag_out.dart. Local items only: a pane row drag that
// leaves the window becomes a shell drag of the shell's own data object
// for those files (CF_HDROP plus the shell formats) under the
// Dart-rendered drag image. Remote items (virtual files) are refused;
// the Dart side declares `localFiles` here and never sends them.
//
// Everything runs on the platform thread. startDrag only prepares the
// session and replies; the modal drag loop starts on a later
// message-loop turn (HandleWindowMessage), so the channel reply never
// waits on it and the loop never runs inside the engine's message
// dispatch.
class DragOut {
 public:
  // |window| is the top-level window that receives the start message;
  // |view| is the Flutter view's HWND, whose press the session ends.
  DragOut(flutter::BinaryMessenger* messenger, HWND window, HWND view);
  ~DragOut();

  DragOut(const DragOut&) = delete;
  DragOut& operator=(const DragOut&) = delete;

  // Runs the session startDrag accepted when |message| is the start
  // message, and returns true: the drag has then already ended. May
  // outlive this object: the window can be torn down while the drag
  // loop runs, and nothing here is touched after that.
  bool HandleWindowMessage(UINT message);

 private:
  // A point in the Flutter view's logical pixels, as Dart sends it.
  struct LogicalPoint {
    double x = 0;
    double y = 0;
  };

  struct Session {
    std::string id;
    Microsoft::WRL::ComPtr<IDataObject> data;
    DWORD effects = DROPEFFECT_COPY;
    // Where the embedder's press ends: the pointer as Dart saw it,
    // outside the view.
    LogicalPoint position;
  };

  void StartDrag(const flutter::EncodableValue* arguments,
                 flutter::MethodResult<flutter::EncodableValue>& result);
  void EndEmbedderPress(const LogicalPoint& position);
  void FinishSession(const std::string& session_id, const char* operation);

  HWND window_;
  HWND view_;
  // A private, registered message: no plugin's WM_APP range can collide.
  UINT start_message_;
  bool ole_initialized_ = false;
  // The accepted session, from startDrag until sessionEnded. A second
  // startDrag meanwhile is refused as busy.
  std::optional<Session> session_;
  // Whether the drag loop is on the stack.
  bool running_ = false;
  // Cleared by the destructor; the drag loop holds a copy (see
  // HandleWindowMessage).
  std::shared_ptr<bool> alive_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_DRAG_OUT_H_

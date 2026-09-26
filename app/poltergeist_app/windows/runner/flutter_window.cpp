#include "flutter_window.h"

#include <optional>
#include <string>

#include <windows.h>

#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

// The channel arguments arrive as UTF-8 strings; the shell APIs want
// UTF-16.
std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         utf8.data(),
                                         static_cast<int>(utf8.size()),
                                         nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                        static_cast<int>(utf8.size()), wide.data(), length);
  return wide;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // The D15 trash channel (03 §7.1, 00 D15): the engine isolate reaches
  // it through the app-served port relay; here IFileOperation work is
  // marshaled onto the dedicated STA worker in TrashOperations, so COM
  // apartment rules are honored and a long recycle-bin move never parks
  // the platform thread.
  trash_operations_ = std::make_unique<TrashOperations>();
  trash_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "poltergeist/trash",
          &flutter::StandardMethodCodec::GetInstance());
  trash_channel_->SetMethodCallHandler(
      [operations = trash_operations_.get()](const auto& call, auto result) {
        if (call.method_name() != "trash") {
          result->NotImplemented();
          return;
        }
        const auto* raw_arguments = call.arguments();
        const auto* arguments =
            raw_arguments == nullptr
                ? nullptr
                : std::get_if<flutter::EncodableMap>(raw_arguments);
        const std::string* path = nullptr;
        if (arguments != nullptr) {
          const auto it = arguments->find(flutter::EncodableValue("path"));
          if (it != arguments->end()) {
            path = std::get_if<std::string>(&it->second);
          }
        }
        if (path == nullptr || path->empty()) {
          result->Error("TRASH_BAD_ARGS",
                        "the trash call needs a 'path' string argument",
                        flutter::EncodableValue());
          return;
        }
        const std::wstring wide_path = WideFromUtf8(*path);
        if (wide_path.empty()) {
          // The UTF-8 argument was non-empty, so an empty wide string
          // means MultiByteToWideChar rejected the bytes.
          result->Error("TRASH_BAD_ARGS", "path is not valid UTF-8",
                        flutter::EncodableValue());
          return;
        }
        operations->Trash(wide_path, std::move(result));
      });

  // OS drag-out (00 D14's 2026-09-25 amendment): a pane row drag that
  // leaves the window becomes a shell drag of its local files. The
  // session starts on its own message-loop turn (MessageHandler below).
  drag_out_ = std::make_unique<DragOut>(
      flutter_controller_->engine()->messenger(), GetHandle(),
      flutter_controller_->view()->GetNativeWindow());

  // Settings in a window of its own (settings_window.h).
  settings_window_ = std::make_unique<SettingsWindowHost>(
      GetHandle(), flutter_controller_->engine()->messenger());

  // More workspace windows on this engine (workspace_windows.h).
  workspace_windows_ = std::make_unique<WorkspaceWindowsHost>(
      GetHandle(), flutter_controller_->engine()->messenger());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Tear down in submission order: the channel first (no new trash
  // calls), then the worker (pending jobs finish and join), and only
  // then the engine — a completing MethodResult needs it alive. The
  // drag-out channel, the settings window, and the workspace windows go
  // before the engine too.
  drag_out_ = nullptr;
  settings_window_ = nullptr;
  workspace_windows_ = nullptr;
  if (trash_channel_) {
    // The channel's destruction alone does not unregister the handler
    // from the engine messenger — clear it explicitly so a late call
    // cannot reach the worker being freed next.
    trash_channel_->SetMethodCallHandler(nullptr);
  }
  trash_channel_ = nullptr;
  trash_operations_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // A drag-out session the channel accepted runs here, after its reply.
  if (drag_out_ && drag_out_->HandleWindowMessage(message)) {
    return 0;
  }

  // The main window's activation, for the workspace windows' active one.
  if (workspace_windows_) {
    workspace_windows_->HandleMainWindowMessage(message, wparam);
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

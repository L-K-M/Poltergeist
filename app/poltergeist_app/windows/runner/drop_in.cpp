#include "drop_in.h"

#include <shellapi.h>

#include <flutter_windows.h>

#include <memory>
#include <string>
#include <utility>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// WindowDropInMethod and WindowDropInKey in Dart.
constexpr char kEnteredMethod[] = "entered";
constexpr char kUpdatedMethod[] = "updated";
constexpr char kExitedMethod[] = "exited";
constexpr char kDroppedMethod[] = "dropped";
constexpr char kViewIdKey[] = "viewId";
constexpr char kPositionKey[] = "position";
constexpr char kPathsKey[] = "paths";

FORMATETC HdropFormat() {
  return {CF_HDROP, nullptr, DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
}

bool CarriesFiles(IDataObject* data) {
  FORMATETC format = HdropFormat();
  return data != nullptr && data->QueryGetData(&format) == S_OK;
}

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int length = WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
      static_cast<int>(wide.size()), nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string utf8(static_cast<size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, wide.data(),
                      static_cast<int>(wide.size()), utf8.data(), length,
                      nullptr, nullptr);
  return utf8;
}

// The paths a CF_HDROP carries, whatever their length (desktop_drop reads
// at most MAX_PATH characters of each).
EncodableList DroppedPaths(IDataObject* data) {
  EncodableList paths;
  FORMATETC format = HdropFormat();
  STGMEDIUM medium = {};
  if (data == nullptr || data->GetData(&format, &medium) != S_OK) {
    return paths;
  }
  auto drop = static_cast<HDROP>(GlobalLock(medium.hGlobal));
  if (drop != nullptr) {
    const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
    for (UINT i = 0; i < count; i++) {
      const UINT length = DragQueryFileW(drop, i, nullptr, 0);
      if (length == 0) {
        continue;
      }
      std::wstring path(length + 1, L'\0');
      DragQueryFileW(drop, i, path.data(), length + 1);
      path.resize(length);
      std::string utf8 = Utf8FromWide(path);
      if (!utf8.empty()) {
        paths.emplace_back(std::move(utf8));
      }
    }
    GlobalUnlock(medium.hGlobal);
  }
  ReleaseStgMedium(&medium);
  return paths;
}

}  // namespace

ViewDropTarget* ViewDropTarget::Register(
    flutter::MethodChannel<EncodableValue>* channel,
    int64_t view_id,
    HWND view) {
  auto* target = new ViewDropTarget(channel, view_id, view);
  // OLE is initialized on this thread already: the main window's
  // desktop_drop and drag-out both need it.
  target->registered_ = SUCCEEDED(RegisterDragDrop(view, target));
  return target;
}

void ViewDropTarget::Revoke() {
  if (registered_) {
    RevokeDragDrop(view_);
    registered_ = false;
  }
  Release();
}

ViewDropTarget::ViewDropTarget(flutter::MethodChannel<EncodableValue>* channel,
                               int64_t view_id,
                               HWND view)
    : channel_(channel), view_id_(view_id), view_(view) {}

HRESULT ViewDropTarget::DragEnter(IDataObject* data,
                                  DWORD key_state,
                                  POINTL point,
                                  DWORD* effect) {
  accepts_ = CarriesFiles(data);
  if (!accepts_) {
    *effect = DROPEFFECT_NONE;
    return S_OK;
  }
  *effect &= DROPEFFECT_COPY;
  Send(kEnteredMethod, point, true);
  return S_OK;
}

HRESULT ViewDropTarget::DragOver(DWORD key_state,
                                 POINTL point,
                                 DWORD* effect) {
  if (!accepts_) {
    *effect = DROPEFFECT_NONE;
    return S_OK;
  }
  *effect &= DROPEFFECT_COPY;
  Send(kUpdatedMethod, point, true);
  return S_OK;
}

HRESULT ViewDropTarget::DragLeave() {
  if (accepts_) {
    Send(kExitedMethod, POINTL{}, false);
  }
  accepts_ = false;
  return S_OK;
}

HRESULT ViewDropTarget::Drop(IDataObject* data,
                             DWORD key_state,
                             POINTL point,
                             DWORD* effect) {
  if (!accepts_) {
    *effect = DROPEFFECT_NONE;
    return S_OK;
  }
  accepts_ = false;
  *effect &= DROPEFFECT_COPY;
  EncodableValue paths(DroppedPaths(data));
  Send(kDroppedMethod, point, true, &paths);
  return S_OK;
}

HRESULT ViewDropTarget::QueryInterface(REFIID iid, void** object) {
  if (iid == IID_IUnknown || iid == IID_IDropTarget) {
    *object = static_cast<IDropTarget*>(this);
    AddRef();
    return S_OK;
  }
  *object = nullptr;
  return E_NOINTERFACE;
}

ULONG ViewDropTarget::AddRef() {
  return InterlockedIncrement(&references_);
}

ULONG ViewDropTarget::Release() {
  const LONG count = InterlockedDecrement(&references_);
  if (count == 0) {
    delete this;
  }
  return count;
}

void ViewDropTarget::Send(const char* method,
                          POINTL point,
                          bool with_position,
                          EncodableValue* paths) {
  EncodableMap arguments{
      {EncodableValue(kViewIdKey), EncodableValue(view_id_)},
  };
  if (with_position) {
    // Screen pixels to the view's client pixels, then its DPI over 96:
    // the embedder's device pixel ratio.
    POINT client = {point.x, point.y};
    ScreenToClient(view_, &client);
    const double scale = FlutterDesktopGetDpiForHWND(view_) / 96.0;
    arguments[EncodableValue(kPositionKey)] = EncodableValue(EncodableList{
        EncodableValue(client.x / scale),
        EncodableValue(client.y / scale),
    });
  }
  if (paths != nullptr) {
    arguments[EncodableValue(kPathsKey)] = std::move(*paths);
  }
  channel_->InvokeMethod(
      method, std::make_unique<EncodableValue>(std::move(arguments)));
}

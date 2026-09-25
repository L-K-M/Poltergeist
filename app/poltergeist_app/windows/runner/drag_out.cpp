#include "drag_out.h"

#include <shlobj.h>
#include <shobjidl.h>
#include <wincodec.h>

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <sstream>
#include <utility>
#include <vector>

// The Windows side of `poltergeist/dragout` (protocol: the library doc
// of lib/services/os_drag_out.dart). Dart decides what to drag; this
// file turns a `startDrag` request into a shell drag and reports its
// end.
//
// The data object is the one Explorer itself drags: the parent folder's
// IShellFolder::GetUIObjectOf for the dragged children, which renders
// CF_HDROP, CFSTR_SHELLIDLIST and the other shell formats, and keeps
// what the drag image helper stores through SetData. (SHCreateDataObject
// only promises the shell ID list, and many targets, desktop_drop among
// them, read CF_HDROP alone.)
//
// The Flutter embedder captures the mouse on the press that began the
// row drag, and the drag loop's own capture swallows the real release,
// so the embedder would still believe the button is down and read the
// next press as a move. Before the loop starts, a synthesized
// WM_LBUTTONUP resets it (and releases its capture) the way a real one
// would. It sits at the position Dart sent, which is outside the view,
// not at the cursor: it can reach Flutter before Dart handles the
// `started` reply, and over a pane Flutter would read it as an in-app
// drop of the items the session carries.
//
// Moves are never offered, whatever Dart sends: the owner's rule (00
// D14's drag-out amendment) is that no trash may take the source, and
// the Recycle Bin takes a drop as DROPEFFECT_MOVE. So the loop is
// offered copy and link at most (AllowedEffects): the Recycle Bin has
// no move to take, and Explorer copies where it would have moved.
//
// Deletes never happen here either (D15). DROPEFFECT_MOVE would only
// mean the target wants the source deleted; nothing here ever unlinks
// a file on a target's behalf, even for a target that reports a move it
// was never offered.

using Microsoft::WRL::ComPtr;

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodResult = flutter::MethodResult<EncodableValue>;

// BEGIN poltergeist/dragout CONTRACT
// test/windows_drag_out_runner_test.dart parses this block and checks
// every string against the Dart side (lib/services/os_drag_out.dart):
// keys against what Dart sends and accepts, with the wire types the
// parsers below expect; methods, refusal reasons and operations against
// the Dart names. One constant per line; the suffix says what it is.
constexpr char kChannelName[] = "poltergeist/dragout";
constexpr char kStartDragMethod[] = "startDrag";
constexpr char kPromiseProgressMethod[] = "promiseProgress";
constexpr char kSessionEndedMethod[] = "sessionEnded";
constexpr char kSessionIdKey[] = "sessionId";
constexpr char kPositionKey[] = "position";
constexpr char kItemsKey[] = "items";
constexpr char kAllowedOperationsKey[] = "allowedOperations";
constexpr char kImageKey[] = "image";
constexpr char kImageSizeKey[] = "imageSize";
constexpr char kImageAnchorKey[] = "imageAnchor";
constexpr char kKindKey[] = "kind";
constexpr char kPathKey[] = "path";
constexpr char kStartedKey[] = "started";
constexpr char kReasonKey[] = "reason";
constexpr char kMessageKey[] = "message";
constexpr char kOperationKey[] = "operation";
constexpr char kFileKind[] = "file";
constexpr char kCopyOperation[] = "copy";
constexpr char kMoveOperation[] = "move";
constexpr char kLinkOperation[] = "link";
constexpr char kNoOperation[] = "none";
constexpr char kButtonReleasedReason[] = "buttonReleased";
constexpr char kNoPointerEventReason[] = "noPointerEvent";
constexpr char kBusyReason[] = "busy";
constexpr char kUnsupportedItemsReason[] = "unsupportedItems";
constexpr char kFailedReason[] = "failed";
// END poltergeist/dragout CONTRACT

constexpr wchar_t kStartMessageName[] = L"Poltergeist.DragOut.Start";

// The Dart image is a name pill a few hundred logical pixels wide; a
// side beyond this is a malformed request, not a picture worth
// allocating for.
constexpr UINT kMaxImageSide = 2048;

// CLR_NONE (commctrl.h): the drag image has an alpha channel, no color
// key.
constexpr COLORREF kNoColorKey = 0xFFFFFFFF;

// What a drag loop is ever offered: never DROPEFFECT_MOVE (see the file
// comment). There is no delete effect to leave out: Windows has none.
constexpr DWORD kOfferedEffects = DROPEFFECT_COPY | DROPEFFECT_LINK;

// What a target may report back, a move included: reading one is how a
// misbehaving target is still understood, and nothing acts on it.
constexpr DWORD kReportedEffects =
    DROPEFFECT_COPY | DROPEFFECT_MOVE | DROPEFFECT_LINK;

bool PrimaryButtonDown() {
  return (GetKeyState(VK_LBUTTON) & 0x8000) != 0;
}

std::string HresultMessage(const char* what, HRESULT hr) {
  std::ostringstream out;
  out << what << " failed (HRESULT 0x" << std::hex
      << static_cast<unsigned long>(hr) << ')';
  return out.str();
}

// The channel arguments arrive as UTF-8; the shell wants UTF-16. Empty
// on invalid input.
std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         utf8.data(),
                                         static_cast<int>(utf8.size()),
                                         nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                      static_cast<int>(utf8.size()), wide.data(), length);
  return wide;
}

const EncodableValue* ValueAt(const EncodableMap& map, const char* key) {
  const auto it = map.find(EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

const std::string* StringAt(const EncodableMap& map, const char* key) {
  const EncodableValue* value = ValueAt(map, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

// A Dart double (an int only if a future codec ever narrows one).
bool NumberFrom(const EncodableValue& value, double* number) {
  if (const auto* as_double = std::get_if<double>(&value)) {
    *number = *as_double;
    return true;
  }
  if (const auto* as_int32 = std::get_if<int32_t>(&value)) {
    *number = static_cast<double>(*as_int32);
    return true;
  }
  if (const auto* as_int64 = std::get_if<int64_t>(&value)) {
    *number = static_cast<double>(*as_int64);
    return true;
  }
  return false;
}

// An [x, y] pair. Dart sends a List<double>, which the codec carries as
// a list of doubles; a Float64List would arrive as a double vector.
bool PairAt(const EncodableMap& map, const char* key, double* x, double* y) {
  const EncodableValue* value = ValueAt(map, key);
  if (value == nullptr) {
    return false;
  }
  if (const auto* list = std::get_if<EncodableList>(value)) {
    return list->size() == 2 && NumberFrom((*list)[0], x) &&
           NumberFrom((*list)[1], y);
  }
  if (const auto* doubles = std::get_if<std::vector<double>>(value)) {
    if (doubles->size() != 2) {
      return false;
    }
    *x = (*doubles)[0];
    *y = (*doubles)[1];
    return true;
  }
  return false;
}

void Refuse(MethodResult& result,
            const char* reason,
            const std::string& message = std::string()) {
  EncodableMap reply{
      {EncodableValue(kStartedKey), EncodableValue(false)},
      {EncodableValue(kReasonKey), EncodableValue(reason)},
  };
  if (!message.empty()) {
    reply[EncodableValue(kMessageKey)] = EncodableValue(message);
  }
  result.Success(EncodableValue(reply));
}

// Copy and link at most (kOfferedEffects), never an empty mask: only
// those two names map to an effect, so a move Dart never sends could
// not be offered either.
DWORD AllowedEffects(const EncodableMap& arguments) {
  DWORD effects = DROPEFFECT_NONE;
  const EncodableValue* value = ValueAt(arguments, kAllowedOperationsKey);
  const auto* operations =
      value == nullptr ? nullptr : std::get_if<EncodableList>(value);
  if (operations != nullptr) {
    for (const EncodableValue& operation : *operations) {
      const auto* name = std::get_if<std::string>(&operation);
      if (name == nullptr) {
        continue;
      }
      if (*name == kCopyOperation) {
        effects |= DROPEFFECT_COPY;
      } else if (*name == kLinkOperation) {
        effects |= DROPEFFECT_LINK;
      }
    }
  }
  effects &= kOfferedEffects;
  return effects == DROPEFFECT_NONE ? DROPEFFECT_COPY : effects;
}

// A well-behaved target reports one effect. desktop_drop (our own drag
// coming back in) leaves the whole allowed mask in place, so a mask
// reads as the least destructive effect in it.
const char* OperationName(DWORD effect) {
  effect &= kReportedEffects;
  if ((effect & DROPEFFECT_COPY) != 0) {
    return kCopyOperation;
  }
  if ((effect & DROPEFFECT_MOVE) != 0) {
    return kMoveOperation;
  }
  if ((effect & DROPEFFECT_LINK) != 0) {
    return kLinkOperation;
  }
  return kNoOperation;
}

// One DWORD a target stored on the data object through SetData.
bool ReadEffect(IDataObject* data, const wchar_t* format_name, DWORD* effect) {
  const UINT format = RegisterClipboardFormatW(format_name);
  if (format == 0) {
    return false;
  }
  FORMATETC request = {static_cast<CLIPFORMAT>(format), nullptr,
                       DVASPECT_CONTENT, -1, TYMED_HGLOBAL};
  STGMEDIUM medium = {};
  if (FAILED(data->GetData(&request, &medium))) {
    return false;
  }
  bool found = false;
  if (medium.tymed == static_cast<DWORD>(TYMED_HGLOBAL) &&
      medium.hGlobal != nullptr &&
      GlobalSize(medium.hGlobal) >= sizeof(DWORD)) {
    if (const void* bytes = GlobalLock(medium.hGlobal)) {
      std::memcpy(effect, bytes, sizeof(DWORD));
      found = true;
      GlobalUnlock(medium.hGlobal);
    }
  }
  ReleaseStgMedium(&medium);
  return found;
}

// What the drop did ("Handling Shell Data Transfer Scenarios"): the
// shell's optimized file move returns NONE or COPY from the drag loop
// so the source does not delete, and records the logical outcome on the
// data object instead.
DWORD PerformedEffect(IDataObject* data, DWORD returned) {
  DWORD effect = DROPEFFECT_NONE;
  if (ReadEffect(data, CFSTR_LOGICALPERFORMEDDROPEFFECT, &effect) &&
      (effect & kReportedEffects) != 0) {
    return effect;
  }
  if (ReadEffect(data, CFSTR_PERFORMEDDROPEFFECT, &effect) &&
      (effect & kReportedEffects) != 0) {
    return effect;
  }
  return returned;
}

// Owns a shell item ID list as the SDK's own pointer type. On x64 that
// type is `ITEMIDLIST_* UNALIGNED *` (`__unaligned`): holding it as a
// plain `ITEMIDLIST_*` pointer drops the qualifier, which MSVC reports
// as C4090 and the runner's /WX turns into an error. ILFree takes the
// unaligned relative type, which the absolute one converts to.
template <typename Pidl>
struct PidlFree {
  using pointer = Pidl;
  void operator()(Pidl pidl) const { ILFree(pidl); }
};
using OwnedAbsolutePidl =
    std::unique_ptr<ITEMIDLIST_ABSOLUTE, PidlFree<PIDLIST_ABSOLUTE>>;
using OwnedRelativePidl =
    std::unique_ptr<ITEMIDLIST_RELATIVE, PidlFree<PIDLIST_RELATIVE>>;

enum class DataObjectStatus { kCreated, kUnsupported, kFailed };

// Splits an absolute path into its folder and its last component. False
// for a path without one (a drive or share root).
bool SplitPath(const std::wstring& path,
               std::wstring* folder,
               std::wstring* name) {
  const size_t separator = path.find_last_of(L'\\');
  if (separator == std::wstring::npos || separator == 0 ||
      separator + 1 >= path.size()) {
    return false;
  }
  *name = path.substr(separator + 1);
  *folder = path.substr(0, separator);
  // "C:\file" lives in "C:\"; a bare "C:" names the drive's current
  // directory instead.
  if (folder->size() == 2 && (*folder)[1] == L':') {
    folder->push_back(L'\\');
  }
  return true;
}

bool SameFolder(const std::wstring& a, const std::wstring& b) {
  return CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()),
                              b.c_str(), static_cast<int>(b.size()),
                              TRUE) == CSTR_EQUAL;
}

// The shell data object for |paths| (see the file comment). Every item
// must live in one folder, as one pane listing's selection does.
DataObjectStatus CreateDataObject(HWND owner,
                                  const std::vector<std::wstring>& paths,
                                  ComPtr<IDataObject>* data,
                                  std::string* error) {
  std::wstring folder_path;
  std::vector<std::wstring> names;
  for (std::wstring path : paths) {
    std::replace(path.begin(), path.end(), L'/', L'\\');
    std::wstring folder;
    std::wstring name;
    if (!SplitPath(path, &folder, &name)) {
      *error = "an item has no parent folder";
      return DataObjectStatus::kUnsupported;
    }
    if (names.empty()) {
      folder_path = folder;
    } else if (!SameFolder(folder, folder_path)) {
      *error = "the items do not share one folder";
      return DataObjectStatus::kUnsupported;
    }
    names.push_back(std::move(name));
  }

  PIDLIST_ABSOLUTE raw_folder = nullptr;
  HRESULT hr = SHParseDisplayName(folder_path.c_str(), nullptr, &raw_folder,
                                  0, nullptr);
  OwnedAbsolutePidl folder_pidl(raw_folder);
  if (FAILED(hr)) {
    *error = HresultMessage("SHParseDisplayName", hr);
    return DataObjectStatus::kFailed;
  }
  ComPtr<IShellFolder> folder;
  hr = SHBindToObject(nullptr, folder_pidl.get(), nullptr,
                      IID_PPV_ARGS(&folder));
  if (FAILED(hr)) {
    *error = HresultMessage("SHBindToObject", hr);
    return DataObjectStatus::kFailed;
  }

  std::vector<OwnedRelativePidl> owned;
  std::vector<PCUITEMID_CHILD> children;
  for (std::wstring& name : names) {
    PIDLIST_RELATIVE raw_child = nullptr;
    // No owner window: parsing must never raise UI mid-drag.
    hr = folder->ParseDisplayName(nullptr, nullptr, name.data(), nullptr,
                                  &raw_child, nullptr);
    owned.emplace_back(raw_child);
    if (FAILED(hr) || raw_child == nullptr) {
      *error = HresultMessage("IShellFolder::ParseDisplayName", hr);
      return DataObjectStatus::kFailed;
    }
    // A name holds no separator, so it parses to exactly one item ID;
    // an empty or multi-level answer would put the wrong item in the
    // child array.
    PCUITEMID_CHILD child = ILFindLastID(raw_child);
    if (raw_child->mkid.cb == 0 ||
        reinterpret_cast<std::uintptr_t>(child) !=
            reinterpret_cast<std::uintptr_t>(raw_child)) {
      *error = "an item did not parse to a direct child of its folder";
      return DataObjectStatus::kFailed;
    }
    children.push_back(child);
  }

  hr = folder->GetUIObjectOf(
      owner, static_cast<UINT>(children.size()), children.data(),
      __uuidof(IDataObject), nullptr,
      reinterpret_cast<void**>(data->ReleaseAndGetAddressOf()));
  if (FAILED(hr) || data->Get() == nullptr) {
    *error = HresultMessage("IShellFolder::GetUIObjectOf", hr);
    return DataObjectStatus::kFailed;
  }
  return DataObjectStatus::kCreated;
}

// The Dart PNG as a 32-bit bottom-up DIB of straight (not
// premultiplied) BGRA: InitializeFromBitmap multiplies by alpha itself.
// Bottom-up is the layout super_native_extensions hands the helper.
HBITMAP DecodePng(const std::vector<uint8_t>& png, UINT* width, UINT* height) {
  if (png.empty() || png.size() > MAXDWORD) {
    return nullptr;
  }
  ComPtr<IWICImagingFactory> factory;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory)))) {
    return nullptr;
  }
  ComPtr<IWICStream> stream;
  if (FAILED(factory->CreateStream(&stream)) ||
      // WIC only reads the buffer; the parameter is just not const.
      FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(png.data()),
                                          static_cast<DWORD>(png.size())))) {
    return nullptr;
  }
  ComPtr<IWICBitmapDecoder> decoder;
  ComPtr<IWICBitmapFrameDecode> frame;
  ComPtr<IWICFormatConverter> converter;
  if (FAILED(factory->CreateDecoderFromStream(
          stream.Get(), nullptr, WICDecodeMetadataCacheOnDemand, &decoder)) ||
      FAILED(decoder->GetFrame(0, &frame)) ||
      FAILED(factory->CreateFormatConverter(&converter)) ||
      FAILED(converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
                                   WICBitmapDitherTypeNone, nullptr, 0.0,
                                   WICBitmapPaletteTypeCustom))) {
    return nullptr;
  }
  UINT image_width = 0;
  UINT image_height = 0;
  if (FAILED(converter->GetSize(&image_width, &image_height)) ||
      image_width == 0 || image_height == 0 || image_width > kMaxImageSide ||
      image_height > kMaxImageSide) {
    return nullptr;
  }
  const UINT stride = image_width * 4;
  std::vector<BYTE> pixels(static_cast<size_t>(stride) * image_height);
  if (FAILED(converter->CopyPixels(nullptr, stride,
                                   static_cast<UINT>(pixels.size()),
                                   pixels.data()))) {
    return nullptr;
  }

  BITMAPINFO info = {};
  info.bmiHeader.biSize = static_cast<DWORD>(sizeof(BITMAPINFOHEADER));
  info.bmiHeader.biWidth = static_cast<LONG>(image_width);
  info.bmiHeader.biHeight = static_cast<LONG>(image_height);
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HDC screen = GetDC(nullptr);
  HBITMAP bitmap =
      CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
  if (screen != nullptr) {
    ReleaseDC(nullptr, screen);
  }
  if (bitmap == nullptr || bits == nullptr) {
    if (bitmap != nullptr) {
      DeleteObject(bitmap);
    }
    return nullptr;
  }
  auto* rows = static_cast<BYTE*>(bits);
  for (UINT row = 0; row < image_height; ++row) {
    std::memcpy(rows + static_cast<size_t>(image_height - 1 - row) * stride,
                pixels.data() + static_cast<size_t>(row) * stride, stride);
  }
  *width = image_width;
  *height = image_height;
  return bitmap;
}

LONG PixelOffset(double logical, double scale, UINT extent) {
  const double pixel = std::clamp(logical * scale, 0.0,
                                  static_cast<double>(extent - 1));
  return static_cast<LONG>(std::lround(pixel));
}

// Attaches the Dart-rendered PNG as the drag image. Best effort: without
// it the shell shows its generic drag image (SHDoDragDrop).
void AttachDragImage(IDataObject* data, const EncodableMap& arguments) {
  const EncodableValue* image = ValueAt(arguments, kImageKey);
  const auto* png =
      image == nullptr ? nullptr : std::get_if<std::vector<uint8_t>>(image);
  double logical_width = 0;
  double logical_height = 0;
  double anchor_x = 0;
  double anchor_y = 0;
  if (png == nullptr ||
      !PairAt(arguments, kImageSizeKey, &logical_width, &logical_height) ||
      !PairAt(arguments, kImageAnchorKey, &anchor_x, &anchor_y) ||
      !(logical_width > 0) || !(logical_height > 0)) {
    return;
  }
  UINT width = 0;
  UINT height = 0;
  HBITMAP bitmap = DecodePng(*png, &width, &height);
  if (bitmap == nullptr) {
    return;
  }
  // The PNG is rendered at the view's device pixel ratio; the anchor is
  // in logical pixels.
  SHDRAGIMAGE drag_image = {};
  drag_image.sizeDragImage.cx = static_cast<LONG>(width);
  drag_image.sizeDragImage.cy = static_cast<LONG>(height);
  drag_image.ptOffset.x = PixelOffset(anchor_x, width / logical_width, width);
  drag_image.ptOffset.y =
      PixelOffset(anchor_y, height / logical_height, height);
  drag_image.hbmpDragImage = bitmap;
  drag_image.crColorKey = kNoColorKey;
  ComPtr<IDragSourceHelper> helper;
  HRESULT hr = CoCreateInstance(CLSID_DragDropHelper, nullptr,
                                CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&helper));
  if (SUCCEEDED(hr)) {
    hr = helper->InitializeFromBitmap(&drag_image, data);
  }
  // On success the helper owns the bitmap (Windows-classic-samples,
  // DragDropVisuals); on failure it is still ours.
  if (FAILED(hr)) {
    DeleteObject(bitmap);
  }
}

// The drop source: Esc cancels, releasing the primary button drops, and
// the shell draws the cursors.
class DropSource final : public IDropSource {
 public:
  DropSource() = default;

  DropSource(const DropSource&) = delete;
  DropSource& operator=(const DropSource&) = delete;

  IFACEMETHODIMP QueryInterface(REFIID riid, void** object) override {
    if (object == nullptr) {
      return E_POINTER;
    }
    if (IsEqualIID(riid, __uuidof(IUnknown)) ||
        IsEqualIID(riid, __uuidof(IDropSource))) {
      *object = static_cast<IDropSource*>(this);
      AddRef();
      return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
  }

  IFACEMETHODIMP_(ULONG) AddRef() override {
    return static_cast<ULONG>(InterlockedIncrement(&references_));
  }

  IFACEMETHODIMP_(ULONG) Release() override {
    const LONG references = InterlockedDecrement(&references_);
    if (references == 0) {
      delete this;
    }
    return static_cast<ULONG>(references);
  }

  IFACEMETHODIMP QueryContinueDrag(BOOL escape_pressed,
                                   DWORD key_state) override {
    if (escape_pressed) {
      return DRAGDROP_S_CANCEL;
    }
    if ((key_state & MK_LBUTTON) == 0) {
      return DRAGDROP_S_DROP;
    }
    return S_OK;
  }

  IFACEMETHODIMP GiveFeedback(DWORD effect) override {
    return DRAGDROP_S_USEDEFAULTCURSORS;
  }

 private:
  ~DropSource() = default;

  LONG references_ = 1;
};

}  // namespace

DragOut::DragOut(flutter::BinaryMessenger* messenger, HWND window, HWND view)
    : window_(window),
      view_(view),
      start_message_(RegisterWindowMessageW(kStartMessageName)),
      alive_(std::make_shared<bool>(true)) {
  // The drag loop needs OLE on this thread. desktop_drop has usually
  // initialized it already; the call is reference counted, so this
  // object balances its own.
  ole_initialized_ = SUCCEEDED(OleInitialize(nullptr));
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, kChannelName, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string& method = call.method_name();
    if (method == kStartDragMethod) {
      StartDrag(call.arguments(), *result);
      return;
    }
    if (method == kPromiseProgressMethod) {
      // No promises on Windows yet; progress has nowhere to go.
      result->Success();
      return;
    }
    result->NotImplemented();
  });
}

DragOut::~DragOut() {
  *alive_ = false;
  // The channel's destruction alone does not unregister the handler
  // from the engine messenger.
  channel_->SetMethodCallHandler(nullptr);
  // A drag loop still on the stack (the window closed under it) keeps
  // OLE: uninitializing would pull it out from under the loop.
  if (ole_initialized_ && !running_) {
    OleUninitialize();
  }
}

void DragOut::StartDrag(const EncodableValue* arguments,
                        MethodResult& result) {
  const auto* map =
      arguments == nullptr ? nullptr : std::get_if<EncodableMap>(arguments);
  const std::string* session_id =
      map == nullptr ? nullptr : StringAt(*map, kSessionIdKey);
  const EncodableValue* items_value =
      map == nullptr ? nullptr : ValueAt(*map, kItemsKey);
  const auto* items = items_value == nullptr
                          ? nullptr
                          : std::get_if<EncodableList>(items_value);
  if (session_id == nullptr || session_id->empty() || items == nullptr ||
      items->empty()) {
    Refuse(result, kFailedReason, "startDrag needs a sessionId and items");
    return;
  }
  if (session_.has_value()) {
    Refuse(result, kBusyReason);
    return;
  }
  if (!ole_initialized_ || start_message_ == 0) {
    Refuse(result, kFailedReason,
           ole_initialized_ ? "the start message is not registered"
                            : "OLE is not initialized on this thread");
    return;
  }
  LogicalPoint position;
  if (!PairAt(*map, kPositionKey, &position.x, &position.y)) {
    Refuse(result, kFailedReason, "startDrag needs a position");
    return;
  }

  std::vector<std::wstring> paths;
  for (const EncodableValue& item_value : *items) {
    const auto* item = std::get_if<EncodableMap>(&item_value);
    const std::string* kind =
        item == nullptr ? nullptr : StringAt(*item, kKindKey);
    const std::string* path =
        item == nullptr ? nullptr : StringAt(*item, kPathKey);
    // Only local files travel here; remote virtual files are a
    // follow-up.
    if (kind == nullptr || *kind != kFileKind || path == nullptr ||
        path->empty()) {
      Refuse(result, kUnsupportedItemsReason);
      return;
    }
    std::wstring wide = WideFromUtf8(*path);
    if (wide.empty()) {
      Refuse(result, kFailedReason, "an item path is not valid UTF-8");
      return;
    }
    paths.push_back(std::move(wide));
  }

  // The session must start while the primary button is still down, from
  // the press the embedder captured. Pen and touch drags never take the
  // mouse capture and stay in-app: the drag loop does not support them.
  if (!PrimaryButtonDown()) {
    Refuse(result, kButtonReleasedReason);
    return;
  }
  if (GetCapture() != view_) {
    Refuse(result, kNoPointerEventReason,
           "the Flutter view does not hold the mouse capture");
    return;
  }

  ComPtr<IDataObject> data;
  std::string error;
  switch (CreateDataObject(window_, paths, &data, &error)) {
    case DataObjectStatus::kUnsupported:
      Refuse(result, kUnsupportedItemsReason, error);
      return;
    case DataObjectStatus::kFailed:
      Refuse(result, kFailedReason, error);
      return;
    case DataObjectStatus::kCreated:
      break;
  }
  AttachDragImage(data.Get(), *map);

  // The loop runs on a later message-loop turn, after this reply.
  if (!PostMessageW(window_, start_message_, 0, 0)) {
    Refuse(result, kFailedReason, "the start message could not be posted");
    return;
  }
  session_ = Session{*session_id, std::move(data), AllowedEffects(*map),
                     position};
  result.Success(
      EncodableValue(EncodableMap{{EncodableValue(kStartedKey),
                                   EncodableValue(true)}}));
}

bool DragOut::HandleWindowMessage(UINT message) {
  if (start_message_ == 0 || message != start_message_) {
    return false;
  }
  if (!session_.has_value() || running_) {
    return true;
  }
  running_ = true;
  // Locals only from here on: the window can be torn down while the loop
  // runs, and |alive| says whether |this| survived it.
  const std::shared_ptr<bool> alive = alive_;
  const std::string session_id = session_->id;
  const ComPtr<IDataObject> data = session_->data;
  const DWORD effects = session_->effects;
  const LogicalPoint position = session_->position;

  EndEmbedderPress(position);
  if (!PrimaryButtonDown()) {
    // Released before the loop could start: nothing was dropped.
    FinishSession(session_id, kNoOperation);
    return true;
  }

  auto* source = new DropSource();
  DWORD effect = DROPEFFECT_NONE;
  // SHDoDragDrop, not DoDragDrop: without our image it shows the shell's
  // generic one. No window: the Flutter view answers no DI_GETDRAGIMAGE.
  const HRESULT hr =
      SHDoDragDrop(nullptr, data.Get(), source, effects, &effect);
  source->Release();
  if (!*alive) {
    return true;
  }
  FinishSession(session_id, hr == DRAGDROP_S_DROP
                                ? OperationName(PerformedEffect(data.Get(),
                                                                effect))
                                : kNoOperation);
  return true;
}

void DragOut::EndEmbedderPress(const LogicalPoint& position) {
  // Only while the embedder still holds the press: a release it already
  // saw needs no second one.
  if (GetCapture() != view_) {
    return;
  }
  // Dart's position in the view's physical client pixels: the
  // embedder's device pixel ratio is the view's DPI over 96.
  const double scale = FlutterDesktopGetDpiForHWND(view_) / 96.0;
  const POINT point = {static_cast<LONG>(std::lround(position.x * scale)),
                       static_cast<LONG>(std::lround(position.y * scale))};
  WPARAM keys = 0;
  if ((GetKeyState(VK_CONTROL) & 0x8000) != 0) {
    keys |= MK_CONTROL;
  }
  if ((GetKeyState(VK_SHIFT) & 0x8000) != 0) {
    keys |= MK_SHIFT;
  }
  SendMessageW(view_, WM_LBUTTONUP, keys, MAKELPARAM(point.x, point.y));
}

void DragOut::FinishSession(const std::string& session_id,
                            const char* operation) {
  session_.reset();
  running_ = false;
  channel_->InvokeMethod(
      kSessionEndedMethod,
      std::make_unique<EncodableValue>(EncodableMap{
          {EncodableValue(kSessionIdKey), EncodableValue(session_id)},
          {EncodableValue(kOperationKey), EncodableValue(operation)},
      }));
}

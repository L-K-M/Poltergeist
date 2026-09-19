#include "trash_operations.h"

#include <shlobj.h>
#include <shobjidl.h>
#include <windows.h>

#include <sstream>
#include <string>

#include <wrl/client.h>

using Microsoft::WRL::ComPtr;

namespace {

// The operation flags (03 §7.1, 00 D15): FOF_ALLOWUNDO routes the delete
// to the Recycle Bin, FOFX_ADDUNDORECORD lands it on Explorer's Ctrl+Z
// stack (FOF_ALLOWUNDO alone does not), and the FOF_NO_UI family keeps a
// delete from ever raising a shell dialog on the app's behalf — errors
// come back through the HRESULT / GetAnyOperationsAborted instead, which
// the Dart side types as a trash failure.
// FILEOPERATION_FLAGS is a DWORD typedef behind a Vista-visibility guard;
// spelling the DWORD avoids depending on the typedef being reachable.
constexpr DWORD kTrashFlags =
    static_cast<DWORD>(FOF_NO_UI | FOF_ALLOWUNDO | FOFX_ADDUNDORECORD);

std::string HresultMessage(const char* what, HRESULT hr) {
  std::ostringstream out;
  out << what << " failed (HRESULT 0x" << std::hex
      << static_cast<unsigned long>(hr) << ')';
  return out.str();
}

void Fail(flutter::MethodResult<flutter::EncodableValue>& result,
          const std::string& message) {
  // EncodableValue carries the detail as the error's details payload.
  result.Error("TRASH_FAILED", message, flutter::EncodableValue());
}

}  // namespace

TrashOperations::TrashOperations() : worker_([this] { Run(); }) {}

TrashOperations::~TrashOperations() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  condition_.notify_all();
  worker_.join();
}

void TrashOperations::Trash(
    std::wstring path,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
        result) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    jobs_.push(Job{std::move(path), std::move(result)});
  }
  condition_.notify_one();
}

void TrashOperations::Run() {
  // IFileOperation requires COINIT_APARTMENTTHREADED on its calling
  // thread; DISABLE_OLE1DDE is the standard pairing for a worker with no
  // DDE use.
  const HRESULT com_status =
      CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
  const bool com_ready = SUCCEEDED(com_status);
  for (;;) {
    Job job;
    {
      std::unique_lock<std::mutex> lock(mutex_);
      condition_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
      if (stopping_ && jobs_.empty()) break;
      job = std::move(jobs_.front());
      jobs_.pop();
    }
    if (!com_ready) {
      Fail(*job.result,
           HresultMessage("COM apartment initialization", com_status));
      continue;
    }
    Perform(job);
  }
  if (com_ready) {
    CoUninitialize();
  }
}

void TrashOperations::Perform(const Job& job) {
  ComPtr<IFileOperation> operation;
  HRESULT hr = CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_ALL,
                                IID_PPV_ARGS(&operation));
  if (FAILED(hr)) {
    Fail(*job.result, HresultMessage("IFileOperation creation", hr));
    return;
  }
  hr = operation->SetOperationFlags(kTrashFlags);
  if (FAILED(hr)) {
    Fail(*job.result, HresultMessage("SetOperationFlags", hr));
    return;
  }
  // FOF_ALLOWUNDO only recycles "if possible": on network volumes (UNC
  // paths and mapped drives report DRIVE_REMOTE) the shell unlinks
  // outright while PerformOperations still succeeds — the silent
  // permanent delete D15 forbids. Fail closed on non-local volumes so
  // the Dart side's confirm-then-permanent fallback applies instead.
  // (Removable and fixed drives both recycle via $RECYCLE.BIN.)
  wchar_t volume_root[MAX_PATH];
  if (!GetVolumePathNameW(job.path.c_str(), volume_root, MAX_PATH)) {
    Fail(*job.result, "could not resolve the volume root for the path");
    return;
  }
  const UINT drive_type = GetDriveTypeW(volume_root);
  if (drive_type == DRIVE_REMOTE || drive_type == DRIVE_UNKNOWN ||
      drive_type == DRIVE_NO_ROOT_DIR || drive_type == DRIVE_CDROM) {
    Fail(*job.result,
         "the volume has no Recycle Bin; confirm permanent deletion "
         "instead");
    return;
  }
  ComPtr<IShellItem> item;
  hr = SHCreateItemFromParsingName(job.path.c_str(), nullptr,
                                   IID_PPV_ARGS(&item));
  if (FAILED(hr)) {
    Fail(*job.result, HresultMessage("SHCreateItemFromParsingName", hr));
    return;
  }
  hr = operation->DeleteItem(item.Get(), nullptr);
  if (FAILED(hr)) {
    Fail(*job.result, HresultMessage("DeleteItem", hr));
    return;
  }
  hr = operation->PerformOperations();
  if (FAILED(hr)) {
    Fail(*job.result, HresultMessage("PerformOperations", hr));
    return;
  }
  BOOL aborted = FALSE;
  hr = operation->GetAnyOperationsAborted(&aborted);
  if (FAILED(hr) || aborted) {
    Fail(*job.result,
         FAILED(hr) ? HresultMessage("GetAnyOperationsAborted", hr)
                    : "the recycle-bin delete was aborted");
    return;
  }
  // No trashed-path result on Windows: the Recycle Bin does not report
  // one through IFileOperation, and restore rides Explorer's undo stack.
  job.result->Success();
}

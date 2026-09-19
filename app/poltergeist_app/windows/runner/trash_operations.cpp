#include "trash_operations.h"

#include <shlobj.h>
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
constexpr FILEOPERATION_FLAGS kTrashFlags =
    static_cast<FILEOPERATION_FLAGS>(FOF_NO_UI | FOF_ALLOWUNDO |
                                     FOFX_ADDUNDORECORD);

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

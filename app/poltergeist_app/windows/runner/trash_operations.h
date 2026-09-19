#ifndef RUNNER_TRASH_OPERATIONS_H_
#define RUNNER_TRASH_OPERATIONS_H_

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>

#include <condition_variable>
#include <memory>
#include <mutex>
#include <queue>
#include <string>
#include <thread>

// The Windows half of the D15 trash channel (03 §7.1, 00 D15):
// IFileOperation with FOF_ALLOWUNDO | FOFX_ADDUNDORECORD must run on an
// apartment-threaded (STA) thread, and a synchronous PerformOperations
// must never park the platform thread for the duration — so requests
// are marshaled onto this one dedicated STA worker. The engine side
// reaches it through the poltergeist/trash MethodChannel.
class TrashOperations {
 public:
  TrashOperations();
  ~TrashOperations();

  TrashOperations(const TrashOperations&) = delete;
  TrashOperations& operator=(const TrashOperations&) = delete;

  // Queues a recycle-bin delete for |path|. |result| is completed on the
  // worker thread — the embedder's platform-message response entrypoint
  // (FlutterDesktopEngineSendPlatformMessageResponse, which
  // MethodResult's implementation forwards to) is thread-safe.
  void Trash(
      std::wstring path,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
          result);

 private:
  struct Job {
    std::wstring path;
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
        result;
  };

  void Run();
  void Perform(const Job& job);

  std::thread worker_;
  std::mutex mutex_;
  std::condition_variable condition_;
  std::queue<Job> jobs_;
  bool stopping_ = false;
};

#endif  // RUNNER_TRASH_OPERATIONS_H_

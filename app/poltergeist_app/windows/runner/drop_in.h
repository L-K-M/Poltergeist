#ifndef RUNNER_DROP_IN_H_
#define RUNNER_DROP_IN_H_

#include <windows.h>

#include <ole2.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <cstdint>

// Files dropped from other apps onto an extra workspace window (00 D39):
// an OLE drop target on the window's Flutter view that reports its drags
// on "poltergeist/dropin", each tagged with the view's id (the protocol is
// the library doc of lib/services/window_drop_in.dart). desktop_drop
// registers the main window's view only, and says nothing of which view a
// drag is over.
//
// Offers the source a copy: a drop from another app carries no move the
// app could honour (00 D14). Positions cross in the view's logical pixels.
class ViewDropTarget : public IDropTarget {
 public:
  // Registers the target on |view|. |channel| belongs to the workspace
  // windows' host and outlives every window.
  static ViewDropTarget* Register(
      flutter::MethodChannel<flutter::EncodableValue>* channel,
      int64_t view_id,
      HWND view);

  // Unregisters the target and drops the reference Register returned.
  void Revoke();

  // IDropTarget.
  HRESULT STDMETHODCALLTYPE DragEnter(IDataObject* data,
                                      DWORD key_state,
                                      POINTL point,
                                      DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragOver(DWORD key_state,
                                     POINTL point,
                                     DWORD* effect) override;
  HRESULT STDMETHODCALLTYPE DragLeave() override;
  HRESULT STDMETHODCALLTYPE Drop(IDataObject* data,
                                 DWORD key_state,
                                 POINTL point,
                                 DWORD* effect) override;

  // IUnknown.
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

 private:
  ViewDropTarget(flutter::MethodChannel<flutter::EncodableValue>* channel,
                 int64_t view_id,
                 HWND view);
  ~ViewDropTarget() = default;

  // Sends |method| with the view id, and |point| (screen pixels) in the
  // view's logical pixels when |with_position|.
  void Send(const char* method,
            POINTL point,
            bool with_position,
            flutter::EncodableValue* paths = nullptr);

  flutter::MethodChannel<flutter::EncodableValue>* channel_;
  int64_t view_id_;
  HWND view_;
  // Whether the drag over the view carries files.
  bool accepts_ = false;
  bool registered_ = false;
  LONG references_ = 1;
};

#endif  // RUNNER_DROP_IN_H_

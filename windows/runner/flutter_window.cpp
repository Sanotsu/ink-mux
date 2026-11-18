#include "flutter_window.h"

#include <objidl.h>
#include <optional>
#include <shobjidl_core.h>
#include <wrl/client.h>

#include "flutter/generated_plugin_registrant.h"

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

  // M3：任务栏进度通道（仅 Windows；失败静默，功能降级为无任务栏进度）。
  RegisterTaskbarChannel();

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
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::RegisterTaskbarChannel() {
  taskbar_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "inkmux/taskbar",
          &flutter::StandardMethodCodec::GetInstance());
  taskbar_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setProgress") {
          result->NotImplemented();
          return;
        }
        const auto* args =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("bad-args", "arguments must be a map");
          return;
        }
        auto find = [args](const char* key) -> const flutter::EncodableValue* {
          auto it = args->find(flutter::EncodableValue(std::string(key)));
          return it == args->end() ? nullptr : &it->second;
        };
        std::string state;
        if (const auto* s = std::get_if<std::string>(find("state"))) {
          state = *s;
        }
        int value = 0;
        int total = 0;
        auto read_int = [&find](const char* key) -> int {
          if (const auto* v = std::get_if<int32_t>(find(key))) return *v;
          if (const auto* v = std::get_if<int64_t>(find(key)))
            return static_cast<int>(*v);
          return 0;
        };
        value = read_int("value");
        total = read_int("total");

        // ITaskbarList3：一次初始化复用（main.cpp 已 CoInitializeEx）。
        Microsoft::WRL::ComPtr<ITaskbarList3> taskbar;
        HRESULT hr = CoCreateInstance(CLSID_TaskbarList, nullptr,
                                      CLSCTX_INPROC_SERVER,
                                      IID_PPV_ARGS(&taskbar));
        if (SUCCEEDED(hr)) {
          TBPFLAG flag = TBPF_NOPROGRESS;
          if (state == "indeterminate") {
            flag = TBPF_INDETERMINATE;
          } else if (state == "normal") {
            flag = TBPF_NORMAL;
          } else if (state == "error") {
            flag = TBPF_ERROR;
          } else if (state == "paused") {
            flag = TBPF_PAUSED;
          }
          HWND hwnd = GetHandle();
          taskbar->SetProgressState(hwnd, flag);
          if (total > 0 &&
              (flag == TBPF_NORMAL || flag == TBPF_ERROR ||
               flag == TBPF_PAUSED)) {
            int clamped = value;
            if (clamped < 0) clamped = 0;
            if (clamped > total) clamped = total;
            taskbar->SetProgressValue(hwnd, clamped, total);
          }
        }
        // 初始化失败时同样返回成功：功能降级不阻塞调用方。
        result->Success();
      });
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

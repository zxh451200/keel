#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <wrl.h>

#include <cwchar>
#include <limits>
#include <optional>
#include <string>
#include <utility>

#include "flutter/generated_plugin_registrant.h"
#include "print_report.h"

using Microsoft::WRL::ComPtr;

struct DesktopFileSelection {
  bool alive = true;
  bool busy = false;
  bool printing = false;
  ComPtr<IFileDialog> dialog;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> pending;
};

namespace {

// No native error text or selected path is included in error envelopes.
void FileError(flutter::MethodResult<flutter::EncodableValue>* result) {
  result->Error("KEEL-IO", "");
}

class ComApartment {
 public:
  ComApartment() : status_(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED)) {}
  ~ComApartment() {
    if (SUCCEEDED(status_)) CoUninitialize();
  }
  bool ready() const { return SUCCEEDED(status_); }

 private:
  HRESULT status_;
};

struct CoTaskMemDeleter {
  void operator()(wchar_t* value) const { CoTaskMemFree(value); }
};

bool ReadLabel(const flutter::EncodableMap& arguments, const char* key,
               std::wstring* output) {
  const auto it = arguments.find(flutter::EncodableValue(key));
  if (it == arguments.end()) return false;
  const auto* value = std::get_if<std::string>(&it->second);
  if (!value || value->empty() || value->find('\0') != std::string::npos ||
      value->size() > static_cast<size_t>((std::numeric_limits<int>::max)())) {
    return false;
  }
  const int length = static_cast<int>(value->size());
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      value->data(), length, nullptr, 0);
  if (count <= 0) return false;
  output->resize(count);
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value->data(),
                             length, output->data(), count) == count;
}

// IFileDialog has no SetCancelButtonLabel. Set the standard button through its
// own HWND once the dialog exists, without hooking the owner's close messages.
class FileDialogEvents final
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          IFileDialogEvents> {
 public:
  explicit FileDialogEvents(std::wstring label) : cancel_label_(std::move(label)) {}
  IFACEMETHODIMP OnFileOk(IFileDialog* dialog) override {
    return SetCancelLabel(dialog, true);
  }
  IFACEMETHODIMP OnFolderChanging(IFileDialog*, IShellItem*) override {
    return S_OK;
  }
  IFACEMETHODIMP OnFolderChange(IFileDialog* dialog) override {
    return SetCancelLabel(dialog, true);
  }
  IFACEMETHODIMP OnSelectionChange(IFileDialog* dialog) override {
    return SetCancelLabel(dialog, false);
  }
  IFACEMETHODIMP OnShareViolation(IFileDialog*, IShellItem*,
                                 FDE_SHAREVIOLATION_RESPONSE* response) override {
    *response = FDESVR_DEFAULT;
    return S_OK;
  }
  IFACEMETHODIMP OnTypeChange(IFileDialog* dialog) override {
    return SetCancelLabel(dialog, false);
  }
  IFACEMETHODIMP OnOverwrite(IFileDialog*, IShellItem*,
                            FDE_OVERWRITE_RESPONSE* response) override {
    *response = FDEOR_DEFAULT;
    return S_OK;
  }

  bool label_failed() const { return label_failed_; }
  bool label_applied() const { return label_applied_; }

 private:
  HRESULT SetCancelLabel(IFileDialog* dialog, bool require_window) {
    ComPtr<IOleWindow> window;
    HWND hwnd = nullptr;
    HRESULT status = dialog->QueryInterface(IID_PPV_ARGS(&window));
    if (SUCCEEDED(status)) status = window->GetWindow(&hwnd);
    if (FAILED(status) || !hwnd) {
      // Type/selection notifications can precede native window creation.
      if (!require_window) return S_OK;
    } else if (SetDlgItemTextW(hwnd, IDCANCEL, cancel_label_.c_str())) {
      label_applied_ = true;
      return S_OK;
    }
    label_failed_ = true;
    dialog->Close(E_FAIL);
    return E_FAIL;
  }
  std::wstring cancel_label_;
  bool label_failed_ = false;
  bool label_applied_ = false;
};

class DialogSubscription {
 public:
  explicit DialogSubscription(IFileDialog* dialog) : dialog_(dialog) {}
  HRESULT Advise(IFileDialogEvents* events) {
    HRESULT status = dialog_->Advise(events, &cookie_);
    advised_ = SUCCEEDED(status);
    return status;
  }
  ~DialogSubscription() {
    if (advised_) dialog_->Unadvise(cookie_);
  }

 private:
  ComPtr<IFileDialog> dialog_;
  DWORD cookie_ = 0;
  bool advised_ = false;
};

bool CsvFileName(const std::wstring& name) {
  if (name.size() <= 4 ||
      name.compare(name.size() - 4, 4, L".csv") != 0) return false;
  for (wchar_t c : name) {
    if (c < 0x20 || (c >= 0x7f && c <= 0x9f) ||
        std::wstring(L"\\/:*?\"<>|").find(c) != std::wstring::npos) return false;
  }
  return true;
}

bool SelectedPath(IFileDialog* dialog, bool save, std::string* output) {
  ComPtr<IShellItem> item;
  if (FAILED(dialog->GetResult(&item))) return false;
  PWSTR raw_path = nullptr;
  HRESULT status = item->GetDisplayName(SIGDN_FILESYSPATH, &raw_path);
  std::unique_ptr<wchar_t, CoTaskMemDeleter> path(raw_path);
  if (FAILED(status) || !path) return false;
  // Only absolute drive paths on local disks; reject UNC, device namespaces,
  // mapped network drives. For open, also reject directories/reparse points.
  // Save only returns a target; Rust checks it and refuses existing files.
  const size_t length = std::wcslen(path.get());
  if (length < 3 || !((path.get()[0] >= L'A' && path.get()[0] <= L'Z') ||
                      (path.get()[0] >= L'a' && path.get()[0] <= L'z')) ||
      path.get()[1] != L':' || path.get()[2] != L'\\') return false;
  wchar_t root[] = {path.get()[0], L':', L'\\', L'\0'};
  const UINT drive_type = GetDriveTypeW(root);
  if (drive_type != DRIVE_FIXED && drive_type != DRIVE_REMOVABLE &&
      drive_type != DRIVE_CDROM && drive_type != DRIVE_RAMDISK) return false;
  if (save) {
    const wchar_t* basename = std::wcsrchr(path.get(), L'\\');
    if (!basename || !CsvFileName(basename + 1)) return false;
  } else {
    const DWORD attributes = GetFileAttributesW(path.get());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT |
                       FILE_ATTRIBUTE_DEVICE)) != 0) return false;
  }
  const int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.get(),
                                       -1, nullptr, 0, nullptr, nullptr);
  if (count <= 1) return false;
  std::string utf8(count, '\0');
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path.get(), -1,
                          utf8.data(), count, nullptr, nullptr) != count) {
    return false;
  }
  utf8.pop_back();
  *output = std::move(utf8);
  return true;
}

void DesktopPrintMethod(
    const std::shared_ptr<DesktopFileSelection>& state, HWND owner,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (!state->alive || state->busy || !IsWindow(owner)) {
    result->Error("KEEL-PRINT", "");
    return;
  }
  const auto* args = call.arguments()
                         ? std::get_if<flutter::EncodableMap>(call.arguments())
                         : nullptr;
  // Copy before entering any nested native loop; the method call belongs to
  // the channel, whose engine may be destroyed while a dialog is open.
  std::string title, content;
  try {
    if (!args) { result->Error("KEEL-PRINT", ""); return; }
    const auto title_it = args->find(flutter::EncodableValue("title"));
    const auto content_it = args->find(flutter::EncodableValue("content"));
    const auto* title_arg = title_it == args->end()
        ? nullptr : std::get_if<std::string>(&title_it->second);
    const auto* content_arg = content_it == args->end()
        ? nullptr : std::get_if<std::string>(&content_it->second);
    if (!title_arg || !content_arg || title_arg->empty() || content_arg->empty() ||
        title_arg->size() > 1024 * 1024 || content_arg->size() > 1024 * 1024) {
      result->Error("KEEL-PRINT", "");
      return;
    }
    title = *title_arg;
    content = *content_arg;
  } catch (...) { result->Error("KEEL-PRINT", ""); return; }
  state->busy = true;
  state->printing = true;
  state->pending = std::move(result);
  PrintReportResult outcome = PrintReportResult::error;
  try {
    outcome = PrintReport(owner, title, content,
        [state, owner] { return state->alive && IsWindow(owner); });
  } catch (...) { /* Callback allocation must also finish with a stable error. */ }
  // OnDestroy detaches/completes pending while the engine is still alive.
  // Detach here too, before completion can trigger further native dispatch.
  auto pending = std::move(state->pending);
  if (state->alive && pending) {
    if (outcome == PrintReportResult::error) pending->Error("KEEL-PRINT", "");
    else pending->Success(flutter::EncodableValue(
        outcome == PrintReportResult::printed ? "printed" : "cancelled"));
  }
  state->printing = false;
  state->busy = false;
}

void DesktopFilesMethod(
    std::shared_ptr<DesktopFileSelection> state, HWND owner,
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (call.method_name() == "printReport") {
    DesktopPrintMethod(state, owner, call, std::move(result));
    return;
  }
  const bool save = call.method_name() == "chooseAuditCsvSavePath";
  const bool diagnostic = call.method_name() == "selectExternalDiagnosticFile";
  if (!save && !diagnostic && call.method_name() != "selectConfigFile") {
    result->NotImplemented();
    return;
  }
  const auto* args = call.arguments()
                         ? std::get_if<flutter::EncodableMap>(call.arguments())
                         : nullptr;
  std::wstring title, filter_label, cancel_label, open_label, suggested_name;
  if (!state->alive || state->busy || !IsWindow(owner) || !args ||
      !ReadLabel(*args, "title", &title) ||
      !ReadLabel(*args, "filterLabel", &filter_label) ||
      !ReadLabel(*args, "cancelLabel", &cancel_label) ||
      !ReadLabel(*args, save ? "saveLabel" : "openLabel", &open_label) ||
      (save && (!ReadLabel(*args, "suggestedName", &suggested_name) ||
                !CsvFileName(suggested_name)))) {
    FileError(result.get());
    return;
  }
  state->busy = true;
  state->pending = std::move(result);
  // Keep all COM resources local across Show's nested message loop. OnDestroy
  // may clear the channel, engine and pending response while Show is running.
  {
    ComApartment apartment;
    ComPtr<IFileDialog> dialog;
    HRESULT status = apartment.ready()
                         ? CoCreateInstance(save ? CLSID_FileSaveDialog
                                                 : CLSID_FileOpenDialog, nullptr,
                                            CLSCTX_INPROC_SERVER,
                                            IID_PPV_ARGS(&dialog))
                         : E_FAIL;
    if (SUCCEEDED(status)) {
      state->dialog = dialog;
      FILEOPENDIALOGOPTIONS options = 0;
      status = dialog->GetOptions(&options);
      if (SUCCEEDED(status)) {
        options &= ~(FOS_ALLOWMULTISELECT | FOS_PICKFOLDERS);
        if (save) options &= ~FOS_FILEMUSTEXIST;
        status = dialog->SetOptions(
            options | FOS_FORCEFILESYSTEM |
            (save ? (FOS_OVERWRITEPROMPT | FOS_NOTESTFILECREATE)
                  : FOS_FILEMUSTEXIST) |
            FOS_PATHMUSTEXIST | FOS_NOCHANGEDIR | FOS_NODEREFERENCELINKS);
      }
      // Extension filtering is a convenience, never content validation.
      const COMDLG_FILTERSPEC filter = {
          filter_label.c_str(), save ? L"*.csv" :
              (diagnostic ? L"*.txt;*.log;*.json;*.jsonl" : L"*.json")};
      if (SUCCEEDED(status)) status = dialog->SetFileTypes(1, &filter);
      if (save && SUCCEEDED(status)) status = dialog->SetDefaultExtension(L"csv");
      if (save && SUCCEEDED(status)) {
        status = dialog->SetFileName(suggested_name.c_str());
      }
      // The dialog's overwrite prompt grants no Rust overwrite permission.
      if (SUCCEEDED(status)) status = dialog->SetTitle(title.c_str());
      if (SUCCEEDED(status)) status = dialog->SetOkButtonLabel(open_label.c_str());
      auto events = Microsoft::WRL::Make<FileDialogEvents>(std::move(cancel_label));
      DialogSubscription subscription(dialog.Get());
      if (SUCCEEDED(status)) {
        status = events ? subscription.Advise(events.Get()) : E_OUTOFMEMORY;
      }
      if (SUCCEEDED(status)) status = dialog->Show(owner);
      if (events && (events->label_failed() ||
                     (SUCCEEDED(status) && !events->label_applied()))) {
        status = E_FAIL;
      }
      if (state->pending) {
        if (status == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
          state->pending->Success();
        } else {
          std::string path;
          if (SUCCEEDED(status) && SelectedPath(dialog.Get(), save, &path)) {
            state->pending->Success(flutter::EncodableValue(path));
          } else {
            FileError(state->pending.get());
          }
        }
        state->pending.reset();
      }
      state->dialog.Reset();
    } else if (state->pending) {
      FileError(state->pending.get());
      state->pending.reset();
    }
  }
  state->busy = false;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  OnDestroy();
}

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
  desktop_file_selection_ = std::make_shared<DesktopFileSelection>();
  desktop_files_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "keel/desktop_files",
          &flutter::StandardMethodCodec::GetInstance());
  desktop_files_channel_->SetMethodCallHandler(
      [state = desktop_file_selection_, owner = GetHandle()](
          const auto& call, auto result) {
        DesktopFilesMethod(state, owner, call, std::move(result));
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  // Keep state local even if completing a response re-enters destruction.
  const auto state = desktop_file_selection_;
  if (state) {
    state->alive = false;
    if (state->pending) {
      auto pending = std::move(state->pending);
      if (state->printing) {
        pending->Error("KEEL-PRINT", "");
      } else {
        FileError(pending.get());
      }
    }
    if (state->dialog) {
      state->dialog->Close(
          HRESULT_FROM_WIN32(ERROR_CANCELLED));
    }
  }
  if (desktop_files_channel_) {
    desktop_files_channel_->SetMethodCallHandler(nullptr);
    desktop_files_channel_.reset();
  }
  desktop_file_selection_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
      if (flutter_controller_) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

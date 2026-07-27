#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "flutter_window.h"
#include "oauth_callback.h"
#include "utils.h"

namespace {

constexpr wchar_t kKurakoWindowTitle[] = L"Kurako";
constexpr wchar_t kKurakoProtocolKey[] = L"Software\\Classes\\kurako";

void WriteRegistryString(const wchar_t* key_path, const wchar_t* value_name,
                         const std::wstring& value) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, key_path, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  ::RegSetValueExW(
      key, value_name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(value.c_str()),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(key);
}

void RegisterKurakoProtocol() {
  std::wstring executable_path(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, executable_path.data(),
      static_cast<DWORD>(executable_path.size()));
  if (length == 0 || length >= executable_path.size()) {
    return;
  }
  executable_path.resize(length);

  WriteRegistryString(kKurakoProtocolKey, nullptr,
                      L"URL:Kurako OAuth Callback");
  WriteRegistryString(kKurakoProtocolKey, L"URL Protocol", L"");
  WriteRegistryString(L"Software\\Classes\\kurako\\shell\\open\\command",
                      nullptr, L"\"" + executable_path + L"\" \"%1\"");
}

bool IsKurakoProtocolActivation(const std::vector<std::string>& arguments) {
  return !arguments.empty() && arguments.front().rfind("kurako://", 0) == 0;
}

void DispatchOAuthCallback(HWND window, const std::string& url) {
  COPYDATASTRUCT callback_data{};
  callback_data.dwData = kKurakoOAuthCallbackMessage;
  callback_data.cbData = static_cast<DWORD>(url.size() + 1);
  callback_data.lpData = const_cast<char*>(url.c_str());
  ::SendMessage(window, WM_COPYDATA, 0,
                reinterpret_cast<LPARAM>(&callback_data));
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  RegisterKurakoProtocol();

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  if (IsKurakoProtocolActivation(command_line_arguments)) {
    HWND existing_window =
        ::FindWindow(L"FLUTTER_RUNNER_WIN32_WINDOW", kKurakoWindowTitle);
    if (existing_window != nullptr) {
      DispatchOAuthCallback(existing_window, command_line_arguments.front());
      ::ShowWindow(existing_window, SW_RESTORE);
      ::SetForegroundWindow(existing_window);
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kKurakoWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Keep this handle open for the complete lifetime of the process.  This is a
// presence marker, not an owned Win32 mutex: ownership is tied to the calling
// thread and becomes abandoned when a runtime worker thread exits.
HANDLE g_single_instance_mutex = nullptr;

bool AcquireSingleInstanceMarker() {
  constexpr wchar_t kMutexName[] =
      L"Local\\PetLife.DesktopPet.SingleInstance.Native.v1";

  ::SetLastError(ERROR_SUCCESS);
  HANDLE handle = ::CreateMutexW(nullptr, FALSE, kMutexName);
  const DWORD error = ::GetLastError();

  if (handle == nullptr) {
    // An elevated instance can expose the named object without granting this
    // unelevated process MUTEX_ALL_ACCESS.  Treat access denied as proof that
    // PetLife is already running instead of failing open.
    return error != ERROR_ACCESS_DENIED;
  }

  if (error == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(handle);
    return false;
  }

  g_single_instance_mutex = handle;
  return true;
}

void ReleaseSingleInstanceMarker() {
  if (g_single_instance_mutex != nullptr) {
    ::CloseHandle(g_single_instance_mutex);
    g_single_instance_mutex = nullptr;
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // This must run before Flutter, plugins, logging, and SQLite.  A duplicate
  // process exits without touching the shared database or creating a window.
  if (!AcquireSingleInstanceMarker()) {
    return EXIT_SUCCESS;
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"petlife", origin, size)) {
    ReleaseSingleInstanceMarker();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  ReleaseSingleInstanceMarker();
  return EXIT_SUCCESS;
}

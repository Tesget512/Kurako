@echo off
setlocal

for %%I in ("%~dp0..") do set "WORKSPACE=%%~fI"
set "BUILD_SCRIPT=%~dp0Build-KurakoWindowsRelease.ps1"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"

if not exist "%WORKSPACE%\pubspec.yaml" (
  echo [FAILED] Kurako workspace not found: %WORKSPACE%
  pause
  exit /b 1
)

if not exist "%BUILD_SCRIPT%" (
  echo [FAILED] Build script not found: %BUILD_SCRIPT%
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%BUILD_SCRIPT%" -Workspace "%WORKSPACE%"
set "BUILD_EXIT_CODE=%ERRORLEVEL%"

if not "%BUILD_EXIT_CODE%"=="0" (
  echo.
  echo [FAILED] Kurako build failed. Exit code: %BUILD_EXIT_CODE%
) else (
  echo.
  echo [SUCCESS] Kurako Windows release is ready in dist\out.
)

pause
exit /b %BUILD_EXIT_CODE%

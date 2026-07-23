@echo off
REM ============================================================================
REM  _dist.bat — 一键构建并把所有产物汇总到固定文件夹 D:\Kurako\dist\out
REM  用法：
REM    _dist.bat            构建 Windows Release + Android Release APK
REM    _dist.bat win        仅 Windows Release
REM    _dist.bat apk        仅 Android Release APK (split-per-abi)
REM  产物固定落在：D:\Kurako\dist\out\
REM ============================================================================
setlocal
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
set "PATH=%USERPROFILE%\.cargo\bin;C:\flutter\bin;%PATH%"
set "PUB_HOSTED_URL=https://pub.flutter-io.cn"
set "FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn"
set "ANDROID_HOME=C:\Users\Developer\AppData\Local\Android\sdk"
set "ANDROID_NDK_HOME=C:\Users\Developer\AppData\Local\Android\sdk\ndk\28.2.13676358"

cd /d D:\Kurako
set "OUT=D:\Kurako\dist\out"
if not exist "%OUT%" mkdir "%OUT%"

set "MODE=%~1"
if "%MODE%"=="" set "MODE=all"

if /I "%MODE%"=="apk" goto :apk

REM ---- Windows Release ----
echo === [1/2] flutter build windows --release ===
taskkill /IM kurako.exe /F >nul 2>&1
call flutter build windows --release
if errorlevel 1 ( echo BUILD FAILED ^(windows^) & exit /b 1 )
echo === 打包 Windows 便携版到 dist\out ===
set "WINSRC=build\windows\x64\runner\Release"
if exist "%OUT%\windows" rmdir /S /Q "%OUT%\windows"
xcopy "%WINSRC%" "%OUT%\windows\" /E /I /Y >nul
echo   -> %OUT%\windows\kurako.exe

echo === 生成 Windows 安装包 (Inno Setup) ===
set "ISCC=C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
if exist "%ISCC%" (
  "%ISCC%" installer.iss
  if errorlevel 1 ( echo BUILD FAILED ^(installer^) & exit /b 1 )
  copy /Y "dist\KURAKO-Setup-1.0.0.exe" "%OUT%\KURAKO-Setup-1.0.0.exe" >nul
  echo   -> %OUT%\KURAKO-Setup-1.0.0.exe
) else (
  echo   [跳过] 未找到 ISCC.exe，未生成安装包
)
if /I "%MODE%"=="win" goto :done

:apk
REM ---- Android Release APK (split-per-abi) ----
echo === [2/2] flutter build apk --release --split-per-abi ===
call flutter build apk --release --split-per-abi
if errorlevel 1 ( echo BUILD FAILED ^(apk^) & exit /b 1 )
echo === 复制 APK 到 dist\out ===
copy /Y "build\app\outputs\flutter-apk\app-arm64-v8a-release.apk"   "%OUT%\KURAKO-arm64-v8a.apk" >nul
copy /Y "build\app\outputs\flutter-apk\app-armeabi-v7a-release.apk" "%OUT%\KURAKO-armeabi-v7a.apk" >nul 2>&1
copy /Y "build\app\outputs\flutter-apk\app-x86_64-release.apk"      "%OUT%\KURAKO-x86_64.apk" >nul 2>&1
echo   -> %OUT%\KURAKO-arm64-v8a.apk

:done
echo.
echo ============================================================
echo  完成。所有产物在： %OUT%
echo ============================================================
explorer "%OUT%"
endlocal

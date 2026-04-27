@echo off
setlocal EnableExtensions

cd /d "%~dp0"
set "ROOT=%CD%"
set "EXIT_CODE=0"
set "FLUTTER_CMD=flutter"
set "DART_CMD=dart"

echo [flclash] Starting Windows test launcher...
echo [flclash] Repo dir: %ROOT%
echo.

where flutter >nul 2>nul
if errorlevel 1 (
  if exist "C:\flutter\bin\flutter.bat" set "FLUTTER_CMD=C:\flutter\bin\flutter.bat"
  if exist "C:\Flutter\bin\flutter.bat" set "FLUTTER_CMD=C:\Flutter\bin\flutter.bat"
)

where dart >nul 2>nul
if errorlevel 1 (
  if exist "C:\flutter\bin\dart.bat" set "DART_CMD=C:\flutter\bin\dart.bat"
  if exist "C:\Flutter\bin\dart.bat" set "DART_CMD=C:\Flutter\bin\dart.bat"
)

if not exist "%FLUTTER_CMD%" if /I not "%FLUTTER_CMD%"=="flutter" (
  echo [flclash] Flutter fallback path does not exist: %FLUTTER_CMD%
  set "EXIT_CODE=1"
  goto end
)

if not exist "%DART_CMD%" if /I not "%DART_CMD%"=="dart" (
  echo [flclash] Dart fallback path does not exist: %DART_CMD%
  set "EXIT_CODE=1"
  goto end
)

where "%FLUTTER_CMD%" >nul 2>nul
if errorlevel 1 if /I "%FLUTTER_CMD%"=="flutter" (
  echo [flclash] flutter was not found in Windows PATH, and no fallback path worked.
  set "EXIT_CODE=1"
  goto end
)

where "%DART_CMD%" >nul 2>nul
if errorlevel 1 if /I "%DART_CMD%"=="dart" (
  echo [flclash] dart was not found in Windows PATH, and no fallback path worked.
  set "EXIT_CODE=1"
  goto end
)

echo [flclash] Using Flutter: %FLUTTER_CMD%
echo [flclash] Using Dart: %DART_CMD%
echo.

if not exist "libclash\windows\FlClashCore.exe" goto build_core
if not exist "libclash\windows\FlClashHelperService.exe" goto build_core
if not exist "env.json" goto build_core
goto pub_get

:build_core
echo [flclash] Native Windows core is missing. Building core...
call "%DART_CMD%" .\setup.dart windows --arch amd64 --out core
if errorlevel 1 (
  echo [flclash] Core build failed.
  set "EXIT_CODE=1"
  goto end
)

:pub_get
echo [flclash] Running flutter pub get...
call "%FLUTTER_CMD%" pub get
if errorlevel 1 (
  echo [flclash] flutter pub get failed.
  set "EXIT_CODE=1"
  goto end
)

echo.
echo [flclash] Launching Flutter Windows debug app...
echo [flclash] Close the app window to stop flutter run.
echo.
call "%FLUTTER_CMD%" run -d windows
set "EXIT_CODE=%ERRORLEVEL%"

:end
echo.
if "%EXIT_CODE%"=="0" (
  echo [flclash] Test process exited.
) else (
  echo [flclash] Startup failed with exit code %EXIT_CODE%.
)
echo.
pause
exit /b %EXIT_CODE%

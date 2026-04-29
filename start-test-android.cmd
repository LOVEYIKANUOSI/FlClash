@echo off
setlocal EnableExtensions

cd /d "%~dp0"
set "ROOT=%CD%"
set "EXIT_CODE=0"
set "FLUTTER_CMD=flutter"
set "EMULATOR_NAME=Pixel_7_API_35"
set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"

echo [flclash] Starting Android test launcher...
echo [flclash] Repo dir: %ROOT%
echo [flclash] Emulator: %EMULATOR_NAME%
echo.

:: --- Find Flutter ---
where flutter >nul 2>nul
if errorlevel 1 (
  if exist "C:\flutter\bin\flutter.bat" set "FLUTTER_CMD=C:\flutter\bin\flutter.bat"
  if exist "C:\Flutter\bin\flutter.bat" set "FLUTTER_CMD=C:\Flutter\bin\flutter.bat"
)
if not exist "%FLUTTER_CMD%" if /I not "%FLUTTER_CMD%"=="flutter" (
  echo [flclash] Flutter not found.
  set "EXIT_CODE=1"
  goto end
)
echo [flclash] Using Flutter: %FLUTTER_CMD%

:: --- Set JAVA_HOME ---
if exist "%JAVA_HOME%\bin\java.exe" (
  echo [flclash] JAVA_HOME=%JAVA_HOME%
) else (
  echo [flclash] Warning: JAVA_HOME not found at %JAVA_HOME%
)

:: --- Check / launch emulator ---
echo [flclash] Checking Android device...
"%FLUTTER_CMD%" devices 2>nul | findstr "emulator-" >nul
if errorlevel 1 (
  echo [flclash] No emulator connected. Launching %EMULATOR_NAME%...
  "%FLUTTER_CMD%" emulators --launch %EMULATOR_NAME%
  if errorlevel 1 (
    echo [flclash] Failed to launch emulator. Please start it manually from Android Studio.
    set "EXIT_CODE=1"
    goto end
  )
  echo [flclash] Waiting for emulator to boot...
  :: Wait up to 60 seconds
  for /L %%i in (1,1,60) do (
    "%FLUTTER_CMD%" devices 2>nul | findstr "emulator-" >nul
    if not errorlevel 1 goto emulator_ready
    timeout /t 1 /nobreak >nul
  )
  echo [flclash] Emulator did not become ready in time.
  set "EXIT_CODE=1"
  goto end
)
:emulator_ready
echo [flclash] Emulator is ready.

:: --- Pub get ---
echo [flclash] Running flutter pub get...
call "%FLUTTER_CMD%" pub get
if errorlevel 1 (
  echo [flclash] flutter pub get failed.
  set "EXIT_CODE=1"
  goto end
)

:: --- Run ---
echo.
echo [flclash] Launching FlClash on Android...
echo [flclash] Press q to quit, R to hot restart.
echo.
call "%FLUTTER_CMD%" run -d emulator-5554
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

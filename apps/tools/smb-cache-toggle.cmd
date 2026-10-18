@echo off
:: Purpose: Toggle Windows SMB client caching so mapped network drives refresh instantly
:: Double-click to switch between "caching off" and Windows defaults. Asks for admin.

net session >nul 2>&1 || (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "K=HKLM\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters"
set "VALUES=DirectoryCacheLifetime FileNotFoundCacheLifetime FileInfoCacheLifetime"

reg query "%K%" /v DirectoryCacheLifetime 2>nul | find "0x0" >nul
if %errorlevel%==0 goto enable

:disable
for %%V in (%VALUES%) do reg add "%K%" /v %%V /t REG_DWORD /d 0 /f >nul
echo.
echo  SMB caching is now OFF - network folders refresh instantly.
goto done

:enable
for %%V in (%VALUES%) do reg delete "%K%" /v %%V /f >nul 2>&1
echo.
echo  SMB caching is now ON - Windows defaults restored.

:done
echo  Restart Windows to apply. Run this file again to switch back.
echo.
choice /c YN /m " Restart now"
if errorlevel 2 exit /b
shutdown /r /t 5

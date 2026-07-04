@echo off
set DEVECO_SDK_HOME=D:\Program Files\Huawei\DevEco Studio\sdk
set HDC_EXE=%DEVECO_SDK_HOME%\default\openharmony\toolchains\hdc.exe

cd /d D:\05_HarmonyNext\XiaoQ

echo ========== UNINSTALL OLD ==========
"%HDC_EXE%" -t 127.0.0.1:5555 app uninstall xiaoq.debug.profile
echo ========== INSTALL NEW ==========
"%HDC_EXE%" -t 127.0.0.1:5555 app install "D:\05_HarmonyNext\XiaoQ\entry\build\default\outputs\default\entry-default-signed.hap"
if %ERRORLEVEL% neq 0 (
    echo ========== DEPLOY FAILED ==========
    exit /b 1
)
echo ========== DEPLOY v1.9.10 SUCCESS ==========

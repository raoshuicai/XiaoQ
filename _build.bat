@echo off
set DEVECO_SDK_HOME=D:\Program Files\Huawei\DevEco Studio\sdk
set NODE_HOME=D:\Program Files\Huawei\DevEco Studio\tools\node
set JAVA_HOME=D:\Program Files\Huawei\DevEco Studio\jbr
set NODE_EXE=%NODE_HOME%\node.exe
set HVIGOR_JS=D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js
set HDC_EXE=%DEVECO_SDK_HOME%\default\openharmony\toolchains\hdc.exe
set PATH=%JAVA_HOME%\bin;%NODE_HOME%;%DEVECO_SDK_HOME%\default\openharmony\toolchains;%PATH%

cd /d D:\05_HarmonyNext\XiaoQ

echo ========== CLEAN ==========
"%NODE_EXE%" "%HVIGOR_JS%" clean

echo ========== BUILD START ==========
"%NODE_EXE%" "%HVIGOR_JS%" assembleApp -p product=default -p buildMode=debug
if %ERRORLEVEL% neq 0 (
    echo ========== BUILD FAILED ==========
    exit /b 1
)
echo ========== BUILD SUCCESS ==========

echo ========== UNINSTALL OLD ==========
"%HDC_EXE%" -t 127.0.0.1:5555 app uninstall xiaoq.debug.profile

echo ========== DEPLOY START ==========
"%HDC_EXE%" -t 127.0.0.1:5555 app install "D:\05_HarmonyNext\XiaoQ\entry\build\default\outputs\default\entry-default-signed.hap"
if %ERRORLEVEL% neq 0 (
    echo ========== DEPLOY FAILED ==========
    exit /b 1
)
echo ========== DEPLOY v2.0.0 SUCCESS ==========

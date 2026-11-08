<#
.SYNOPSIS
  小Q APP 一键编译部署
.DESCRIPTION
  编译 -> 部署 -> 验证 三步合一，一次工具调用完成
#>
param(
  [string]$ProjectDir = "D:\05_HarmonyNext\XiaoQ",
  [string]$RepoDir = "",
  [switch]$SkipSync = $false,
  [string]$DeviceId = "127.0.0.1:5555",
  # 2026-11-08: hdc default server port 8710 falls inside a Hyper-V reserved
  # range (8693-8752) -> bind fails, every hdc command silently no-ops and
  # install falsely reports success. Pass an explicit server port instead.
  [int]$HdcServerPort = 18710
)

$ErrorActionPreference = "Continue"
$env:DEVECO_SDK_HOME = "D:\Program Files\Huawei\DevEco Studio\sdk"
$env:JAVA_HOME = "D:\Program Files\Huawei\DevEco Studio\jbr"
$env:NODE_HOME = "D:\Program Files\Huawei\DevEco Studio\tools\node"
$env:PATH = "$env:JAVA_HOME\bin;$env:NODE_HOME;$env:PATH"

$HDC = "D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$HDCS = @("-s", "127.0.0.1:$HdcServerPort")
$HR = "=" * 60

function Step($Msg) { Write-Host "`n$HR`n$Msg`n$HR" -ForegroundColor Cyan }
function OK($Msg) { Write-Host "  OK $Msg" -ForegroundColor Green }
function Fail($Msg) { Write-Host "  FAILED $Msg" -ForegroundColor Red; exit 1 }

# 1. sync
if ((-not $SkipSync) -and ($RepoDir -ne "")) {
  Step "1/3 Sync source files"
  $files = @(
    "AppScope/app.json5",
    "entry/src/main/module.json5",
    "entry/src/main/ets/pages/ChatPage.ets",
    "entry/src/main/ets/utils/HermesApi.ets",
    "entry/src/main/ets/utils/PreferencesHelper.ets",
    "entry/src/main/ets/utils/WebSocketClient.ets",
    "entry/src/main/ets/entryability/PushServiceAbility.ets",
    "entry/src/main/ets/entryability/EntryAbility.ets"
  )
  foreach ($f in $files) {
    $src = "$RepoDir/$f"
    $dst = "$ProjectDir/$f"
    if (Test-Path $src) {
      Copy-Item -Path $src -Destination $dst -Force
      OK $f
    }
  }
}

# 2. build
Step "2/3 Build HAP"
Set-Location $ProjectDir
$node = "D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe"
$hvigor = "D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js"
$log = "$ProjectDir\_build.log"

& $node $hvigor assembleHap -p product=default -p buildMode=debug --no-daemon *> $log
$ok = $LASTEXITCODE -eq 0
$text = Get-Content $log -Raw

if ($ok) {
  OK "BUILD SUCCESSFUL"
  Remove-Item $log -Force -ErrorAction SilentlyContinue
} else {
  Write-Host "BUILD FAILED" -ForegroundColor Red
  $text -split "`n" | Select-String "ERROR.*\.ets" | Select-Object -First 5 | ForEach-Object {
    Write-Host "  $($_.Line.Trim())" -ForegroundColor Yellow
  }
  Fail "See $_build.log for details"
}

# 3. deploy + verify
Step "3/3 Deploy to $DeviceId"
$hap = "$ProjectDir\entry\build\default\outputs\default\entry-default-signed.hap"
if (-not (Test-Path $hap)) {
  Fail "HAP not found: $hap"
}
$size = [math]::Round((Get-Item $hap).Length / 1KB)
OK "HAP size: ${size}KB"

# hdc 只接受原生反斜杠绝对路径（$hap 就是），不要改成相对路径或 MSYS 风格
$result = & $HDC @HDCS -t $DeviceId install -r $hap 2>&1 | Out-String
if ($result -match "Fail|error") {
  Fail "Install failed: $result"
}
OK "Install success"

Start-Sleep -Seconds 1
& $HDC @HDCS -t $DeviceId shell "aa start -a EntryAbility -b xiaoq.debug.profile" *>$null
OK "App started"

$dump = & $HDC @HDCS -t $DeviceId shell "bm dump -n xiaoq.debug.profile" 2>&1 | Out-String
$verLine = $dump | Select-String '"versionName"' | Select-Object -First 1
if ($verLine) {
  $v = ($verLine.Line -replace '.*"versionName": "(.*)"', '$1').Trim()
  Write-Host "  OK Version: $v" -ForegroundColor Green
}

Write-Host "`n$HR`n  ALL DONE`n$HR" -ForegroundColor Green

<#
.SYNOPSIS
  XiaoQ APP - build main HAP + ohosTest HAP, install, run hypium unit tests on device.
.DESCRIPTION
  Used by S4 verification (ChatService extraction). Pure ASCII to avoid codepage issues.
  -SelfTest : validate the verdict logic only, no device touched.
#>
param(
  [string]$ProjectDir = "D:\05_HarmonyNext\XiaoQ",
  [string]$DeviceId = "127.0.0.1:5555",
  [string]$BundleName = "xiaoq.debug.profile",
  [string]$TestModule = "entry_test",
  [string]$TestClass = "",
  [switch]$SelfTest
)

$HR = "=" * 60

# aa test prints one line of this shape:
#   OHOS_REPORT_RESULT: stream=Tests run: 37, Failure: 0, Error: 0, Pass: 37, Ignore: 0
# NOTE: counters are singular ("Failure:"), so the regex must not pluralize.
function Get-TestVerdict([string]$out) {
  if ($out -notmatch 'Tests run:\s*(\d+)') { return 'UNKNOWN' }
  if ([int]$Matches[1] -le 0) { return 'UNKNOWN' }
  if ($out -match 'Failure:\s*[1-9]' -or $out -match 'Error:\s*[1-9]') { return 'FAIL' }
  if ($out -match 'Failure:\s*0') { return 'PASS' }
  return 'UNKNOWN'
}

if ($SelfTest) {
  $cases = @(
    @{ name = 'pass';  text = 'OHOS_REPORT_RESULT: stream=Tests run: 37, Failure: 0, Error: 0, Pass: 37, Ignore: 0'; want = 'PASS' },
    @{ name = 'fail';  text = 'OHOS_REPORT_RESULT: stream=Tests run: 37, Failure: 2, Error: 0, Pass: 35, Ignore: 0'; want = 'FAIL' },
    @{ name = 'error'; text = 'OHOS_REPORT_RESULT: stream=Tests run: 37, Failure: 0, Error: 1, Pass: 36, Ignore: 0'; want = 'FAIL' },
    @{ name = 'zero';  text = 'OHOS_REPORT_RESULT: stream=Tests run: 0, Failure: 0, Error: 0, Pass: 0, Ignore: 0'; want = 'UNKNOWN' },
    @{ name = 'died';  text = 'error: failed to start ability, App died'; want = 'UNKNOWN' }
  )
  $bad = 0
  foreach ($c in $cases) {
    $got = Get-TestVerdict $c.text
    if ($got -eq $c.want) {
      Write-Host ("selftest[$($c.name)] got=$got want=$($c.want) OK")
    } else {
      $bad = $bad + 1
      Write-Host ("selftest[$($c.name)] got=$got want=$($c.want) MISMATCH")
    }
  }
  if ($bad -eq 0) { Write-Host 'SELFTEST_RESULT: OK'; exit 0 }
  Write-Host ("SELFTEST_RESULT: FAIL (" + $bad + " mismatches)")
  exit 1
}

$env:DEVECO_SDK_HOME = "D:\Program Files\Huawei\DevEco Studio\sdk"
$env:JAVA_HOME = "D:\Program Files\Huawei\DevEco Studio\jbr"
$env:NODE_HOME = "D:\Program Files\Huawei\DevEco Studio\tools\node"
$env:PATH = "$env:JAVA_HOME\bin;$env:NODE_HOME;$env:PATH"

$HDC   = "D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
$node  = "D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe"
$hvigor = "D:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js"

function Step($m) { Write-Host "`n$HR`n$m`n$HR" -ForegroundColor Cyan }

Set-Location $ProjectDir

Step "1/4 build main HAP"
& $node $hvigor assembleHap -p product=default -p buildMode=debug --no-daemon *> "$ProjectDir\_b_main.log"
if ($LASTEXITCODE -ne 0) {
  Write-Host "MAIN BUILD FAILED" -ForegroundColor Red
  Get-Content "$ProjectDir\_b_main.log" | Select-String "ERROR" | Select-Object -First 10 | ForEach-Object { Write-Host $_.Line.Trim() -ForegroundColor Yellow }
  exit 1
}
Write-Host "  OK main HAP built" -ForegroundColor Green

Step "2/4 build ohosTest HAP"
& $node $hvigor assembleHap --mode module -p module=entry@ohosTest -p product=default -p buildMode=debug --no-daemon *> "$ProjectDir\_b_test.log"
if ($LASTEXITCODE -ne 0) {
  Write-Host "TEST BUILD FAILED" -ForegroundColor Red
  Get-Content "$ProjectDir\_b_test.log" | Select-String "ERROR" | Select-Object -First 15 | ForEach-Object { Write-Host $_.Line.Trim() -ForegroundColor Yellow }
  exit 1
}
Write-Host "  OK ohosTest HAP built" -ForegroundColor Green

Step "3/4 install HAPs to $DeviceId"
$mainHap = "$ProjectDir\entry\build\default\outputs\default\entry-default-signed.hap"
$testHap = "$ProjectDir\entry\build\default\outputs\ohosTest\entry-ohosTest-signed.hap"
foreach ($h in @($mainHap, $testHap)) {
  if (-not (Test-Path $h)) { Write-Host "MISSING: $h" -ForegroundColor Red; exit 1 }
}
& $HDC -t $DeviceId install -r $mainHap | Out-String | Write-Host
& $HDC -t $DeviceId install -r $testHap | Out-String | Write-Host
Write-Host "  OK install done" -ForegroundColor Green

Step "4/4 run aa test"
$aaArgs = @("-t", $DeviceId, "shell", "aa", "test", "-b", $BundleName, "-m", $TestModule, "-s", "unittest", "OpenHarmonyTestRunner", "-s", "timeout", "60000")
if ($TestClass -ne "") { $aaArgs += @("-s", "class", $TestClass) }
$out = & $HDC @aaArgs 2>&1 | Out-String
$out -split "`n" | Select-String "OHOS_REPORT_RESULT|TestFinished" | ForEach-Object { Write-Host $_.Line.Trim() }

# build logs are only useful on failure (failure paths exit earlier), so drop them here
Remove-Item "$ProjectDir\_b_main.log", "$ProjectDir\_b_test.log" -Force -ErrorAction SilentlyContinue

$verdict = Get-TestVerdict $out
Write-Host "`n$HR" -ForegroundColor Cyan
if ($verdict -eq 'PASS') {
  Write-Host "TEST RESULT: PASS" -ForegroundColor Green
} elseif ($verdict -eq 'FAIL') {
  Write-Host "TEST RESULT: FAIL" -ForegroundColor Red
} else {
  Write-Host "TEST RESULT: UNKNOWN (no test summary found - inspect device output)" -ForegroundColor Yellow
}
Write-Host $HR -ForegroundColor Cyan
if ($verdict -eq 'PASS') { exit 0 } else { exit 1 }

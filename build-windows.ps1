# Dawn / FlClash Windows 构建脚本
#
# 两个值不能写进仓库源码，构建时用环境变量注入（S-34 / 订阅加密）：
#
#   $env:SUBSCRIBE_ENC_KEY = "<64 位 hex>"          # 与服务端 config('v2board.subscribe_enc_key') 一致
#   $env:PANEL_DEFAULT_URL = "https://你的面板域名"   # 登录页默认回填的面板地址，可选
#   .\build-windows.ps1
#
# 未注入 SUBSCRIBE_ENC_KEY 时构建仍可完成，但专属订阅无法解密（面板未开启 enc 时无影响）。
# 未注入 PANEL_DEFAULT_URL 时登录页面板地址为空，用户需自己填写（源码不再内置生产入口）。
param(
    [switch]$NoClean  # 跳过 flutter clean（增量构建更快，但改过 Go core 时不要用）
)

$ErrorActionPreference = "Stop"

$defineArgs = @()

$key = $env:SUBSCRIBE_ENC_KEY
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Warning "未设置 SUBSCRIBE_ENC_KEY，本次构建的专属订阅将无法解密。"
} elseif ($key.Length -ne 64) {
    Write-Error "SUBSCRIBE_ENC_KEY 必须是 64 位 hex，当前长度 $($key.Length)"
    exit 1
} else {
    $defineArgs += "--dart-define=SUBSCRIBE_ENC_KEY=$key"
}

$panelUrl = $env:PANEL_DEFAULT_URL
if ([string]::IsNullOrWhiteSpace($panelUrl)) {
    Write-Warning "未设置 PANEL_DEFAULT_URL，登录页不会预填面板地址（用户需自己填）。"
} else {
    $defineArgs += "--dart-define=PANEL_DEFAULT_URL=$panelUrl"
}

$flutter = if (Test-Path "C:\v2node\flclash2\flutter\bin\flutter.bat") {
    "C:\v2node\flclash2\flutter\bin\flutter.bat"
} else {
    "flutter"
}

if (-not $NoClean) {
    & $flutter clean
    & $flutter pub get
}

& $flutter build windows --release @defineArgs

Write-Host ""
Write-Host "构建完成: build\windows\x64\runner\Release\FlClash.exe"

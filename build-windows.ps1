# Dawn / FlClash Windows 构建脚本
#
# 专属订阅（app=flclash）的订阅正文是 AES-256-GCM 加密下发的，客户端需要注入
# 与服务端 config('v2board.subscribe_enc_key') 一致的主密钥（64 位 hex）才能解密。
# 为避免密钥进入仓库，这里从环境变量读取：
#
#   $env:SUBSCRIBE_ENC_KEY = "<64 位 hex>"
#   .\build-windows.ps1
#
# 未注入时构建仍可完成，但专属订阅会回退为明文拉取（面板未开启 enc 时无影响）。
param(
    [switch]$NoClean  # 跳过 flutter clean（增量构建更快，但改过 Go core 时不要用）
)

$ErrorActionPreference = "Stop"

$key = $env:SUBSCRIBE_ENC_KEY
if ([string]::IsNullOrWhiteSpace($key)) {
    Write-Warning "未设置 SUBSCRIBE_ENC_KEY，本次构建的专属订阅将无法解密。"
} elseif ($key.Length -ne 64) {
    Write-Error "SUBSCRIBE_ENC_KEY 必须是 64 位 hex，当前长度 $($key.Length)"
    exit 1
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

$defineArg = if ([string]::IsNullOrWhiteSpace($key)) { @() } else { @("--dart-define=SUBSCRIBE_ENC_KEY=$key") }
& $flutter build windows --release @defineArg

Write-Host ""
Write-Host "构建完成: build\windows\x64\runner\Release\FlClash.exe"

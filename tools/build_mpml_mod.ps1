# Machine Party 8 人 mod —— 生成 MPML 备选安装包
#
# 用法：  powershell -ExecutionPolicy Bypass -File tools\build_mpml_mod.ps1
# 前置：  先跑过 tools\build.ps1（本脚本吃的是 patch_gdc\ 里的 .gdc）
#
# 产物：  dist\mpml\overtime\  —— 玩家把这个文件夹整个丢进游戏的 mods\ 即可
#
# 这是**备选**安装方式。主推的仍然是 overtime_launcher.exe。
# 它存在的唯一理由：走 exe 的玩家装不了 MPML，也就用不了
# MachineParty+ / 第一人称 / 离线机器人。想要共存就走这条。
#
# 不打包 MachinePartyModLoader 本身：它的仓库没有 LICENSE
# （GitHub API 报 license:null），未经作者许可无权再分发。
# 加载器作者自己的三合一整合包里也没有塞加载器，生态惯例就是链接。

# Godot 编辑器版可执行文件。作者本机是 Steam 版，所以默认值写它；
# 别人克隆下来装在哪儿都行，两种覆盖方式：
#   powershell ... -File tools\build_mpml_mod.ps1 -Godot "D:\Godot\godot.exe"
#   $env:GODOT = "D:\Godot\godot.exe"; powershell ... -File tools\build_mpml_mod.ps1
param([string]$Godot = "")

$ErrorActionPreference = "Stop"
$root  = Split-Path -Parent $PSScriptRoot
$godot = $Godot
if ([string]::IsNullOrWhiteSpace($godot)) { $godot = $env:GODOT }
if ([string]::IsNullOrWhiteSpace($godot)) {
    $godot = "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
}

foreach ($needed in @((Join-Path $root "patch_gdc"), (Join-Path $root "mpml\overtime"), $godot)) {
    if (-not (Test-Path $needed)) { throw "缺少：$needed" }
}

$n = (Get-ChildItem (Join-Path $root "patch_gdc") -Filter *.gdc).Count
if ($n -eq 0) { throw "patch_gdc 是空的 —— 先跑 tools\build.ps1" }
Write-Host "patch_gdc 里有 $n 个 .gdc"

$out = Join-Path $root "dist\mpml\overtime"
Remove-Item (Join-Path $out "*") -Force -ErrorAction SilentlyContinue

# 用 Start-Process -Wait，不用 `&`：实测 `&` 在 Godot 还没落盘时就返回了，
# 紧跟着的 Test-Path 会稳定误报「缺产物」。build.ps1 调 gdre 也是这个写法。
Start-Process $godot -ArgumentList @(
    "--headless", "--path", (Join-Path $root "tools\probe"), "--script", "build_mpml_mod.gd"
) -NoNewWindow -Wait

# 按**产物是否齐全**判断成败。Godot 的退出码经 PowerShell 传回来不可靠
# （实测 $LASTEXITCODE 是空的），跟 build.ps1 检查 new.pck 是一个路子。
foreach ($f in @("mod.json", "main.gd", "vanilla_md5.json", "overtime_overlay.zip")) {
    $q = Join-Path $out $f
    if (-not (Test-Path $q)) { throw "生成失败：缺产物 $f" }
}

# ── 打成 Release 附件 ───────────────────────────────────
# 散文件夹没法当 Release 附件传，而公开仓库装不下它
# （make_release_repo.ps1 的干净度闸门对 .zip / .gdc 直接 throw）。
# 所以 zip 就在这里出，跟文件夹同一步 —— 分开手打必然会出现
# “文件夹新、zip 旧”而看不出来的那一天。
#
# 版本号从 vanilla_md5.json 的 game_version 取 —— 那是 build_mpml_mod.gd
# 刚从 MP8_VERSION_TAG 读出来的，唯一权威，不另立第二个来源。
# ⚠️ -Encoding UTF8 不能省：这个 JSON 里有中文，Windows PowerShell 5.1 默认按
# 系统 ANSI 读，读出来是乱码，ConvertFrom-Json 当场报 "':' or '}' expected"。
$ver = ((Get-Content (Join-Path $out "vanilla_md5.json") -Raw -Encoding UTF8 | ConvertFrom-Json).game_version) -replace '^overtime-', ''
if ([string]::IsNullOrWhiteSpace($ver)) { throw "从 vanilla_md5.json 读不出版本号" }

$zip = Join-Path $root ("dist/mpml/Machine-Party-Overtime-" + $ver + "-MPML.zip")
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $out -DestinationPath $zip
Write-Host ("      " + (Split-Path $zip -Leaf) + "  " + (Get-Item $zip).Length + " 字节（Release 附件）")

Write-Host ""
Write-Host "玩家侧安装：把 dist\mpml\overtime 整个文件夹放进游戏目录的 mods 里。" -ForegroundColor Green
Write-Host "前置是玩家自己先装 MachinePartyModLoader —— 我们不打包它。" -ForegroundColor DarkGray

# Builds dist\ from build-release\ by WHITELIST: only the Qt modules and
# plugins KadBuffer actually loads. Then installer\kadbuffer.iss packs dist\.
#
#   powershell -ExecutionPolicy Bypass -File tools\make-dist.ps1
#
# ASCII only: Windows PowerShell 5.1 reads BOM-less .ps1 as ANSI.
#
# Dropped on purpose (26.10.2026):
#   opengl32sw.dll  - software OpenGL fallback (20 MB). ANGLE (libEGL,
#                     libGLESv2, D3Dcompiler_47) stays and covers machines
#                     without a proper OpenGL driver.
#                     D3Dcompiler_47 is KEPT on purpose: Windows 10/11 have
#                     it in System32, Windows 7/8 do not.
#   imageformats    - NSPD tiles are PNG (built into QtGui), the icon is
#                     in the exe resources: qjpeg/qico not needed.
#   Qt5Widgets/Sql/SerialPort/RemoteObjects/Svg, bearer, iconengines,
#   position, sqldrivers, styles, qmltooling, QtGraphicalEffects, map
#   plugins other than itemsoverlay, Controls 2 styles other than Default.
param(
    [string]$Build = "build-release",
    [string]$Dist = "dist"
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$src = Join-Path $root $Build
$dst = Join-Path $root $Dist

if (-not (Test-Path (Join-Path $src "kadbuffer.exe"))) { throw "no kadbuffer.exe in $src" }
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Force $dst | Out-Null

$files = @(
    "kadbuffer.exe", "manual.html",
    "Qt5Core.dll", "Qt5Gui.dll", "Qt5Network.dll",
    "Qt5Qml.dll", "Qt5QmlModels.dll", "Qt5QmlWorkerScript.dll",
    "Qt5Quick.dll", "Qt5QuickControls2.dll", "Qt5QuickTemplates2.dll",
    "Qt5Location.dll", "Qt5Positioning.dll", "Qt5PositioningQuick.dll",
    "libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll",
    "libEGL.dll", "libGLESv2.dll", "D3Dcompiler_47.dll",
    "libcrypto-1_1-x64.dll", "libssl-1_1-x64.dll",
    "platforms\qwindows.dll",
    "geoservices\qtgeoservices_itemsoverlay.dll",
    "QtQml\qmldir", "QtQml\qmlplugin.dll", "QtQml\plugins.qmltypes"
)
# QML modules copied whole.
$dirs = @(
    "QtQuick.2", "QtQuick\Templates.2", "QtQuick\Layouts", "QtQuick\Window.2",
    "QtQml\Models.2", "QtQml\WorkerScript.2",
    "QtLocation", "QtPositioning"
)
# Controls 2: Default style only.
$controlsSkip = @("Fusion", "Imagine", "Material", "Universal", "designer")

foreach ($f in $files) {
    $from = Join-Path $src $f
    if (-not (Test-Path $from)) { throw "missing $from" }
    $to = Join-Path $dst $f
    New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
    Copy-Item $from $to
}
foreach ($d in $dirs) {
    $from = Join-Path $src $d
    if (-not (Test-Path $from)) { throw "missing $from" }
    $to = Join-Path $dst $d
    New-Item -ItemType Directory -Force (Split-Path -Parent $to) | Out-Null
    Copy-Item $from $to -Recurse
}
$ctlSrc = Join-Path $src "QtQuick\Controls.2"
$ctlDst = Join-Path $dst "QtQuick\Controls.2"
New-Item -ItemType Directory -Force $ctlDst | Out-Null
Get-ChildItem $ctlSrc | Where-Object { $controlsSkip -notcontains $_.Name } | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $ctlDst $_.Name) -Recurse
}
# Visual C++ runtime for OpenSSL (built with MSVC 2017): vcruntime140.dll
# 14.28 + Universal CRT (Windows SDK 10.0.10240, needed on Windows 7;
# Windows 10/11 use the system UCRT). Without it OpenSSL fails to load on
# machines lacking the VC++ Redistributable: "TLS initialization failed".
$rt = Join-Path $root "runtime"
if (-not (Test-Path (Join-Path $rt "vcruntime140.dll"))) { throw "missing runtime/vcruntime140.dll" }
Get-ChildItem $rt -Filter *.dll | ForEach-Object { Copy-Item $_.FullName (Join-Path $dst $_.Name) }

# Debug builds of plugins (*d.dll next to *.dll) are not needed.
Get-ChildItem $dst -Recurse -Filter *.pdb | Remove-Item -Force

$mb = (Get-ChildItem $dst -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
"dist: {0} files, {1:N1} MB" -f (Get-ChildItem $dst -Recurse -File).Count, $mb

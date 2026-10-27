; Установщик «Буфер участка» (KadBuffer). Пакует dist\ — его собирает
; tools\make-dist.ps1 из build-release\ по белому списку (только нужные
; модули Qt). Ни Qt, ни Python на целевой машине не нужны.
;
; Сборка: ISCC.exe installer\kadbuffer.iss
; Результат — installer\output\KadBuffer-Setup-<версия>.exe.
;
; Версия читается из VERSION в корне репозитория — та же точка правды,
; что и для exe (CMakeLists.txt/resources/version.rc.in).
#define VersionFile FileOpen(SourcePath + "..\\VERSION")
#define MyAppVersion Trim(FileRead(VersionFile))
#expr FileClose(VersionFile)

#define MyAppName "KadBuffer"
#define MyAppPublisher "KadBuffer"
#define MyAppExeName "kadbuffer.exe"

[Setup]
AppId={{7B3F2A81-4C5D-4E92-9F61-2D8A0C5E3B74}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=output
OutputBaseFilename=KadBuffer-Setup-{#MyAppVersion}
Compression=lzma2/ultra64
SolidCompression=yes
LZMAUseSeparateProcess=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile=..\resources\app.ico
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать значок на рабочем столе"; GroupDescription: "Дополнительно:"

; Обновление поверх 1.0/1.1: убрать то, чего в новом составе нет (Python,
; программный OpenGL, лишние модули Qt). [InstallDelete] выполняется до
; копирования [Files], поэтому нужные плагины из этих папок вернутся.
[InstallDelete]
Type: filesandordirs; Name: "{app}\python"
Type: filesandordirs; Name: "{app}\python-embed"
Type: filesandordirs; Name: "{app}\bearer"
Type: filesandordirs; Name: "{app}\iconengines"
Type: filesandordirs; Name: "{app}\position"
Type: filesandordirs; Name: "{app}\sqldrivers"
Type: filesandordirs; Name: "{app}\styles"
Type: filesandordirs; Name: "{app}\qmltooling"
Type: filesandordirs; Name: "{app}\QtGraphicalEffects"
Type: filesandordirs; Name: "{app}\QtQml\RemoteObjects"
Type: filesandordirs; Name: "{app}\QtQml\StateMachine"
Type: filesandordirs; Name: "{app}\QtQuick\Controls.2\Fusion"
Type: filesandordirs; Name: "{app}\QtQuick\Controls.2\Imagine"
Type: filesandordirs; Name: "{app}\QtQuick\Controls.2\Material"
Type: filesandordirs; Name: "{app}\QtQuick\Controls.2\Universal"
Type: files; Name: "{app}\geoservices\*.dll"
Type: files; Name: "{app}\opengl32sw.dll"
Type: filesandordirs; Name: "{app}\imageformats"
Type: files; Name: "{app}\Qt5Widgets.dll"
Type: files; Name: "{app}\Qt5Sql.dll"
Type: files; Name: "{app}\Qt5SerialPort.dll"
Type: files; Name: "{app}\Qt5RemoteObjects.dll"
Type: files; Name: "{app}\Qt5Svg.dll"

[Files]
Source: "..\dist\*"; DestDir: "{app}"; Excludes: "*.bak"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Инструкция {#MyAppName}"; Filename: "{app}\manual.html"
Name: "{group}\Удалить {#MyAppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{autodesktop}\Удалить {#MyAppName}"; Filename: "{uninstallexe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Запустить {#MyAppName}"; Flags: nowait postinstall skipifsilent

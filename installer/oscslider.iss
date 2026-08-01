; Inno Setup script for OSCSlider.
; there's only one build variant (x64) - it also runs on ARM64 Windows via
; the OS's built-in x64 emulation, since Flutter doesn't ship a native ARM64
; Windows toolchain to build a genuinely separate ARM64 binary from.

#define AppName "OSCSlider"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppPublisher "OSCSlider"
#define AppExeName "OSCSlider.exe"
#define ReleaseDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{6F5215C0-AFFC-4636-8DA5-FF65CDA7723A}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#AppExeName}
OutputDir=Output
OutputBaseFilename=OSCSlider-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; x64compatible steers {autopf} to the right Program Files folder (plain
; "Program Files", not the x86 one) and - since Inno Setup 6.3 - also matches
; ARM64 Windows machines with x64 emulation, so this one installer covers both.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\Uninstall {#AppName}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

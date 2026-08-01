; Inno Setup script for OSCSlider.
; builds one architecture at a time - pass /DAppArch=x64 or /DAppArch=arm64
; on the ISCC command line (defaults to x64 if omitted). Flutter builds each
; architecture into its own output folder under build\windows\<arch>\, so
; this script just points at whichever one matches.

#ifndef AppArch
  #define AppArch "x64"
#endif

#define AppName "OSCSlider"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#define AppPublisher "OSCSlider"
#define AppExeName "OSCSlider.exe"
#define ReleaseDir "..\build\windows\" + AppArch + "\runner\Release"

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
OutputBaseFilename=OSCSlider-Setup-{#AppArch}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; ArchitecturesAllowed/InstallIn64BitMode steer {autopf} to the right Program
; Files folder (plain "Program Files" for 64-bit/ARM64, not the x86 one -
; that's reserved for genuinely 32-bit apps, which Flutter can't produce).
#if AppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

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

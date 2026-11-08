; Clearinghouse installer (Inno Setup 6). Built by .github/workflows/companion.yml on a companion-v* tag:
;   iscc /DAppVersion=0.2.0 installer.iss
; Installs per user (no admin prompt), adds a Start menu entry, and can start with Windows.
; The app updates itself by downloading the newest Clearinghouse-Setup.exe and running it /SILENT.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{6E3C1B52-6A0B-4C1B-9E3E-C1EA41A9F0A7}
AppName=Clearinghouse
AppVersion={#AppVersion}
AppPublisher=AuctionIQ
AppPublisherURL=https://github.com/Courtizy/AuctionIQ
DefaultDirName={localappdata}\Programs\Clearinghouse
DefaultGroupName=Clearinghouse
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=Clearinghouse-Setup
SetupIconFile=clearinghouse.ico
UninstallDisplayIcon={app}\Clearinghouse.exe
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=yes

[Files]
Source: "dist\Clearinghouse\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Clearinghouse"; Filename: "{app}\Clearinghouse.exe"
Name: "{userdesktop}\Clearinghouse"; Filename: "{app}\Clearinghouse.exe"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Add a desktop shortcut"; Flags: unchecked
Name: "autostart"; Description: "Start Clearinghouse with Windows"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Clearinghouse"; \
  ValueData: """{app}\Clearinghouse.exe"" --minimized"; Tasks: autostart; Flags: uninsdeletevalue

[Run]
Filename: "{app}\Clearinghouse.exe"; Description: "Open Clearinghouse"; Flags: nowait postinstall skipifsilent
Filename: "{app}\Clearinghouse.exe"; Flags: nowait runasoriginaluser; Check: WizardSilent

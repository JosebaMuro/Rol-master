; Instalador de Director de Rol para Windows (Inno Setup 6)
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6F7B2C1E-3D4A-4E59-9C7B-5A1D2E3F4B6C}
AppName=Director de Rol
AppVersion={#AppVersion}
AppPublisher=Joseba
DefaultDirName={autopf}\Director de Rol
DefaultGroupName=Director de Rol
OutputBaseFilename=DirectorDeRol-windows-x64-setup
OutputDir=Output
Compression=lzma2/ultra64
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
UninstallDisplayIcon={app}\director_de_rol.exe

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Director de Rol"; Filename: "{app}\director_de_rol.exe"
Name: "{autodesktop}\Director de Rol"; Filename: "{app}\director_de_rol.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\director_de_rol.exe"; Description: "{cm:LaunchProgram,Director de Rol}"; Flags: nowait postinstall skipifsilent

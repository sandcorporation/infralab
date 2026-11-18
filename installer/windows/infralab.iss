; infralab Windows 설치 프로그램 (Inno Setup 6).
; 버전은 빌드 인자 한 곳에서만 온다:  iscc /DAppVersion=1.0.0 infralab.iss
; Docker Desktop 은 묶지 않는다 — 설치 화면이 필요하다고 안내만 한다.

#ifndef AppVersion
  #error AppVersion 이 없습니다. 예: iscc /DAppVersion=1.0.0 infralab.iss
#endif

[Setup]
AppId={{6B1D6F0E-3C55-4C0B-9A57-1AF2A0B7E080}
AppName=infralab 실습 도구
AppVersion={#AppVersion}
AppPublisher=Sandcorp
DefaultDirName={localappdata}\Programs\infralab
DefaultGroupName=infralab
PrivilegesRequired=lowest
OutputDir=Output
OutputBaseFilename=infralab-setup-{#AppVersion}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
DisableProgramGroupPage=yes
; 설치 화면 첫 안내: Docker Desktop · Linux 컨테이너 모드 · 기업 요금제
InfoBeforeFile=docker-notice.txt

[Messages]
WelcomeLabel2=이 프로그램은 infralab 실습 도구(실습 환경을 받고 띄우는 실행 스크립트와 바로가기)를 설치합니다.%n%nDocker Desktop(Linux 컨테이너 모드)이 따로 필요합니다. 기업에서 쓰면 Docker 유료 요금제가 필요할 수 있습니다. 다음 화면의 안내를 읽어 주세요.

[Files]
Source: "infralab-start.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "docker-notice.txt"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autodesktop}\infralab 실습 시작"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\infralab-start.ps1"""; WorkingDir: "{app}"
Name: "{autoprograms}\infralab\infralab 실습 시작"; Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\infralab-start.ps1"""; WorkingDir: "{app}"
Name: "{autoprograms}\infralab\infralab 삭제"; Filename: "{uninstallexe}"

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\infralab-start.ps1"""; Description: "지금 실습 환경 시작(Docker Desktop 을 먼저 켜 두세요)"; Flags: postinstall nowait skipifsilent unchecked

[Code]
var
  UrlPage: TInputQueryWizardPage;

procedure InitializeWizard;
begin
  UrlPage := CreateInputQueryPage(wpSelectDir, 'compose.yml 주소',
    '학생(지원자) 화면의 설치 안내에서 받은 주소를 넣습니다.',
    '비워 두면 실행 스크립트가 %APPDATA%\infralab\compose.yml 을 그대로 씁니다(브라우저로 받아 그 폴더에 저장).');
  UrlPage.Add('compose.yml 주소:', False);
  UrlPage.Add('대시보드 주소(선택, 시작 뒤 브라우저로 엽니다):', False);
end;

function JsonEscape(const S: String): String;
begin
  Result := S;
  StringChangeEx(Result, '\', '\\', True);
  StringChangeEx(Result, '"', '\"', True);
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Dir: String;
begin
  if CurStep = ssPostInstall then
  begin
    Dir := ExpandConstant('{userappdata}\infralab');
    ForceDirectories(Dir);
    SaveStringToFile(Dir + '\settings.json',
      '{"compose_url":"' + JsonEscape(Trim(UrlPage.Values[0])) + '","dashboard_url":"' +
      JsonEscape(Trim(UrlPage.Values[1])) + '"}', False);
  end;
end;

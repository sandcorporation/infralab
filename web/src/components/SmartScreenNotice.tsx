// Windows 설치 파일 내려받기 링크와 SmartScreen 안내. 설치 파일은 서명 인증서 없이 배포한다 — 실행하면 SmartScreen
// 경고가 Inno Setup 화면보다 먼저 뜬다(대표 결정 2026-11-18, #115).
export const WINDOWS_INSTALLER_URL = "https://github.com/sandcorporation/infralab/releases/latest";

export const SMARTSCREEN_NOTICE =
  "'Windows의 PC 보호' 창이 뜨면 '추가 정보' → '실행'을 누르세요. 서명 인증서가 없는 설치 파일이라 뜨는 경고입니다.";

export function WindowsInstallerNotice() {
  return (
    <div className="windows-installer">
      <a href={WINDOWS_INSTALLER_URL} target="_blank" rel="noreferrer">
        Windows 설치 파일 내려받기
      </a>
      <p className="smartscreen-notice">{SMARTSCREEN_NOTICE}</p>
    </div>
  );
}

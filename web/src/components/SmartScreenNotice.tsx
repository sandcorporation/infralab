// 서명 인증서 없이 배포하는 Windows 설치 파일 — 실행하면 SmartScreen 경고가 먼저 뜬다(대표 결정 2026-11-18, #115).
export const SMARTSCREEN_NOTICE =
  "'Windows의 PC 보호' 창이 뜨면 '추가 정보' → '실행'을 누르세요. 서명 인증서가 없는 설치 파일이라 뜨는 경고입니다.";

export function SmartScreenNotice() {
  return <span className="smartscreen-notice">{SMARTSCREEN_NOTICE}</span>;
}

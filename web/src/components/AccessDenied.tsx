import { useState } from "react";
import { useLocation, useNavigate } from "react-router-dom";
import { useAuth } from "../auth";
import { isExamUser } from "../exam";

/**
 * 강사 화면 거절. 응시(`exam-invite:`) 세션이면 그 사실을, 아니면 권한이 없음을 말하고, 둘 다 로그아웃 뒤
 * 지금 경로로 돌아오는 로그인 길을 준다(#155).
 */
export function AccessDenied() {
  const { me, logout } = useAuth();
  const location = useLocation();
  const navigate = useNavigate();
  const [busy, setBusy] = useState(false);
  async function switchAccount() {
    setBusy(true);
    try {
      await logout();
    } finally {
      navigate(`/login?${new URLSearchParams({ next: location.pathname + location.search })}`, { replace: true });
    }
  }
  return <AccessDeniedView examSession={isExamUser(me?.username)} busy={busy} onSwitch={() => void switchAccount()} />;
}

export function AccessDeniedView({ examSession, busy, onSwitch }: { examSession: boolean; busy: boolean; onSwitch: () => void }) {
  return (
    <section className="access-denied">
      <h1 className="sc-page-head-title">{examSession ? "응시 세션으로 들어와 있습니다" : "강사만 볼 수 있는 화면입니다"}</h1>
      <button onClick={onSwitch} disabled={busy}>
        {examSession ? "로그아웃하고 내 계정으로 로그인" : "로그아웃하고 다른 계정으로 로그인"}
      </button>
    </section>
  );
}

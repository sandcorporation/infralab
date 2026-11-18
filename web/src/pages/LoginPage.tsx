import { useState, type FormEvent } from "react";
import { Navigate, useLocation, useNavigate, useSearchParams } from "react-router-dom";
import { loginUrl } from "../api";
import { useAuth } from "../auth";

// 개발용 로그인 폼은 개발 서버(DEV)이거나 명시 변수 VITE_DEV_LOGIN=1 일 때만 보인다(backend 도 DEBUG 에서만 받는다).
// 운영 빌드는 Sandcorp 계정 버튼 하나 — 카카오·GitHub·Google 선택은 auth 쪽 화면이다.
function devLoginAllowed(): boolean {
  return import.meta.env.DEV || import.meta.env.VITE_DEV_LOGIN === "1";
}

export default function LoginPage() {
  const { me, login } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const [params] = useSearchParams();
  const returnTo = (location.state as { from?: string } | null)?.from ?? "/";
  const [uid, setUid] = useState("");
  const [nickname, setNickname] = useState("");
  const [error, setError] = useState<string | null>(params.get("error") ? "로그인하지 못했습니다. 다시 시도하세요." : null);
  const [busy, setBusy] = useState(false);

  if (me) return <Navigate to={returnTo} replace />;

  async function fakeLogin(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      await login(uid, nickname);
      navigate(returnTo, { replace: true });
    } catch (err) {
      setError((err as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card narrow">
      <h1>로그인</h1>
      {devLoginAllowed() ? (
        <>
          <p className="muted">개발용 로그인</p>
          <form onSubmit={fakeLogin} className="stack">
            <label>
              아이디
              <input value={uid} onChange={(e) => setUid(e.target.value)} placeholder="예: student1" required />
            </label>
            <label>
              표시 이름 (선택)
              <input value={nickname} onChange={(e) => setNickname(e.target.value)} placeholder="예: 김철수" />
            </label>
            <button type="submit" disabled={busy || !uid}>
              {busy ? "로그인 중…" : "로그인"}
            </button>
          </form>
        </>
      ) : (
        <button className="sso" onClick={() => window.location.assign(loginUrl(returnTo))}>Sandcorp 계정으로 로그인</button>
      )}
      {error && <p className="error">{error}</p>}
    </section>
  );
}

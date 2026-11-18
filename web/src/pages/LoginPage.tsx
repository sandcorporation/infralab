import { useState, type FormEvent } from "react";
import { Navigate, useLocation, useNavigate } from "react-router-dom";
import { useAuth } from "../auth";
import { kakaoEnabled, startKakaoLogin } from "../kakao";

// 개발용(Fake) 로그인 폼은 개발 서버(DEV)이거나 명시 변수 VITE_DEV_LOGIN=1 일 때만 보인다.
// 운영 빌드는 카카오 키가 없어도 폼을 띄우지 않는다.
function devLoginAllowed(): boolean {
  return import.meta.env.DEV || import.meta.env.VITE_DEV_LOGIN === "1";
}

export default function LoginPage() {
  const { me, login } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const returnTo = (location.state as { from?: string } | null)?.from ?? "/";
  const [uid, setUid] = useState("");
  const [nickname, setNickname] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  if (me) return <Navigate to={returnTo} replace />;

  async function fakeLogin(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError(null);
    try {
      // Fake 어댑터 토큰 형식: "<uid>:<email>[:<nickname>]"
      await login("kakao", `${uid}:${uid}@example.com${nickname ? `:${nickname}` : ""}`);
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
      {kakaoEnabled ? (
        <button className="kakao" onClick={() => startKakaoLogin(returnTo)}>
          카카오로 로그인
        </button>
      ) : !devLoginAllowed() ? (
        <p className="muted">로그인 준비 중</p>
      ) : (
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
      )}
      {error && <p className="error">{error}</p>}
    </section>
  );
}

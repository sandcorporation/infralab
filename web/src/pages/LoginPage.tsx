import { useState, type FormEvent } from "react";
import { Navigate, useLocation, useNavigate } from "react-router-dom";
import { useAuth } from "../auth";
import { kakaoEnabled, startKakaoLogin } from "../kakao";

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
      ) : (
        <>
          <p className="muted">개발 모드 — 카카오 키가 없어 Fake 로그인을 씁니다. 아이디만 넣으면 됩니다.</p>
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

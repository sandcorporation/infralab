import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useSearchParams } from "react-router-dom";
import { useAuth } from "../auth";
import { finishKakaoLogin } from "../kakao";

export default function KakaoCallbackPage() {
  const [params] = useSearchParams();
  const navigate = useNavigate();
  const { login } = useAuth();
  const [error, setError] = useState<string | null>(null);
  // 인가 코드는 한 번만 쓸 수 있다 — StrictMode 의 두 번째 effect 가 다시 교환을 시도하면 안 된다.
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    const code = params.get("code");
    const state = params.get("state") ?? "";
    if (!code) {
      setError(params.get("error_description") ?? "카카오가 인가 코드를 주지 않았습니다.");
      return;
    }
    finishKakaoLogin(code, state)
      .then(async ({ accessToken, returnTo }) => {
        await login("kakao", accessToken);
        navigate(returnTo, { replace: true });
      })
      .catch((err: Error) => setError(err.message));
  }, [params, login, navigate]);

  return (
    <section className="card narrow">
      <h1>카카오 로그인</h1>
      {error ? (
        <>
          <p className="error">{error}</p>
          <p>
            <Link className="button" to="/login">
              다시 로그인
            </Link>
          </p>
        </>
      ) : (
        <p className="muted">로그인 중…</p>
      )}
    </section>
  );
}

import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { ApiError, join, previewJoin, type JoinPreview } from "../api";
import { useAuth } from "../auth";

type Phase = "idle" | "joining" | "failed";

// 가입 링크. 로그인하지 않았으면 기수 이름을 보여 주고 로그인으로 보낸 뒤 돌아와 자동으로 참여한다.
// 이미 로그인 상태면 바로 참여한다 — 재수강도 같은 계정이다.
export default function JoinPage() {
  const { token = "" } = useParams();
  const { me, loading } = useAuth();
  const navigate = useNavigate();
  const [preview, setPreview] = useState<JoinPreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [phase, setPhase] = useState<Phase>("idle");
  // StrictMode 가 effect 를 두 번 돌려도 POST /join 은 한 번만.
  const attempted = useRef(false);

  useEffect(() => {
    let cancelled = false;
    previewJoin(token)
      .then((p) => !cancelled && setPreview(p))
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [token]);

  useEffect(() => {
    if (loading || !me || !preview || !preview.join_open || attempted.current) return;
    attempted.current = true;
    setPhase("joining");
    join(token)
      .then(() => navigate("/", { replace: true, state: { joined: preview.name } }))
      .catch((err: ApiError) => {
        setError(err.message);
        setPhase("failed");
      });
  }, [loading, me, preview, token, navigate]);

  function retry() {
    attempted.current = false;
    setError(null);
    setPhase("idle");
    // preview 를 다시 받아 effect 가 다시 돌게 한다(가입이 다시 열렸을 수 있다).
    previewJoin(token).then(setPreview).catch((err: ApiError) => setError(err.message));
  }

  return (
    <section className="card narrow">
      <h1>기수 가입</h1>
      {error && <p className="error">{error}</p>}
      {!error && !preview && <p className="muted">확인 중…</p>}
      {preview && (
        <>
          <p>
            <strong>{preview.name}</strong> 에 가입합니다.
          </p>
          {!preview.join_open && <p className="error">가입이 닫힌 기수입니다.</p>}
          {preview.join_open && !me && !loading && (
            <p>
              <Link className="button" to="/login" state={{ from: `/join/${token}` }}>
                로그인하고 가입하기
              </Link>
            </p>
          )}
          {phase === "joining" && <p className="muted">가입하는 중…</p>}
          {phase === "failed" && <button onClick={retry}>다시 시도</button>}
        </>
      )}
    </section>
  );
}

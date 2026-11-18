import { useEffect, useRef, useState } from "react";
import { Link, useNavigate, useParams } from "react-router-dom";
import { ApiError, acceptOrgInvite, previewOrgInvite, type OrgInvitePreview } from "../api";
import { useAuth } from "../auth";

// 조직 담당자 초대 링크. 로그인하지 않았으면 조직 이름을 보여 주고 로그인으로 보낸 뒤 돌아와 자동으로 수락한다.
export default function OrgInvitePage() {
  const { token = "" } = useParams();
  const { me, loading, refreshMe } = useAuth();
  const navigate = useNavigate();
  const [preview, setPreview] = useState<OrgInvitePreview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [accepting, setAccepting] = useState(false);
  // StrictMode 가 effect 를 두 번 돌려도 수락은 한 번만.
  const attempted = useRef(false);

  useEffect(() => {
    let cancelled = false;
    previewOrgInvite(token)
      .then((p) => !cancelled && setPreview(p))
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [token]);

  useEffect(() => {
    if (loading || !me || !preview || !preview.valid || attempted.current) return;
    attempted.current = true;
    setAccepting(true);
    acceptOrgInvite(token)
      .then(async () => {
        await refreshMe();
        navigate("/instructor", { replace: true });
      })
      .catch((err: ApiError) => {
        setError(err.message);
        setAccepting(false);
      });
  }, [loading, me, preview, token, navigate, refreshMe]);

  return (
    <section className="card narrow">
      <h1>조직 담당자 초대</h1>
      {error && <p className="error">{error}</p>}
      {!error && !preview && <p className="muted">확인 중…</p>}
      {preview && (
        <>
          <p>
            <strong>{preview.org_name}</strong> 의 담당자({preview.role})로 들어갑니다.
          </p>
          {!preview.valid && <p className="error">만료되었거나 닫힌 초대 링크입니다. 담당자에게 새 링크를 받으세요.</p>}
          {preview.valid && !me && !loading && (
            <p>
              <Link className="button" to="/login" state={{ from: `/org-invite/${token}` }}>
                로그인하고 수락하기
              </Link>
            </p>
          )}
          {accepting && <p className="muted">수락하는 중…</p>}
        </>
      )}
    </section>
  );
}

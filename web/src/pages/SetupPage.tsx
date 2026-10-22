import { useState } from "react";
import { Link, useParams } from "react-router-dom";
import { ApiError, fetchComposeFile, parseId, regenerateAgentToken } from "../api";
import { AgentStatusBadge, useAgentProbe } from "../components/AgentStatusBadge";
import { useMyCohort } from "../hooks";

export default function SetupPage() {
  const { id } = useParams();
  const cohortId = parseId(id);
  const { cohort, error: loadError, setCohort } = useMyCohort(cohortId);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState(false);
  const [confirmRegen, setConfirmRegen] = useState(false);
  const [busy, setBusy] = useState(false);
  const probe = useAgentProbe(cohort?.agent_url, cohort?.agent_token, 3000);

  async function download() {
    if (cohortId === null) return;
    setError(null);
    try {
      const text = await fetchComposeFile(cohortId);
      const url = URL.createObjectURL(new Blob([text], { type: "text/yaml" }));
      const a = document.createElement("a");
      a.href = url;
      a.download = "compose.yml";
      document.body.appendChild(a);
      a.click();
      // 클릭 직후 바로 지우면 일부 브라우저가 내려받기를 취소한다.
      setTimeout(() => {
        a.remove();
        URL.revokeObjectURL(url);
      }, 1000);
    } catch (err) {
      setError((err as ApiError).message);
    }
  }

  async function copy() {
    if (cohortId === null) return;
    setError(null);
    try {
      await navigator.clipboard.writeText(await fetchComposeFile(cohortId));
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch (err) {
      setError((err as Error).message);
    }
  }

  async function regenerate() {
    if (cohortId === null) return;
    setBusy(true);
    setError(null);
    try {
      setCohort(await regenerateAgentToken(cohortId));
      setConfirmRegen(false);
    } catch (err) {
      setError((err as ApiError).message);
    } finally {
      setBusy(false);
    }
  }

  if (loadError) return <p className="error">{loadError}</p>;
  if (!cohort) return <p className="muted">불러오는 중…</p>;

  return (
    <section>
      <p>
        <Link to={`/cohorts/${cohort.id}`}>← {cohort.name}</Link>
      </p>
      <div className="row">
        <h1>실습 환경 설치</h1>
        <AgentStatusBadge probe={probe} />
      </div>
      {error && <p className="error">{error}</p>}

      <section className="card">
        <h2>준비물</h2>
        <ul>
          <li>
            <strong>Docker Desktop</strong> (또는 Docker Engine + compose v2). 설치 뒤 한 번 실행해 둔다.
          </li>
          <li>
            <strong>Chrome</strong>. Safari 는 지원하지 않는다.
          </li>
          <li>
            메모리: kind(Kubernetes) 시나리오까지 하려면 Docker 에 <strong>6GB 이상</strong>을 준다.
          </li>
        </ul>
        <details>
          <summary>Windows 주의</summary>
          <p>
            Docker Desktop 은 WSL2 를 쓴다. 메모리가 기본값(전체의 절반)보다 작게 잡혔다면 사용자 홈의{" "}
            <code>.wslconfig</code> 에 <code>[wsl2]</code> / <code>memory=8GB</code> 를 적고 <code>wsl --shutdown</code> 뒤
            Docker Desktop 을 다시 켠다. 명령은 PowerShell 이나 Windows Terminal 에서 친다.
          </p>
        </details>
        <details>
          <summary>Mac 주의</summary>
          <p>
            Docker Desktop → Settings → Resources 에서 Memory 를 6GB 이상으로 올린다. Apple Silicon 에서는 이미지가
            amd64 라 에뮬레이션으로 돌며 조금 느릴 수 있다.
          </p>
        </details>
      </section>

      <section className="card">
        <h2>세 단계</h2>
        <ol className="steps">
          <li>
            홈 폴더 아래에 새 폴더를 만든다. 예: <code>~/infralab</code> (Windows 는 <code>C:\Users\이름\infralab</code>).
          </li>
          <li>
            <strong>compose.yml</strong> 을 그 폴더에 저장한다. 내 에이전트 토큰이 들어 있으니 공유하지 않는다.
            <div className="row actions">
              <button onClick={download}>compose.yml 내려받기</button>
              <button className="secondary" onClick={copy}>
                {copied ? "복사됨" : "내용 복사"}
              </button>
            </div>
          </li>
          <li>
            그 폴더에서 터미널을 열고 실행한다.
            <pre>
              <code>docker compose up -d</code>
            </pre>
            첫 실행은 이미지를 받느라 몇 분 걸린다(Floci 약 350MB, workstation 약 300MB, kind 노드 이미지 약 1GB 는 클러스터를
            처음 올릴 때). 옆에 생기는 <code>work</code> 폴더가 터미널의 <code>/work</code> 다.
          </li>
        </ol>
        <p>
          끝나면 위 배지가 <strong>「에이전트 연결됨」</strong>이 된다. 안 되면 Docker Desktop 실행 여부와{" "}
          <code>docker compose ps</code> 를 확인한다.
        </p>
      </section>

      <section className="card">
        <h2>Chrome 「로컬 네트워크 접근」 허용</h2>
        <p>
          대시보드가 <code>127.0.0.1:7777</code> 의 에이전트에 접근할 때 Chrome 이 처음 한 번{" "}
          <strong>「로컬 네트워크의 기기에 접근하려 합니다」</strong> 를 묻는다. <strong>허용</strong>을 누른다. 거부했다면
          주소창 왼쪽 아이콘 → 사이트 설정에서 허용으로 바꾼다.
        </p>
        <p className="muted">
          대시보드를 <code>127.0.0.1</code>·<code>localhost</code> 로 열었을 때는 묻지 않는다.
        </p>
      </section>

      <section className="card">
        <h2>토큰 재발급</h2>
        <p className="muted">재발급 뒤 새 compose.yml 을 받아 덮어쓰고 <code>docker compose up -d</code> 를 다시 한다.</p>
        {confirmRegen ? (
          <div className="row">
            <span className="muted">지금 떠 있는 에이전트는 무효가 됩니다.</span>
            <button className="danger" onClick={regenerate} disabled={busy}>
              재발급 확정
            </button>
            <button className="link" onClick={() => setConfirmRegen(false)}>
              취소
            </button>
          </div>
        ) : (
          <button className="secondary" onClick={() => setConfirmRegen(true)}>
            에이전트 토큰 재발급
          </button>
        )}
      </section>
    </section>
  );
}

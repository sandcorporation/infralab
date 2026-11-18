import { useCallback, useEffect, useState } from "react";
import { useAuth } from "../auth";
import {
  ApiError,
  formatTime,
  orgAdmin,
  orgInviteUrl,
  type OrgInvite,
  type OrgMemberRow,
} from "../api";
import { InstructorTabs } from "../components/InstructorTabs";
import { loadSelectedOrg, pickOrg, saveSelectedOrg } from "../orgSelection";

type Role = "owner" | "staff";

// 조직 탭 — 담당자 목록·역할·내보내기, 초대 링크 복사·재발급·닫기. owner 만 관리한다.
export default function InstructorOrgPage() {
  const { me, refreshMe } = useAuth();
  const orgs = me?.orgs ?? [];
  const [orgId, setOrgId] = useState<number | null>(() => pickOrg(orgs, loadSelectedOrg())?.id ?? null);
  const org = orgs.find((o) => o.id === orgId) ?? null;
  const isOwner = org?.role === "owner";
  const [members, setMembers] = useState<OrgMemberRow[] | null>(null);
  const [invites, setInvites] = useState<OrgInvite[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [copied, setCopied] = useState<number | null>(null);
  const [confirming, setConfirming] = useState<number | null>(null);
  const [inviteRole, setInviteRole] = useState<Role>("staff");
  const [pending, setPending] = useState(false);

  const reload = useCallback(async () => {
    if (orgId === null || !isOwner) return;
    try {
      const [m, i] = await Promise.all([orgAdmin.members(orgId), orgAdmin.invites(orgId)]);
      setMembers(m);
      setInvites(i);
    } catch (err) {
      setError((err as ApiError).message);
    }
  }, [orgId, isOwner]);

  useEffect(() => {
    setMembers(null);
    setError(null);
    setConfirming(null);
    void reload();
  }, [reload]);

  async function act(label: string, fn: () => Promise<void>) {
    if (pending) return;
    setPending(true);
    setError(null);
    try {
      await fn();
      await reload();
    } catch (err) {
      setError(`${label} 실패: ${(err as ApiError).message}`);
    } finally {
      setPending(false);
      setConfirming(null);
    }
  }

  async function copy(invite: OrgInvite) {
    try {
      await navigator.clipboard.writeText(orgInviteUrl(invite.token));
      setCopied(invite.id);
      setTimeout(() => setCopied(null), 1500);
    } catch {
      setError("클립보드에 복사하지 못했습니다. 링크를 직접 선택해 복사하세요.");
    }
  }

  function chooseOrg(id: number) {
    setOrgId(id);
    saveSelectedOrg(id);
  }

  if (!org || orgId === null) return <p className="muted">담당 조직이 없습니다.</p>;

  return (
    <section>
      <InstructorTabs />
      {orgs.length > 1 ? (
        <select aria-label="조직" value={orgId} onChange={(e) => chooseOrg(Number(e.target.value))}>
          {orgs.map((o) => (
            <option key={o.id} value={o.id}>
              {o.name}
            </option>
          ))}
        </select>
      ) : (
        <p className="muted">{org.name}</p>
      )}
      <h1>조직 담당자</h1>
      {!isOwner && <p className="muted">owner 만 담당자를 관리할 수 있습니다. 내 역할: {org.role}</p>}
      {error && <p className="error">{error}</p>}
      {isOwner && (
        <>
          <h2>초대 링크</h2>
          <div className="row card">
            <div role="radiogroup" aria-label="초대 역할" className="row">
              {(["staff", "owner"] as const).map((r) => (
                <button
                  key={r}
                  type="button"
                  role="radio"
                  aria-checked={inviteRole === r}
                  className={inviteRole === r ? "" : "secondary"}
                  onClick={() => setInviteRole(r)}
                >
                  {r}
                </button>
              ))}
            </div>
            <button
              disabled={pending}
              onClick={() => act("초대 링크 발급", async () => void (await orgAdmin.createInvite(orgId, inviteRole)))}
            >
              {invites.some((i) => i.role === inviteRole) ? "재발급" : "발급"}
            </button>
          </div>
          {invites.length === 0 ? (
            <p className="muted">열린 초대 링크가 없습니다.</p>
          ) : (
            <ul className="list">
              {invites.map((i) => (
                <li key={i.id} className="card">
                  <div className="row">
                    <span className="tag">{i.role}</span>
                    <code>{orgInviteUrl(i.token)}</code>
                    <button onClick={() => copy(i)}>{copied === i.id ? "복사됨" : "링크 복사"}</button>
                    <button
                      className="secondary"
                      disabled={pending}
                      onClick={() => act("초대 링크 닫기", () => orgAdmin.revokeInvite(orgId, i.id))}
                    >
                      닫기
                    </button>
                  </div>
                  <div className="muted">만료 {formatTime(i.expires_at)}</div>
                </li>
              ))}
            </ul>
          )}
          <h2>담당자</h2>
          {!members ? (
            <p className="muted">불러오는 중…</p>
          ) : (
            <table>
              <thead>
                <tr>
                  <th>이름</th>
                  <th>역할</th>
                  <th>들어온 날</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {members.map((m) => {
                  const other: Role = m.role === "owner" ? "staff" : "owner";
                  return (
                    <tr key={m.id}>
                      <td>{m.display_name || m.username}</td>
                      <td>{m.role}</td>
                      <td>{formatTime(m.joined_at)}</td>
                      <td className="row">
                        <button
                          className="secondary"
                          disabled={pending}
                          onClick={() =>
                            act("역할 바꾸기", async () => {
                              await orgAdmin.setRole(orgId, m.id, other);
                              if (m.user_id === me?.id) await refreshMe();
                            })
                          }
                        >
                          {other} 로
                        </button>
                        {confirming === m.id ? (
                          <button
                            disabled={pending}
                            onClick={() =>
                              act("내보내기", async () => {
                                await orgAdmin.remove(orgId, m.id);
                                if (m.user_id === me?.id) await refreshMe();
                              })
                            }
                          >
                            내보내기 확정
                          </button>
                        ) : (
                          <button className="secondary" onClick={() => setConfirming(m.id)}>
                            내보내기
                          </button>
                        )}
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </>
      )}
    </section>
  );
}

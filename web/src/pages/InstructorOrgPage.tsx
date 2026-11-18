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
import { loadSelectedOrg, pickOrg, saveSelectedOrg } from "../orgSelection";
import { OrgSelect } from "../components/OrgSelect";
import { ConfirmDialog, Modal, PageHead } from "../components/ui";
import { useCrumbs } from "../shell/crumbs";
import { IconPlus } from "../shell/icons";

type Role = "owner" | "staff";

// 조직 — 담당자 표(역할·내보내기)와 열린 초대 링크(복사·닫기), 초대 발급은 상자. owner 만 관리한다.
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
  const [inviting, setInviting] = useState(false);
  useCrumbs([{ label: "조직" }]);

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
  const issued = invites.some((i) => i.role === inviteRole);

  return (
    <>
      <PageHead
        title="조직"
        sub={<OrgSelect orgs={orgs} org={org} choose={chooseOrg} />}
        actions={
          isOwner && (
            <button onClick={() => setInviting(true)}>
              <IconPlus /> 담당자 초대
            </button>
          )
        }
      />
      {!isOwner && <p className="muted">owner 만 담당자를 관리할 수 있습니다. 내 역할: {org.role}</p>}
      {error && <p className="error">{error}</p>}
      {isOwner && (
        <div className="org-grid">
          <section className="sc-panel">
            <div className="sc-panel-section">
              <h2 className="sc-panel-title">담당자 {members?.length ?? ""}</h2>
              {!members ? (
                <p className="muted">불러오는 중…</p>
              ) : (
                <div className="sc-table-scroll">
                  <table className="sc-table">
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
                            <td>
                              <span className="sc-badge sc-badge--neutral">{m.role}</span>
                            </td>
                            <td>{formatTime(m.joined_at)}</td>
                            <td className="right nowrap">
                              <button
                                className="link"
                                disabled={pending}
                                onClick={() =>
                                  act("역할 바꾸기", async () => {
                                    await orgAdmin.setRole(orgId, m.id, other);
                                    if (m.user_id === me?.id) await refreshMe();
                                  })
                                }
                              >
                                {other} 로
                              </button>{" "}
                              · {" "}
                              <button className="link" onClick={() => setConfirming(m.id)}>
                                내보내기
                              </button>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </div>
          </section>
          <section className="sc-panel">
            <div className="sc-panel-section">
              <h2 className="sc-panel-title">열린 초대 링크</h2>
              {invites.length === 0 ? (
                <p className="muted">열린 초대 링크가 없습니다.</p>
              ) : (
                <ul className="list">
                  {invites.map((i) => (
                    <li key={i.id}>
                      <div className="row">
                        <span className="sc-badge sc-badge--neutral">{i.role}</span>
                        <span className="grow muted">만료 {formatTime(i.expires_at)}</span>
                        <button className="secondary" onClick={() => copy(i)} title={orgInviteUrl(i.token)}>
                          {copied === i.id ? "복사됨" : "링크 복사"}
                        </button>
                        <button
                          className="link"
                          disabled={pending}
                          onClick={() => act("초대 링크 닫기", () => orgAdmin.revokeInvite(orgId, i.id))}
                        >
                          닫기
                        </button>
                      </div>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </section>
        </div>
      )}

      <Modal
        open={inviting}
        title="담당자 초대 링크"
        onClose={() => setInviting(false)}
        foot={
          <>
            <button type="button" className="secondary" onClick={() => setInviting(false)}>
              취소
            </button>
            <button
              type="button"
              disabled={pending}
              onClick={() =>
                act("초대 링크 발급", async () => {
                  await orgAdmin.createInvite(orgId, inviteRole);
                  setInviting(false);
                })
              }
            >
              {issued ? "재발급" : "발급"}
            </button>
          </>
        }
      >
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
        {issued && <p className="muted">같은 역할의 열린 링크는 무효가 됩니다.</p>}
      </Modal>

      <ConfirmDialog
        open={confirming !== null}
        title="담당자 내보내기"
        confirmLabel="내보내기"
        busy={pending}
        onClose={() => setConfirming(null)}
        onConfirm={() => {
          const m = members?.find((x) => x.id === confirming);
          if (!m) return;
          void act("내보내기", async () => {
            await orgAdmin.remove(orgId, m.id);
            if (m.user_id === me?.id) await refreshMe();
          });
        }}
      >
        <p>{members?.find((x) => x.id === confirming)?.display_name ?? ""} — 이 조직의 담당자에서 뺍니다.</p>
      </ConfirmDialog>
    </>
  );
}

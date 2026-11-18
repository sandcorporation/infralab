import { useState } from "react";
import { useAuth } from "../auth";
import type { OrgRole } from "../api";
import { loadSelectedOrg, pickOrg, saveSelectedOrg } from "../orgSelection";

/** 담당 조직 고르기(저장된 선택을 따른다). */
export function useSelectedOrg(): { orgs: OrgRole[]; org: OrgRole | null; choose: (id: number) => void } {
  const { me } = useAuth();
  const orgs = me?.orgs ?? [];
  const [orgId, setOrgId] = useState<number | null>(() => pickOrg(orgs, loadSelectedOrg())?.id ?? null);
  const org = orgs.find((o) => o.id === orgId) ?? null;
  return {
    orgs,
    org,
    choose: (id) => {
      setOrgId(id);
      saveSelectedOrg(id);
    },
  };
}

/** 페이지 머리 보조 줄의 조직 표시: 둘 이상이면 고르는 칸. */
export function OrgSelect({ orgs, org, choose }: ReturnType<typeof useSelectedOrg>) {
  if (!org) return null;
  if (orgs.length < 2) return <>{org.name}</>;
  return (
    <select className="sc-select" aria-label="조직" value={org.id} onChange={(e) => choose(Number(e.target.value))}>
      {orgs.map((o) => (
        <option key={o.id} value={o.id}>
          {o.name}
        </option>
      ))}
    </select>
  );
}

import type { OrgRole } from "./api";

export const SELECTED_ORG_KEY = "infralab.instructor.org";

/** 저장된 선택이 아직 담당 조직이면 그것을, 아니면 첫 조직을 고른다. 담당 조직이 없으면 null. */
export function pickOrg(orgs: OrgRole[], storedId: string | null): OrgRole | null {
  return orgs.find((o) => String(o.id) === storedId) ?? orgs[0] ?? null;
}

export function loadSelectedOrg(): string | null {
  try {
    return localStorage.getItem(SELECTED_ORG_KEY);
  } catch {
    return null;
  }
}

export function saveSelectedOrg(id: number): void {
  try {
    localStorage.setItem(SELECTED_ORG_KEY, String(id));
  } catch {
    // 저장소를 못 쓰면 이번 화면에서만 고른 채로 둔다.
  }
}

/** 묶음의 종류별 표시 이름: 수업 묶음은 「기수」, 시험 묶음은 「시험 회차」. */
export const KIND_LABEL = { class: "기수", exam: "시험 회차" } as const;

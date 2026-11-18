import { describe, expect, it } from "vitest";
import type { Cohort } from "../api";
import { filterCohorts } from "./InstructorCohortsPage";

const base: Cohort = {
  id: 0,
  org_id: 1,
  name: "",
  kind: "class",
  exam_settings: {},
  join_token: "t",
  join_open: true,
  archived: false,
  open_scenario_ids: [],
  member_count: 0,
  created_at: "2026-11-18T00:00:00Z",
};
const rows: Cohort[] = [
  { ...base, id: 1, name: "인프라 3기" },
  { ...base, id: 2, name: "신입 진단 1회차", kind: "exam" },
  { ...base, id: 3, name: "인프라 2기", archived: true },
  { ...base, id: 4, name: "다른 조직 기수", org_id: 2 },
];
const ids = (r: Cohort[]) => r.map((c) => c.id);

describe("기수 목록 거름", () => {
  it("진행 중 = 고른 조직의 보관 안 된 것 전부", () => expect(ids(filterCohorts(rows, 1, "active", ""))).toEqual([1, 2]));
  it("종류 거름은 보관 안 된 것 중에서", () => {
    expect(ids(filterCohorts(rows, 1, "class", ""))).toEqual([1]);
    expect(ids(filterCohorts(rows, 1, "exam", ""))).toEqual([2]);
  });
  it("보관됨은 보관된 것만", () => expect(ids(filterCohorts(rows, 1, "archived", ""))).toEqual([3]));
  it("이름 찾기", () => expect(ids(filterCohorts(rows, 1, "active", " 3기 "))).toEqual([1]));
});

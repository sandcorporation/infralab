import { describe, expect, it } from "vitest";
import { pickOrg } from "./orgSelection";

const orgs = [
  { id: 1, name: "A 학교", role: "owner" as const },
  { id: 2, name: "B 회사", role: "staff" as const },
];

describe("pickOrg", () => {
  it("저장된 조직이 담당이면 그것을 고른다", () => expect(pickOrg(orgs, "2")?.id).toBe(2));
  it("저장값이 없거나 담당이 아니면 첫 조직", () => {
    expect(pickOrg(orgs, null)?.id).toBe(1);
    expect(pickOrg(orgs, "9")?.id).toBe(1);
  });
  it("담당 조직이 없으면 null", () => expect(pickOrg([], "1")).toBeNull());
});

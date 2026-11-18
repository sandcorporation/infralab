import { afterEach, describe, expect, it, vi } from "vitest";
import { acceptOrgInvite, orgInviteUrl } from "./api";

afterEach(() => vi.unstubAllGlobals());

describe("조직 초대", () => {
  it("초대 링크는 /org-invite/<토큰> 이다", () => {
    vi.stubGlobal("location", { origin: "https://infralab.test" });
    expect(orgInviteUrl("abc")).toBe("https://infralab.test/org-invite/abc");
  });

  it("수락은 토큰 경로로 POST 한다", async () => {
    const fetchMock = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ org_id: 1, org_name: "A", role: "staff", created: true }), { status: 200 }),
    );
    vi.stubGlobal("fetch", fetchMock);
    const out = await acceptOrgInvite("a/b");
    expect(out.created).toBe(true);
    expect(fetchMock.mock.calls[0][0]).toBe("/api/org-invites/a%2Fb/accept");
    expect(fetchMock.mock.calls[0][1].method).toBe("POST");
  });
});

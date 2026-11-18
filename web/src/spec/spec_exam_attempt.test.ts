// target: web/src/spec/spec_exam_attempt.test.ts
// AC: #71: 웹 — 남은 시간을 서버 시각 기준으로 셈하고 H:MM:SS(한 시간 미만이면 MM:SS)로 보인다
// AC: #71: 시작 버튼은 동의를 실어 POST /api/exam/<토큰>/start 를 부른다
//
// 응시 화면이 쓰는 순수 함수와 요청(web/src/exam.ts)을 본다. 남은 시간은 서버가 준 deadline·server_time 과
// 그 응답을 받은 뒤 흐른 시간으로 센다 — 브라우저 시계가 틀려도 같은 값이어야 한다. 화면은 「손 확인」.
import { afterEach, describe, expect, it, vi } from "vitest";
import { formatRemaining, remainingSecondsAt, startExam } from "../exam";
import type { ExamStatus } from "../exam";

afterEach(() => vi.unstubAllGlobals());

describe("남은 시간", () => {
  it.skip("서버 시각과 마감 시각, 흐른 시간으로 센다", () => { // #71
    const deadline = "2026-11-18T10:00:00Z";
    const serverTime = "2026-11-18T09:00:00Z";
    expect(remainingSecondsAt(deadline, serverTime, 0)).toBe(3600);
    expect(remainingSecondsAt(deadline, serverTime, 2000)).toBe(3598);
    expect(remainingSecondsAt(deadline, "2026-11-18T09:59:30+00:00", 10_000)).toBe(20);
  });

  it.skip("마감이 지나면 0 이고 음수가 되지 않는다", () => { // #71
    expect(remainingSecondsAt("2026-11-18T10:00:00Z", "2026-11-18T09:59:59Z", 5000)).toBe(0);
    expect(remainingSecondsAt("2026-11-18T10:00:00Z", "2026-11-18T11:00:00Z", 0)).toBe(0);
  });

  it.skip("한 시간 이상은 H:MM:SS, 미만은 MM:SS 로 보인다", () => { // #71
    expect(formatRemaining(3600)).toBe("1:00:00");
    expect(formatRemaining(7322)).toBe("2:02:02");
    expect(formatRemaining(36000)).toBe("10:00:00");
    expect(formatRemaining(3599)).toBe("59:59");
    expect(formatRemaining(65)).toBe("01:05");
    expect(formatRemaining(0)).toBe("00:00");
  });
});

describe("시작", () => {
  it.skip("동의를 실어 시작 요청을 보낸다", async () => { // #71
    const status: ExamStatus = {
      cohort_id: 3,
      cohort_name: "백엔드 1회차",
      status: "in_progress",
      time_limit_minutes: 60,
      tools: ["claude_code"],
      proctoring: true,
      started_at: "2026-11-18T09:00:00Z",
      deadline: "2026-11-18T10:00:00Z",
      remaining_seconds: 3600,
      server_time: "2026-11-18T09:00:00Z",
    };
    const fetchMock = vi.fn(async () => new Response(JSON.stringify(status), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    const out = await startExam("tok123");

    expect(out).toEqual(status);
    const [path, init] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(path).toBe("/api/exam/tok123/start");
    expect(init.method).toBe("POST");
    expect(JSON.parse(String(init.body))).toEqual({ consent: true });
  });
});

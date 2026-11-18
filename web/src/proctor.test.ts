import { describe, expect, it } from "vitest";
import { watchProctorSignals } from "./exam";

function fake() {
  const handlers: Record<string, ((e: Event) => void)[]> = {};
  return {
    handlers,
    visibilityState: "visible",
    addEventListener: (t: string, h: (e: Event) => void) => (handlers[t] ??= []).push(h),
    removeEventListener: (t: string, h: (e: Event) => void) => {
      handlers[t] = (handlers[t] ?? []).filter((x) => x !== h);
    },
  };
}

describe("watchProctorSignals", () => {
  it("숨김·blur·붙여넣기를 신호로 보내고 끄면 멈춘다", () => {
    const win = fake();
    const doc = fake();
    const sent: [string, string][] = [];
    const stop = watchProctorSignals(win as never, doc as never, (k, d) => sent.push([k, d]));

    doc.visibilityState = "visible";
    doc.handlers.visibilitychange[0](new Event("visibilitychange"));
    doc.visibilityState = "hidden";
    doc.handlers.visibilitychange[0](new Event("visibilitychange"));
    win.handlers.blur[0](new Event("blur"));
    doc.handlers.paste[0]({ clipboardData: { getData: () => "ls" } } as unknown as Event);
    expect(sent).toEqual([
      ["tab_hidden", ""],
      ["focus_lost", ""],
      ["paste", "ls"],
    ]);

    stop();
    expect(win.handlers.blur).toEqual([]);
    expect(doc.handlers.paste).toEqual([]);
  });
});

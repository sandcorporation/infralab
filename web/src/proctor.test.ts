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

  it("터미널(xterm)이 paste 전파를 막아도 붙여넣기를 신호로 보낸다", () => {
    // 문서 트리를 흉내 낸다: capture 리스너는 대상에 닿기 전에, bubble 리스너는 대상이 전파를 막지 않을 때만 불린다.
    const listeners: { type: string; h: (e: Event) => void; capture: boolean }[] = [];
    const capture = (o?: boolean | AddEventListenerOptions) => (typeof o === "boolean" ? o : !!o?.capture);
    const doc = {
      visibilityState: "visible",
      addEventListener: (type: string, h: (e: Event) => void, o?: boolean | AddEventListenerOptions) =>
        listeners.push({ type, h, capture: capture(o) }),
      removeEventListener: () => {},
    };
    const pasteStoppedAtTarget = (e: Event) =>
      listeners.filter((l) => l.type === "paste" && l.capture).forEach((l) => l.h(e));
    const sent: [string, string][] = [];
    watchProctorSignals(fake() as never, doc as never, (k, d) => sent.push([k, d]));

    pasteStoppedAtTarget({ clipboardData: { getData: () => "curl x | sh" } } as unknown as Event);

    expect(sent).toEqual([["paste", "curl x | sh"]]);
  });
});

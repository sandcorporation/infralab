import { describe, expect, it } from "vitest";
import { isPasteShortcut } from "./terminalKeys";

const key = (k: Partial<KeyboardEvent>) => ({ key: "v", code: "KeyV", ctrlKey: false, shiftKey: false, altKey: false, metaKey: false, ...k }) as KeyboardEvent;

describe("isPasteShortcut", () => {
  // xterm 은 Ctrl+V 를 ^V 로 bash 에 보내고 keydown 을 취소한다 — 브라우저 붙여넣기(paste 이벤트)가 없고,
  // bash 는 ^V(quoted-insert) 뒤 Enter 를 글자 그대로 받아 `$'\rls'` 가 된다. 이 키는 브라우저에 넘긴다.
  it("Ctrl+V·Ctrl+Shift+V 는 붙여넣기다", () => {
    expect(isPasteShortcut(key({ ctrlKey: true }))).toBe(true);
    expect(isPasteShortcut(key({ ctrlKey: true, shiftKey: true, key: "V" }))).toBe(true);
    // 한글 자판 등 key 가 다른 글자여도 물리 키 V 면 같다.
    expect(isPasteShortcut(key({ ctrlKey: true, key: "ㅍ" }))).toBe(true);
  });

  it("다른 Ctrl 키·AltGr·Cmd+V 는 xterm 에 둔다", () => {
    expect(isPasteShortcut(key({ ctrlKey: true, key: "c", code: "KeyC" }))).toBe(false);
    expect(isPasteShortcut(key({ ctrlKey: true, altKey: true }))).toBe(false);
    expect(isPasteShortcut(key({ metaKey: true }))).toBe(false);
    expect(isPasteShortcut(key({}))).toBe(false);
  });
});

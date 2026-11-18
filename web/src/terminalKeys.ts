/** 브라우저 붙여넣기로 넘길 키 — Ctrl+V·Ctrl+Shift+V(물리 키 V). Cmd+V 는 xterm 이 막지 않아 따로 볼 필요가 없다. */
export function isPasteShortcut(ev: Pick<KeyboardEvent, "key" | "code" | "ctrlKey" | "altKey" | "metaKey">): boolean {
  return ev.ctrlKey && !ev.altKey && !ev.metaKey && (ev.code === "KeyV" || ev.key.toLowerCase() === "v");
}

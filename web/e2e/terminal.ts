// 시나리오 터미널(xterm ↔ 에이전트 WebSocket ↔ docker exec bash) 손잡이.
import { expect, type Page } from "@playwright/test";

/** 에이전트로 나간 터미널 입력({t:"i",d}) 을 모두 모은다 — bash 의 pty 에 들어가는 바이트 그대로다. */
export function recordTerminalInput(page: Page): string[] {
  const sent: string[] = [];
  page.on("websocket", (ws) => {
    if (!ws.url().includes("/ws/terminal")) return;
    ws.on("framesent", (f) => {
      if (typeof f.payload !== "string") return;
      try {
        const m = JSON.parse(f.payload) as { t?: string; d?: string };
        if (m.t === "i" && typeof m.d === "string") sent.push(m.d);
      } catch {
        // JSON 이 아닌 프레임은 입력이 아니다.
      }
    });
  });
  return sent;
}

/** 클립보드에 넣고 터미널에서 Ctrl+V 를 누른다(사람이 하는 붙여넣기 그대로). */
export async function pasteIntoTerminal(page: Page, text: string): Promise<void> {
  await page.evaluate((t) => navigator.clipboard.writeText(t), text);
  await page.locator(".terminal-host").click();
  await page.keyboard.press("Control+V");
}

/** 터미널 화면 글자. */
export const terminalScreen = (page: Page) => page.locator(".terminal-host .xterm-rows");

export async function typeInTerminal(page: Page, text: string): Promise<void> {
  await page.locator(".terminal-host").click();
  await page.keyboard.type(text);
}

export async function expectScreenContains(page: Page, text: string): Promise<void> {
  await expect(terminalScreen(page)).toContainText(text);
}

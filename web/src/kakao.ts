// 카카오 로그인(인가 코드 흐름). REST API 키가 설정돼 있을 때만 켜진다 — 없으면 화면은 Fake 로그인만 보인다.
// 카카오 개발자 콘솔의 Redirect URI 에 `${origin}/auth/kakao/callback` 을 등록해야 한다.

export const KAKAO_REST_KEY: string = import.meta.env.VITE_KAKAO_REST_KEY ?? "";
export const kakaoEnabled = KAKAO_REST_KEY.length > 0;

const STATE_KEY = "infralab.kakao.state";

export function redirectUri(): string {
  return `${location.origin}/auth/kakao/callback`;
}

export function startKakaoLogin(returnTo: string) {
  const state = crypto.randomUUID();
  sessionStorage.setItem(STATE_KEY, JSON.stringify({ state, returnTo }));
  const params = new URLSearchParams({
    client_id: KAKAO_REST_KEY,
    redirect_uri: redirectUri(),
    response_type: "code",
    state,
  });
  location.assign(`https://kauth.kakao.com/oauth/authorize?${params}`);
}

/** 인가 코드를 카카오 access token 으로 바꾼다. 돌아갈 경로를 함께 돌려준다.
 *  저장한 state 는 성공했을 때만 지운다 — 토큰 교환이 실패하면 같은 콜백에서 다시 시도할 수 있게. */
export async function finishKakaoLogin(code: string, state: string): Promise<{ accessToken: string; returnTo: string }> {
  const saved = sessionStorage.getItem(STATE_KEY);
  const parsed = saved ? (JSON.parse(saved) as { state: string; returnTo: string }) : null;
  if (!parsed || parsed.state !== state) throw new Error("로그인 상태가 맞지 않습니다. 다시 시도하세요.");
  const res = await fetch("https://kauth.kakao.com/oauth/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded;charset=utf-8" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: KAKAO_REST_KEY,
      redirect_uri: redirectUri(),
      code,
    }),
  });
  if (!res.ok) throw new Error(`카카오 토큰 발급 실패 (${res.status})`);
  const body = (await res.json()) as { access_token: string };
  sessionStorage.removeItem(STATE_KEY);
  return { accessToken: body.access_token, returnTo: parsed.returnTo || "/" };
}

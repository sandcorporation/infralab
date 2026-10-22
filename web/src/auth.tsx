import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { ApiError, UNAUTHENTICATED_EVENT, getMe, loadTokens, saveTokens, socialLogin, type Me } from "./api";

type AuthState = {
  me: Me | null;
  loading: boolean;
  login: (provider: string, accessToken: string) => Promise<Me>;
  logout: () => void;
  refreshMe: () => Promise<void>;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [loading, setLoading] = useState(true);

  const refreshMe = useCallback(async () => {
    if (!loadTokens()) {
      setMe(null);
      return;
    }
    try {
      setMe(await getMe());
    } catch (err) {
      // 401 만 「토큰이 죽었다」다. 네트워크 오류·백엔드 재기동(5xx)에 토큰을 버리면 멀쩡한 로그인을 잃는다.
      if (err instanceof ApiError && err.status === 401) saveTokens(null);
      setMe(null);
    }
  }, []);

  useEffect(() => {
    refreshMe().finally(() => setLoading(false));
  }, [refreshMe]);

  // api.ts 가 리프레시 거부를 받아 토큰을 지우면 화면도 로그아웃 상태로 따라간다.
  useEffect(() => {
    const onUnauthenticated = () => setMe(null);
    window.addEventListener(UNAUTHENTICATED_EVENT, onUnauthenticated);
    return () => window.removeEventListener(UNAUTHENTICATED_EVENT, onUnauthenticated);
  }, []);

  const login = useCallback(async (provider: string, accessToken: string) => {
    const pair = await socialLogin(provider, accessToken);
    saveTokens({ access: pair.access, refresh: pair.refresh });
    const who = await getMe();
    setMe(who);
    return who;
  }, []);

  const logout = useCallback(() => {
    saveTokens(null);
    setMe(null);
  }, []);

  const value = useMemo(() => ({ me, loading, login, logout, refreshMe }), [me, loading, login, logout, refreshMe]);
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth outside AuthProvider");
  return ctx;
}

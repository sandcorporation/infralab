import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from "react";
import { UNAUTHENTICATED_EVENT, devLogin, getMe, logoutSession, type Me } from "./api";

type AuthState = {
  me: Me | null;
  loading: boolean;
  /** 개발용 로그인(dev-login). 운영 로그인은 /api/auth/login 으로 페이지째 넘어간다. */
  login: (uid: string, nickname: string) => Promise<Me>;
  logout: () => Promise<void>;
  refreshMe: () => Promise<void>;
};

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [loading, setLoading] = useState(true);

  const refreshMe = useCallback(async () => {
    try {
      setMe(await getMe());
    } catch {
      setMe(null);
    }
  }, []);

  useEffect(() => {
    refreshMe().finally(() => setLoading(false));
  }, [refreshMe]);

  // 어느 요청이든 401 을 받으면(세션 만료·탈퇴) 화면도 로그아웃 상태로 따라간다.
  useEffect(() => {
    const onUnauthenticated = () => setMe(null);
    window.addEventListener(UNAUTHENTICATED_EVENT, onUnauthenticated);
    return () => window.removeEventListener(UNAUTHENTICATED_EVENT, onUnauthenticated);
  }, []);

  const login = useCallback(async (uid: string, nickname: string) => {
    await devLogin(uid, nickname);
    const who = await getMe();
    setMe(who);
    return who;
  }, []);

  const logout = useCallback(async () => {
    try {
      await logoutSession();
    } finally {
      setMe(null);
    }
  }, []);

  const value = useMemo(() => ({ me, loading, login, logout, refreshMe }), [me, loading, login, logout, refreshMe]);
  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error("useAuth outside AuthProvider");
  return ctx;
}

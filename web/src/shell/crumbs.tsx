import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

/** 상단 바 이동 경로 한 칸. `to` 가 없으면 지금 화면(마지막 칸)이다. */
export type Crumb = { label: string; to?: string };

type CrumbsState = { crumbs: Crumb[]; setCrumbs: (c: Crumb[]) => void };

const CrumbsContext = createContext<CrumbsState | null>(null);

export function CrumbsProvider({ children }: { children: ReactNode }) {
  const [crumbs, setCrumbs] = useState<Crumb[]>([]);
  return <CrumbsContext.Provider value={{ crumbs, setCrumbs }}>{children}</CrumbsContext.Provider>;
}

export function useCrumbList(): Crumb[] {
  return useContext(CrumbsContext)?.crumbs ?? [];
}

/** 화면이 자기 이동 경로를 상단 바에 올린다. 화면을 떠나면 비운다. */
export function useCrumbs(crumbs: Crumb[]) {
  const set = useContext(CrumbsContext)?.setCrumbs;
  const key = JSON.stringify(crumbs);
  useEffect(() => {
    if (!set) return;
    set(JSON.parse(key) as Crumb[]);
    return () => set([]);
  }, [set, key]);
}

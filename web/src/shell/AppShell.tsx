import { useEffect, useRef, useState, type ReactNode } from "react";
import { Link, Outlet, matchPath, useLocation } from "react-router-dom";
import { useAuth } from "../auth";
import type { Me } from "../api";
import { isExamUser, rememberedExamToken } from "../exam";
import { ExamBar, ExamClockProvider } from "../examAttempt";
import { CrumbsProvider, useCrumbList } from "./crumbs";
import { IconClose, IconCohorts, IconExam, IconHome, IconMenu, IconOrg, IconPractice } from "./icons";
import mark from "sandcorp-design/assets/mark.svg";
import markDark from "sandcorp-design/assets/mark-dark.svg";

export type NavItem = {
  to: string;
  label: string;
  icon: () => ReactNode;
  /** 이 항목을 현재 위치로 칠 경로 무늬(react-router matchPath, end 없이). */
  match: string[];
};
export type NavGroup = { heading: string; items: NavItem[] };

/** 역할별 사이드바 묶음. 강사는 강사 묶음이 먼저, 모두에게 학생 묶음. */
export function navGroups(me: Pick<Me, "is_instructor">): NavGroup[] {
  const groups: NavGroup[] = [];
  if (me.is_instructor) {
    groups.push({
      heading: "강사",
      items: [
        { to: "/instructor", label: "기수", icon: IconCohorts, match: ["/instructor", "/instructor/cohorts/*"] },
        { to: "/instructor/exams", label: "시험", icon: IconExam, match: ["/instructor/exams/*"] },
        { to: "/instructor/org", label: "조직", icon: IconOrg, match: ["/instructor/org/*"] },
      ],
    });
  }
  groups.push({
    heading: "학생",
    items: [
      { to: "/", label: "내 기수", icon: IconHome, match: ["/", "/cohorts/*"] },
      { to: "/practice", label: "연습", icon: IconPractice, match: ["/practice/*"] },
    ],
  });
  return groups;
}

/** 지금 경로에 맞는 항목 하나(가장 먼저 맞는 것). */
export function currentNavItem(groups: NavGroup[], pathname: string): NavItem | null {
  for (const g of groups)
    for (const item of g.items)
      if (item.match.some((pattern) => matchPath({ path: pattern, end: true }, pathname))) return item;
  return null;
}

function Brand() {
  return (
    <picture>
      <source srcSet={markDark} media="(prefers-color-scheme: dark)" />
      <img src={mark} alt="" width={20} height={20} />
    </picture>
  );
}

function SideNav({ groups, pathname, onNavigate }: { groups: NavGroup[]; pathname: string; onNavigate: () => void }) {
  // 연습 시나리오는 기수와 같은 /cohorts/... 경로를 쓴다 — 화면이 올린 이동 경로의 첫 칸이 메뉴 항목이면 그것을 켠다.
  const first = useCrumbList()[0]?.to;
  const current = groups.flatMap((g) => g.items).find((i) => first !== undefined && i.to === first) ?? currentNavItem(groups, pathname);
  return (
    <nav className="sc-sidenav" id="app-sidenav" aria-label="주 메뉴">
      <Link to="/" className="sc-sidenav-org app-brand" onClick={onNavigate}>
        <span className="sc-sidenav-mark">
          <Brand />
        </span>
        <span className="sc-sidenav-org-text">
          Sandcorp
          <small>infralab</small>
        </span>
      </Link>
      {groups.map((g) => (
        <div className="app-nav-group" key={g.heading}>
          <div className="sc-sidenav-heading">{g.heading}</div>
          {g.items.map((item) => (
            // NavLink 는 앞부분 일치로 스스로 aria-current 를 달아(/instructor ⊂ /instructor/org) 둘을 칠한다 — Link 로 한 곳만.
            <Link
              key={item.to}
              to={item.to}
              className="sc-sidenav-item"
              title={item.label}
              aria-current={item === current ? "page" : undefined}
              onClick={onNavigate}
            >
              <item.icon />
              <span className="sc-sidenav-label">{item.label}</span>
            </Link>
          ))}
        </div>
      ))}
    </nav>
  );
}

function AccountMenu({ me, logout }: { me: Me; logout: () => Promise<void> }) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => !ref.current?.contains(e.target as Node) && setOpen(false);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);
  const name = me.display_name || me.username;
  return (
    <div className="app-account" ref={ref}>
      <button
        type="button"
        className="sc-topbar-account"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((v) => !v)}
      >
        <span className="sc-topbar-avatar" aria-hidden="true">
          {name.slice(0, 1).toUpperCase()}
        </span>
        <span className="sc-topbar-account-text">
          {name}
          <small>{me.is_instructor ? "강사" : "학생"}</small>
        </span>
      </button>
      {/* 떠 있는 메뉴 상자는 디자인시스템에 없다(sandcorp-design#29) — 토큰으로 짠다. */}
      {open && (
        <div className="app-menu" role="menu">
          <button type="button" role="menuitem" onClick={() => void logout()}>
            로그아웃
          </button>
        </div>
      )}
    </div>
  );
}

function TopBar({ me, logout, navOpen, onToggleNav }: { me: Me; logout: () => Promise<void>; navOpen: boolean; onToggleNav: () => void }) {
  const crumbs = useCrumbList();
  return (
    <header className="sc-topbar">
      <nav aria-label="이동 경로" className="app-crumbs">
        <button
          type="button"
          className="sc-icon-btn app-nav-toggle"
          aria-label={navOpen ? "메뉴 닫기" : "메뉴 열기"}
          aria-expanded={navOpen}
          aria-controls="app-sidenav"
          onClick={onToggleNav}
        >
          {navOpen ? <IconClose /> : <IconMenu />}
        </button>
        <ol className="sc-topbar-crumbs">
          {crumbs.map((c, i) => (
            <li key={i}>
              {c.to && i < crumbs.length - 1 ? (
                <Link to={c.to}>{c.label}</Link>
              ) : (
                <span aria-current={i === crumbs.length - 1 ? "page" : undefined}>{c.label}</span>
              )}
            </li>
          ))}
        </ol>
      </nav>
      <AccountMenu me={me} logout={logout} />
    </header>
  );
}

/**
 * 로그인 전·응시자 화면: 사이드바 없이 브랜드 한 줄 + 가운데 본문.
 * 응시(examToken)면 브랜드가 응시 첫 화면으로 가고(「내 기수」 길 없음) 본문은 콘솔 규칙(머리·카드/탭 세로 쌓기).
 */
function BareLayout({
  me,
  logout,
  exam,
  examToken,
}: {
  me: Me | null;
  logout: () => Promise<void>;
  exam: boolean;
  examToken: string | null;
}) {
  const brand = (
    <>
      <Brand />
      Sandcorp <span className="brand-product">infralab</span>
    </>
  );
  return (
    <div className="app-bare">
      <header className="sc-topbar">
        {!exam ? (
          <Link to="/" className="app-bare-brand">
            {brand}
          </Link>
        ) : examToken ? (
          <Link to={`/exam/${encodeURIComponent(examToken)}`} className="app-bare-brand">
            {brand}
          </Link>
        ) : (
          <span className="app-bare-brand">{brand}</span>
        )}
        {me ? (
          <button type="button" className="link" onClick={() => void logout()}>
            로그아웃
          </button>
        ) : (
          <Link to="/login">로그인</Link>
        )}
      </header>
      <ExamBar />
      <main className={exam ? "app-bare-page app-exam-page" : "app-bare-page"}>
        <Outlet />
      </main>
    </div>
  );
}

export function AppShell() {
  const { me, logout } = useAuth();
  const location = useLocation();
  const [navOpen, setNavOpen] = useState(false);
  // 경로가 바뀌면 휴대폰 메뉴를 닫는다.
  useEffect(() => setNavOpen(false), [location.pathname]);
  const examUser = isExamUser(me?.username);
  // 응시 화면이면 그 링크, 응시자 세션이면 들어온 링크의 시계를 어느 화면에서나 보인다.
  const examToken = matchPath("/exam/:token", location.pathname)?.params.token ?? (examUser ? rememberedExamToken() : null);
  const exam = examUser || matchPath("/exam/:token", location.pathname) !== null;
  const bare = !me || exam;
  return (
    <ExamClockProvider token={examToken}>
      {bare ? (
        <BareLayout me={me} logout={logout} exam={exam} examToken={examToken} />
      ) : (
        <CrumbsProvider>
          <div className="sc-app" data-nav-open={navOpen || undefined}>
            <SideNav groups={navGroups(me)} pathname={location.pathname} onNavigate={() => setNavOpen(false)} />
            <div className="sc-app-main">
              <TopBar me={me} logout={logout} navOpen={navOpen} onToggleNav={() => setNavOpen((v) => !v)} />
              <ExamBar />
              <main className="sc-app-page">
                <Outlet />
              </main>
            </div>
          </div>
        </CrumbsProvider>
      )}
    </ExamClockProvider>
  );
}

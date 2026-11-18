import { Link, Navigate, Outlet, Route, Routes, matchPath, useLocation } from "react-router-dom";
import { useAuth } from "./auth";
import LoginPage from "./pages/LoginPage";
import JoinPage from "./pages/JoinPage";
import MyCohortsPage from "./pages/MyCohortsPage";
import InstructorCohortsPage from "./pages/InstructorCohortsPage";
import InstructorCohortPage from "./pages/InstructorCohortPage";
import CohortPage from "./pages/CohortPage";
import SetupPage from "./pages/SetupPage";
import ScenarioPage from "./pages/ScenarioPage";
import InstructorExamDashboardPage from "./pages/InstructorExamDashboardPage";
import InstructorOrgPage from "./pages/InstructorOrgPage";
import OrgInvitePage from "./pages/OrgInvitePage";
import InstructorGridPage from "./pages/InstructorGridPage";
import InstructorExamReportPage from "./pages/InstructorExamReportPage";
import ExamPage from "./pages/ExamPage";
import { isExamUser, rememberedExamToken } from "./exam";
import { ExamBar, ExamClockProvider } from "./examAttempt";

function Layout() {
  const { me, logout } = useAuth();
  const location = useLocation();
  // 응시 화면이면 그 링크, 응시자 세션이면 들어온 링크의 시계를 어느 화면에서나 보인다.
  const examToken =
    matchPath("/exam/:token", location.pathname)?.params.token ?? (isExamUser(me?.username) ? rememberedExamToken() : null);
  return (
    <ExamClockProvider token={examToken}>
      <header className="topbar">
        <Link to="/" className="brand">
          infralab
        </Link>
        <nav>
          {me?.is_instructor && <Link to="/instructor">강사</Link>}
          {me ? (
            <>
              <span className="muted">{me.display_name || me.username}</span>
              <button className="link" onClick={logout}>
                로그아웃
              </button>
            </>
          ) : (
            <Link to="/login">로그인</Link>
          )}
        </nav>
      </header>
      <ExamBar />
      <main className="page">
        <Outlet />
      </main>
    </ExamClockProvider>
  );
}

function RequireAuth({ instructor = false }: { instructor?: boolean }) {
  const { me, loading } = useAuth();
  const location = useLocation();
  if (loading) return <p className="muted">불러오는 중…</p>;
  if (!me) return <Navigate to="/login" state={{ from: location.pathname + location.search }} replace />;
  if (instructor && !me.is_instructor) return <p className="error">강사만 볼 수 있는 화면입니다.</p>;
  return <Outlet />;
}

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route path="/login" element={<LoginPage />} />
        <Route path="/join/:token" element={<JoinPage />} />
        <Route path="/org-invite/:token" element={<OrgInvitePage />} />
        <Route path="/exam/:token" element={<ExamPage />} />
        <Route element={<RequireAuth />}>
          <Route path="/" element={<MyCohortsPage />} />
          <Route path="/cohorts/:id" element={<CohortPage />} />
          <Route path="/cohorts/:id/setup" element={<SetupPage />} />
          <Route path="/cohorts/:id/scenarios/:scenarioId" element={<ScenarioPage />} />
        </Route>
        <Route element={<RequireAuth instructor />}>
          <Route path="/instructor" element={<InstructorCohortsPage />} />
          <Route path="/instructor/exams" element={<InstructorExamDashboardPage />} />
          <Route path="/instructor/org" element={<InstructorOrgPage />} />
          <Route path="/instructor/cohorts/:id" element={<InstructorCohortPage />} />
          <Route path="/instructor/cohorts/:id/grid" element={<InstructorGridPage />} />
          <Route path="/instructor/cohorts/:id/exam-invites/:inviteId/report" element={<InstructorExamReportPage />} />
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

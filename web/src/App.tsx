import { Navigate, Outlet, Route, Routes, useLocation } from "react-router-dom";
import { useAuth } from "./auth";
import LoginPage from "./pages/LoginPage";
import JoinPage from "./pages/JoinPage";
import MyCohortsPage from "./pages/MyCohortsPage";
import InstructorCohortsPage from "./pages/InstructorCohortsPage";
import InstructorCohortPage, {
  CohortInvites,
  CohortOverview,
  CohortScenarios,
  CohortSettings,
  CohortStudents,
} from "./pages/InstructorCohortPage";
import CohortPage from "./pages/CohortPage";
import PracticePage from "./pages/PracticePage";
import SetupPage from "./pages/SetupPage";
import ScenarioPage from "./pages/ScenarioPage";
import InstructorExamDashboardPage from "./pages/InstructorExamDashboardPage";
import InstructorOrgPage from "./pages/InstructorOrgPage";
import OrgInvitePage from "./pages/OrgInvitePage";
import InstructorGridPage from "./pages/InstructorGridPage";
import InstructorExamReportPage from "./pages/InstructorExamReportPage";
import ExamPage from "./pages/ExamPage";
import { AppShell } from "./shell/AppShell";
import { AccessDenied } from "./components/AccessDenied";

function RequireAuth({ instructor = false }: { instructor?: boolean }) {
  const { me, loading } = useAuth();
  const location = useLocation();
  if (loading) return <p className="muted">불러오는 중…</p>;
  if (!me) return <Navigate to="/login" state={{ from: location.pathname + location.search }} replace />;
  if (instructor && !me.is_instructor) return <AccessDenied />;
  return <Outlet />;
}

export default function App() {
  return (
    <Routes>
      <Route element={<AppShell />}>
        <Route path="/login" element={<LoginPage />} />
        <Route path="/join/:token" element={<JoinPage />} />
        <Route path="/org-invite/:token" element={<OrgInvitePage />} />
        <Route path="/exam/:token" element={<ExamPage />} />
        <Route element={<RequireAuth />}>
          <Route path="/" element={<MyCohortsPage />} />
          <Route path="/practice" element={<PracticePage />} />
          <Route path="/cohorts/:id" element={<CohortPage />} />
          <Route path="/cohorts/:id/setup" element={<SetupPage />} />
          <Route path="/cohorts/:id/scenarios/:scenarioId" element={<ScenarioPage />} />
        </Route>
        <Route element={<RequireAuth instructor />}>
          <Route path="/instructor" element={<InstructorCohortsPage />} />
          <Route path="/instructor/exams" element={<InstructorExamDashboardPage />} />
          <Route path="/instructor/org" element={<InstructorOrgPage />} />
          <Route path="/instructor/cohorts/:id" element={<InstructorCohortPage />}>
            <Route index element={<CohortOverview />} />
            <Route path="scenarios" element={<CohortScenarios />} />
            <Route path="students" element={<CohortStudents />} />
            <Route path="grid" element={<InstructorGridPage />} />
            <Route path="invites" element={<CohortInvites />} />
            <Route path="settings" element={<CohortSettings />} />
          </Route>
          <Route path="/instructor/cohorts/:id/exam-invites/:inviteId/report" element={<InstructorExamReportPage />} />
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Route>
    </Routes>
  );
}

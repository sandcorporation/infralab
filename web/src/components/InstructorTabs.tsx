import { NavLink } from "react-router-dom";

// 강사 화면의 탭 — 묶음 목록과 조직(담당자 관리).
export function InstructorTabs() {
  return (
    <nav className="row" aria-label="강사 화면">
      <NavLink to="/instructor" end>
        기수
      </NavLink>
      <NavLink to="/instructor/org">조직</NavLink>
    </nav>
  );
}

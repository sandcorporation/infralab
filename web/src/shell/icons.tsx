// 사이드바·도구 단추 아이콘. 16px 선 그림, 색은 currentColor(토큰을 따르는 글자색).
import type { ReactNode } from "react";

function Icon({ children }: { children: ReactNode }) {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      {children}
    </svg>
  );
}

export const IconCohorts = () => (
  <Icon>
    <circle cx="6" cy="5.5" r="2.25" />
    <path d="M1.75 13.25c.4-2.3 2.1-3.5 4.25-3.5s3.85 1.2 4.25 3.5" />
    <path d="M10.5 3.5a2.1 2.1 0 1 1 0 4.2M12 9.9c1.3.4 2 1.5 2.25 3.35" />
  </Icon>
);

export const IconExam = () => (
  <Icon>
    <rect x="3" y="2" width="10" height="12.5" rx="1" />
    <path d="M5.5 5.5h5M5.5 8h5M5.5 10.5h3" />
  </Icon>
);

export const IconOrg = () => (
  <Icon>
    <rect x="2" y="5" width="12" height="9" rx="1" />
    <path d="M5.5 5V2.5h5V5M2 9h12" />
  </Icon>
);

export const IconHome = () => (
  <Icon>
    <path d="M2 7.25 8 2.5l6 4.75V14H2z" />
    <path d="M6.25 14v-4h3.5v4" />
  </Icon>
);

export const IconPractice = () => (
  <Icon>
    <rect x="1.75" y="2.5" width="12.5" height="11" rx="1" />
    <path d="m4.5 6.25 2 1.75-2 1.75M8.25 10h3" />
  </Icon>
);

export const IconMenu = () => (
  <Icon>
    <path d="M2.5 4h11M2.5 8h11M2.5 12h11" />
  </Icon>
);

export const IconClose = () => (
  <Icon>
    <path d="m3.5 3.5 9 9M12.5 3.5l-9 9" />
  </Icon>
);

export const IconSearch = () => (
  <Icon>
    <circle cx="7" cy="7" r="4.25" />
    <path d="m10.25 10.25 3.5 3.5" />
  </Icon>
);

export const IconPlus = () => (
  <Icon>
    <path d="M8 3v10M3 8h10" />
  </Icon>
);

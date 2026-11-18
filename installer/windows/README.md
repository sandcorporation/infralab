# Windows 설치 프로그램 (Inno Setup)

지원자·학생 Windows PC 에 infralab 실습 도구를 까는 설치 파일 하나를 만든다.

| 파일 | 역할 |
| --- | --- |
| `infralab.iss` | Inno Setup 스크립트. 설치 화면 안내(`docker-notice.txt`), 바탕화면·시작 메뉴 바로가기, compose.yml 주소 입력 |
| `infralab-start.ps1` | 바로가기가 도는 실행 스크립트. compose.yml 받기 → `docker compose up -d` → agent 의 `GET /api/preflight` 점검, 실패면 안내 링크 열기 |
| `docker-notice.txt` | 설치 화면 문구: Docker Desktop 필요(묶지 않음)·Linux 컨테이너 모드·기업 유료 요금제 |

## 로컬 빌드

[Inno Setup 6](https://jrsoftware.org/isinfo.php) 이 있는 Windows 에서:

```powershell
cd installer\windows
iscc /DAppVersion=1.0.0 infralab.iss
```

산출물: `installer\windows\Output\infralab-setup-1.0.0.exe` (`infralab-setup-<버전>.exe`).
버전 문자열은 `/DAppVersion=` 빌드 인자 한 곳에서만 온다(없으면 빌드가 실패한다). 

## 설치 뒤 동작

- 설치 중 compose.yml 주소(와 선택 대시보드 주소)를 묻고 `%APPDATA%\infralab\settings.json` 에 적는다.
  - 채용 시험 응시자: 응시 화면의 「설치 프로그램의 compose.yml 주소에 붙여 넣기」 주소
    (`https://<대시보드>/api/exam/<응시 토큰>/compose.yml`)를 붙여 넣는다. 로그인 쿠키 없이 응시 토큰만으로 받는다 —
    회수된 링크면 404, 시험이 끝났으면 410.
  - 수업 학생: 기수 compose.yml(`/api/cohorts/<id>/compose.yml`)은 로그인해야 받는다. 주소를 비워 두고, 설치 안내
    화면에서 받은 `compose.yml` 을 `%APPDATA%\infralab\` 에 저장한다.
- 바로가기(「infralab 실습 시작」)는 compose 를 받고 `docker compose up -d` 한 뒤, compose.yml 의 `AGENT_TOKEN` 으로
  `http://127.0.0.1:7777/api/preflight` 를 부른다. 실패한 항목(엔진·Linux 모드·권한)의 `help_url` 을 브라우저로 연다.
  docker 가 없거나 compose 가 실패하거나 agent 가 응답하지 않으면 Docker Desktop 안내 페이지를 연다.
- 스크립트는 직접도 돌릴 수 있다: `powershell -File infralab-start.ps1 -ComposeUrl <주소> -DashboardUrl <주소>`.

## 릴리스

`.github/workflows/app-release.yml` 이 Windows 실행기에서 빌드한다. 태그 `app-v<버전>`(예 `app-v1.0.0`)을 밀면 GitHub Release 에 `infralab-setup-<버전>.exe` 와 `.sha256` 을 올린다.
태그 없이 Actions 에서 `app-release` 를 수동 실행(workflow_dispatch, 버전 입력)하면 빌드만 하고 artifact 로 남긴다. 코드 서명은 하지 않는다.

## SmartScreen

코드 서명 인증서 없이 배포한다(대표 결정 2026-11-18). 그래서 받은 `.exe` 를 실행하면 Inno Setup 화면보다 먼저
Windows SmartScreen 「Windows의 PC 보호」 창이 뜬다. 지원자는 「추가 정보」 → 「실행」을 누르면 된다.
설치 프로그램은 그 뒤에야 뜨므로 이 안내는 설치 마법사가 아니라 웹의 설치 안내(`SetupPage`)와 응시 안내(`ExamPage`)에
있다(`web/src/components/SmartScreenNotice.tsx`, 설치 파일 링크 `releases/latest` 와 함께). 설치 파일 링크를 따로 전할 때도 같은 문구를 붙인다.

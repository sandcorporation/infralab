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
버전 문자열은 `/DAppVersion=` 빌드 인자 한 곳에서만 온다(없으면 빌드가 실패한다). 빌드·게시 workflow 는 따로 둔다.

## 설치 뒤 동작

- 설치 중 compose.yml 주소(와 선택 대시보드 주소)를 묻고 `%APPDATA%\infralab\settings.json` 에 적는다.
  주소가 로그인 없이 받을 수 있는 링크가 아니면 비워 두고, 브라우저로 받은 `compose.yml` 을 `%APPDATA%\infralab\` 에 저장한다.
- 바로가기(「infralab 실습 시작」)는 compose 를 받고 `docker compose up -d` 한 뒤, compose.yml 의 `AGENT_TOKEN` 으로
  `http://127.0.0.1:7777/api/preflight` 를 부른다. 실패한 항목(엔진·Linux 모드·권한)의 `help_url` 을 브라우저로 연다.
  docker 가 없거나 compose 가 실패하거나 agent 가 응답하지 않으면 Docker Desktop 안내 페이지를 연다.
- 스크립트는 직접도 돌릴 수 있다: `powershell -File infralab-start.ps1 -ComposeUrl <주소> -DashboardUrl <주소>`.

# 0002. 조직 → 묶음 → 응시자, 강사 권한은 조직 역할로

- 상태: 채택
- 날짜: 2026-11-18 (#48, 상위 spec #45 의 1단계)

## 맥락

infralab 은 인프라 수업 하나를 위한 서비스였다. 강사는 전역 플래그 `User.is_instructor` 로 정해졌고, 기수(`Cohort`)는
주인이 없어 강사라면 모든 기수·제출을 봤다. #45 는 교육기관·채용·사내 진단이 같은 재료를 쓰게 하려고 구조를
**조직 → 묶음 → 응시자** 로 일반화한다. 진행 중인 수업은 멈추면 안 된다.

## 결정

1. **모델.** 새 앱 `orgs` 에 `Organization(name 유일, created_at)` 과 `OrgMember(org, user, role: owner|staff, joined_at,
   unique(org, user))`. 묶음은 지금의 `Cohort` 이고 `Cohort.org` 는 필수 FK(`PROTECT` — 기수가 남은 조직은 지울 수 없다).
   응시자는 지금의 `Membership`. 테이블·API 경로 이름은 바꾸지 않는다(「기수」는 수업 묶음의 표시 이름으로 남는다).
2. **권한.** 강사 표면(`/api/instructor/…`)의 입장은 「담당 조직이 하나라도 있는가」(`orgs.services.is_org_staff`)다.
   아니면 지금처럼 403. 기수·참여자·격자·이력·제출 상세·시나리오 열기·학생 내보내기는 모두 「내가 담당자인 조직의
   기수」(`cohorts.services.managed_cohorts`) 안에서만 찾고, 남의 조직 것은 **404** 로 존재도 알리지 않는다.
   owner 와 staff 는 이번에는 권한이 같다. 담당자 관리처럼 owner 만 할 일은 다음 단계에서 붙인다.
3. **기수 만들기.** `POST /api/instructor/cohorts` 에 선택 필드 `org_id`. 담당 조직이 하나면 생략할 수 있고, 여럿인데
   생략하면 422, 담당이 아닌 조직이면 403. 기수 응답에는 `org_id` 가 붙는다.
4. **`/accounts/me`.** `orgs: [{id, name, role}]` 를 더하고, `is_instructor` 는 「담당 조직이 하나라도 있음」으로 계산해
   응답 모양을 유지한다. web 은 바꾸지 않아도 된다.
5. **`is_instructor` DB 필드는 남긴다.** 권한 판정에는 쓰지 않는다. 지울지는 다음 티켓에서 정한다.
6. **관리 명령.** `create_org <name> --owner <username>`(조직을 만들고 owner 하나), `add_org_member <org> <username>
   [--role staff]`(`<org>` 는 id 또는 이름, 역할 기본 owner, 이미 담당자면 역할만 바꾼다). 옛 `set_instructor <username>
   [--off]` 는 「기본 조직」(없으면 만든다)의 owner 로 넣고 빼는 지름길로 남긴다(옛 플래그도 같이 맞춘다).

## 이전 방식

세 마이그레이션으로 나눠, 어느 단계에서 멈춰도 DB 가 일관되게 한다.

| 마이그레이션 | 하는 일 |
| --- | --- |
| `orgs 0001_initial` | `Organization`·`OrgMember` 테이블 |
| `cohorts 0002_cohort_org` | `Cohort.org` 를 **nullable** 로 더한다 |
| `cohorts 0003_default_org` | 데이터 이전: 조직 없는 기수나 `is_instructor=True` 사용자가 있으면 「기본 조직」을 하나 만들고(`get_or_create`) 조직 없는 기수 전부를 연결, 그 사용자 전부를 owner 로. 옮길 것이 없는 새 DB 에서는 조직을 만들지 않는다. 되돌리기는 아무것도 하지 않는다 |
| `cohorts 0004_cohort_org_not_null` | `Cohort.org` 를 NOT NULL 로 |

기수·참여·제출 행은 FK 하나 말고는 건드리지 않으므로 가입 링크(`join_token`)·에이전트 토큰·제출은 그대로 유효하다.
`tests/test_org_migration.py` 가 이전 전 상태(조직 없는 기수 2개, 강사 1명, 학생·제출)에서 이전을 돌려 이것을 확인한다.

## 결과

- 지금 수업은 이전 뒤 「기본 조직」 안에서 그대로 돈다. 새 조직은 `create_org` 로 만든다.
- 강사 표면의 모든 기수 조회가 조직으로 걸러지므로, 앞으로 강사 엔드포인트를 더할 때는 `Cohort.objects` 를 직접
  쓰지 말고 `managed_cohorts`·`managed_cohort` 를 거친다.
- 번호: 티켓은 `0001-organization-structure.md` 를 말했지만 0001 은 이미 소프트웨어 공장 ADR 이라 0002 로 둔다.
- 대표 전용 기능이 생기면 `sandcorp_auth.VerifiedToken.is_owner_strong`(대표 토큰이고 `amr` 에 `fed` 가 없음)으로만 연다. 소셜(`fed`)로 들어온 대표 토큰은 받되 조직 역할 밖의 권한은 주지 않는다. 지금은 대표 전용 기능이 없다.

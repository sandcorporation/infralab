from ninja import Schema


class SocialLoginIn(Schema):
    access_token: str


class TokenPairOut(Schema):
    access: str
    refresh: str
    token_type: str = "bearer"


class RefreshIn(Schema):
    refresh: str


class OrgOut(Schema):
    id: int
    name: str
    role: str


class MeOut(Schema):
    id: int
    username: str
    display_name: str
    #: 담당 조직이 하나라도 있으면 참 — 강사 표면을 쓸 수 있다는 뜻. 옛 전역 플래그와 응답 모양이 같다.
    is_instructor: bool
    #: 내가 담당자인 조직과 역할.
    orgs: list[OrgOut]

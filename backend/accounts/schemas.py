from ninja import Schema


class SocialLoginIn(Schema):
    access_token: str


class TokenPairOut(Schema):
    access: str
    refresh: str
    token_type: str = "bearer"


class RefreshIn(Schema):
    refresh: str


class MeOut(Schema):
    id: int
    username: str
    display_name: str
    is_instructor: bool

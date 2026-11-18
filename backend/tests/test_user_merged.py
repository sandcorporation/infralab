"""auth `user.merged` 웹훅과 대표 토큰(A1·A4) — 합치기는 데이터를 지우지 않고 옮긴다."""

from __future__ import annotations

import json

import pytest
from django.contrib.auth import get_user_model

from accounts import merge, sandcorp_auth
from cohorts.models import Cohort, Membership
from orgs.models import Organization, OrgMember
from submissions.models import Submission
from tests.test_sandcorp_login import (  # noqa: F401 — fake 는 픽스처
    MEMBER,
    OTHER_MEMBER,
    _failed,
    _hook,
    _login,
    _me,
    _signed,
    fake,
)

User = get_user_model()
EVENT_ID = "01JB0Z8F3W4Q2Y6K7M9N0P1R2S"


def _merged(from_sub: str = MEMBER, to_sub: str = OTHER_MEMBER, event_id: str = EVENT_ID) -> bytes:
    return json.dumps({"id": event_id, "type": "user.merged", "from_sub": from_sub, "to_sub": to_sub}).encode()


def _user(sub: str, **kw):
    return User.objects.create(username=f"sandcorp:{sub}", **kw)


def _submission(membership: Membership) -> Submission:
    return Submission.objects.create(membership=membership, scenario_id="s3", passed=1, total=2, results=[])


@pytest.mark.django_db
def test_merged_without_a_target_renames_the_user_and_keeps_everything(fake, client):
    source = _user(MEMBER)
    org = Organization.objects.create(name="o")
    OrgMember.objects.create(org=org, user=source, role="owner")
    cohort = Cohort.objects.create(org=org, name="c")
    sub = _submission(Membership.objects.create(user=source, cohort=cohort))
    body = _merged()
    assert _hook(client, body, _signed(body)).status_code == 204
    source.refresh_from_db()
    assert source.username == f"sandcorp:{OTHER_MEMBER}" and source.is_active
    assert OrgMember.objects.get(user=source).role == "owner"
    assert Submission.objects.get(pk=sub.pk).membership.user == source


@pytest.mark.django_db
def test_merged_into_an_existing_user_moves_and_combines(fake, client):
    session, _ = _login(fake)  # MEMBER 의 열린 세션
    source = User.objects.get(username=f"sandcorp:{MEMBER}")
    source.display_name = "옛 이름"
    source.save()
    target = _user(OTHER_MEMBER)
    org_both, org_only = Organization.objects.create(name="both"), Organization.objects.create(name="only-from")
    OrgMember.objects.create(org=org_both, user=source, role="owner")
    OrgMember.objects.create(org=org_both, user=target, role="staff")
    OrgMember.objects.create(org=org_only, user=source, role="staff")
    shared, solo = Cohort.objects.create(org=org_both, name="shared"), Cohort.objects.create(org=org_both, name="solo")
    from_shared = Membership.objects.create(user=source, cohort=shared)
    to_shared = Membership.objects.create(user=target, cohort=shared)
    from_solo = Membership.objects.create(user=source, cohort=solo)
    moved = _submission(from_shared)
    kept = _submission(to_shared)

    body = _merged()
    assert _hook(client, body, _signed(body)).status_code == 204

    source.refresh_from_db()
    target.refresh_from_db()
    assert source.is_active is False
    assert _me(session).status_code == 401
    assert target.display_name == "옛 이름"
    assert dict(OrgMember.objects.filter(user=target).values_list("org__name", "role")) == {
        "both": "owner",
        "only-from": "staff",
    }
    assert not OrgMember.objects.filter(user=source).exists()
    assert set(Membership.objects.filter(user=target).values_list("cohort__name", flat=True)) == {"shared", "solo"}
    assert not Membership.objects.filter(user=source).exists()
    assert Membership.objects.get(pk=from_solo.pk).user == target
    assert not Membership.objects.filter(pk=from_shared.pk).exists()
    assert Submission.objects.get(pk=moved.pk).membership_id == to_shared.pk
    assert Submission.objects.get(pk=kept.pk).membership_id == to_shared.pk


@pytest.mark.django_db
def test_merged_keeps_the_higher_role_of_the_target_and_its_own_name(fake, client):
    source, target = _user(MEMBER), _user(OTHER_MEMBER, display_name="나")
    org = Organization.objects.create(name="o")
    OrgMember.objects.create(org=org, user=source, role="staff")
    OrgMember.objects.create(org=org, user=target, role="owner")
    source.display_name = "남"
    source.save()
    body = _merged()
    assert _hook(client, body, _signed(body)).status_code == 204
    assert OrgMember.objects.get(user=target).role == "owner"
    target.refresh_from_db()
    assert target.display_name == "나"


@pytest.mark.django_db
def test_merged_is_processed_once_per_event_id(fake, client):
    source, target = _user(MEMBER), _user(OTHER_MEMBER)
    org = Organization.objects.create(name="o")
    cohort = Cohort.objects.create(org=org, name="c")
    Membership.objects.create(user=source, cohort=cohort)
    body = _merged()
    assert _hook(client, body, _signed(body)).status_code == 204
    # 합친 뒤 from 에 새 가입이 생겨도 같은 id 재전송은 다시 처리하지 않는다.
    late = Membership.objects.create(user=source, cohort=Cohort.objects.create(org=org, name="late"))
    assert _hook(client, body, _signed(body)).status_code == 204
    assert Membership.objects.get(pk=late.pk).user == source
    assert Membership.objects.filter(user=target).count() == 1


@pytest.mark.django_db
def test_merged_with_a_bad_signature_is_401_and_changes_nothing(fake, client):
    source = _user(MEMBER)
    body = _merged()
    assert _hook(client, body, _signed(body, secret="not-the-secret")).status_code == 401
    source.refresh_from_db()
    assert source.username == f"sandcorp:{MEMBER}"


@pytest.mark.django_db
def test_merged_with_an_unknown_from_sub_is_2xx_and_does_nothing(fake, client):
    target = _user(OTHER_MEMBER)
    body = _merged(from_sub="m_01JB2Z3Y4X5W6V7T8S9R0Q1P2K")
    assert _hook(client, body, _signed(body)).status_code == 204
    assert User.objects.count() == 1 and User.objects.get().pk == target.pk


def test_every_relation_to_the_user_is_declared_in_merge():
    pointing = {
        f"{rel.related_model._meta.label}.{rel.field.name}"
        for rel in User._meta.related_objects  # FK·OneToOne·ManyToMany 의 역방향 전부
    }
    # 인증·관리 앱의 내장 관계(관리 로그 등)는 이 앱들이 쓰지 않는다.
    builtin = {p for p in pointing if p.split(".")[0] in {"auth", "admin", "contenttypes", "sessions"}}
    missing = pointing - builtin - merge.HANDLED
    assert not missing, f"사용자를 가리키는 관계 {sorted(missing)} — accounts/merge.py 에 옮기는 법을 더하고 HANDLED 에 적어라"


# ---------- 대표 토큰 A1·A4 ----------


def _owner_token(fake, **claims) -> str:
    import time

    now = int(time.time())
    base = {
        "iss": "https://auth.example.test",
        "sub": "farrar142",
        "aud": f"{__import__('django.conf', fromlist=['settings']).settings.PUBLIC_ORIGIN}/api",
        "client_id": "x",
        "scope": "infralab",
        "iat": now,
        "exp": now + 600,
        "jti": "j",
    }
    return fake._sign({k: v for k, v in {**base, **claims}.items() if v is not None})


@pytest.mark.django_db
def test_owner_token_with_another_sub_is_rejected(fake):
    fake.access_overrides = {"acct": None, "sub": "someone-else"}
    client, res = _login(fake, sub="someone-else")
    assert res["Location"] == _failed()
    assert _me(client).status_code == 401


@pytest.mark.django_db
@pytest.mark.parametrize("amr", ["fed", {"0": "fed"}, ["fed", 1], 1])
def test_owner_token_amr_must_be_a_string_array(fake, amr):
    fake.access_overrides = {"acct": None, "sub": "farrar142", "amr": amr}
    client, res = _login(fake, sub="farrar142")
    assert res["Location"] == _failed()


@pytest.mark.django_db
def test_owner_token_with_fed_logs_in_but_is_not_strong(fake):
    fake.access_overrides = {"acct": None, "sub": "farrar142", "amr": ["fed"]}
    client, res = _login(fake, sub="farrar142")
    assert res["Location"].endswith("/instructor")
    assert _me(client).json()["username"] == "sandcorp:farrar142"
    assert sandcorp_auth.verify_token(_owner_token(fake, amr=["fed"])).is_owner_strong is False


@pytest.mark.django_db
def test_owner_token_without_amr_is_strong(fake):
    token = sandcorp_auth.verify_token(_owner_token(fake))
    assert token.sub == "farrar142" and token.is_owner_strong is True
    assert sandcorp_auth.verify_token(_owner_token(fake, amr=["pwd"])).is_owner_strong is True


@pytest.mark.django_db
def test_member_token_is_never_strong(fake):
    token = sandcorp_auth.verify_token(_owner_token(fake, acct="member", sub=MEMBER))
    assert token.is_owner_strong is False

"""조직 담당자 관리 — 초대 링크·수락·역할·내보내기, 마지막 owner 보호, 조직 경계."""

from datetime import timedelta

import pytest
from django.utils import timezone

from orgs.models import OrgInvite

BASE = "/api/instructor/orgs"


def _org_id(api, session):
    return api.me(session)["orgs"][0]["id"]


def _invite(api, owner, org_id, role="staff"):
    res = api.post(f"{BASE}/{org_id}/invites", {"role": role}, owner)
    assert res.status_code == 201, res.content
    return res.json()


@pytest.mark.django_db
def test_accept_invite_makes_member_who_sees_org_cohorts(api):
    owner = api.login_instructor("owner", org="A 학교")
    org_id = _org_id(api, owner)
    cohort = api.create_cohort(owner, "A 1기")
    invite = _invite(api, owner, org_id)

    newcomer = api.login("newbie")
    assert api.get("/api/instructor/cohorts", newcomer).status_code == 403

    preview = api.get(f"/api/org-invites/{invite['token']}")
    assert preview.json() == {"org_name": "A 학교", "role": "staff", "valid": True}

    res = api.post(f"/api/org-invites/{invite['token']}/accept", session=newcomer)
    assert res.status_code == 200 and res.json()["created"] is True
    assert api.me(newcomer)["orgs"] == [{"id": org_id, "name": "A 학교", "role": "staff"}]
    assert [c["id"] for c in api.get("/api/instructor/cohorts", newcomer).json()] == [cohort["id"]]

    again = api.post(f"/api/org-invites/{invite['token']}/accept", session=newcomer)
    assert again.status_code == 200 and again.json()["created"] is False


@pytest.mark.django_db
def test_accept_requires_login(api):
    owner = api.login_instructor("owner", org="A 학교")
    invite = _invite(api, owner, _org_id(api, owner))
    assert api.post(f"/api/org-invites/{invite['token']}/accept").status_code == 401


@pytest.mark.django_db
def test_accepting_does_not_demote_existing_owner(api):
    owner = api.login_instructor("owner", org="A 학교")
    org_id = _org_id(api, owner)
    invite = _invite(api, owner, org_id, "staff")
    res = api.post(f"/api/org-invites/{invite['token']}/accept", session=owner)
    assert res.json() == {"org_id": org_id, "org_name": "A 학교", "role": "owner", "created": False}


@pytest.mark.django_db
def test_staff_cannot_manage_members(api):
    api.login_instructor("owner", org="A 학교")
    staff = api.login_instructor("staff", org="A 학교", role="staff")
    org_id = _org_id(api, staff)

    calls = [
        api.get(f"{BASE}/{org_id}/members", staff),
        api.patch(f"{BASE}/{org_id}/members/1", {"role": "staff"}, staff),
        api.delete(f"{BASE}/{org_id}/members/1", staff),
        api.get(f"{BASE}/{org_id}/invites", staff),
        api.post(f"{BASE}/{org_id}/invites", {"role": "staff"}, staff),
        api.delete(f"{BASE}/{org_id}/invites/1", staff),
    ]
    assert [r.status_code for r in calls] == [403] * len(calls)


@pytest.mark.django_db
def test_expired_and_revoked_invites_are_rejected(api):
    owner = api.login_instructor("owner", org="A 학교")
    org_id = _org_id(api, owner)

    expired = _invite(api, owner, org_id, "staff")
    OrgInvite.objects.filter(token=expired["token"]).update(expires_at=timezone.now() - timedelta(minutes=1))
    late = api.login("late")
    assert api.get(f"/api/org-invites/{expired['token']}").json()["valid"] is False
    assert api.post(f"/api/org-invites/{expired['token']}/accept", session=late).status_code == 410

    closed = _invite(api, owner, org_id, "staff")
    assert api.delete(f"{BASE}/{org_id}/invites/{closed['id']}", owner).status_code == 204
    assert api.post(f"/api/org-invites/{closed['token']}/accept", session=late).status_code == 410

    assert api.post("/api/org-invites/nope/accept", session=late).status_code == 404
    assert api.get("/api/instructor/cohorts", late).status_code == 403


@pytest.mark.django_db
def test_regenerate_closes_previous_link_of_same_role(api):
    owner = api.login_instructor("owner", org="A 학교")
    org_id = _org_id(api, owner)
    first = _invite(api, owner, org_id)
    second = _invite(api, owner, org_id)
    other_role = _invite(api, owner, org_id, "owner")

    active = {i["token"] for i in api.get(f"{BASE}/{org_id}/invites", owner).json()}
    assert active == {second["token"], other_role["token"]}
    assert api.post(f"/api/org-invites/{first['token']}/accept", session=api.login("x")).status_code == 410


@pytest.mark.django_db
def test_owner_lists_changes_role_and_removes_members(api):
    owner = api.login_instructor("owner", org="A 학교")
    staff = api.login_instructor("staff", org="A 학교", role="staff")
    org_id = _org_id(api, owner)

    members = api.get(f"{BASE}/{org_id}/members", owner).json()
    assert [(m["username"], m["role"]) for m in members] == [("kakao:owner", "owner"), ("kakao:staff", "staff")]
    staff_id = members[1]["id"]

    res = api.patch(f"{BASE}/{org_id}/members/{staff_id}", {"role": "owner"}, owner)
    assert res.status_code == 200 and res.json()["role"] == "owner"

    assert api.delete(f"{BASE}/{org_id}/members/{staff_id}", owner).status_code == 204
    assert api.get("/api/instructor/cohorts", staff).status_code == 403


@pytest.mark.django_db
def test_last_owner_is_protected(api):
    owner = api.login_instructor("owner", org="A 학교")
    org_id = _org_id(api, owner)
    own_id = api.get(f"{BASE}/{org_id}/members", owner).json()[0]["id"]

    assert api.patch(f"{BASE}/{org_id}/members/{own_id}", {"role": "staff"}, owner).status_code == 409
    assert api.delete(f"{BASE}/{org_id}/members/{own_id}", owner).status_code == 409
    assert api.me(owner)["orgs"][0]["role"] == "owner"

    # 다른 owner 가 생기면 내려갈 수 있다.
    second = api.login_instructor("second", org="A 학교", role="owner")
    assert api.patch(f"{BASE}/{org_id}/members/{own_id}", {"role": "staff"}, second).status_code == 200


@pytest.mark.django_db
def test_other_org_owner_cannot_manage_this_org(api):
    a = api.login_instructor("owner-a", org="A 학교")
    b = api.login_instructor("owner-b", org="B 회사")
    a_org = _org_id(api, a)
    a_member = api.get(f"{BASE}/{a_org}/members", a).json()[0]["id"]
    invite = _invite(api, a, a_org)

    denied = [
        api.get(f"{BASE}/{a_org}/members", b),
        api.patch(f"{BASE}/{a_org}/members/{a_member}", {"role": "staff"}, b),
        api.delete(f"{BASE}/{a_org}/members/{a_member}", b),
        api.get(f"{BASE}/{a_org}/invites", b),
        api.post(f"{BASE}/{a_org}/invites", {"role": "owner"}, b),
        api.delete(f"{BASE}/{a_org}/invites/{invite['id']}", b),
    ]
    assert [r.status_code for r in denied] == [404] * len(denied)
    assert len(api.get(f"{BASE}/{a_org}/members", a).json()) == 1
    assert len(api.get(f"{BASE}/{a_org}/invites", a).json()) == 1

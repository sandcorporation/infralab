"""강사 플래그 — manage.py set_instructor 로 켜고, 강사 전용 API 는 그 플래그로 막는다."""

import pytest
from django.core.management import CommandError, call_command


@pytest.mark.django_db
def test_instructor_api_rejects_anonymous_and_plain_students(api):
    assert api.get("/api/instructor/me").status_code == 401
    student = api.login("student-1")
    assert api.get("/api/instructor/me", student).status_code == 403


@pytest.mark.django_db
def test_set_instructor_opens_the_instructor_api(api):
    s = api.login("teacher-1")
    assert api.get("/api/instructor/me", s).status_code == 403

    call_command("set_instructor", "sandcorp:teacher-1")

    assert api.get("/api/instructor/me", s).status_code == 200
    assert api.me(s)["is_instructor"] is True


@pytest.mark.django_db
def test_set_instructor_off_closes_it_again(api):
    s = api.login_instructor("teacher-2")
    assert api.get("/api/instructor/me", s).status_code == 200

    call_command("set_instructor", "sandcorp:teacher-2", "--off")

    assert api.get("/api/instructor/me", s).status_code == 403


@pytest.mark.django_db
def test_set_instructor_for_unknown_user_fails_clearly():
    with pytest.raises(CommandError, match="사용자가 없습니다"):
        call_command("set_instructor", "sandcorp:nobody")

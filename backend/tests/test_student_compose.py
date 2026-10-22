"""학생의 compose.yml — 내 토큰이 박힌 파일 하나로 설치가 끝난다."""

import pytest
import yaml
from django.test import override_settings


def _compose(api, student, cohort_id):
    res = api.get(f"/api/cohorts/{cohort_id}/compose.yml", student)
    assert res.status_code == 200, res.content
    return res


@pytest.mark.django_db
def test_compose_has_my_token_fixed_names_and_is_a_yaml_download(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "1기")
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    mine = api.get(f"/api/cohorts/{cohort['id']}", student).json()
    assert mine["agent_url"] == "http://127.0.0.1:7777"
    assert len(mine["agent_token"]) >= 20

    res = _compose(api, student, cohort["id"])
    assert res["Content-Type"].startswith("text/yaml")
    assert 'filename="compose.yml"' in res["Content-Disposition"]
    doc = yaml.safe_load(res.content.decode("utf-8"))
    agent = doc["services"]["agent"]
    assert agent["environment"]["AGENT_TOKEN"] == mine["agent_token"]
    assert agent["ports"] == ["127.0.0.1:7777:7777"]
    assert agent["container_name"] == "infralab-agent"
    assert agent["environment"]["WORKSTATION_CONTAINER"] == "infralab-workstation"
    assert doc["services"]["workstation"]["container_name"] == "infralab-workstation"
    assert doc["services"]["workstation"]["volumes"] == ["./work:/work"]
    assert doc["services"]["workstation"]["environment"]["AWS_ENDPOINT_URL"] == "http://infralab-floci:4566"
    assert doc["services"]["floci"]["container_name"] == "infralab-floci"
    assert "/var/run/docker.sock:/var/run/docker.sock" in doc["services"]["agent"]["volumes"]


@pytest.mark.django_db
def test_compose_never_carries_someone_elses_token(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    a = api.login("a")
    b = api.login("b")
    api.join(a, cohort["join_token"])
    api.join(b, cohort["join_token"])
    token_a = api.get(f"/api/cohorts/{cohort['id']}", a).json()["agent_token"]
    token_b = api.get(f"/api/cohorts/{cohort['id']}", b).json()["agent_token"]
    assert token_a != token_b
    body_a = _compose(api, a, cohort["id"]).content.decode()
    assert token_a in body_a and token_b not in body_a


@pytest.mark.django_db
def test_images_and_dashboard_origin_come_from_settings(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    with override_settings(
        AGENT_IMAGE="ghcr.io/x/agent:1.2.3",
        WORKSTATION_IMAGE="ghcr.io/x/ws:1.2.3",
        FLOCI_IMAGE="floci/floci:9",
        DASHBOARD_ORIGIN="https://lab.example.com",
    ):
        doc = yaml.safe_load(_compose(api, student, cohort["id"]).content)
    assert doc["services"]["agent"]["image"] == "ghcr.io/x/agent:1.2.3"
    assert doc["services"]["workstation"]["image"] == "ghcr.io/x/ws:1.2.3"
    assert doc["services"]["floci"]["image"] == "floci/floci:9"
    assert doc["services"]["agent"]["environment"]["AGENT_ALLOWED_ORIGINS"] == "https://lab.example.com"


@pytest.mark.django_db
def test_local_dashboard_origin_allows_both_localhost_spellings(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    with override_settings(DASHBOARD_ORIGIN="http://127.0.0.1:53040"):
        doc = yaml.safe_load(_compose(api, student, cohort["id"]).content)
    assert doc["services"]["agent"]["environment"]["AGENT_ALLOWED_ORIGINS"] == "http://127.0.0.1:53040,http://localhost:53040"


def test_allowed_origins_are_normalized_and_deduplicated():
    from cohorts.compose import allowed_origins

    # 뒤 슬래시·경로는 버린다 — 브라우저 Origin 헤더와 글자 그대로 비교된다.
    assert allowed_origins("https://lab.example.com/") == ["https://lab.example.com"]
    assert allowed_origins("https://lab.example.com/app/index.html") == ["https://lab.example.com"]
    assert allowed_origins("http://localhost:5173, http://127.0.0.1:5173") == ["http://localhost:5173", "http://127.0.0.1:5173"]
    assert allowed_origins("not-a-url,") == []


@pytest.mark.django_db
def test_cohort_name_with_newlines_cannot_break_the_yaml(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher, "1기\nservices: {}")
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    doc = yaml.safe_load(_compose(api, student, cohort["id"]).content)
    assert set(doc["services"]) == {"agent", "workstation", "floci"}


@pytest.mark.django_db
def test_regenerating_the_agent_token_changes_the_compose_file(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    student = api.login("s1")
    api.join(student, cohort["join_token"])
    old = api.get(f"/api/cohorts/{cohort['id']}", student).json()["agent_token"]

    res = api.post(f"/api/cohorts/{cohort['id']}/agent-token/regenerate", session=student)
    assert res.status_code == 200
    new = res.json()["agent_token"]
    assert new != old
    body = _compose(api, student, cohort["id"]).content.decode()
    assert new in body and old not in body


@pytest.mark.django_db
def test_only_members_get_a_compose_file(api):
    teacher = api.login_instructor()
    cohort = api.create_cohort(teacher)
    outsider = api.login("out")
    assert api.get(f"/api/cohorts/{cohort['id']}", outsider).status_code == 404
    assert api.get(f"/api/cohorts/{cohort['id']}/compose.yml", outsider).status_code == 404
    assert api.post(f"/api/cohorts/{cohort['id']}/agent-token/regenerate", session=outsider).status_code == 404
    assert api.get(f"/api/cohorts/{cohort['id']}/compose.yml").status_code == 401

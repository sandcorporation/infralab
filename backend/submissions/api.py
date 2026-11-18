"""학생의 제출 API — 브라우저가 에이전트 결과를 올리고, 자기 최신 제출과 이력을 본다."""

from __future__ import annotations

from django.http import HttpRequest
from ninja import Router
from ninja.errors import HttpError
from ninja.responses import Status

from accounts.auth import jwt_auth
from cohorts.services import my_membership, open_scenario
from exams.services import check_attempt

from .models import MAX_OUTPUT_CHARS, Submission
from .schemas import SubmissionIn, SubmissionOut, SubmissionSummaryOut
from .services import has_transcript, normalize_transcript, score

student_router = Router(tags=["student"], auth=jwt_auth)


def summary_out(sub: Submission) -> dict:
    passed, total = score(sub)
    return {
        "id": sub.id,
        "scenario_id": sub.scenario_id,
        "submitted_at": sub.submitted_at,
        "agent_version": sub.agent_version,
        "passed": passed,
        "total": total,
        "has_transcript": has_transcript(sub),
    }


def submission_out(sub: Submission) -> dict:
    return {**summary_out(sub), "results": sub.results, "ai_transcript": sub.ai_transcript}


def _clip(text: str) -> tuple[str, bool]:
    if len(text) <= MAX_OUTPUT_CHARS:
        return text, False
    return text[:MAX_OUTPUT_CHARS] + "\n…(truncated)", True


@student_router.post("/cohorts/{cohort_id}/scenarios/{scenario_id}/submissions", response={201: SubmissionOut})
def submit(request: HttpRequest, cohort_id: int, scenario_id: str, payload: SubmissionIn):
    """에이전트가 돌린 결과를 증거와 함께 저장한다. 검사 id 는 시나리오의 것이어야 하고, 하나씩 다 있어야 한다."""

    m = my_membership(request, cohort_id)
    check_attempt(m, submitting=True)
    scenario = open_scenario(m, scenario_id)
    expected = [c.id for c in scenario.checks]
    got = [r.id for r in payload.results]
    if sorted(got) != sorted(expected):
        raise HttpError(422, f"검사 결과가 시나리오와 맞지 않습니다 (기대 {expected}, 받음 {got})")

    transcript = normalize_transcript(payload.ai_transcript)
    by_id = {r.id: r for r in payload.results}
    names = {c.id: c.name for c in scenario.checks}
    results = []
    for cid in expected:
        r = by_id[cid]
        output, clipped = _clip(r.output)
        results.append(
            {
                "check_id": cid,
                "name": names[cid],
                "pass": r.pass_,
                "output": output,
                "truncated": r.truncated or clipped,
                "exit_code": r.exit_code,
                "error": r.error[:500],
            }
        )
    sub = Submission.objects.create(
        membership=m,
        scenario_id=scenario_id,
        # 에이전트 빌드 문자열이 길어도 채점 결과를 버리지 않는다 — 잘라 둔다.
        agent_version=payload.agent_version[:64],
        passed=sum(1 for r in results if r["pass"]),
        total=len(expected),
        results=results,
        ai_transcript=transcript,
    )
    return Status(201, submission_out(sub))


@student_router.get("/cohorts/{cohort_id}/scenarios/{scenario_id}/submissions", response=list[SubmissionSummaryOut])
def my_submissions(request: HttpRequest, cohort_id: int, scenario_id: str):
    m = my_membership(request, cohort_id)
    open_scenario(m, scenario_id)
    return [summary_out(s) for s in Submission.objects.filter(membership=m, scenario_id=scenario_id)]


@student_router.get("/cohorts/{cohort_id}/scenarios/{scenario_id}/submissions/latest", response=SubmissionOut)
def my_latest_submission(request: HttpRequest, cohort_id: int, scenario_id: str):
    m = my_membership(request, cohort_id)
    open_scenario(m, scenario_id)
    sub = Submission.objects.filter(membership=m, scenario_id=scenario_id).first()
    if sub is None:
        raise HttpError(404, "아직 제출이 없습니다.")
    return submission_out(sub)

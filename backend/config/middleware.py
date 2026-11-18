from django.conf import settings


class VersionHeaderMiddleware:
    """모든 /api/ 응답(인증 실패·404 포함)에 X-Infralab-Version 헤더로 배포된 판을 붙인다."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)
        if request.path.startswith("/api/"):
            response["X-Infralab-Version"] = settings.INFRALAB_VERSION
        return response

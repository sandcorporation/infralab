from django.apps import AppConfig


class ScenariosConfig(AppConfig):
    default_auto_field = "django.db.models.BigAutoField"
    name = "scenarios"

    def ready(self) -> None:
        # 시작 때 전부 읽어 메모리에 든다 — 깨진 YAML 은 여기서 부팅을 막는다(수업 중에 만나지 않게).
        from . import registry

        registry.load()

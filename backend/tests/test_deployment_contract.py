"""Docker/Compose와 Git 체크아웃 안전성 계약의 정적 회귀 검사."""

from pathlib import Path
import re


PROJECT_ROOT = Path(__file__).resolve().parents[2]


def _service_block(compose: str, service: str) -> str:
    """Compose 원문에서 지정 서비스의 들여쓰기 블록만 반환한다."""
    lines = compose.splitlines()
    marker = f"  {service}:"
    try:
        start = lines.index(marker) + 1
    except ValueError as exc:
        raise AssertionError(f"Compose service missing: {service}") from exc

    block: list[str] = []
    for line in lines[start:]:
        if line and line.startswith("  ") and not line.startswith("    "):
            break
        block.append(line)
    return "\n".join(block)


def test_backend_entrypoint_is_normalized_and_invoked_safely():
    dockerfile = (PROJECT_ROOT / "backend" / "Dockerfile").read_text(encoding="utf-8")

    assert "COPY --chmod=0755 docker-entrypoint.sh /app/docker-entrypoint.sh" in dockerfile
    assert "sed -i 's/\\r$//' /app/docker-entrypoint.sh" in dockerfile
    assert "sed -i '1s/^\\xEF\\xBB\\xBF//' /app/docker-entrypoint.sh" in dockerfile
    assert 'ENTRYPOINT ["/bin/sh", "/app/docker-entrypoint.sh"]' in dockerfile


def test_entrypoint_source_has_no_bom_or_crlf():
    entrypoint = (PROJECT_ROOT / "backend" / "docker-entrypoint.sh").read_bytes()

    assert not entrypoint.startswith(b"\xef\xbb\xbf")
    assert b"\r\n" not in entrypoint


def test_compose_supports_backend_image_and_waits_for_healthy_services():
    compose = (PROJECT_ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    backend = _service_block(compose, "backend")
    frontend = _service_block(compose, "frontend")

    assert "context: ./backend" in backend
    assert "image: ghcr.io/jskim1102/rtsp-tracking-backend:latest" in backend
    assert "pull_policy: build" not in backend
    assert "pull_policy: build" in frontend
    assert "healthcheck:" in backend
    assert "http://127.0.0.1:8000/api/health" in backend
    assert "healthcheck:" in frontend
    assert "http://127.0.0.1/" in frontend
    assert re.search(
        r"(?m)^    depends_on:\n      backend:\n        condition: service_healthy$",
        frontend,
    )


def test_compose_persists_both_weight_caches_and_opts_into_gpu():
    compose = (PROJECT_ROOT / "docker-compose.yml").read_text(encoding="utf-8")
    backend = _service_block(compose, "backend")
    assert "YOLO_WEIGHTS_DIR: /app/models" in backend
    assert "yolo_weights:/app/models" in backend
    assert "hf_weights:/root/.cache/huggingface" in backend
    assert "TRACKER_DEVICE: ${TRACKER_DEVICE:-}" in backend
    assert "driver: nvidia" not in compose
    gpu = (PROJECT_ROOT / "docker-compose.gpu.yml").read_text(encoding="utf-8")
    assert "driver: nvidia" in _service_block(gpu, "backend")


def test_git_attributes_keep_shell_scripts_on_lf():
    attributes = (PROJECT_ROOT / ".gitattributes").read_text(encoding="utf-8").splitlines()

    assert "* text=auto eol=lf" in attributes
    assert "*.sh text eol=lf" in attributes

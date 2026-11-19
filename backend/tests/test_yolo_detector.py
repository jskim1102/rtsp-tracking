from __future__ import annotations

from pathlib import Path
from pickle import UnpicklingError
from types import SimpleNamespace
from unittest.mock import Mock
from zipfile import ZipFile

import numpy as np
import pytest

from app.tracking import detector as detector_module
from app.tracking.detector import YoloSegDetector


class _Tensor:
    def __init__(self, value) -> None:
        self._value = np.asarray(value)

    def detach(self):
        return self

    def cpu(self):
        return self

    def numpy(self) -> np.ndarray:
        return self._value


class _FakeModel:
    def __init__(self, results) -> None:
        self.results = results
        self.calls: list[tuple[np.ndarray, dict]] = []

    def predict(self, frame: np.ndarray, **kwargs):
        self.calls.append((frame, dict(kwargs)))
        return self.results


def _result(*, masks=True):
    first_mask = np.zeros((8, 8), dtype=np.uint8)
    first_mask[1:5, 1:5] = 1
    second_mask = np.zeros((8, 8), dtype=np.uint8)
    second_mask[2:7, 2:7] = 1
    return SimpleNamespace(
        boxes=SimpleNamespace(
            xyxy=_Tensor([[1.2, 2.7, 10.4, 20.6], [2, 3, 7, 8]]),
            conf=_Tensor([0.91, 0.88]),
            cls=_Tensor([0, 2]),
        ),
        masks=(
            SimpleNamespace(data=_Tensor([first_mask, second_mask]))
            if masks
            else None
        ),
    )


def test_detector_converts_person_boxes_scores_and_largest_mask_contour(monkeypatch, tmp_path):
    model = _FakeModel([_result()])
    monkeypatch.setattr(detector_module.app_config, "YOLO_WEIGHTS_DIR", tmp_path)
    loaded: list[str] = []
    monkeypatch.setattr(
        detector_module,
        "_load_yolo_model",
        lambda path: loaded.append(path) or model,
    )
    detector = YoloSegDetector(
        "yolo26n-seg.pt",
        device="cuda:0",
        conf=0.5,
        imgsz=560,
    )
    frame = np.zeros((8, 8, 3), dtype=np.uint8)

    detections = detector.detect(frame)

    assert loaded == [str(tmp_path / "yolo26n-seg.pt")]
    assert len(detections) == 1
    assert detections[0].bbox == (1, 3, 10, 21)
    assert detections[0].score == pytest.approx(0.91)
    assert detections[0].polygon is not None
    assert set(detections[0].polygon) == {(1, 1), (1, 4), (4, 4), (4, 1)}
    assert model.calls == [
        (
            frame,
            {
                "classes": [0],
                "conf": 0.5,
                "device": "cuda:0",
                "half": True,
                "imgsz": 560,
                "retina_masks": True,
                "verbose": False,
            },
        )
    ]


def test_detector_keeps_person_box_when_mask_is_missing(monkeypatch):
    model = _FakeModel([_result(masks=False)])
    monkeypatch.setattr(detector_module, "_load_yolo_model", lambda _: model)
    detector = YoloSegDetector("yolo26n-seg.pt", "cpu", 0.4, 480)

    detections = detector.detect(np.zeros((8, 8, 3), dtype=np.uint8))

    assert len(detections) == 1
    assert detections[0].polygon is None
    assert model.calls[0][1]["half"] is False


def test_detector_rejects_non_allowlisted_model_before_loading(monkeypatch):
    monkeypatch.setattr(
        detector_module,
        "_load_yolo_model",
        lambda _: pytest.fail("untrusted model must not be loaded"),
    )

    with pytest.raises(ValueError, match="preset"):
        YoloSegDetector("/tmp/untrusted.pt", "cpu", 0.5, 560)


@pytest.mark.parametrize("error", [EOFError(), UnpicklingError("truncated"), RuntimeError("incomplete archive")])
def test_incomplete_preset_is_downloaded_again_once(tmp_path, monkeypatch, error):
    path = tmp_path / "yolo26n-seg.pt"
    path.write_bytes(b"partial")
    other = tmp_path / "yolo26x-seg.pt"
    other.write_bytes(b"keep")
    monkeypatch.setattr(detector_module.app_config, "YOLO_WEIGHTS_DIR", tmp_path)
    loads = []
    model = _FakeModel([])

    def load(filename):
        assert Path(filename) == path
        loads.append(path.exists())
        if len(loads) == 1:
            raise error
        if isinstance(error, EOFError):
            raise EOFError("second load failed")
        return model

    monkeypatch.setattr("ultralytics.YOLO", load)
    if isinstance(error, EOFError):
        with pytest.raises(EOFError, match="second load failed"):
            YoloSegDetector(path.name, "cpu")
    else:
        assert YoloSegDetector(path.name, "cpu").model is model

    assert loads == [True, False]
    assert other.read_bytes() == b"keep"


@pytest.mark.parametrize("state", ["zip", "missing", "oom"])
def test_preset_load_preserves_valid_archive_and_skips_unrelated_retries(tmp_path, monkeypatch, state):
    path = tmp_path / "yolo26n-seg.pt"
    error = RuntimeError("load failed")
    if state == "zip":
        with ZipFile(path, "w") as archive:
            archive.writestr("weights", b"model")
    elif state == "oom":
        path.write_bytes(b"keep")
        error = RuntimeError("CUDA out of memory")
    original = path.read_bytes() if path.exists() else None
    monkeypatch.setattr(detector_module.app_config, "YOLO_WEIGHTS_DIR", tmp_path)
    load = Mock(side_effect=error)
    monkeypatch.setattr("ultralytics.YOLO", load)

    with pytest.raises(RuntimeError, match=str(error)):
        YoloSegDetector(path.name, "cpu")

    load.assert_called_once_with(str(path))
    assert (path.read_bytes() if path.exists() else None) == original

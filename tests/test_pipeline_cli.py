import sys

import pricing_canasta.pipeline as pipeline


def test_all_stage_propagates_as_of_force_and_order(monkeypatch):
    calls = []
    monkeypatch.setattr(pipeline, "download_all", lambda: calls.append(("download",)))
    monkeypatch.setattr(
        pipeline,
        "ingest_all",
        lambda **kwargs: calls.append(("ingest", kwargs)),
    )
    monkeypatch.setattr(
        pipeline,
        "build_analytics",
        lambda **kwargs: calls.append(("build", kwargs)),
    )
    monkeypatch.setattr(pipeline, "export_all", lambda: calls.append(("export",)))
    monkeypatch.setattr(pipeline, "validate", lambda: calls.append(("validate",)))
    monkeypatch.setattr(
        sys,
        "argv",
        [
            "pipeline",
            "all",
            "--force",
            "--as-of",
            "2026-08-02",
            "--only-snapshot",
            "2026-08-02",
        ],
    )
    pipeline.main()
    assert [call[0] for call in calls] == ["download", "ingest", "build", "export"]
    assert calls[1][1]["force"] is True
    assert str(calls[1][1]["as_of"]) == "2026-08-02"
    assert str(calls[2][1]["as_of"]) == "2026-08-02"


def test_validate_stage_runs_only_validation(monkeypatch):
    calls = []
    monkeypatch.setattr(pipeline, "validate", lambda: calls.append("validate"))
    monkeypatch.setattr(sys, "argv", ["pipeline", "validate"])
    pipeline.main()
    assert calls == ["validate"]

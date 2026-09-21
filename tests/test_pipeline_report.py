"""运行报告的内容正确性。

写这个测试的原因：报告里的错误**不会让任何东西报错**，只会让人拿错东西。
实际发生过的两处：

1. 数据源被硬编码成「合成数据」——用真人复核数据跑完，报告第一行仍写着
   「合成数据，不可用于交付模型」；
2. 导出命令硬编码指向 `runs/pg_pipeline/weights/best.pt`——一个已过期的旧权重。
"""
from pathlib import Path

from run_pipeline import REPO_ROOT, build_report

BEST = REPO_ROOT / "runs" / "pg_review_v0" / "weights" / "best.pt"

SUMMARY = {
    "map50": 0.7875,
    "map50_95": 0.5556,
    "precision": 0.5667,
    "recall": 0.75,
    "per_class": [
        {"id": 6, "name": "pedestrian", "precision": 0.333, "recall": 0.5, "map50": 0.58},
        {"id": 7, "name": "bin", "precision": 0.8, "recall": 1.0, "map50": 0.995},
    ],
}

SKIPPED_EXPORT = {"skipped": "沙箱环境下 TFLite 导出不可用"}


def _report(**over):
    kwargs = dict(
        data_source="复用现有数据集（真人采集/人工复核）",
        n_images=44,
        split={"seed": 42, "counts": {"train": 36, "val": 4, "test": 4},
               "single_source": True,
               "single_source_note": "单来源等间隔取样：同源划分无法防泄漏"},
        elapsed=72.0,
        summary=SUMMARY,
        export_info=SKIPPED_EXPORT,
        best=BEST,
        base_model="yolo11n.pt",
        epochs=100,
        imgsz=416,
        batch=8,
        workers=0,
        now="2026-09-22 02:44:21",
    )
    kwargs.update(over)
    return build_report(**kwargs)


def test_real_reviewed_data_is_not_described_as_synthetic():
    text = _report()
    assert "数据源：复用现有数据集（真人采集/人工复核）" in text
    assert "合成数据的指标没有实际意义" not in text


def test_synthetic_label_still_gets_the_synthetic_caveat():
    text = _report(data_source="合成数据（仅用于验证流水线）")
    assert "合成数据的指标没有实际意义" in text


def test_export_command_points_at_the_weights_this_run_produced():
    """曾经的缺陷：导出命令硬编码指向 runs/pg_pipeline 的旧权重。"""
    text = _report()
    assert "runs/pg_review_v0/weights/best.pt" in text
    assert "runs\\pg_pipeline" not in text


def test_single_source_split_gets_a_prominent_confidence_warning():
    text = _report()
    assert "单来源划分" in text
    assert "不得作为论文性能结论" in text


def test_multi_source_split_has_no_single_source_warning():
    text = _report(split={"seed": 42, "counts": {"train": 30, "val": 7, "test": 7},
                          "single_source": False})
    assert "不得作为论文性能结论" not in text


def test_report_lists_every_class_metric():
    text = _report()
    assert "| 7 | bin | 0.800 | 1.000 | 0.995 |" in text
    assert "| 6 | pedestrian | 0.333 | 0.500 | 0.580 |" in text


def test_report_includes_overall_metrics_with_four_decimals():
    text = _report()
    assert "mAP@0.5：0.7875" in text
    assert "macro Recall：0.7500" in text

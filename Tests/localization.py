#!/usr/bin/env python3
"""检查原生语言匹配、资源覆盖、占位符和可选的原生菜单快照，不改系统语言。"""
import argparse
import json
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("app", type=pathlib.Path)
parser.add_argument("--ui-reports", type=pathlib.Path)
args = parser.parse_args()
executable = args.app / "Contents/MacOS/MonitorOnOff"
resources = args.app / "Contents/Resources"
languages = ["en", "zh-Hans", "zh-Hant", "ko", "ja"]
catalogs = {}
for language in languages:
    data = subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(resources / f"{language}.lproj/Localizable.strings")])
    catalogs[language] = json.loads(data)
keys = set(catalogs["en"])
placeholders = lambda value: re.findall(r"%(?:\d+\$)?(?:l)?[@du]", value)
for language, catalog in catalogs.items():
    assert set(catalog) == keys, (language, "资源键不完整")
    assert all(isinstance(value, str) and value for value in catalog.values()), language
    for key in keys:
        assert placeholders(catalog[key]) == placeholders(catalogs["en"][key]), (language, key, "占位符不一致")
print(f"5 种语言 × {len(keys)} 项文案：键、非空值与格式占位符检查通过。")

cases = [(f"({language})", language) for language in languages] + [
    ("(zh-CN)", "zh-Hans"), ("(zh-SG)", "zh-Hans"),
    ("(zh-TW)", "zh-Hant"), ("(zh-HK)", "zh-Hant"),
    ("(ko-KR)", "ko"), ("(ja-JP)", "ja"), ("(en-GB)", "en"),
    ("(fr)", "en"), ("(fr, ja)", "ja")
]
for preferences, expected in cases:
    result = json.loads(subprocess.check_output([str(executable), "--localization-diagnostics", "-AppleLanguages", preferences]))
    assert result["language"] == expected, (preferences, result["language"], expected)
    assert result["strings"] == catalogs[expected], (preferences, "运行时文案与资源不匹配")
    sample = result["samples"]
    assert "2" in sample["status.tooltip_disabled"]
    assert "42" in sample["display.external_name"]
    assert "1000" in sample["error.enumerate"] and "1000" in sample["error.configure"]
    assert catalogs[expected]["error.commit"] in sample["error.configure"]
    assert "Sample Display" in sample["error.for_display"] and "Sample Error" in sample["error.for_display"]
    assert "Sample Display" in sample["restore.incomplete_details"]
    assert all("%@" not in value and "%ld" not in value and "%u" not in value and "%d" not in value for value in sample.values())
    print(f"原生语言匹配 {preferences} → {expected}：通过。")

if args.ui_reports:
    for language in languages:
        report = json.loads((args.ui_reports / f"{language}.json").read_text())
        assert len(report) == 15 and all(report.values()), (language, report)
        snapshot = json.loads((args.ui_reports / f"{language}.json.localization.json").read_text())
        assert snapshot["language"] == language, snapshot["language"]
        catalog = catalogs[language]
        assert snapshot["strings"] == catalog
        titles = [row["title"] for row in snapshot["menus"]]
        for key in ["menu.restore", "menu.refresh", "menu.login", "menu.about", "menu.quit"]:
            assert catalog[key] in titles, (language, key, titles)
        display_rows = [row for row in snapshot["menus"] if row["children"]]
        assert display_rows, (language, "没有显示器菜单")
        for row in display_rows:
            children = row["children"]
            assert children[0] in [catalog["output.off"], catalog["output.on"]], (language, children)
            assert children[1] in [catalog["status.on"], catalog["status.off"]], (language, children)
        assert any(row["title"].endswith(catalog["display.builtin_suffix"]) and catalog["safety.builtin"] in row["children"] for row in display_rows)
        print(f"{language}：15 项原生界面检查及菜单翻译核对通过。")

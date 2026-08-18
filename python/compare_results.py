#!/usr/bin/env python3
"""Bit-exact comparison of Vivado XSIM Sobel output against MATLAB data."""

from __future__ import annotations

import argparse
import binascii
import csv
import json
import math
import struct
import zlib
from pathlib import Path
from typing import Iterable


def read_hex_pixels(path: Path) -> list[int]:
    values: list[int] = []
    with path.open("r", encoding="ascii") as handle:
        for line_number, raw_line in enumerate(handle, start=1):
            line = raw_line.split("//", 1)[0].strip()
            if not line:
                continue
            token = line.split()[0]
            try:
                value = int(token, 16)
            except ValueError as exc:
                raise ValueError(f"{path}:{line_number}: invalid hex pixel {token!r}") from exc
            if not 0 <= value <= 255:
                raise ValueError(f"{path}:{line_number}: pixel outside uint8 range: {value}")
            values.append(value)
    return values


def fit_frame(values: Iterable[int], frame_pixels: int) -> list[int]:
    fitted = list(values)[:frame_pixels]
    if len(fitted) < frame_pixels:
        fitted.extend([0] * (frame_pixels - len(fitted)))
    return fitted


def png_chunk(chunk_type: bytes, data: bytes) -> bytes:
    payload = chunk_type + data
    return struct.pack(">I", len(data)) + payload + struct.pack(">I", binascii.crc32(payload) & 0xFFFFFFFF)


def write_png(path: Path, pixels: Iterable[int], width: int, height: int) -> None:
    frame = fit_frame(pixels, width * height)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        scanlines = b"".join(
            b"\x00" + bytes(frame[row * width : (row + 1) * width])
            for row in range(height)
        )
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(png_chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0)))
        handle.write(png_chunk(b"IDAT", zlib.compress(scanlines, level=9)))
        handle.write(png_chunk(b"IEND", b""))


def count_nonzero_border(pixels: list[int], width: int, height: int) -> int:
    if len(pixels) != width * height:
        return -1
    count = 0
    for row in range(height):
        for col in range(width):
            if row in (0, height - 1) or col in (0, width - 1):
                count += int(pixels[row * width + col] != 0)
    return count


def compare_case(project_root: Path, row: dict[str, str], preview_dir: Path) -> dict[str, object]:
    case_name = row["case_name"]
    width = int(row["width"])
    height = int(row["height"])
    frame_pixels = width * height

    golden_path = project_root / row["golden_mem"]
    rtl_path = project_root / row["rtl_mem"]

    golden = read_hex_pixels(golden_path)
    if rtl_path.exists():
        rtl = read_hex_pixels(rtl_path)
        missing_rtl = False
    else:
        rtl = []
        missing_rtl = True

    paired = min(len(golden), len(rtl))
    differences = [abs(golden[index] - rtl[index]) for index in range(paired)]
    mismatch_indices = [index for index, difference in enumerate(differences) if difference != 0]

    length_ok = len(golden) == frame_pixels and len(rtl) == frame_pixels
    exact_match = length_ok and not mismatch_indices and not missing_rtl
    max_abs_error = max(differences, default=0)
    mae = (sum(differences) / paired) if paired else float("nan")
    rmse = math.sqrt(sum(value * value for value in differences) / paired) if paired else float("nan")

    if mismatch_indices:
        first_index = mismatch_indices[0]
        first_row = first_index // width
        first_col = first_index % width
        first_mismatch = f"({first_row},{first_col})"
    elif not length_ok:
        first_mismatch = "length"
    else:
        first_mismatch = ""

    golden_frame = fit_frame(golden, frame_pixels)
    rtl_frame = fit_frame(rtl, frame_pixels)
    difference_frame = [abs(expected - actual) for expected, actual in zip(golden_frame, rtl_frame)]
    write_png(preview_dir / f"{case_name}_rtl.png", rtl_frame, width, height)
    write_png(preview_dir / f"{case_name}_absdiff.png", difference_frame, width, height)

    return {
        "case_name": case_name,
        "width": width,
        "height": height,
        "expected_pixels": frame_pixels,
        "golden_pixels": len(golden),
        "rtl_pixels": len(rtl),
        "mismatch_count": len(mismatch_indices) + abs(len(golden) - len(rtl)),
        "max_abs_error": max_abs_error,
        "mae": mae,
        "rmse": rmse,
        "first_mismatch": first_mismatch,
        "rtl_nonzero_border_pixels": count_nonzero_border(rtl, width, height),
        "status": "PASS" if exact_match else "FAIL",
    }


def parse_args() -> argparse.Namespace:
    script_path = Path(__file__).resolve()
    default_root = script_path.parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=default_root)
    parser.add_argument("--manifest", type=Path, default=Path("testdata/manifest.csv"))
    parser.add_argument("--report-dir", type=Path, default=Path("reports"))
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project_root = args.project_root.resolve()
    manifest_path = args.manifest if args.manifest.is_absolute() else project_root / args.manifest
    report_dir = args.report_dir if args.report_dir.is_absolute() else project_root / args.report_dir
    preview_dir = report_dir / "previews"
    report_dir.mkdir(parents=True, exist_ok=True)

    with manifest_path.open("r", encoding="utf-8", newline="") as handle:
        manifest_rows = list(csv.DictReader(handle))

    results = [compare_case(project_root, row, preview_dir) for row in manifest_rows]
    fieldnames = list(results[0].keys()) if results else []

    csv_path = report_dir / "comparison_report.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(results)

    pass_count = sum(result["status"] == "PASS" for result in results)
    try:
        manifest_label = manifest_path.relative_to(project_root).as_posix()
    except ValueError:
        manifest_label = str(manifest_path)

    summary = {
        "manifest": manifest_label,
        "total_cases": len(results),
        "passed_cases": pass_count,
        "failed_cases": len(results) - pass_count,
        "all_passed": pass_count == len(results),
        "cases": results,
    }
    json_path = report_dir / "comparison_report.json"
    json_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8")

    print("\nBit-exact MATLAB vs RTL comparison")
    print("case_name         status  mismatches  max_error  border_nonzero")
    print("----------------  ------  ----------  ---------  --------------")
    for result in results:
        print(
            f"{result['case_name']:<16}  {result['status']:<6}  "
            f"{result['mismatch_count']:>10}  {result['max_abs_error']:>9}  "
            f"{result['rtl_nonzero_border_pixels']:>14}"
        )
    print(f"\nSummary: {pass_count}/{len(results)} cases passed")
    print(f"CSV report : {csv_path}")
    print(f"JSON report: {json_path}")
    return 0 if summary["all_passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

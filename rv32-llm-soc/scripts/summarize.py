#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
RESULTS = ROOT / "results"
RESULTS.mkdir(exist_ok=True)


def cmd(command: list[str]) -> str:
    try:
        return subprocess.check_output(
            command, text=True, stderr=subprocess.STDOUT
        ).strip()
    except Exception as exc:
        return f"unavailable: {exc}"


def sha256(path: Path) -> str | None:
    if not path.exists():
        return None
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_size(path: Path) -> int | None:
    return path.stat().st_size if path.exists() else None


def used_available(text: str, label: str) -> dict[str, int | float] | None:
    match = re.search(
        rf"{re.escape(label)}:\s*(\d+)\s*/\s*(\d+)", text, re.MULTILINE
    )
    if not match:
        return None
    used = int(match.group(1))
    available = int(match.group(2))
    return {
        "used": used,
        "available": available,
        "percent": round(100.0 * used / available, 3) if available else 0.0,
    }


def parse_pnr(text: str) -> dict[str, object]:
    resources: dict[str, object] = {}
    labels = {
        "lut4_total": "Total LUT4s",
        "dff_total": "Total DFFs",
        "trellis_comb": "TRELLIS_COMB",
        "trellis_ff": "TRELLIS_FF",
        "distributed_ram_write": "TRELLIS_RAMW",
        "block_ram_dp16kd": "DP16KD",
        "dsp_mult18x18d": "MULT18X18D",
        "io": "TRELLIS_IO",
        "global_clock_buffers": "DCCA",
        "pll": "EHXPLLL",
    }
    for key, label in labels.items():
        parsed = used_available(text, label)
        if parsed is not None:
            resources[key] = parsed

    timing_matches = re.findall(
        r"Max frequency for clock '([^']+)':\s*([0-9.]+) MHz "
        r"\((PASS|FAIL) at ([0-9.]+) MHz\)",
        text,
    )
    timing_reports = [
        {
            "clock": clock,
            "max_frequency_mhz": float(max_mhz),
            "status": status,
            "target_frequency_mhz": float(target_mhz),
        }
        for clock, max_mhz, status, target_mhz in timing_matches
    ]

    out: dict[str, object] = {
        "resources": resources,
        "program_finished_normally": "Program finished normally." in text,
        "timing_reports_in_log_order": timing_reports,
    }
    if timing_reports:
        # nextpnr can print a pre-route estimate and a final post-route report.
        # The final report is authoritative for the emitted routed configuration.
        final = timing_reports[-1]
        out["final_timing"] = final
        out["max_frequency_mhz"] = final["max_frequency_mhz"]
        out["timing_pass_25mhz"] = (
            final["status"] == "PASS"
            and abs(float(final["target_frequency_mhz"]) - 25.0) < 1e-9
        )
    else:
        out["timing_pass_25mhz"] = False
    return out


def main() -> None:
    pnr_log = (
        (BUILD / "nextpnr.log").read_text(errors="replace")
        if (BUILD / "nextpnr.log").exists()
        else ""
    )
    sim_log = (
        (BUILD / "simulation.log").read_text(errors="replace")
        if (BUILD / "simulation.log").exists()
        else ""
    )
    sim_cycle_match = re.search(
        r"PASS: RV32 firmware completed INT8 and INT4 accelerator tests at cycle (\d+)",
        sim_log,
    )

    manifest = {
        "design": "RV32 TinyLLM SoC for ULX3S-85F",
        "provenance": {
            "git_commit": os.environ.get("GITHUB_SHA"),
            "git_branch": os.environ.get("GITHUB_REF_NAME"),
            "github_actions_run_id": os.environ.get("GITHUB_RUN_ID"),
        },
        "target": {
            "fpga": "Lattice ECP5 LFE5U-85F-6BG381C",
            "board": "ULX3S v2.x/v3.0.x",
            "clock_mhz": 25,
        },
        "cpu": {
            "core": "PicoRV32",
            "isa": "RV32I",
            "pinned_commit": "a473fc8fca393771d83b0ffcf0b14db3393339d8",
            "memory_bytes": 16384,
        },
        "accelerator": {
            "operations": ["INT8 GEMV", "packed signed INT4 GEMV"],
            "m_max": 2,
            "k_max": 8,
            "lanes": 4,
            "accumulator_bits": 32,
            "mmio_base": "0x10000000",
            "self_test": {
                "int8_expected_results": [-20, -15],
                "int4_expected_results": [-53, 35],
                "expected_macs_per_test": 16,
                "expected_accelerator_cycles_per_test": 4,
            },
        },
        "verification": {
            "cpu_firmware_simulation_pass": (
                "PASS: RV32 firmware completed INT8 and INT4 accelerator tests"
                in sim_log
            ),
            "simulation_completion_cycle": (
                int(sim_cycle_match.group(1)) if sim_cycle_match else None
            ),
            "simulation_log_sha256": sha256(BUILD / "simulation.log"),
        },
        "physical_implementation": parse_pnr(pnr_log),
        "artifacts": {
            "bitstream": "build/rv32_llm_soc_ulx3s_85f.bit",
            "bitstream_bytes": file_size(BUILD / "rv32_llm_soc_ulx3s_85f.bit"),
            "bitstream_sha256": sha256(BUILD / "rv32_llm_soc_ulx3s_85f.bit"),
            "placed_routed_config_sha256": sha256(BUILD / "ulx3s.config"),
            "netlist_json_sha256": sha256(BUILD / "ulx3s.json"),
            "firmware_elf_bytes": file_size(BUILD / "firmware.elf"),
            "firmware_elf_sha256": sha256(BUILD / "firmware.elf"),
            "firmware_binary_bytes": file_size(BUILD / "firmware.bin"),
            "firmware_binary_sha256": sha256(BUILD / "firmware.bin"),
        },
        "tool_versions": {
            "yosys": cmd(["yosys", "-V"]),
            "nextpnr_ecp5": cmd(["nextpnr-ecp5", "--version"]),
            "ecppack": cmd(["ecppack", "--version"]),
            "iverilog": cmd(["iverilog", "-V"]).splitlines()[0],
            "verilator": cmd(["verilator", "--version"]),
            "riscv_gcc": cmd(
                ["riscv64-unknown-elf-gcc", "--version"]
            ).splitlines()[0],
        },
        "honesty": {
            "fpga_board_programmed_in_ci": False,
            "silicon_tapeout_completed": False,
            "claim": (
                "The bitstream is generated from RISC-V firmware, synthesizable RTL, "
                "ECP5 synthesis, placement, routing, and static timing analysis. "
                "Physical board execution requires programming an ULX3S-85F."
            ),
        },
    }
    (RESULTS / "build_manifest.json").write_text(
        json.dumps(manifest, indent=2), encoding="utf-8"
    )
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()

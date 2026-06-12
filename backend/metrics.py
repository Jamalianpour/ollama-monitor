import json
import platform
import subprocess

import psutil


def get_gpu_metrics() -> list[dict]:
    metrics = []
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu",
             "--format=csv,noheader,nounits"],
            timeout=3, stderr=subprocess.DEVNULL).decode()
        for i, line in enumerate(out.strip().splitlines()):
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 5:
                metrics.append({"index": i, "name": parts[0], "vendor": "nvidia",
                                 "utilization_pct": float(parts[1]), "memory_used_mb": float(parts[2]),
                                 "memory_total_mb": float(parts[3]), "temperature_c": float(parts[4])})
        if metrics:
            return metrics
    except Exception:
        pass
    try:
        out = subprocess.check_output(
            ["rocm-smi", "--showuse", "--showmeminfo", "vram", "--json"],
            timeout=3, stderr=subprocess.DEVNULL).decode()
        data = json.loads(out)
        for i, (key, val) in enumerate(data.items()):
            if key.startswith("card"):
                metrics.append({"index": i, "name": val.get("Card series", key), "vendor": "amd",
                                 "utilization_pct": float(val.get("GPU use (%)", 0)),
                                 "memory_used_mb": float(val.get("VRAM Total Used Memory (B)", 0)) / 1024 / 1024,
                                 "memory_total_mb": float(val.get("VRAM Total Memory (B)", 0)) / 1024 / 1024,
                                 "temperature_c": None})
        if metrics:
            return metrics
    except Exception:
        pass
    return []


def get_system_metrics() -> dict:
    cpu = psutil.cpu_percent(interval=None)
    vm = psutil.virtual_memory()
    disk = psutil.disk_usage("/") if platform.system() != "Windows" else psutil.disk_usage("C:\\")
    return {"cpu_pct": cpu, "ram_used_gb": vm.used / 1e9, "ram_total_gb": vm.total / 1e9,
            "ram_pct": vm.percent, "disk_used_gb": disk.used / 1e9, "disk_total_gb": disk.total / 1e9,
            "disk_pct": disk.percent, "gpus": get_gpu_metrics()}

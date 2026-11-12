#!/usr/bin/env python3
"""采样 macOS 进程的物理内存占用与单核口径平均 CPU。"""
import ctypes
import json
import sys
import time

names = "user_time system_time pkg_idle_wkups interrupt_wkups pageins wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated cpu_time_qos_user_interactive billed_system_time serviced_system_time logical_writes lifetime_max_phys_footprint instructions cycles billed_energy serviced_energy interval_max_phys_footprint runnable_time".split()

class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [(name, ctypes.c_uint64) for name in names]

lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
pid = int(sys.argv[1])
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 60

def sample():
    value = Usage()
    if lib.proc_pid_rusage(pid, 4, ctypes.byref(value)) != 0:
        raise OSError(ctypes.get_errno(), "无法读取目标进程的资源数据")
    return value

first = sample()
started = time.monotonic()
peak = first.phys_footprint
while time.monotonic() - started < seconds:
    time.sleep(min(1, max(0, seconds - (time.monotonic() - started))))
    last = sample()
    peak = max(peak, last.phys_footprint)
last = sample()
elapsed = time.monotonic() - started
print(json.dumps({"pid": pid, "sample_seconds": round(elapsed, 3),
    "physical_footprint_mib": round(last.phys_footprint / 1048576, 2),
    "peak_sampled_footprint_mib": round(peak / 1048576, 2),
    "resident_mib": round(last.resident_size / 1048576, 2),
    "average_cpu_percent": round(((last.user_time + last.system_time) - (first.user_time + first.system_time)) / 1e9 / elapsed * 100, 3)}, ensure_ascii=False, indent=2))

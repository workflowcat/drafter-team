"""Memory watchdog: the process kills itself when its memory footprint passes the cap (the Mac froze on 2026-10-06).

The footprint is what Activity Monitor shows (phys_footprint), which counts Metal buffers too; plain RSS does not."""
import ctypes, os, sys, threading, time

_libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")


class _RU(ctypes.Structure):  # rusage_info_v2, enough fields to reach ri_phys_footprint
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in (
        "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size", "resident_size",
        "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time", "child_system_time",
        "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins", "child_elapsed_abstime",
        "diskio_bytesread", "diskio_byteswritten")]


def footprint_gb(pid=None):
    ru = _RU()
    if _libc.proc_pid_rusage(pid or os.getpid(), 2, ctypes.byref(ru)) != 0: return 0.0
    return ru.phys_footprint / 2**30


rss_gb = footprint_gb


def usage(pid=None):
    """Page-ins so far, resident and footprint MB: a reading's delta in page-ins and the resident share before it
    tell paged-out weights (voice speed round two, 2026-11-17) from a cold GPU. {} when the call fails."""
    ru = _RU()
    if _libc.proc_pid_rusage(pid or os.getpid(), 2, ctypes.byref(ru)) != 0: return {}
    return {"pageins": int(ru.pageins), "resident": ru.resident_size >> 20, "footprint": ru.phys_footprint >> 20}


_cap = [0.0]   # the cap in force now; allow() raises it for one known heavy job


def start(cap_gb, every=0.5, hold=4, spike=0.5):
    """Exit when the footprint stays above the cap for `hold` samples (2 s), or ever passes cap + spike.
    Loading weights spikes for a moment; a leak or a runaway context does not go away."""
    _cap[0] = cap_gb
    def watch():
        over = 0
        while True:
            r, cap = footprint_gb(), _cap[0]
            over = over + 1 if r > cap else 0
            if over >= hold or r > cap + spike:
                sys.stderr.write(f"drafter guard: {r:.2f} GB > cap {cap} GB, exiting\n"); sys.stderr.flush()
                os._exit(137)
            time.sleep(every)
    threading.Thread(target=watch, daemon=True).start()


class allow:
    """A higher cap while one known job runs (the final Whisper reading of a call peaked at 2.93 GB against 2.8 and
    the guard killed it, 2026-10-29), back to the old cap after it."""
    def __init__(self, gb): self.gb = gb
    def __enter__(self): self.old = _cap[0]; _cap[0] = max(self.old, self.gb); return self
    def __exit__(self, *a): _cap[0] = self.old

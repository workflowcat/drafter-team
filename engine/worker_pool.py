"""Bookkeeping for the four Claude helper pools; callers retain their feature locks and worker transport."""
import time


def get_or_create(pool, model, worker_type, system, max_tokens):
    """Call under the feature's lock. Build the prompt only after stopping an expired worker."""
    worker = pool.get(model)
    if worker is None or not worker.alive() or worker.turns >= worker_type.MAX_TURNS:
        if worker: worker.stop()
        worker = pool[model] = worker_type(model, system(), max_tokens=max_tokens)
    worker.used = time.time()
    return worker

"""
In-memory store for attendance jobs.

An adjudicated scan is not a request/response shape. It takes as long as it
takes, it produces output the whole time it is running, and the interesting
part is the output *during* the run rather than the value at the end.

So the scan is a job: the upload returns an id immediately, the work continues
on a background thread, and the client pulls whatever has accumulated since it
last asked. Two things fall out of that which matter here:

- The client can never time out waiting for the scan. The upload returns in
  milliseconds, so a slow Gemini call (a cold start has been measured at ~126s)
  can no longer exceed the app's request timeout, because it is not inside a
  request any more.
- Reconnecting is free. A cursor is just an integer, so a client that drops mid
  scan resumes by asking again from where it stopped.

Jobs live in process memory and die with it, which is correct for what they
are: a live view of a scan that is happening right now. The attendance record
itself is written to Firestore and does not depend on any of this.
"""

import threading
import time
import uuid
from collections import OrderedDict

# Completed jobs are kept so a client can still fetch the result after the run
# finishes, but only the most recent ones — this is a live view, not history.
MAX_JOBS = 20


class AttendanceJobStore:
    def __init__(self, max_jobs: int = MAX_JOBS):
        self._jobs: OrderedDict[str, dict] = OrderedDict()
        self._lock = threading.Lock()
        self._max_jobs = max_jobs

    def create(self) -> str:
        job_id = uuid.uuid4().hex[:12]
        with self._lock:
            self._jobs[job_id] = {
                "id": job_id,
                "status": "running",
                "events": [],
                "result": None,
                "error": None,
                "created_at": time.time(),
            }
            while len(self._jobs) > self._max_jobs:
                self._jobs.popitem(last=False)
        return job_id

    def append_event(self, job_id: str, event: dict):
        """Called from the worker thread as the Adjudicator reasons."""
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            event = dict(event)
            event["seq"] = len(job["events"])
            job["events"].append(event)

    def finish(self, job_id: str, result: dict):
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            job["result"] = result
            job["status"] = "done"

    def fail(self, job_id: str, message: str):
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return
            job["error"] = message
            job["status"] = "error"

    def snapshot(self, job_id: str, since: int = 0) -> dict | None:
        """
        Everything the client has not seen yet.

        `since` is the number of events already received, so a client that has
        seen 7 asks with since=7 and gets event 7 onward. Thumbnails make events
        chunky, and re-sending them on every poll would dominate the traffic.
        """
        with self._lock:
            job = self._jobs.get(job_id)
            if job is None:
                return None
            events = job["events"][max(0, since):]
            return {
                "job_id": job["id"],
                "status": job["status"],
                "events": events,
                "cursor": len(job["events"]),
                "result": job["result"],
                "error": job["error"],
            }

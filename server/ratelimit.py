import time
import threading
from collections import defaultdict

from fastapi import HTTPException, Request, status


class RateLimiter:
    """Simple in-memory sliding-window rate limiter keyed by client IP."""

    def __init__(self, max_requests: int, window_seconds: int):
        self.max_requests = max_requests
        self.window = window_seconds
        self._hits: dict[str, list[float]] = defaultdict(list)
        self._lock = threading.Lock()

    def _cleanup(self, key: str, now: float):
        cutoff = now - self.window
        entries = self._hits[key]
        # drop expired timestamps
        while entries and entries[0] < cutoff:
            entries.pop(0)

    def check(self, request: Request):
        ip = request.client.host if request.client else "unknown"
        now = time.monotonic()

        with self._lock:
            self._cleanup(ip, now)
            if len(self._hits[ip]) >= self.max_requests:
                raise HTTPException(
                    status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                    detail="Too many requests. Try again later.",
                )
            self._hits[ip].append(now)


# 10 attempts per 60 seconds for auth endpoints
auth_limiter = RateLimiter(max_requests=10, window_seconds=60)

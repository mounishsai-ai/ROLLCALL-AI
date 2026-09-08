"""
One shared key, checked on every request.

This is deliberately the simplest thing that actually closes the door. There
are no user accounts, no sessions and no tokens to expire — there is one secret
that the app knows and nobody else does. For a single-classroom demo that is
the honest amount of security to build; anything more would be scaffolding for
users who do not exist.

**Why middleware and not a route dependency.** `app.mount("/faces", StaticFiles(...))`
attaches a whole separate application, and a `Depends(...)` on the API's routes
does not run for it. That mount serves every enrolled student's photograph. A
dependency-based check would have looked complete and left the actual
photographs of real people readable by anyone with the URL. Middleware sees
every request, mounts included.

**Why a query parameter is also accepted.** The app shows face photos with an
ordinary image request, and an `<img>` tag cannot send a custom header. So
`?key=` is honoured for exactly that. It is the same secret either way — this
buys compatibility, not a second, weaker door.
"""

import os
import secrets

from fastapi import Request
from fastapi.responses import JSONResponse

HEADER_NAME = "X-API-Key"
QUERY_NAME = "key"

# Cloud Run pings the root to decide whether the container is alive. It must
# answer before anybody has configured a key, so it stays open — it reveals
# only that a server exists.
OPEN_PATHS = {"/", "/health"}


def get_api_key() -> str | None:
    key = os.getenv("API_KEY", "").strip()
    return key or None


def describe_state() -> str:
    """One line for the startup log, so the state is never a guess."""
    if get_api_key():
        return "[OK] API key required on every request (header X-API-Key or ?key=)."
    return (
        "[WARN] API_KEY is not set — the API is OPEN. Fine on a laptop, "
        "NOT fine once this has a public URL. Set API_KEY before deploying."
    )


async def api_key_middleware(request: Request, call_next):
    """Reject anything that does not carry the shared secret."""
    expected = get_api_key()

    # No key configured: local development, everything is allowed. The startup
    # log has already said so loudly.
    if expected is None:
        return await call_next(request)

    # Browsers send an unauthenticated OPTIONS before a cross-origin request
    # and cannot attach headers to it. Blocking it breaks CORS for the real
    # request that follows, which is still checked.
    if request.method == "OPTIONS" or request.url.path in OPEN_PATHS:
        return await call_next(request)

    # Stripped on both sides. A key that has picked up a stray newline or
    # carriage return on its way through a file, a clipboard or a secret store
    # should not fail to match something that is otherwise identical — that
    # failure looks exactly like a wrong key and is miserable to diagnose.
    # (Creating the secret from a Windows text file did precisely this once.)
    supplied = (request.headers.get(HEADER_NAME) or request.query_params.get(QUERY_NAME) or "").strip()

    # Constant-time comparison: a plain `==` returns faster the earlier it
    # finds a difference, which over many attempts leaks the key one character
    # at a time.
    if not secrets.compare_digest(supplied, expected):
        return JSONResponse(
            status_code=401,
            content={
                "status": "error",
                "error": {
                    "code": "UNAUTHORIZED",
                    "message": "Missing or invalid API key.",
                    "details": f"Send it as the {HEADER_NAME} header, or ?{QUERY_NAME}= for image URLs.",
                },
            },
        )

    return await call_next(request)

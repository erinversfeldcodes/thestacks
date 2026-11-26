#!/usr/bin/env python3
"""Derive the least-privilege runtime connection URL from the owner's.

Reads `EFFECTIVE_DATABASE_URL` and `STACKS_APP_DB_PASSWORD` from the
environment and prints a URL for the `stacks_app` role on the same host, port,
database and query string. Prints NOTHING and exits 0 when the input is not a
URL it can rewrite.

⛔ DERIVED, never configured, and the reason is the failure mode. The host and
database differ per environment — every preview gets its own Neon branch — so a
fixed value in `.env` or a CI secret would point every preview at whichever
branch it was written for. That is worse than not setting it at all: the
application would start, serve, and write to the wrong database. "It works" and
"it is correct" come apart completely.

⚠️ Printing nothing on unparseable input is deliberate. The caller treats an
empty value as "do not set the secret", which leaves `config/runtime.exs`'s
documented fallback to the owner URL in place. Emitting a half-rewritten string
would point the application at nothing.

⚠️ This lives in its own file rather than a heredoc inside `deploy-stack.sh`,
where it started. Embedded in bash it could not be run directly, shellcheck
could not see past it, and its test had to EXTRACT it from the deploy script by
string markers — a test whose first job was parsing the thing it tested.

⚠️ Must run under the oldest `python3` that can reach it, which is the SYSTEM
interpreter — `deploy-stack.sh` calls bare `python3`, and on macOS that is 3.9.
The `from __future__` import below is what makes the `str | None` annotation
legal there (3.10 syntax, deferred to a string by that import). Without it this
file raises `TypeError` at import, the caller's `||` swallows it, and the
derivation silently yields nothing: the deploy warns, sets no secret, and the
stack runs as the OWNER while every grant written for the least-privilege role
sits decorative. Inert on the machines that matter and indistinguishable from
working — so the suite runs this file under bare `python3` rather than parsing
it, because `ast.parse` succeeds on exactly the version where importing fails.
"""

from __future__ import annotations

import os
import sys
from urllib.parse import quote, urlsplit, urlunsplit

APP_ROLE = "stacks_app"


def derive(url: str, password: str) -> str | None:
    """The owner URL with the role and password swapped, or None."""
    parts = urlsplit(url)

    if not parts.hostname:
        return None

    host = parts.hostname
    if parts.port:
        host = f"{host}:{parts.port}"

    # ⚠️ `safe=''` so every URL metacharacter is encoded. A password containing
    # `@`, `/`, `?` or `#` each terminates a different part of a URL, so an
    # unencoded one produces a URL that parses — into something else entirely,
    # which fails as a wrong connection rather than as an error.
    netloc = f"{APP_ROLE}:{quote(password, safe='')}@{host}"

    return urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))


def main() -> int:
    url = os.environ.get("EFFECTIVE_DATABASE_URL", "")
    password = os.environ.get("STACKS_APP_DB_PASSWORD", "")

    if not url or not password:
        return 0

    derived = derive(url, password)
    if derived:
        print(derived)

    return 0


if __name__ == "__main__":
    sys.exit(main())

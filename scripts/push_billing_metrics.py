#!/usr/bin/env python3
"""Compute month-to-date provider costs from the same inputs the providers
bill on, and push them as gauges to the self-hosted VictoriaMetrics.

Fly: whole-account machine inventory (api.machines.dev) priced at the rate
card fetched from Fly's GraphQL API, plus volumes. The scale-to-zero core
app is excluded — the app itself measures its awake time from its own
pushed metrics. Neon: the consumption API for every project, priced
against the account plan (free plan -> 0, with the allowance tracked).

Pushed series (read by the app's daily RefreshCostsJob):
    stacks_billing_mtd_cents{provider="fly",component="machines|volumes"}
    stacks_billing_mtd_cents{provider="neon",component="database"}
    stacks_billing_run_rate_cents_per_month{provider="fly"}

Requires FLY_API_TOKEN and NEON_API_KEY. The metrics store is 6PN-internal,
so the caller must expose it first (fly proxy) and pass VM_URL.
"""

import json
import os
import re
import sys
import urllib.parse
import urllib.request
from datetime import UTC, datetime

FLY_MACHINES_API = "https://api.machines.dev/v1"
FLY_GRAPHQL = "https://api.fly.io/graphql"
NEON_API = "https://console.neon.tech/api/v2"

# Fly's published add-on rates, cents per month
RAM_CENTS_PER_GB_MONTH = 500
VOLUME_CENTS_PER_GB_MONTH = 15
SHARED_1X_BASE_CENTS_FALLBACK = 194  # shared-cpu-1x @ 256MB
SHARED_1X_INCLUDED_GB = 0.25

NEON_FREE_PLAN_CU_HOURS = 191.9


def http_json(url, token, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def parse_rfc3339(value):
    # older pythons reject non-6-digit fractional seconds; drop the fraction
    value = re.sub(r"\.\d+", "", value)
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def month_window(now):
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if start.month == 12:
        end = start.replace(year=start.year + 1, month=1)
    else:
        end = start.replace(month=start.month + 1)
    return start, end


def overlap_fraction(created_at, month_start, now, month_seconds):
    """Fraction of the month a resource has existed for, up to now."""
    begin = max(created_at, month_start)
    if begin >= now:
        return 0.0
    return (now - begin).total_seconds() / month_seconds


def shared_1x_base_cents(fly_token):
    try:
        data = http_json(
            FLY_GRAPHQL,
            fly_token,
            {"query": "query { platform { vmSizes { name priceMonth } } }"},
        )
        for size in data["data"]["platform"]["vmSizes"]:
            if size["name"] == "shared-cpu-1x":
                return round(float(size["priceMonth"]) * 100)
    except Exception as exc:  # rate card fetch is best-effort
        print(f"warn: rate card fetch failed ({exc}); using fallback", file=sys.stderr)
    return SHARED_1X_BASE_CENTS_FALLBACK


def machine_monthly_cents(guest, base_cents):
    """Price a machine at Fly's model: per-CPU base + extra RAM."""
    cpus = guest.get("cpus", 1)
    mem_gb = guest.get("memory_mb", 256) / 1024
    if guest.get("cpu_kind") != "shared":
        return None  # no dedicated machines expected; skip loudly rather than misprice
    included_gb = SHARED_1X_INCLUDED_GB * cpus
    extra_gb = max(0.0, mem_gb - included_gb)
    return round(cpus * base_cents + extra_gb * RAM_CENTS_PER_GB_MONTH)


def is_core_app(name):
    # Core apps scale to zero and measure their own awake time from their
    # pushed metrics — pricing them by sampled state would be wrong in both
    # directions. Everything else runs 24/7 in practice even where autostop
    # is configured (Grafana, preview stacks), so state sampling is honest.
    return "core" in name


def fly_costs(fly_token, month_start, now, month_seconds):
    base_cents = shared_1x_base_cents(fly_token)
    apps = http_json(f"{FLY_MACHINES_API}/apps?org_slug=personal", fly_token)["apps"]

    machines_mtd = 0.0
    volumes_mtd = 0.0
    run_rate = 0
    for app in apps:
        name = app["name"]
        if is_core_app(name):
            continue
        machines = http_json(f"{FLY_MACHINES_API}/apps/{name}/machines", fly_token)
        for machine in machines:
            config = machine.get("config") or {}
            if machine.get("state") != "started":
                continue
            monthly = machine_monthly_cents(config.get("guest") or {}, base_cents)
            if monthly is None:
                print(f"warn: unpriceable machine on {name}; skipped", file=sys.stderr)
                continue
            if name.startswith("thestacks"):
                # permanent prod services run all month; deploys recreate the
                # machine and reset created_at, which would undercount them
                created = month_start
            else:
                created = parse_rfc3339(machine["created_at"])
            frac = overlap_fraction(created, month_start, now, month_seconds)
            machines_mtd += monthly * frac
            run_rate += monthly
            print(f"fly: {name} {config.get('guest')} {monthly}c/mo x {frac:.3f}")

        volumes = http_json(f"{FLY_MACHINES_API}/apps/{name}/volumes", fly_token)
        for volume in volumes:
            monthly = volume["size_gb"] * VOLUME_CENTS_PER_GB_MONTH
            frac = overlap_fraction(
                parse_rfc3339(volume["created_at"]), month_start, now, month_seconds
            )
            volumes_mtd += monthly * frac
            run_rate += monthly

    return round(machines_mtd), round(volumes_mtd), run_rate


def neon_costs(neon_key):
    """Month-to-date Neon cents across this platform's projects (consumption API)."""
    me = http_json(f"{NEON_API}/users/me", neon_key)
    plan = me.get("plan", "unknown")

    orgs = http_json(f"{NEON_API}/users/me/organizations", neon_key)["organizations"]
    projects = []
    for org in orgs:
        listing = http_json(f"{NEON_API}/projects?org_id={org['id']}", neon_key)
        projects.extend(listing["projects"])

    cu_hours = 0.0
    for project in projects:
        # the account hosts unrelated projects too; only this platform's count
        if not project["name"].startswith("thestacks"):
            print(f"neon: skipping unrelated project '{project['name']}'")
            continue
        detail = http_json(f"{NEON_API}/projects/{project['id']}", neon_key)["project"]
        cu_hours += detail.get("compute_time_seconds", 0) / 3600

    if plan == "free":
        print(f"neon: free plan, {cu_hours:.1f}/{NEON_FREE_PLAN_CU_HOURS} CU-hours")
        return 0
    print(f"warn: neon plan '{plan}' has no rate model here; not pushing", file=sys.stderr)
    return None


def push_gauges(vm_url, lines):
    body = ("\n".join(lines) + "\n").encode()
    req = urllib.request.Request(f"{vm_url}/api/v1/import/prometheus", data=body)
    with urllib.request.urlopen(req, timeout=30) as resp:
        resp.read()


def main():
    fly_token = os.environ["FLY_API_TOKEN"]
    neon_key = os.environ["NEON_API_KEY"]
    vm_url = os.environ.get("VM_URL", "http://localhost:18428").rstrip("/")

    now = datetime.now(UTC)
    month_start, month_end = month_window(now)
    month_seconds = (month_end - month_start).total_seconds()

    machines_mtd, volumes_mtd, run_rate = fly_costs(fly_token, month_start, now, month_seconds)
    neon_mtd = neon_costs(neon_key)

    lines = [
        f'stacks_billing_mtd_cents{{provider="fly",component="machines"}} {machines_mtd}',
        f'stacks_billing_mtd_cents{{provider="fly",component="volumes"}} {volumes_mtd}',
        f'stacks_billing_run_rate_cents_per_month{{provider="fly"}} {run_rate}',
    ]
    if neon_mtd is not None:
        lines.append(f'stacks_billing_mtd_cents{{provider="neon",component="database"}} {neon_mtd}')

    push_gauges(vm_url, lines)
    print(
        f"pushed: fly mtd {machines_mtd + volumes_mtd}c (run rate {run_rate}c/mo), neon {neon_mtd}c"
    )


if __name__ == "__main__":
    main()

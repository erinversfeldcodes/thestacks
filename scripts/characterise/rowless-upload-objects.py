"""Read-only characterisation of objects under `uploads/` that no database row points at.

⛔ READ-ONLY BY CONSTRUCTION. It lists and counts; it never deletes, writes or
   copies. The sweep that CAN delete this population already exists
   (`ImageRetention.cleanup_orphan_objects/1`) and must not be pointed at
   production until the decision this script informs has been made and recorded.

⚠️ It prints counts, dates, sizes and key SHAPES. It never prints a credential,
   the bucket name, or a user's identifier.

Usage (needs the R2_* vars from .env):
    set -a; source .env; set +a
    python3 -I scripts/characterise/rowless-upload-objects.py [objects.tsv]

With no argument it lists the bucket live. With a TSV (key, size, iso8601) it
re-characterises a previous listing, so the analysis is reproducible without
re-reading the bucket.
"""

import collections
import os
import re
import sys

UUID_KEY = re.compile(r"^uploads/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")


def live_listing():
    import boto3

    acct = os.environ["R2_ACCOUNT_ID"]
    s3 = boto3.client(
        "s3",
        endpoint_url=f"https://{acct}.r2.cloudflarestorage.com",
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        region_name="auto",
    )
    out = []
    for page in s3.get_paginator("list_objects_v2").paginate(
        Bucket=os.environ["R2_BUCKET_NAME"], Prefix="uploads/"
    ):
        for o in page.get("Contents", []):
            out.append((o["Key"], o["Size"], o["LastModified"].isoformat()))
    return out


def main():
    if len(sys.argv) > 1:
        with open(sys.argv[1]) as fh:
            rows = [(k, int(s), t) for k, s, t in (line.rstrip("\n").split("\t") for line in fh)]
    else:
        rows = live_listing()

    print(f"objects under uploads/: {len(rows)}\n")

    print("-- LastModified by month " + "-" * 40)
    by_month = collections.Counter(t[:7] for _, _, t in rows)
    for m in sorted(by_month):
        print(f"   {m}   {by_month[m]:>6}")

    # ⛔ THE DECISIVE MEASURE. A population of readers' photographs has roughly
    # as many distinct sizes as objects. A population of test fixtures has a
    # handful, repeated. Which it is decides whether this is a reportable
    # exposure or development residue, so it is measured rather than assumed.
    print("\n-- distinct sizes " + "-" * 47)
    sizes = collections.Counter(s for _, s, _ in rows)
    print(f"   distinct sizes: {len(sizes)} across {len(rows)} objects")
    covered = 0
    for s, n in sizes.most_common(8):
        covered += n
        print(f"   {s:>9} bytes  x{n:>5}  ({100 * n / len(rows):5.1f}%)")
    print(f"   top 8 cover {100 * covered / len(rows):.1f}% of all objects")
    print(f"   sizes occurring EXACTLY ONCE: {sum(1 for n in sizes.values() if n == 1)}")
    print("   -> an upper bound on how many objects can be unique photographs")

    print("\n-- key shapes " + "-" * 51)
    odd = [k for k, _, _ in rows if not UUID_KEY.match(k)]
    print(f"   keys that are not uploads/<uuid>: {len(odd)}")
    for k in odd:
        print(f"      {k}")
    print("   -> a non-uuid key was never reserved by init_upload/2, so it")
    print("      cannot have had a row at any point")

    print(f"\n   zero-byte objects: {sum(1 for _, s, _ in rows if s == 0)}")

    print("\n-- 2-hex-prefix buckets " + "-" * 41)
    print("   Compare against the database's own per-prefix counts:")
    print("     select substr(storage_path,9,2) p, count(*) from op.uploaded_images group by 1;")
    print("   Summing max(0, objects-rows) over prefixes is an exact LOWER BOUND")
    print("   on row-less objects; summing max(0, rows-objects) counts rows")
    print("   pointing at objects that are already gone.")
    buckets = collections.Counter(k[8:10] for k, _, _ in rows if k.startswith("uploads/"))
    print("   " + ",".join(f"{p}:{n}" for p, n in sorted(buckets.items())))


if __name__ == "__main__":
    main()

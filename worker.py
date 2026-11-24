import io
import json
import os
import sys
from collections import Counter
from pathlib import Path

from pipeline import map_reduce

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data/full.jsonl"
REFERENCE = json.loads((ROOT / "data/reference.json").read_text())
BUCKET = "hw5-skills"
PARTS = 4


def count(lines):
    counts, _ = map_reduce((json.loads(line) for line in lines), 250, 1)
    return Counter({pair: n for pair, n in counts.items() if len(pair) == 2})


def parts():
    lines = DATA.read_bytes().splitlines(keepends=True)
    return [lines[i*len(lines)//PARTS:(i+1)*len(lines)//PARTS] for i in range(PARTS)]


def verify(counts):
    result = [{"size": 2, "skills": list(pair), "frequency": n}
              for pair, n in sorted(counts.items(), key=lambda item: (-item[1], item[0]))[:10]]
    if result != REFERENCE:
        raise ValueError(result)
    print(json.dumps(result, ensure_ascii=False))


def run(mode):
    if mode == "single":
        with DATA.open("rb") as stream:
            verify(count(stream))
        peak = Path("/sys/fs/cgroup/memory.peak")
        if peak.exists():
            print("peak_bytes", peak.read_text().strip())
        return
    if mode == "local":
        totals = Counter()
        for chunk in parts():
            totals.update(count(chunk))
        verify(totals)
        return
    import boto3
    s3 = boto3.client("s3", endpoint_url="http://rustfs:9000", region_name="us-east-1")
    if mode == "seed":
        if BUCKET not in [b["Name"] for b in s3.list_buckets()["Buckets"]]:
            s3.create_bucket(Bucket=BUCKET)
        for i, lines in enumerate(parts()):
            s3.put_object(Bucket=BUCKET, Key=f"input/{i}", Body=b"".join(lines))
    elif mode == "map":
        i = int(os.environ["JOB_COMPLETION_INDEX"])
        body = s3.get_object(Bucket=BUCKET, Key=f"input/{i}")["Body"]
        with io.BytesIO(body.read()) as stream:
            rows = [[*pair, n] for pair, n in count(stream).items()]
        s3.put_object(Bucket=BUCKET, Key=f"counts/{i}", Body=json.dumps(rows).encode())
        print("part", i, "distinct_pairs", len(rows))
    elif mode == "reduce":
        totals = Counter()
        for i in range(PARTS):
            rows = json.loads(s3.get_object(Bucket=BUCKET, Key=f"counts/{i}")["Body"].read())
            totals.update({(a,b): n for a,b,n in rows})
        verify(totals)
    else:
        raise ValueError(mode)


if __name__ == "__main__":
    run(sys.argv[1])

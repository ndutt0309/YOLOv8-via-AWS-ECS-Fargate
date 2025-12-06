import os, json, time, uuid, math, random, argparse, logging
from statistics import mean
import requests
from dotenv import load_dotenv

load_dotenv()
API_BASE_URL = os.getenv("API_BASE_URL")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("sim")

def pct(values, p):
    if not values: return 0.0
    arr = sorted(values)
    k = max(0, int(math.ceil(p/100 * len(arr))) - 1)
    return arr[k]

def load_manifest(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)

def send_once(api_url, item, timeout=30, max_retries=2):
    """POST request to the /predict_json endpoint"""
    payload = {
        "req_id": str(uuid.uuid4()),
        "image_id": item["image_id"],
        "coco_url": item["coco_url"]
    }
    attempt = 0
    while True:
        t0 = time.time()
        try:
            r = requests.post(f"{api_url}/predict_json", json=payload, timeout=timeout)
            latency_ms = (time.time() - t0) * 1000.0
            status = r.status_code

            detections = []
            try:
                body = r.json()
                detections = body.get("detections", [])
            except:
                detections = []

            if status in (429,) or status >= 500:
                if attempt < max_retries:
                    time.sleep(2 ** attempt)
                    attempt += 1
                    continue

            return {
                "req_id": payload["req_id"],
                "image_id": item["image_id"],
                "status": status,
                "latency_ms": round(latency_ms, 2),
                "coco_url": item["coco_url"],
                "detections": detections
            }
        except Exception as e:
            if attempt < max_retries:
                time.sleep(2 ** attempt)
                attempt += 1
                continue
            return {
                "req_id": payload["req_id"],
                "image_id": item["image_id"],
                "status": 0,
                "error": str(e),
                "detections": []
            }

def run(manifest_path, api_base_url, mode, limit, interval_override, show_classes):
    if not api_base_url:
        raise SystemExit("API_BASE_URL must be set in .env")

    manifest = load_manifest(manifest_path)
    if limit:
        manifest = manifest[:limit]

    log.info(f"Base URL: {api_base_url} | Mode={mode} | Count={len(manifest)}")
    results = []

    for i, item in enumerate(manifest, 1):
        res = send_once(api_base_url, item)
        results.append(res)

        log.info(f"[{i}/{len(manifest)}] {res['status']} | {res['latency_ms']:.1f} ms | {item['image_id']}")

        if mode == "burst":
            delay = random.uniform(0.02, 0.12)
        elif mode == "sustained":
            delay = random.uniform(0.2, 0.5)
        elif mode == "quiet":
            delay = random.uniform(2.0, 6.0)
        else:
            delay = 1.0

        log.info(f"Delay: {delay} seconds")
        time.sleep(delay)

    # save NDJSON log
    with open("request_log.ndjson", "w", encoding="utf-8") as f:
        for r in results:
            f.write(json.dumps(r) + "\n")

    # Summary
    ok = [r["latency_ms"] for r in results if 200 <= r["status"] < 300]
    if ok:
        log.info("=== SUMMARY ===")
        log.info(f"Total: {len(results)}, Success: {len(ok)}")
        log.info(f"p50={pct(ok,50):.1f}ms | p95={pct(ok,95):.1f}ms | p99={pct(ok,99):.1f}ms | mean={mean(ok):.1f}ms")

    # CLASS SUMMARY
    if show_classes:
        class_counts = {}
        for r in results:
            for d in r.get("detections", []):
                cname = d.get("class_name", "unknown")
                class_counts[cname] = class_counts.get(cname, 0) + 1

        log.info("=== CLASS COUNTS ===")
        for cname, cnt in sorted(class_counts.items(), key=lambda x: -x[1]):
            log.info(f"{cname}: {cnt}")

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="./validate_json/coco_val_manifest.json")
    ap.add_argument("--mode", choices=["quiet","sustained","burst"], default="sustained")
    ap.add_argument("--limit", type=int, default=100)
    ap.add_argument("--interval", type=float, default=None)
    ap.add_argument("--show_classes", action="store_true")  # ← FIXED
    args = ap.parse_args()

    run(
        manifest_path=args.manifest,
        api_base_url=API_BASE_URL,
        mode=args.mode,
        limit=args.limit,
        interval_override=args.interval,
        show_classes=args.show_classes
    )
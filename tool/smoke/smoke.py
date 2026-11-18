#!/usr/bin/env python3
"""InkMux 冒烟脚本（M0）：直连两家中转站验证生图 API 行为，结论回填 presets。

用法（PowerShell，当前终端会话注入 AK，绝不写入文件）：
    $env:INKMUX_SW_KEY = "sk-..."     # 神稳AI 生图 Key
    $env:INKMUX_A6_KEY = "sk-..."     # A6API Key
    python tool/smoke/smoke.py --provider sw --case models
    python tool/smoke/smoke.py --provider sw --case generate --prompt "一只橘猫"
    python tool/smoke/smoke.py --provider sw --case edit --image D:/ref.png
    python tool/smoke/smoke.py --provider a6 --case async --prompt "一只橘猫"
    python tool/smoke/smoke.py --provider a6 --case poll --task-id <id>

纯标准库实现；输出与 App 内调试日志同规则脱敏（Authorization 掩码、
base64 字段截前 64 字符）。
"""

import argparse
import json
import mimetypes
import os
import random
import sys
import time
import urllib.error
import urllib.request
import uuid

PROVIDERS = {
    "sw": {
        "name": "神稳AI",
        "base": "https://api.shenwenai.com/v1",
        "env": "INKMUX_SW_KEY",
    },
    "a6": {
        "name": "A6API",
        "base": "https://media.a6api.net/v1",
        "env": "INKMUX_A6_KEY",
    },
}

MEDIA_KEYS = {"b64_json", "image", "images", "mask", "image_b64", "thumbnail"}


# ---------- 脱敏输出（与 App LogSanitizer 同规则） ----------

def mask_headers(headers):
    out = {}
    for k, v in headers.items():
        if k.lower() in ("authorization", "x-api-key", "cookie"):
            tail = v[-4:] if len(v) >= 4 else ""
            head = "Bearer " if v.lower().startswith("bearer") else ""
            out[k] = f"{head}**** {tail}"
        else:
            out[k] = v
    return out


def sanitize(node, key=None):
    if isinstance(node, dict):
        return {k: sanitize(v, k) for k, v in node.items()}
    if isinstance(node, list):
        return [sanitize(v, key) for v in node]
    if isinstance(node, str):
        is_media = key is not None and key.lower() in MEDIA_KEYS
        looks_b64 = len(node) >= 256 and all(
            c.isalnum() or c in "+/=" for c in node[:256]
        )
        if (is_media or looks_b64) and len(node) > 64:
            return f"{node[:64]}…[base64 截断，原 {len(node)} 字符]"
        return node
    return node


def pretty(data):
    try:
        return json.dumps(sanitize(data), ensure_ascii=False, indent=2)
    except Exception:
        return str(data)


# ---------- HTTP ----------

class Http:
    def __init__(self, base, key, timeout_connect=15):
        self.base = base.rstrip("/")
        self.key = key
        self.timeout_connect = timeout_connect

    def request(self, method, path, body=None, headers=None, timeout=60,
                raw_body=None, content_type=None, quiet=False):
        url = f"{self.base}{path}"
        hdrs = {"Authorization": f"Bearer {self.key}"}
        if content_type:
            hdrs["Content-Type"] = content_type
        hdrs.update(headers or {})
        data = None
        if raw_body is not None:
            data = raw_body
        elif body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            hdrs.setdefault("Content-Type", "application/json")
        req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
        if not quiet:
            print(f"→ {method} {url}")
            for k, v in mask_headers(hdrs).items():
                print(f"   {k}: {v}")
            if body is not None:
                print("   body:", json.dumps(sanitize(body), ensure_ascii=False)[:2000])
        t0 = time.time()
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                cost = (time.time() - t0) * 1000
                text = resp.read().decode("utf-8", errors="replace")
                if not quiet:
                    print(f"← {resp.status} {cost:.0f}ms")
                try:
                    parsed = json.loads(text)
                except Exception:
                    parsed = text[:4000]
                if not quiet:
                    print(pretty(parsed)[:6000])
                return resp.status, dict(resp.headers), parsed
        except urllib.error.HTTPError as e:
            cost = (time.time() - t0) * 1000
            text = e.read().decode("utf-8", errors="replace")
            print(f"← HTTP {e.code} {cost:.0f}ms")
            try:
                parsed = json.loads(text)
            except Exception:
                parsed = text[:4000]
            print(pretty(parsed)[:6000])
            return e.code, dict(e.headers), parsed
        except Exception as e:  # noqa: BLE001
            print(f"← 网络异常: {type(e).__name__}: {e}")
            return None, {}, {"error": str(e)}


# ---------- multipart（stdlib 手搓） ----------

def multipart(fields, files):
    """fields: {name: value}; files: [(name, filepath)] → (bytes, content_type)"""
    boundary = f"----inkmux-{uuid.uuid4().hex}"
    buf = bytearray()
    for name, value in fields.items():
        buf += (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
            f"{value}\r\n"
        ).encode("utf-8")
    for name, path in files:
        filename = os.path.basename(path)
        mime = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        with open(path, "rb") as f:
            content = f.read()
        buf += (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'
            f"Content-Type: {mime}\r\n\r\n"
        ).encode("utf-8")
        buf += content + b"\r\n"
        print(f"   [file] {name}={filename} ({len(content)} bytes, {mime})")
    buf += f"--{boundary}--\r\n".encode("utf-8")
    return bytes(buf), f"multipart/form-data; boundary={boundary}"


# ---------- 用例 ----------

def case_models(http, args):
    status, headers, body = http.request("GET", "/models", timeout=30)
    if status == 200 and isinstance(body, dict):
        data = body.get("data") or []
        ids = [m.get("id") for m in data if isinstance(m, dict)]
        print(f"\n共 {len(ids)} 个模型 ID；前 10 个: {ids[:10]}")
        img = [m.get("id") for m in data
               if isinstance(m, dict)
               and any(e == "image-generation"
                       for e in (m.get("supported_endpoint_types") or []))]
        print(f"supported_endpoint_types 含 image-generation 的: {len(img)} 个 → {img[:10]}")


def case_generate(http, args):
    body = {
        "model": args.model or "gpt-image-2",
        "prompt": args.prompt,
        "n": args.n,
        "size": args.size or "1024x1024",
        "response_format": args.format,
    }
    idem = uuid.uuid4().hex
    print(f"(Idempotency-Key: {idem})")
    status, _, _ = http.request(
        "POST", "/images/generations", body=body,
        headers={"Idempotency-Key": idem},
        timeout=15 * 60,
    )
    print(f"\n[结论] 同步生图 HTTP {status}（计费请求，产出与通道见上方响应）")


def case_edit(http, args):
    if not args.image:
        sys.exit("--case edit 需要 --image 路径（可多次出现）")
    fields = {
        "model": args.model or "gpt-image-2",
        "prompt": args.prompt,
        "size": args.size or "1024x1024",
    }
    files = [("image[]", p) for p in args.image]
    raw, ctype = multipart(fields, files)
    idem = uuid.uuid4().hex
    print(f"(Idempotency-Key: {idem})")
    status, _, _ = http.request(
        "POST", "/images/edits", raw_body=raw, content_type=ctype,
        headers={"Idempotency-Key": idem},
        timeout=15 * 60,
    )
    print(f"\n[结论] 同步编辑 HTTP {status}")


def case_error(http, args):
    body = {"model": "no-such-model", "prompt": "x", "n": 1}
    http.request("POST", "/images/generations", body=body, timeout=60)


def case_a6_async(http, args):
    body = {
        "model": args.model or "gpt-image-1",
        "prompt": args.prompt,
        "n": args.n,
        "size": args.size or "1024x1024",
    }
    status, headers, resp = http.request(
        "POST", "/images/generations/async", body=body, timeout=60,
    )
    task_id = resp.get("task_id") if isinstance(resp, dict) else None
    if status != 202 or not task_id:
        print("\n[结论] 异步提交失败（若 404 image_task_disabled → 站点未开异步存储）")
        return
    print(f"\n[结论] 已受理 task_id={task_id} expires_at={resp.get('expires_at')}")
    print(f"轮询: python tool/smoke/smoke.py --provider a6 --case poll --task-id {task_id}")
    if args.poll:
        _poll(http, task_id, args.timeout)


def case_a6_poll(http, args):
    if not args.task_id:
        sys.exit("--case poll 需要 --task-id")
    _poll(http, args.task_id, args.timeout)


def _poll(http, task_id, timeout_s):
    interval = 3.0
    deadline = time.time() + (timeout_s or 1800)
    while time.time() < deadline:
        time.sleep(interval * random.uniform(0.8, 1.2))
        status, headers, body = http.request(
            "GET", f"/images/tasks/{task_id}", quiet=True,
        )
        state = body.get("status") if isinstance(body, dict) else None
        print(f"[poll] {time.strftime('%H:%M:%S')} status={state}")
        if state == "completed":
            print(pretty(body))
            data = ((body.get("result") or {}).get("data")) or []
            print(f"\n[结论] 完成：{len(data)} 张图，url 有效期默认 24h，应立即下载：")
            for i, item in enumerate(data):
                print(f"  [{i}] {item.get('mime_type')}: {item.get('url')}")
            return
        if state == "failed":
            print(pretty(body))
            print(f"\n[结论] 失败 http_status={body.get('http_status')} error={body.get('error')}")
            return
        retry_after = headers.get("Retry-After")
        base = float(retry_after) if retry_after else interval
        interval = min(max(base, interval) * 1.8, 15.0)
    print("[结论] 轮询超时退出")


def case_a6_sync(http, args):
    body = {
        "model": args.model or "gpt-image-1",
        "prompt": args.prompt,
        "n": args.n,
        "size": args.size or "1024x1024",
    }
    status, _, _ = http.request(
        "POST", "/images/generations", body=body, timeout=15 * 60,
    )
    print(f"\n[结论] a6api 同步生图 HTTP {status}")


def main():
    ap = argparse.ArgumentParser(description="InkMux 冒烟脚本")
    ap.add_argument("--provider", choices=list(PROVIDERS), required=True)
    ap.add_argument("--case", required=True,
                    choices=["models", "generate", "edit", "error",
                             "async", "poll", "sync"])
    ap.add_argument("--prompt", default="一只戴黄色雨衣的橘猫站在雨后的城市街角，电影感灯光")
    ap.add_argument("--model", default=None)
    ap.add_argument("--size", default=None)
    ap.add_argument("--n", type=int, default=1)
    ap.add_argument("--format", default="url", choices=["url", "b64_json"])
    ap.add_argument("--image", action="append", help="编辑参考图路径，可多次")
    ap.add_argument("--task-id", default=None)
    ap.add_argument("--timeout", type=int, default=None, help="轮询总时长秒")
    ap.add_argument("--poll", action="store_true", help="async 提交后立即轮询")
    args = ap.parse_args()

    conf = PROVIDERS[args.provider]
    key = os.environ.get(conf["env"], "").strip()
    if not key:
        sys.exit(f"缺少环境变量 {conf['env']}（PowerShell: $env:{conf['env']} = 'sk-...'）")

    print(f"=== {conf['name']} · {args.case} · {time.strftime('%Y-%m-%d %H:%M:%S')} ===\n")
    http = Http(conf["base"], key)

    handler = {
        "models": case_models,
        "generate": case_generate,
        "edit": case_edit,
        "error": case_error,
        "async": case_a6_async,
        "poll": case_a6_poll,
        "sync": case_a6_sync,
    }[args.case]
    handler(http, args)


if __name__ == "__main__":
    main()

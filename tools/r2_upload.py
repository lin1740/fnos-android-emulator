# -*- coding: utf-8 -*-
"""Cloudflare R2 读写工具（基于 curl --aws-sigv4，无需 boto3）。

用法：
    python r2_upload.py test                       # 传一个 1KB 测试对象并读回校验
    python r2_upload.py put <本地文件> <对象名>      # 上传（自动算 md5 作为元数据）
    python r2_upload.py head <对象名>               # 查看远端对象大小与 ETag
    python r2_upload.py speed <对象名> [字节数]      # 从 R2 拉一段测速

凭据文件（与本脚本同目录的 r2_credentials.txt）：
    ACCOUNT_ID=...
    BUCKET=androidemu
    ACCESS_KEY=...
    SECRET_KEY=...
    PUBLIC_BASE=https://pub-xxxxxxxx.r2.dev   # 可选，仅用于打印公开地址

安全约定：本脚本不打印 ACCESS_KEY / SECRET_KEY 的明文。
"""
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CRED = os.path.join(HERE, "r2_credentials.txt")


def load_cred():
    """优先读凭据文件，其次读环境变量（供 CI/定时任务使用，避免把密钥写进仓库）。"""
    d = {}
    if os.path.exists(CRED):
        for line in open(CRED, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    for k in ("ACCOUNT_ID", "BUCKET", "ACCESS_KEY", "SECRET_KEY", "PUBLIC_BASE"):
        env = os.environ.get("R2_" + k)
        if env and not d.get(k):
            d[k] = env
    for k in ("ACCOUNT_ID", "BUCKET", "ACCESS_KEY", "SECRET_KEY"):
        if not d.get(k):
            sys.exit("缺少 %s（凭据文件或 R2_%s 环境变量）" % (k, k))
    return d


def endpoint(c):
    return "https://%s.r2.cloudflarestorage.com" % c["ACCOUNT_ID"]


def curl(args, timeout=3600):
    """统一走 curl，SigV4 由 curl 自己算；密钥通过 -u 传入但不出现在输出里。"""
    c = load_cred()
    cmd = [
        "curl", "-sS", "--max-time", str(timeout),
        "--aws-sigv4", "aws:amz:auto:s3",
        "--user", "%s:%s" % (c["ACCESS_KEY"], c["SECRET_KEY"]),
    ] + args
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def md5_file(p):
    h = hashlib.md5()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def cmd_test():
    c = load_cred()
    url = "%s/%s/houdini/_healthcheck.txt" % (endpoint(c), c["BUCKET"])
    body = b"androidemu r2 healthcheck\n"
    rc, out, err = curl(["-X", "PUT", "-H", "Content-Type: text/plain",
                         "--data-binary", body.decode().strip(), url], timeout=60)
    if rc != 0:
        print("上传失败 rc=%d" % rc)
        print(err[:400])
        return 1
    rc2, out2, err2 = curl([url], timeout=60)
    if rc2 == 0 and out2.strip() == body.decode().strip():
        print("OK：读写权限正常，对象可读回，内容一致")
        print("对象地址：%s/%s/houdini/_healthcheck.txt" % (endpoint(c), c["BUCKET"]))
        return 0
    print("读回失败或内容不一致 rc=%d" % rc2)
    print((err2 or out2)[:400])
    return 1


def cmd_put(local, key):
    c = load_cred()
    if not os.path.isfile(local):
        sys.exit("本地文件不存在：%s" % local)
    size = os.path.getsize(local)
    m = md5_file(local)
    print("本地：%s  大小 %.1f MB  md5=%s" % (os.path.basename(local), size / 1048576, m))
    url = "%s/%s/%s" % (endpoint(c), c["BUCKET"], key)
    print("上传中（大文件较久，请耐心等）…")
    rc, out, err = curl(["-X", "PUT",
                         "-H", "x-amz-meta-md5: %s" % m,
                         "-H", "Content-Type: application/octet-stream",
                         "--data-binary", "@" + local, url], timeout=3600)
    if rc != 0:
        print("上传失败 rc=%d" % rc)
        print(err[:600])
        return 1
    print("上传完成，校验远端…")
    rc2, out2, err2 = curl(["-I", url], timeout=120)
    head = (out2 or "") + (err2 or "")
    etag = ""
    for line in head.splitlines():
        if line.lower().startswith("etag:"):
            etag = line.split(":", 1)[1].strip().strip('"')
    print("远端 ETag：%s" % (etag or "(未读到)"))
    if etag and etag.lower() == m.lower():
        print("校验通过：远端 ETag 与本地 md5 一致")
    else:
        print("提示：ETag 与 md5 不一致（R2 分片上传时 ETag 不是 md5，属正常现象，可再用 head 看大小）")
    base = c.get("PUBLIC_BASE", "").rstrip("/")
    if base:
        print("公开地址：%s/%s" % (base, key))
    return 0


def cmd_head(key):
    c = load_cred()
    url = "%s/%s/%s" % (endpoint(c), c["BUCKET"], key)
    rc, out, err = curl(["-I", url], timeout=120)
    head = (out or "") + (err or "")
    if rc != 0:
        print("查询失败 rc=%d" % rc)
        print(head[:400])
        return 1
    for line in head.splitlines():
        low = line.lower()
        if low.startswith(("http/", "content-length", "etag", "last-modified", "content-type")):
            print("  " + line.strip())
    return 0


def cmd_speed(key, nbytes=8388608):
    c = load_cred()
    url = "%s/%s/%s" % (endpoint(c), c["BUCKET"], key)
    rc, out, err = curl(["-o", os.devnull, "-w", "%{http_code} %{speed_download} %{size_download}",
                         "-r", "0-%d" % (nbytes - 1), url], timeout=120)
    if rc != 0:
        print("测速失败 rc=%d" % rc)
        print(err[:400])
        return 1
    parts = out.split()
    if len(parts) >= 3:
        code, spd, got = parts[0], float(parts[1]), float(parts[2])
        print("HTTP=%s  速度=%.0f KB/s  实收=%.1f MB" % (code, spd / 1024, got / 1048576))
    else:
        print("输出异常：%r" % out[:200])
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    a = sys.argv[1]
    if a == "test":
        return cmd_test()
    if a == "put" and len(sys.argv) >= 4:
        return cmd_put(sys.argv[2], sys.argv[3])
    if a == "head" and len(sys.argv) >= 3:
        return cmd_head(sys.argv[2])
    if a == "speed" and len(sys.argv) >= 3:
        n = int(sys.argv[3]) if len(sys.argv) >= 4 else 8388608
        return cmd_speed(sys.argv[2], n)
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())

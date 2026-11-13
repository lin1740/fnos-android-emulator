# -*- coding: utf-8 -*-
"""把 houdini ARM 库集同步到 Cloudflare R2（只在上游有变化时才重传）。

判断依据不是下载下来算 md5，而是 GitHub 分支的最新 commit sha：
    上游 hpe 分支最新 sha  !=  R2 上 houdini/UPSTREAM_SHA.txt 记录的 sha
才算"过时"，否则一次网络往返就结束，不会每月白下 97MB。

用法：
    python sync_r2_houdini.py --check      # 只比对，不下载不上传
    python sync_r2_houdini.py              # 有变化则下载 + 上传 + 记录新 sha

退出码：0=已是最新或同步成功；1=出错。
"""
import os
import ssl
import subprocess
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import r2_upload as r2  # noqa: E402

REPO = "supremegamers/vendor_intel_proprietary_houdini"
BRANCH = "hpe"
KEY_TAR = "houdini/hpe.tar.gz"
KEY_SHA = "houdini/UPSTREAM_SHA.txt"
LOCAL_CACHE = os.path.join(HERE, "_houdini_upstream.tar.gz")
CTX = ssl._create_unverified_context()


def api(path, token=None, raw=False):
    url = "https://api.github.com" + path
    req = urllib.request.Request(url, headers={
        "User-Agent": "androidemu-r2-sync",
        "Accept": "application/vnd.github+json",
    })
    if token:
        req.add_header("Authorization", "token " + token)
    with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
        data = r.read()
        return data if raw else __import__("json").loads(data)


def github_token():
    """优先环境变量（CI 用），其次复用仓库里已有的 token 以避免匿名限流。"""
    import re
    env = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if env:
        return env
    p = os.path.join(HERE, "gh_push_readme_391.py")
    if not os.path.exists(p):
        return None
    m = re.search(r"ghp_[A-Za-z0-9]{20,}", open(p, encoding="utf-8", errors="ignore").read())
    return m.group(0) if m else None


def upstream_sha():
    d = api("/repos/%s/commits/%s" % (REPO, BRANCH), token=github_token())
    return d["sha"], d["commit"]["committer"]["date"]


def remote_sha():
    c = r2.load_cred()
    url = "%s/%s/%s" % (r2.endpoint(c), c["BUCKET"], KEY_SHA)
    rc, out, err = r2.curl([url], timeout=60)
    if rc != 0:
        return None
    return out.strip() or None


def put_text(key, text):
    c = r2.load_cred()
    url = "%s/%s/%s" % (r2.endpoint(c), c["BUCKET"], key)
    rc, out, err = r2.curl(["-X", "PUT", "-H", "Content-Type: text/plain; charset=utf-8",
                            "--data-binary", text, url], timeout=60)
    if rc != 0:
        print("写入 %s 失败：%s" % (key, err[:300]))
        return False
    return True


def download(dest):
    """下载上游整包。codeload 动态打包不支持 Range，只能整下。"""
    urls = [
        "https://gh-proxy.com/https://codeload.github.com/%s/tar.gz/refs/heads/%s" % (REPO, BRANCH),
        "https://codeload.github.com/%s/tar.gz/refs/heads/%s" % (REPO, BRANCH),
    ]
    for u in urls:
        print("下载：%s" % u)
        r = subprocess.run(["curl", "-L", "--retry", "2", "--retry-delay", "5",
                            "-m", "3600", "--progress-bar", "-o", dest, u])
        if r.returncode == 0 and os.path.getsize(dest) > 10 * 1024 * 1024:
            with open(dest, "rb") as f:
                if f.read(2) == b"\x1f\x8b":
                    print("下载完成：%.1f MB" % (os.path.getsize(dest) / 1048576))
                    return True
        print("该源失败，换下一个")
    return False


def main():
    check_only = "--check" in sys.argv
    up, when = upstream_sha()
    cur = remote_sha()
    print("上游 %s@%s 最新提交：%s（%s）" % (REPO, BRANCH, up[:12], when))
    print("R2 上记录：%s" % (cur[:12] if cur else "(无，首次同步)"))

    if cur == up:
        print("已是最新，无需上传。")
        return 0
    if check_only:
        print("检测到差异（--check 模式，未下载/未上传）。")
        return 0

    tmpdir = tempfile.mkdtemp(prefix="houdini_sync_")
    dest = os.path.join(tmpdir, "hpe.tar.gz")
    if not download(dest):
        print("两个源都下载失败，本次放弃（R2 上的旧包保持可用）。")
        return 1

    rc = r2.cmd_put(dest, KEY_TAR)
    try:
        os.remove(dest)
        os.rmdir(tmpdir)
    except OSError:
        pass
    if rc != 0:
        return 1
    if put_text(KEY_SHA, up + "\n"):
        print("已记录上游 sha：%s" % up[:12])
    print("同步完成。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

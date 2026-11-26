#!/usr/bin/env python3
"""造书脊快照用的四份配置，并导入到指定根目录。

用法：
    python3 scripts/spine-fixtures.py [根目录，默认 /tmp/spine-fixture]

产出：<根>/profiles/*.json（四份），<根>/in/*.yaml（原始输入，留作对照）。
四份配置刻意覆盖书脊的四种状态：健康、无策略组、有悬空引用与空组、超过 30 天未更新。
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

# 根目录只收显式给定的一个路径，且拒绝带 `..` 的写法：这个脚本会先整目录清空再写入，
# 调用者手滑把根指到仓库或家目录时，宁可拒跑也不能删错地方。
_raw_root = sys.argv[1] if len(sys.argv) > 1 else "/tmp/spine-fixture"
if ".." in pathlib.PurePath(_raw_root).parts:
    raise SystemExit("拒绝包含 .. 的根目录：%s" % _raw_root)
ROOT = os.path.realpath(_raw_root)
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CLI = os.path.join(REPO, ".build", "debug", "leapin")


def proxy(name, server, port=443):
    return ("  - name: %s\n    type: ss\n    server: %s\n    port: %d\n"
            "    cipher: aes-256-gcm\n    password: \"x\"\n" % (name, server, port))


def rules_block(rules):
    return "rules:\n" + "".join("  - %s\n" % r for r in rules)


def company():
    rules = ["DOMAIN-SUFFIX,corp.example.com,公司出口", "DOMAIN-SUFFIX,gitlab.example.com,公司出口",
             "DOMAIN-SUFFIX,jira.example.com,公司出口", "DOMAIN-SUFFIX,confluence.example.com,公司出口",
             "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve", "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
             "DOMAIN-SUFFIX,apple.com,DIRECT", "DOMAIN-SUFFIX,icloud.com,DIRECT",
             "DOMAIN-KEYWORD,tracker,REJECT", "GEOIP,CN,DIRECT", "MATCH,公司出口"]
    return ("mixed-port: 7890\nmode: rule\ndns:\n  nameserver:\n"
            "    - https://1.1.1.1/dns-query\n    - tls://1.0.0.1\n"
            + "proxies:\n" + proxy("Office-HK", "10.1.2.3", 8443) + proxy("Office-SG", "10.1.2.4", 8443)
            + "proxy-groups:\n  - name: 公司出口\n    type: select\n    proxies:\n"
              "      - Office-HK\n      - Office-SG\n"
            + rules_block(rules))


def home():
    rules = ["DOMAIN-SUFFIX,svc%02d.home.arpa,DIRECT" % i for i in range(28)] + [
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve", "IP-CIDR,10.10.0.0/16,DIRECT,no-resolve",
        "DOMAIN-SUFFIX,plex.tv,DIRECT", "DOMAIN-SUFFIX,tautulli.local,DIRECT",
        "DOMAIN-KEYWORD,ads,REJECT", "MATCH,DIRECT"]
    return ("mixed-port: 7891\nmode: rule\n"
            + "proxies:\n" + proxy("Home-NAS", "192.168.1.10", 9000)
            + rules_block(rules))


def airport():
    rules = ["DOMAIN-SUFFIX,cdn%03d.example.net,Proxy" % i for i in range(300)] + [
        "DOMAIN-KEYWORD,netflix,Streaming", "GEOIP,CN,DIRECT", "MATCH,Proxy"]
    return ("mixed-port: 7892\nmode: rule\ndns:\n  nameserver:\n"
            "    - 223.5.5.5\n    - 119.29.29.29\n"
            + "proxies:\n" + "".join(proxy("HK-%02d" % (i + 1), "203.0.113.%d" % (i + 1)) for i in range(9))
            + "proxy-groups:\n  - name: Proxy\n    type: url-test\n    proxies:\n"
            + "".join("      - HK-%02d\n" % (i + 1) for i in range(9))
            + "  - name: Fallback\n    type: fallback\n    proxies:\n"
            + rules_block(rules))


def stale():
    rules = ["DOMAIN-SUFFIX,example.org,DIRECT", "DOMAIN-SUFFIX,example.net,DIRECT",
             "DOMAIN-SUFFIX,old-mirror.example,DIRECT",
             "IP-CIDR,203.0.113.0/24,DIRECT,no-resolve", "MATCH,DIRECT"]
    return "mixed-port: 7893\nmode: rule\n" + rules_block(rules)


def main():
    if not os.path.exists(CLI):
        raise SystemExit("先构建 CLI：swift build --product leapin（缺 %s）" % CLI)
    shutil.rmtree(ROOT, ignore_errors=True)
    os.makedirs(os.path.join(ROOT, "in"), exist_ok=True)
    files = {"公司直连.yaml": company(), "家庭网络.yaml": home(),
             "机场主订阅.yaml": airport(), "旧配置备份.yaml": stale()}
    for name, text in files.items():
        with open(os.path.join(ROOT, "in", name), "w", encoding="utf-8") as f:
            f.write(text)

    env = dict(os.environ, LEAPIN_PROFILE_ROOT=ROOT)
    for name in files:
        path = os.path.join(ROOT, "in", name)
        out = subprocess.run([CLI, "import", path], env=env, capture_output=True, text=True)
        if out.returncode != 0:
            raise SystemExit("导入失败 %s: %s" % (name, out.stderr.strip()))
        print(out.stdout.splitlines()[0])

    # 让「更新」体检项落到 warn：把旧配置的 mtime 推到 40 天前。
    old = time.time() - 40 * 86400
    profiles = os.path.join(ROOT, "profiles")
    for entry in os.listdir(profiles):
        path = os.path.join(profiles, entry)
        with open(path, encoding="utf-8") as f:
            if json.load(f).get("name") == "旧配置备份":
                os.utime(path, (old, old))
                print("已把「旧配置备份」改成 40 天前更新")
    print("fixture 就绪：%s" % ROOT)


if __name__ == "__main__":
    main()

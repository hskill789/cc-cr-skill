#!/usr/bin/env python3
"""
静态飞书卡片发送脚本（schema 2.0）
用法：
  python3 send_feishu_card.py \
    --title "项目 | Release CR !205" \
    --color blue \
    --body-file /tmp/cr_report.md \
    --recipients-json '["ou_xxx","oc_xxx"]' \
    --app-id APP_ID \
    --app-secret SECRET \
    --domain https://open.feishu.cn
"""

import argparse
import json
import sys
import urllib.request
import urllib.error


def get_receive_id_type(rid: str) -> str:
    if rid.startswith("ou_"):
        return "open_id"
    if rid.startswith("oc_"):
        return "chat_id"
    raise ValueError(f"不支持的 receive_id 前缀: {rid}")


def get_token(domain: str, app_id: str, app_secret: str) -> str:
    url = f"{domain}/open-apis/auth/v3/tenant_access_token/internal"
    payload = json.dumps({"app_id": app_id, "app_secret": app_secret}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
    if data.get("code") != 0:
        raise RuntimeError(f"获取飞书 token 失败: {data}")
    return data["tenant_access_token"]


def build_card(title: str, color: str, body: str) -> dict:
    # 按段落边界切分，避免在表格/代码块中间截断
    CHUNK = 2000
    elements = []
    paragraphs = body.split("\n\n")
    current = []
    current_len = 0
    for para in paragraphs:
        seg = para + "\n\n"
        # 单个段落超长时按行再切
        if len(seg) > CHUNK:
            if current:
                elements.append({"tag": "markdown", "content": "".join(current).rstrip()})
                current, current_len = [], 0
            for line in para.splitlines(keepends=True):
                if current_len + len(line) > CHUNK and current:
                    elements.append({"tag": "markdown", "content": "".join(current).rstrip()})
                    current, current_len = [], 0
                current.append(line)
                current_len += len(line)
            current.append("\n\n")
            current_len += 2
        elif current_len + len(seg) > CHUNK and current:
            elements.append({"tag": "markdown", "content": "".join(current).rstrip()})
            current, current_len = [seg], len(seg)
        else:
            current.append(seg)
            current_len += len(seg)
    if current:
        elements.append({"tag": "markdown", "content": "".join(current).rstrip()})
    return {
        "schema": "2.0",
        "header": {
            "title": {"tag": "plain_text", "content": title},
            "template": color
        },
        "body": {"elements": elements}
    }


def send_card(domain: str, token: str, rid: str, card: dict) -> None:
    rid_type = get_receive_id_type(rid)
    url = f"{domain}/open-apis/im/v1/messages?receive_id_type={rid_type}"
    payload = json.dumps({
        "receive_id": rid,
        "msg_type": "interactive",
        "content": json.dumps(card, ensure_ascii=False)
    }).encode()
    req = urllib.request.Request(url, data=payload, headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}"
    })
    with urllib.request.urlopen(req, timeout=15) as resp:
        data = json.loads(resp.read())
    if data.get("code") != 0:
        raise RuntimeError(f"发送失败 (rid={rid}): {data}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--title", required=True)
    parser.add_argument("--color", default="blue", choices=["blue", "yellow", "red", "green"])
    parser.add_argument("--body", default="")
    parser.add_argument("--body-file", default="")
    parser.add_argument("--recipients-json", required=True)
    parser.add_argument("--app-id", required=True)
    parser.add_argument("--app-secret", required=True)
    parser.add_argument("--domain", default="https://open.feishu.cn")
    args = parser.parse_args()

    if args.body_file:
        with open(args.body_file, "r", encoding="utf-8") as f:
            body = f.read()
    else:
        body = args.body

    if not body.strip():
        print("[send_feishu_card] 警告：正文为空", file=sys.stderr)

    recipients = json.loads(args.recipients_json)
    token = get_token(args.domain, args.app_id, args.app_secret)
    card = build_card(args.title, args.color, body)

    errors = []
    for rid in recipients:
        try:
            send_card(args.domain, token, rid, card)
            print(f"[send_feishu_card] 已发送 → {rid}")
        except Exception as e:
            print(f"[send_feishu_card] 发送失败 → {rid}: {e}", file=sys.stderr)
            errors.append(rid)

    if errors:
        sys.exit(1)


if __name__ == "__main__":
    main()

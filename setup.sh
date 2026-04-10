#!/bin/bash
# setup.sh - cc-cr 配置向导
# 用法：bash setup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cr_config.json"
EXAMPLE_FILE="${SCRIPT_DIR}/cr_config.json.example"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; }
prompt()  { echo -e "${YELLOW}[?]${NC} $*"; }

echo ""
echo "╔══════════════════════════════════════╗"
echo "║      cc-cr 配置向导                  ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ── 1. 检查依赖 ────────────────────────────────────────────────────────────────
echo "── 检查依赖 ──"
MISSING=()
for cmd in jq curl python3 perl git; do
  if command -v "$cmd" &>/dev/null; then
    info "$cmd 已安装 ($(command -v "$cmd"))"
  else
    error "$cmd 未找到"
    MISSING+=("$cmd")
  fi
done

if command -v claude &>/dev/null; then
  info "claude CLI 已安装 ($(command -v claude))"
else
  error "claude CLI 未找到"
  MISSING+=("claude")
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo ""
  warn "缺少以下依赖：${MISSING[*]}"
  warn "安装建议："
  for dep in "${MISSING[@]}"; do
    case "$dep" in
      jq)     warn "  jq:     brew install jq" ;;
      curl)   warn "  curl:   brew install curl" ;;
      python3) warn "  python3: brew install python3" ;;
      perl)   warn "  perl:   macOS 自带，或 brew install perl" ;;
      git)    warn "  git:    brew install git" ;;
      claude) warn "  claude: https://claude.ai/download" ;;
    esac
  done
  echo ""
  read -r -p "仍然继续配置？[y/N] " cont
  [[ "$cont" =~ ^[Yy]$ ]] || exit 1
fi

echo ""
echo "── 配置文件 ──"

# ── 2. 已有配置文件则询问是否覆盖 ─────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
  warn "已存在配置文件：$CONFIG_FILE"
  read -r -p "是否重新配置？[y/N] " overwrite
  if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
    info "保留现有配置，退出。"
    exit 0
  fi
fi

cp "$EXAMPLE_FILE" "$CONFIG_FILE"

# ── 3. GitLab 配置 ─────────────────────────────────────────────────────────────
echo ""
echo "── GitLab 配置 ──"
prompt "GitLab 实例地址（如 https://gitlab.example.com）："
read -r gitlab_url
[[ -n "$gitlab_url" ]] && jq --arg v "$gitlab_url" '.gitlab_base_url = $v' "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"

prompt "GitLab Personal Access Token（留空则从环境变量 GITLAB_TOKEN 读取）："
read -r -s gitlab_token
echo ""
if [[ -n "$gitlab_token" ]]; then
  jq --arg v "$gitlab_token" '.gitlab_token = $v' "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"
  warn "Token 已写入配置文件。建议改用环境变量：export GITLAB_TOKEN=<token>"
else
  info "将从环境变量 GITLAB_TOKEN 读取"
fi

prompt "本地代码库根目录（如 /Users/yourname/projects）："
read -r local_base
[[ -n "$local_base" ]] && jq --arg v "$local_base" '.local_base_path = $v' "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"

prompt "全局 release 分支名（默认 release）："
read -r release_branch
if [[ -n "$release_branch" ]]; then
  jq --arg v "$release_branch" '.release_branch = $v' "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"
fi

# ── 4. 飞书配置 ────────────────────────────────────────────────────────────────
echo ""
echo "── 飞书配置（选填，不填则跳过推送）──"
prompt "飞书应用 App ID（如 cli_xxxxxxxxx，留空跳过）："
read -r feishu_app_id
if [[ -n "$feishu_app_id" ]]; then
  jq --arg v "$feishu_app_id" '.feishu_app_id = $v' "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"

  prompt "飞书应用 App Secret："
  read -r -s feishu_app_secret
  echo ""
  [[ -n "$feishu_app_secret" ]] && jq --arg v "$feishu_app_secret" '.feishu_app_secret = $v' "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"

  prompt "飞书推送接收人 ID（ou_xxx=个人，oc_xxx=群，多个用逗号分隔）："
  read -r recipients_raw
  if [[ -n "$recipients_raw" ]]; then
    IFS=',' read -ra recipients_arr <<< "$recipients_raw"
    recipients_json=$(printf '%s\n' "${recipients_arr[@]}" | jq -R . | jq -s .)
    jq --argjson v "$recipients_json" '.feishu_recipients = $v' "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"
  fi
else
  info "跳过飞书配置"
fi

# ── 5. 添加项目 ────────────────────────────────────────────────────────────────
echo ""
echo "── 添加监控项目 ──"
jq '.projects = []' "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"

while true; do
  prompt "GitLab 项目路径（如 group/project-name，留空结束）："
  read -r project_path
  [[ -z "$project_path" ]] && break

  prompt "检测模式（mr=合并请求 / tag=版本标签，默认 mr）："
  read -r mode
  mode="${mode:-mr}"

  jq --arg p "$project_path" --arg m "$mode" \
    '.projects += [{"gitlab_project_path": $p, "mode": $m}]' \
    "$CONFIG_FILE" > /tmp/cc_cr_tmp.json && mv /tmp/cc_cr_tmp.json "$CONFIG_FILE"
  info "已添加：$project_path ($mode)"
done

# ── 6. 完成 ────────────────────────────────────────────────────────────────────
echo ""
info "配置完成！配置文件：$CONFIG_FILE"
echo ""
echo "下一步："
echo "  1. 运行一次检测：bash ${SCRIPT_DIR}/cr_monitor.sh"
echo "  2. 在 Claude Code 中说：cr自动检测"
echo ""

PROJECT_COUNT=$(jq '.projects | length' "$CONFIG_FILE")
info "共配置 ${PROJECT_COUNT} 个项目"

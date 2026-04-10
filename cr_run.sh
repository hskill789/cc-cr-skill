#!/bin/bash
# cr_run.sh - 统一 CR 执行器（被 cr_monitor.sh 和交互式 SKILL.md 共用）
#
# 用法（MR 模式）：
#   cr_run.sh --mode mr \
#             --project-path tmc/isavana/hisavana-traffic-dispatch \
#             --iid 96 \
#             [--release-branch release]
#
# 用法（Tag 模式）：
#   cr_run.sh --mode tag \
#             --project-path tmc/strategy/ad-server/eagllwin-adserver \
#             --old-tag v1.0.0 \
#             --new-tag v1.1.0 \
#             [--tag-created-at "2026-04-09 18:00:00"]
#
# 成功后输出一行（供调用方解析）：
#   CR_REPORT_READY:/path/to/report.md
#
# 退出码：0 成功，1 失败

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cr_config.json"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
CACHE_DIR="${SCRIPT_DIR}/cache"
LOG_DIR="${SCRIPT_DIR}/logs"
TMP_DIR="${SCRIPT_DIR}/tmp"
mkdir -p "$CACHE_DIR" "$LOG_DIR" "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# ── 参数解析 ───────────────────────────────────────────────────────────────────
MODE=""
PROJECT_PATH=""
IID=""
OLD_TAG=""
NEW_TAG=""
TAG_CREATED_AT=""
RELEASE_BRANCH=""
NO_FEISHU=false
FEISHU_TARGET="personal"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)           MODE="$2";           shift 2 ;;
    --project-path)   PROJECT_PATH="$2";   shift 2 ;;
    --iid)            IID="$2";            shift 2 ;;
    --old-tag)        OLD_TAG="$2";        shift 2 ;;
    --new-tag)        NEW_TAG="$2";        shift 2 ;;
    --tag-created-at) TAG_CREATED_AT="$2"; shift 2 ;;
    --release-branch) RELEASE_BRANCH="$2"; shift 2 ;;
    --no-feishu)      NO_FEISHU=true;      shift ;;
    --feishu-target)  FEISHU_TARGET="$2";  shift 2 ;;
    *) echo "[cr_run] 未知参数: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$CLAUDE_BIN" ]]; then
  echo "[cr_run] 缺少 claude CLI，请安装后重试：https://claude.ai/download" >&2
  exit 1
fi

if [[ -z "$MODE" || -z "$PROJECT_PATH" ]]; then
  echo "[cr_run] 缺少必填参数: --mode 和 --project-path" >&2
  exit 1
fi

if [[ "$MODE" == "mr" && -z "$IID" ]]; then
  echo "[cr_run] MR 模式必须提供 --iid" >&2
  exit 1
fi

if [[ "$MODE" == "tag" && (-z "$OLD_TAG" || -z "$NEW_TAG") ]]; then
  echo "[cr_run] Tag 模式必须提供 --old-tag 和 --new-tag" >&2
  exit 1
fi

# ── 读取配置 ───────────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[cr_run] 配置文件不存在: $CONFIG_FILE" >&2
  exit 1
fi

GITLAB_BASE=$(jq -r '.gitlab_base_url' "$CONFIG_FILE")
LOCAL_BASE_PATH=$(jq -r '.local_base_path' "$CONFIG_FILE")
REPORT_DIR="${LOCAL_BASE_PATH}/cr-reports"
# 根据 --feishu-target 按 ID 前缀过滤推送目标（ou_=个人，oc_=群）
if [[ "$FEISHU_TARGET" == "group" ]]; then
  RECIPIENTS_JSON=$(jq -r '[.feishu_recipients[] | select(startswith("oc_"))] | tojson' "$CONFIG_FILE")
else
  RECIPIENTS_JSON=$(jq -r '[.feishu_recipients[] | select(startswith("ou_"))] | tojson' "$CONFIG_FILE")
fi
GLOBAL_RELEASE_BRANCH=$(jq -r '.release_branch // "release"' "$CONFIG_FILE")
mkdir -p "$REPORT_DIR"

# RELEASE_BRANCH 优先命令行参数，降级配置文件全局值
[[ -z "$RELEASE_BRANCH" ]] && RELEASE_BRANCH="$GLOBAL_RELEASE_BRANCH"

# ── GitLab Token ───────────────────────────────────────────────────────────────
_CONFIG_TOKEN=$(jq -r '.gitlab_token // ""' "$CONFIG_FILE")
GITLAB_TOKEN="${GITLAB_TOKEN:-${_CONFIG_TOKEN:-${CTI_GITLAB_TOKEN:-}}}"

# ── 飞书凭证 ───────────────────────────────────────────────────────────────────
# 优先级：环境变量 > cr_config.json > ~/.claude-to-im/config.env
CTI_FEISHU_APP_ID="${CTI_FEISHU_APP_ID:-$(jq -r '.feishu_app_id // ""' "$CONFIG_FILE")}"
CTI_FEISHU_APP_SECRET="${CTI_FEISHU_APP_SECRET:-$(jq -r '.feishu_app_secret // ""' "$CONFIG_FILE")}"
CTI_FEISHU_DOMAIN="${CTI_FEISHU_DOMAIN:-$(jq -r '.feishu_domain // ""' "$CONFIG_FILE")}"
CTI_FEISHU_DOMAIN="${CTI_FEISHU_DOMAIN:-https://open.feishu.cn}"
CTI_CONFIG="$HOME/.claude-to-im/config.env"
if [[ -f "$CTI_CONFIG" && (-z "$CTI_FEISHU_APP_ID" || -z "$CTI_FEISHU_APP_SECRET") ]]; then
  _tmp_env=$(mktemp)
  grep -E "^CTI_FEISHU_(APP_ID|APP_SECRET|DOMAIN)=" "$CTI_CONFIG" > "$_tmp_env"
  source "$_tmp_env"
  rm -f "$_tmp_env"
fi
export CTI_FEISHU_APP_ID CTI_FEISHU_APP_SECRET CTI_FEISHU_DOMAIN GITLAB_TOKEN

# ── 派生变量 ───────────────────────────────────────────────────────────────────
PROJECT_NAME=$(basename "$PROJECT_PATH")
ENCODED_PATH="${PROJECT_PATH//\//%2F}"
LOCAL_PATH="${LOCAL_BASE_PATH}/${PROJECT_NAME}"
PROJECT_NAME_UNDERSCORED=$(echo "$PROJECT_NAME" | tr '-' '_')
CR_REPORT_STRUCTURE=$(cat "${SCRIPT_DIR}/cr_report_format.md")

case "$MODE" in
  tag)
    # 若只指定了 NEW_TAG，自动查找前一个 tag 作为 OLD_TAG
    if [[ -z "$OLD_TAG" && -n "$NEW_TAG" ]]; then
      _tags_json=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_BASE}/api/v4/projects/${ENCODED_PATH}/repository/tags?per_page=10")
      # 写临时文件再解析，避免 here-doc 引号问题
      _tags_tmp=$(mktemp "${TMP_DIR}/tags_XXXXXX")
      echo "$_tags_json" > "$_tags_tmp"
      OLD_TAG=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
new_tag = sys.argv[2]
tags = [t['name'] for t in data]
idx = next((i for i,n in enumerate(tags) if n == new_tag), None)
print(tags[idx+1] if idx is not None and idx+1 < len(tags) else '')
" "$_tags_tmp" "${NEW_TAG}")
      if [[ -n "$_tags_json" && -z "$TAG_CREATED_AT" ]]; then
        TAG_CREATED_AT=$(python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
with open(sys.argv[1]) as f:
    data = json.load(f)
new_tag = sys.argv[2]
t = next((t for t in data if t['name'] == new_tag), None)
s = t['commit']['created_at'] if t else ''
try:
    dt = datetime.fromisoformat(s.replace('Z', '+00:00'))
    print(dt.astimezone(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S'))
except:
    print(s)
" "$_tags_tmp" "${NEW_TAG}")
      fi
      rm -f "$_tags_tmp"
    fi
    # 若 NEW_TAG 也为空，取最新两个 tag
    if [[ -z "$NEW_TAG" ]]; then
      _tags_json=$(curl -s -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
        "${GITLAB_BASE}/api/v4/projects/${ENCODED_PATH}/repository/tags?per_page=2")
      _tags_tmp=$(mktemp "${TMP_DIR}/tags_XXXXXX")
      echo "$_tags_json" > "$_tags_tmp"
      NEW_TAG=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d[0]['name'])" "$_tags_tmp")
      OLD_TAG=$(python3 -c "import json, sys; d=json.load(open(sys.argv[1])); print(d[1]['name'])" "$_tags_tmp")
      TAG_CREATED_AT=$(python3 -c "
import json, sys
from datetime import datetime, timezone, timedelta
d=json.load(open(sys.argv[1]))
s=d[0]['commit']['created_at']
try:
    dt=datetime.fromisoformat(s.replace('Z','+00:00'))
    print(dt.astimezone(timezone(timedelta(hours=8))).strftime('%Y-%m-%d %H:%M:%S'))
except: print(s)
" "$_tags_tmp")
      rm -f "$_tags_tmp"
    fi
    REPORT_FILE="${REPORT_DIR}/cr_report_${PROJECT_NAME}_${NEW_TAG}.md"
    CARD_TITLE="${PROJECT_NAME} | Release CR ${OLD_TAG}→${NEW_TAG}"
    CACHE_FILE="${CACHE_DIR}/${PROJECT_NAME_UNDERSCORED}_last_cr_tag"
    CACHE_VALUE="$NEW_TAG"
    ;;
  mr)
    REPORT_FILE="${REPORT_DIR}/cr_report_${PROJECT_NAME}_mr${IID}.md"
    CARD_TITLE="${PROJECT_NAME} | Release CR !${IID}"
    CACHE_FILE="${CACHE_DIR}/${PROJECT_NAME_UNDERSCORED}_last_cr_mr_iid"
    CACHE_VALUE="$IID"
    ;;
esac

LOG_FILE="${LOG_DIR}/cr_${PROJECT_NAME}.log"
SESSION_LOG="${LOG_DIR}/cr_session_$(date +%Y%m%d_%H%M%S)_${PROJECT_NAME}.log"
rm -f "$REPORT_FILE"

# 写 stdout + session log
log()     { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$SESSION_LOG"; }
log_err() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$SESSION_LOG" >&2; }

# ── 构造 Prompt ────────────────────────────────────────────────────────────────
if [[ "$MODE" == "tag" ]]; then
  _created_at_line=""
  [[ -n "$TAG_CREATED_AT" ]] && _created_at_line="- tag 创建时间：${TAG_CREATED_AT}（北京时间）"

  PROMPT=$(cat <<PROMPT
对 ${PROJECT_NAME} 执行 Release CR。全程自动完成，不需要用户确认。

**Step 1：Read CLAUDE.md**

Read \`${LOCAL_PATH}/CLAUDE.md\`，记住其中的 CR 关注点、已知技术债务、流程链路信息。

**Step 2：对比范围（已由外部确定，直接使用）**

- old_tag = \`${OLD_TAG}\`
- new_tag = \`${NEW_TAG}\`
${_created_at_line}

**Step 3：获取 diff + 读取本地文件**

运行 \`GITLAB_TOKEN=\${GITLAB_TOKEN:-\$CTI_GITLAB_TOKEN} curl -s -H "PRIVATE-TOKEN: \$GITLAB_TOKEN" "${GITLAB_BASE}/api/v4/projects/${ENCODED_PATH}/repository/compare?from=${OLD_TAG}&to=${NEW_TAG}"\` 获取 diff。对每个变更文件 Read 本地 \`${LOCAL_PATH}/<file_path>\`。对新增或修改的 public 方法 grep 搜索调用方。在 \`${LOCAL_PATH}\` 目录下运行 \`git log ${OLD_TAG}..${NEW_TAG} --numstat --pretty="%h %an %s"\` 获取提交信息（每个 commit 带行数统计）。按 author_name 分组 commits，累计每个作者的总增删行数。

**Step 4：执行 CR**

GitLab 链接：\`${GITLAB_BASE}/${PROJECT_PATH}/-/tags\`

基于 CLAUDE.md 指南、完整 diff、本地文件上下文、grep 调用方分析：

${CR_REPORT_STRUCTURE}

**Step 5：输出 CR 报告到文件**

将上面 Step 4 完整输出的 CR 报告（所有章节，不省略）写入文件 \`${REPORT_FILE}\`。

完成后输出一行：\`CR_REPORT_READY:${REPORT_FILE}\`
PROMPT
)
else
  PROMPT=$(cat <<PROMPT
对 ${PROJECT_NAME} 执行 Release CR。全程自动完成，不需要用户确认。

**Step 1：Read CLAUDE.md**

Read \`${LOCAL_PATH}/CLAUDE.md\`，记住其中的架构信息、技术栈、关注点。

**Step 2：已知最新 merged MR**

Shell 预检已获取：new_mr_iid = ${IID}，跳过 API 查询，直接进入 Step 3。

**Step 3：获取 MR 详情 + diff**

并行运行：\`GITLAB_TOKEN=\${GITLAB_TOKEN:-\$CTI_GITLAB_TOKEN}\`
- \`curl -s -H "PRIVATE-TOKEN: \$GITLAB_TOKEN" "${GITLAB_BASE}/api/v4/projects/${ENCODED_PATH}/merge_requests/${IID}"\`
- \`curl -s -H "PRIVATE-TOKEN: \$GITLAB_TOKEN" "${GITLAB_BASE}/api/v4/projects/${ENCODED_PATH}/merge_requests/${IID}/changes"\`
- \`curl -s -H "PRIVATE-TOKEN: \$GITLAB_TOKEN" "${GITLAB_BASE}/api/v4/projects/${ENCODED_PATH}/merge_requests/${IID}/commits?with_stats=true"\`

提取 title、author、source_branch、target_branch、diff_refs（base_sha、head_sha）、变更文件列表、created_at（MR 创建时间）、merged_at（MR 合并时间）。按 author_name 分组 commits，累计 stats.additions 和 stats.deletions。

**Step 4：读取本地文件 + grep 调用方**

对每个变更文件 Read 本地 \`${LOCAL_PATH}/<file_path>\`。若 diff 被截断，用 \`git diff \{base_sha\}..\{head_sha\} -- <file_path>\` 获取完整 diff（在 \`${LOCAL_PATH}\` 目录下执行）。对新增或修改的 public 函数/方法 grep 搜索调用方。

**Step 5：执行 CR**

GitLab 链接：\`${GITLAB_BASE}/${PROJECT_PATH}/-/merge_requests?scope=all&state=merged&target_branch=${RELEASE_BRANCH}\`

基于 CLAUDE.md 指南、完整 diff、本地文件上下文、grep 调用方分析：

${CR_REPORT_STRUCTURE}

**Step 6：输出 CR 报告到文件**

将上面 Step 5 完整输出的 CR 报告（所有章节，不省略）写入文件 \`${REPORT_FILE}\`。

完成后输出一行：\`CR_REPORT_READY:${REPORT_FILE}\`
PROMPT
)
fi

# ── 调用 Claude ────────────────────────────────────────────────────────────────
log "[cr_run] 开始 CR: ${PROJECT_NAME} (mode=${MODE})"
"$CLAUDE_BIN" -p "$PROMPT" \
  --dangerously-skip-permissions \
  --output-format text \
  >> "$LOG_FILE" 2>&1

# ── 发送飞书卡片 ───────────────────────────────────────────────────────────────
if [[ ! -f "$REPORT_FILE" ]]; then
  log_err "[cr_run] 未找到报告文件 ${REPORT_FILE}"
  exit 1
fi

if [[ "$NO_FEISHU" == "true" ]]; then
  log "[cr_run] 跳过飞书推送（交互式模式）: ${PROJECT_NAME}"
else
  python3 "${SCRIPT_DIR}/send_feishu_card.py" \
    --title "$CARD_TITLE" \
    --color blue \
    --body-file "$REPORT_FILE" \
    --recipients-json "$RECIPIENTS_JSON" \
    --app-id "$CTI_FEISHU_APP_ID" \
    --app-secret "$CTI_FEISHU_APP_SECRET" \
    --domain "$CTI_FEISHU_DOMAIN" \
    >> "$LOG_FILE" 2>&1 \
    && log "[cr_run] 飞书卡片已发送: ${PROJECT_NAME}" \
    || { log_err "[cr_run] 飞书卡片发送失败，见 ${LOG_FILE}"; exit 1; }
fi

# ── 更新 cache ─────────────────────────────────────────────────────────────────
echo -n "$CACHE_VALUE" > "$CACHE_FILE"
log "[cr_run] cache 已更新: ${CACHE_FILE} = ${CACHE_VALUE}"

# ── 通知调用方报告路径 ─────────────────────────────────────────────────────────
echo "CR_REPORT_READY:${REPORT_FILE}"

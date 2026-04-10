#!/bin/bash
# cr_monitor.sh - 通用 CR 监测脚本（已重构）
# Usage: cr_monitor.sh [--feishu-target personal|group]
#
# 架构：
#   tag/mr 模式 → Shell 层预检版本号，有变化才调用 Claude；Shell 负责 cache 更新

set -euo pipefail

# ── 参数解析 ──────────────────────────────────────────────────────────────────
FEISHU_TARGET="personal"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feishu-target) FEISHU_TARGET="$2"; shift 2 ;;
    *) echo "[cr_monitor] 未知参数: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cr_config.json"
CACHE_DIR="${SCRIPT_DIR}/cache"
LOG_DIR="${SCRIPT_DIR}/logs"
TMP_DIR="${SCRIPT_DIR}/tmp"
mkdir -p "$CACHE_DIR" "$LOG_DIR" "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

RUN_LOG="${LOG_DIR}/cr_monitor_$(date '+%Y%m%d_%H%M%S').log"
exec > >(perl -ne 'use POSIX qw(strftime); print strftime("[%Y-%m-%d %H:%M:%S] ", localtime), $_; $|=1' | tee -a "$RUN_LOG") 2>&1
echo "[cr_monitor] 运行日志: $RUN_LOG"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "[cr_monitor] 配置文件不存在: $CONFIG_FILE" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "[cr_monitor] 缺少 jq，请先安装: brew install jq" >&2
  exit 1
fi

GITLAB_BASE=$(jq -r '.gitlab_base_url' "$CONFIG_FILE")
# 根据 --feishu-target 按 ID 前缀过滤推送目标（ou_=个人，oc_=群）
if [[ "$FEISHU_TARGET" == "group" ]]; then
  RECIPIENTS_JSON=$(jq -r '[.feishu_recipients[] | select(startswith("oc_"))] | tojson' "$CONFIG_FILE")
else
  RECIPIENTS_JSON=$(jq -r '[.feishu_recipients[] | select(startswith("ou_"))] | tojson' "$CONFIG_FILE")
fi
PROJECT_COUNT=$(jq '.projects | length' "$CONFIG_FILE")

# 兼容 notify_no_change 为 boolean 或 {hourly, daily} 对象两种写法
NOTIFY_NO_CHANGE=$(jq -r 'if .notify_no_change == null then "true" else .notify_no_change end' "$CONFIG_FILE")

# GitLab token（优先环境变量，降级到配置文件，再降级到 CTI_GITLAB_TOKEN）
_CONFIG_TOKEN=$(jq -r '.gitlab_token // ""' "$CONFIG_FILE")
GITLAB_TOKEN="${GITLAB_TOKEN:-${_CONFIG_TOKEN:-${CTI_GITLAB_TOKEN:-}}}"

# 飞书认证：优先环境变量 > cr_config.json > ~/.claude-to-im/config.env
CTI_FEISHU_APP_ID="${CTI_FEISHU_APP_ID:-$(jq -r '.feishu_app_id // ""' "$CONFIG_FILE")}"
CTI_FEISHU_APP_SECRET="${CTI_FEISHU_APP_SECRET:-$(jq -r '.feishu_app_secret // ""' "$CONFIG_FILE")}"
CTI_FEISHU_DOMAIN="${CTI_FEISHU_DOMAIN:-$(jq -r '.feishu_domain // ""' "$CONFIG_FILE")}"
CTI_FEISHU_DOMAIN="${CTI_FEISHU_DOMAIN:-https://open.feishu.cn}"
CTI_CONFIG="$HOME/.claude-to-im/config.env"
if [[ -f "$CTI_CONFIG" && (-z "$CTI_FEISHU_APP_ID" || -z "$CTI_FEISHU_APP_SECRET") ]]; then
  # source <(...) 在 macOS bash 3.2 下不可靠，改用临时文件
  _tmp_env=$(mktemp "${TMP_DIR}/env_XXXXXX")
  grep -E "^CTI_FEISHU_(APP_ID|APP_SECRET|DOMAIN)=" "$CTI_CONFIG" > "$_tmp_env"
  # shellcheck source=/dev/null
  source "$_tmp_env"
  rm -f "$_tmp_env"
fi
# 导出给子进程（claude）
export CTI_FEISHU_APP_ID CTI_FEISHU_APP_SECRET CTI_FEISHU_DOMAIN

# ─── Shell 层版本预检（tag/mr 模式专用）─────────────────────────────────────

# 返回最新 tag 名，失败或无 tag 返回空串
fetch_latest_tag() {
  local encoded_path="$1"
  curl -sf --max-time 15 -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_BASE}/api/v4/projects/${encoded_path}/repository/tags?per_page=1" \
    2>/dev/null | jq -r 'if type == "array" and length > 0 then .[0].name else "" end' \
    2>/dev/null || echo ""
}

# 返回最新 tag 的创建时间（北京时间），失败返回空串
fetch_latest_tag_created_at() {
  local encoded_path="$1"
  local iso
  iso=$(curl -sf --max-time 15 -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_BASE}/api/v4/projects/${encoded_path}/repository/tags?per_page=1" \
    2>/dev/null | jq -r 'if type == "array" and length > 0 then (.[0].commit.created_at // "") else "" end' \
    2>/dev/null) || true
  [[ -z "$iso" ]] && echo "" && return
  python3 -c "
from datetime import datetime, timezone, timedelta
import sys
s = '$iso'
try:
    dt = datetime.fromisoformat(s.replace('Z','+00:00'))
    bj = dt.astimezone(timezone(timedelta(hours=8)))
    print(bj.strftime('%Y-%m-%d %H:%M:%S'))
except Exception:
    print(s)
"
}

# 返回最新 merged MR 的 iid（字符串），失败或无 MR 返回空串
fetch_latest_mr_iid() {
  local encoded_path="$1"
  local release_branch="$2"
  curl -sf --max-time 15 -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_BASE}/api/v4/projects/${encoded_path}/merge_requests?state=merged&target_branch=${release_branch}&per_page=1" \
    2>/dev/null | jq -r 'if type == "array" and length > 0 then .[0].iid | tostring else "" end' \
    2>/dev/null || echo ""
}

# ─── 无变化通知（直接 shell 调用静态脚本，不走 Claude）─────────────────────────
# 参数：name mode(tag|mr) version project_gitlab_path release_branch
send_no_change_notify() {
  local name="$1"
  local mode="$2"
  local version="$3"
  local project_gitlab_path="$4"
  local release_branch="$5"

  local version_desc link_line
  if [[ "$mode" == "tag" ]]; then
    version_desc="tag：${version}"
    link_line="Tags：[查看所有版本](${GITLAB_BASE}/${project_gitlab_path}/-/tags)"
  else
    version_desc="MR：!${version}"
    link_line="MR 列表：[查看所有 Release MR](${GITLAB_BASE}/${project_gitlab_path}/-/merge_requests?scope=all&state=merged&target_branch=${release_branch})"
  fi

  local body="目前版本没有变化，无需 CR。当前最新${version_desc}。${link_line}"

  python3 "${SCRIPT_DIR}/send_feishu_card.py" \
    --title "${name} | Release CR 检查" \
    --color yellow \
    --body "${body}" \
    --recipients-json "${RECIPIENTS_JSON}" \
    --app-id "${CTI_FEISHU_APP_ID}" \
    --app-secret "${CTI_FEISHU_APP_SECRET}" \
    --domain "${CTI_FEISHU_DOMAIN}"
}


# ─── 主流程：并行预检 → 汇总 → 串行 CR ────────────────────────────────────────
echo "[cr_monitor] 开始检测，共 ${PROJECT_COUNT} 个项目"
echo "[cr_monitor] 无变化通知: ${NOTIFY_NO_CHANGE}"

GLOBAL_RELEASE_BRANCH=$(jq -r '.release_branch // "release"' "$CONFIG_FILE")

# ── Phase 1：并行预检所有项目 ────────────────────────────────────────────────
PRECHECK_DIR=$(mktemp -d "${TMP_DIR}/precheck_XXXXXX")

pids=()
for i in $(seq 0 $((PROJECT_COUNT - 1))); do
  (
    PROJECT_PATH=$(jq -r ".projects[$i].gitlab_project_path" "$CONFIG_FILE")
    PROJECT_NAME=$(basename "$PROJECT_PATH")
    MODE=$(jq -r ".projects[$i].mode" "$CONFIG_FILE")
    RELEASE_BRANCH=$(jq -r --arg g "$GLOBAL_RELEASE_BRANCH" \
      ".projects[$i].release_branch // \$g" "$CONFIG_FILE")
    PROJECT_NOTIFY=$(jq -r --arg g "$NOTIFY_NO_CHANGE" \
      ".projects[$i].notify_no_change | if . == null then \$g else . end" "$CONFIG_FILE")
    ENCODED_PATH="${PROJECT_PATH//\//%2F}"
    RESULT_FILE="${PRECHECK_DIR}/${i}.env"

    if [[ "$MODE" != "tag" && "$MODE" != "mr" ]]; then
      echo "HAS_CHANGE=skip" > "$RESULT_FILE"
      exit 0
    fi

    case "$MODE" in
      tag) CACHE_FILE="${CACHE_DIR}/$(echo "$PROJECT_NAME" | tr '-' '_')_last_cr_tag" ;;
      mr)  CACHE_FILE="${CACHE_DIR}/$(echo "$PROJECT_NAME" | tr '-' '_')_last_cr_mr_iid" ;;
    esac

    echo "[cr_monitor] 预检: ${PROJECT_NAME} (mode=${MODE})"

    if [[ "$MODE" == "tag" ]]; then
      LATEST_VERSION=$(fetch_latest_tag "$ENCODED_PATH")
      TAG_CREATED_AT=$(fetch_latest_tag_created_at "$ENCODED_PATH")
    else
      LATEST_VERSION=$(fetch_latest_mr_iid "$ENCODED_PATH" "$RELEASE_BRANCH")
      TAG_CREATED_AT=""
    fi

    if [[ -z "$LATEST_VERSION" ]]; then
      echo "[cr_monitor] ${PROJECT_NAME}: API 预检失败，跳过" >&2
      echo "HAS_CHANGE=skip" > "$RESULT_FILE"
      exit 0
    fi

    CACHED_VERSION=$(cat "$CACHE_FILE" 2>/dev/null || echo "")

    if [[ "$LATEST_VERSION" == "$CACHED_VERSION" ]]; then
      echo "[cr_monitor] ${PROJECT_NAME}: 无变化 (${MODE}=${LATEST_VERSION})"
      if [[ "$PROJECT_NOTIFY" == "true" ]]; then
        send_no_change_notify "$PROJECT_NAME" "$MODE" "$LATEST_VERSION" \
          "$PROJECT_PATH" "$RELEASE_BRANCH"
        echo "[cr_monitor] ${PROJECT_NAME}: 无变化通知已发送"
      fi
      echo "HAS_CHANGE=false" > "$RESULT_FILE"
      exit 0
    fi

    echo "[cr_monitor] 检测到新版本: ${PROJECT_NAME} ${CACHED_VERSION:-(无缓存)} → ${LATEST_VERSION}"
    cat > "$RESULT_FILE" <<ENV
HAS_CHANGE=true
PROJECT_PATH=${PROJECT_PATH}
PROJECT_NAME=${PROJECT_NAME}
MODE=${MODE}
RELEASE_BRANCH=${RELEASE_BRANCH}
LATEST_VERSION=${LATEST_VERSION}
CACHED_VERSION=${CACHED_VERSION}
TAG_CREATED_AT="${TAG_CREATED_AT}"
CACHE_FILE=${CACHE_FILE}
ENV
  ) &
  pids+=($!)
done

echo "[cr_monitor] 等待并行预检完成..."
for pid in "${pids[@]}"; do wait "$pid" || true; done
echo "[cr_monitor] 预检完成"

# ── Phase 2：汇总有变化的项目 ────────────────────────────────────────────────
CHANGED_INDEXES=()
for i in $(seq 0 $((PROJECT_COUNT - 1))); do
  RESULT_FILE="${PRECHECK_DIR}/${i}.env"
  [[ ! -f "$RESULT_FILE" ]] && continue
  HAS_CHANGE=$(grep '^HAS_CHANGE=' "$RESULT_FILE" | cut -d= -f2)
  [[ "$HAS_CHANGE" == "true" ]] && CHANGED_INDEXES+=("$i")
done

if [[ ${#CHANGED_INDEXES[@]} -eq 0 ]]; then
  echo "[cr_monitor] 所有项目均无版本变化，跳过 CR"
  echo "[cr_monitor] 本轮检测完成"
  exit 0
fi

echo "[cr_monitor] 有变化项目: ${#CHANGED_INDEXES[@]} 个，开始串行 CR"

# ── Phase 3：串行 CR ──────────────────────────────────────────────────────────
CR_COUNT=${#CHANGED_INDEXES[@]}
for idx in "${!CHANGED_INDEXES[@]}"; do
  i="${CHANGED_INDEXES[$idx]}"
  # shellcheck source=/dev/null
  source "${PRECHECK_DIR}/${i}.env"

  LOG_FILE="${LOG_DIR}/cr_${PROJECT_NAME}.log"

  case "$MODE" in
    tag)
      bash "${SCRIPT_DIR}/cr_run.sh" \
        --mode tag \
        --project-path "$PROJECT_PATH" \
        --old-tag "$CACHED_VERSION" \
        --new-tag "$LATEST_VERSION" \
        ${TAG_CREATED_AT:+--tag-created-at "$TAG_CREATED_AT"} \
        --feishu-target "$FEISHU_TARGET" \
        >> "$LOG_FILE" 2>&1 \
        && echo "[cr_monitor] 完成: ${PROJECT_NAME}" \
        || echo "[cr_monitor] ${PROJECT_NAME}: CR 失败，见 ${LOG_FILE}" >&2
      ;;
    mr)
      bash "${SCRIPT_DIR}/cr_run.sh" \
        --mode mr \
        --project-path "$PROJECT_PATH" \
        --iid "$LATEST_VERSION" \
        --release-branch "$RELEASE_BRANCH" \
        --feishu-target "$FEISHU_TARGET" \
        >> "$LOG_FILE" 2>&1 \
        && echo "[cr_monitor] 完成: ${PROJECT_NAME}" \
        || echo "[cr_monitor] ${PROJECT_NAME}: CR 失败，见 ${LOG_FILE}" >&2
      ;;
  esac

  # 不是最后一个 CR 项目时才等待
  if [[ $((idx + 1)) -lt $CR_COUNT ]]; then
    sleep 60
  fi
done

echo "[cr_monitor] 本轮检测完成"

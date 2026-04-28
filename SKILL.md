---
name: cc-cr
description: >
  统一 CR skill，整合批量自动检测（原 cr-monitor）和交互式单次 CR（原 gitlab-cr）两种能力。
  TRIGGER when:
    - 用户消息包含"cr自动检测" → 自动检测模式（批量扫描所有配置项目）
    - 用户提供 GitLab URL（含 /-/merge_requests/ 或 /-/tags） → 交互式 CR 模式
    - 用户说"做cr"、"review MR"、"帮我cr"、"cr检查"等（不含"自动检测"） → 交互式 CR 模式
    - 用户说"cc-cr setup"、"cr配置"、"配置cr"、"setup" → 配置向导
  DO NOT TRIGGER when: 用户仅在询问关于 CR 的问题，没有执行 CR 的意图
argument-hint: "setup | cr自动检测 | <GitLab URL>"
allowed-tools: [Bash, Read, Write, Edit, Grep, AskUserQuestion]
---

# CC-CR — 统一代码审查

## 模式判断

根据用户输入确定执行模式和飞书推送目标：

| 输入特征 | 执行模式 | 飞书目标 |
|---------|---------|---------|
| 包含"setup"/"cr配置"/"配置cr" | **配置向导模式** | — |
| 包含"cr自动检测" | **自动检测模式** | personal（默认） |
| 包含"cr自动检测" + "推给群" / "发群" / "通知群" | **自动检测模式** | group |
| 包含 GitLab URL | **交互式 CR 模式** | — |
| 包含"做cr"/"review"/"帮我cr"/"cr检查"但无 URL | **交互式 CR 模式** | — |

**飞书目标判断规则（自动检测模式）：**
- 默认推送个人（`personal`）
- 用户输入包含"推给群"、"发群"、"通知群"、"发给群"等词汇时，使用 `group`

---

## 模式 S：配置向导（setup）

> 用 `AskUserQuestion` 逐步收集配置，最终写入 `SCRIPT_DIR/cr_config.json`，全程在 Claude Code session 内完成，无需终端交互。

`SCRIPT_DIR` = `~/.claude/skills/cc-cr`

### 前置检查

先运行依赖检查：

```bash
for cmd in jq curl python3 perl git; do
  command -v "$cmd" &>/dev/null && echo "✓ $cmd" || echo "✗ $cmd (缺失)"
done
command -v claude &>/dev/null && echo "✓ claude" || echo "✗ claude (缺失，需要安装: https://claude.ai/download)"
```

输出检查结果。如有缺失，列出安装命令（`brew install jq` 等），并询问是否继续。

若 `cr_config.json` 已存在，用 `AskUserQuestion` 询问：**是否覆盖现有配置？** 选"是"继续（先执行备份），选"否"退出。

选"是"时，先备份并**明确告知用户备份文件完整路径**：

```bash
BACKUP_FILE="${SCRIPT_DIR}/cr_config.json.bak.$(date +%Y%m%d_%H%M%S)"
cp "${SCRIPT_DIR}/cr_config.json" "$BACKUP_FILE"
echo "已备份到：$BACKUP_FILE"
```

**备份后立即用 `Read` 读取现有配置**，将各字段值保存为变量，作为后续步骤的默认值：

```bash
# 读取现有配置用于后续默认值
EXISTING_GITLAB_URL=$(jq -r '.gitlab_base_url // ""' "${SCRIPT_DIR}/cr_config.json")
EXISTING_TOKEN=$(jq -r '.gitlab_token // ""' "${SCRIPT_DIR}/cr_config.json")
EXISTING_LOCAL_PATH=$(jq -r '.local_base_path // ""' "${SCRIPT_DIR}/cr_config.json")
EXISTING_RELEASE_BRANCH=$(jq -r '.release_branch // "release"' "${SCRIPT_DIR}/cr_config.json")
EXISTING_NOTIFY_NO_CHANGE=$(jq -r '.notify_no_change // "false"' "${SCRIPT_DIR}/cr_config.json")
EXISTING_RECIPIENTS=$(jq -r '.feishu_recipients // [] | join(",")' "${SCRIPT_DIR}/cr_config.json")
```

### Step 1：GitLab 配置

用 `AskUserQuestion` 依次收集（每次一个问题）：

**1. GitLab 实例地址**

选项：
- 若 `EXISTING_GITLAB_URL` 非空，第一个选项显示现有值（标注"当前配置"）
- 第二个选项为"其他地址（Other 输入）"

**2. GitLab Personal Access Token**

根据 `EXISTING_TOKEN` 是否非空，提供不同选项：
- 若现有 token 非空：
  - 选项1：`保留现有 token`（显示末尾 4 位，如 `****yuj`）
  - 选项2：`使用环境变量 GITLAB_TOKEN（留空）`
  - 选项3：`重新输入（Other 填写）`
- 若现有 token 为空：
  - 选项1：`使用环境变量 GITLAB_TOKEN`
  - 选项2：`手动输入（Other 填写）`

**3. 本地代码库根目录**

选项：
- 若 `EXISTING_LOCAL_PATH` 非空，第一个选项显示现有值（标注"当前配置"）
- 其他常见路径作为备选（如 `~/projects`、`~/workspace`）
- Other 自由输入

**4. Release 分支名**

选项：
- `release（当前配置）` 或 `release（默认）`
- `main`
- Other 自由输入

### Step 2：飞书配置（可选）

**先执行自动检测**，再根据结果决定问什么：

```bash
# 检查 ~/.claude-to-im/config.env 是否已有飞书凭证
CTI_CONFIG="$HOME/.claude-to-im/config.env"
HAS_CTI_FEISHU=false
if [[ -f "$CTI_CONFIG" ]]; then
  grep -q "CTI_FEISHU_APP_ID=" "$CTI_CONFIG" && grep -q "CTI_FEISHU_APP_SECRET=" "$CTI_CONFIG" && HAS_CTI_FEISHU=true
fi
```

用 `AskUserQuestion` 询问：**是否配置飞书推送？**

- 若选"是"，根据 `HAS_CTI_FEISHU` 值决定后续：
  - **`HAS_CTI_FEISHU=true`**：提示"已检测到 claude-to-im 飞书配置，App ID/Secret 将自动继承，无需重复填写"，直接跳到接收人配置
  - **`HAS_CTI_FEISHU=false`**：继续收集：
    1. **飞书应用 App ID**（格式 `cli_xxxxxxxxx`）
    2. **飞书应用 App Secret**
    3. **飞书域名**（默认 `https://open.feishu.cn`，私有化部署时修改）

  无论哪种情况，都询问**飞书推送接收人 ID**：
  - 若 `EXISTING_RECIPIENTS` 非空，第一个选项显示现有值（标注"当前配置"）
  - 说明：`ou_` 开头=个人，`oc_` 开头=群，多个用英文逗号分隔
  - Other 自由输入

- 若选"否"，跳过飞书配置（recipients 为空数组，app_id/secret 为空）。

### Step 3：notify_no_change

用 `AskUserQuestion` 询问：**无版本变化时是否推送飞书通知？**

选项：
- `false — 不推送（推荐）`：安静模式，只有真正有变化时才通知
- `true — 也推送`：每次检测都推一条"无变化"通知

### Step 4：监控项目配置

先检查是否已有项目配置：

- 若已有项目，展示现有项目列表，用 `AskUserQuestion` 询问：
  - 选项1：`保留现有项目`
  - 选项2：`追加新项目`
  - 选项3：`删除指定项目`
  - 选项4：`清空，重新配置`

**选"保留"**：跳过，直接进入 Step 5。

**选"追加"**：循环用 `AskUserQuestion` 收集新项目，每轮两个问题：
1. **GitLab 项目路径**（格式 `group/project-name`；选"完成添加"结束）
2. **检测模式**：`mr`（合并请求，默认）或 `tag`（版本标签）

**选"删除指定项目"**：用 `AskUserQuestion` 展示当前所有项目，**multiSelect: true**，让用户勾选要**删除**的项目，未勾选的保留。每个选项格式为 `group/project-name（mode）`。删除后展示剩余项目列表确认。

**选"清空重新配置"**：从空列表开始，循环添加（同"追加"流程）。

至少需要保留一个项目。

### Step 5：汇总确认 & 写入

展示完整配置摘要（**Token 和 Secret 只显示最后 4 位**），用 `AskUserQuestion` 确认：**确认写入配置？**

确认后：

```bash
mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/cache" "${SCRIPT_DIR}/tmp"
```

用 `Write` 将配置写入 `${SCRIPT_DIR}/cr_config.json`（JSON 格式，参照 `cr_config.json.example` 结构）。

写入完成后输出提示：
- "配置完成！现在可以在 Claude Code 中说：**cr自动检测**"
- 若飞书凭证来自 claude-to-im 继承，提示确认 `~/.claude-to-im/config.env` 中凭证有效
- 若飞书凭证直接配置，提醒检查 App ID/Secret 和接收人 ID 是否正确

---

## 重要：CC 独白（每次 CR 必须遵守）

**每次交互式 CR 报告的最后（总结表格和总体评价之后），必须附上独白**，没有例外。规则：
- 格式：`**CC 内心OS：** ...`（加粗前缀 + 普通文本，不要用 blockquote `>` 或斜体 `*`，飞书不支持）
- 内容：结合本次变更特点（文件数、改动类型、commit message 质量、代码风格）幽默吐槽或感悟
- 风格：深夜写代码的内心 OS、程序员自嘲、代码拟人化比喻、生活化类比
- 要求：够毒、够搞笑、够扎心
- 长度：2-4 句话
- 每次要有新意，禁止重复

---

## 模式 A：自动检测模式

> 批量轮询所有配置项目，有版本变化才执行 CR，结果发飞书卡片。

### Step 1：前台运行脚本

根据模式判断结果确定 `FEISHU_TARGET`（`personal` 或 `group`），然后执行：

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 默认推个人
bash "${SCRIPT_DIR}/cr_monitor.sh" 2>&1

# 推群（用户输入含"推给群"/"发群"/"通知群"等词时）
bash "${SCRIPT_DIR}/cr_monitor.sh" --feishu-target group 2>&1
```

直接前台执行（**不加 `&`**），等待完成。

### Step 2：汇总输出

脚本结束后，读取各项目 log：`${SCRIPT_DIR}/logs/cr_<project-name>.log`

输出一条简洁结论：
- 有变化的项目：`<project-name> CR完成`
- 无变化项目：合并为一句 `其它项目未发现版本变化`

不输出版本号、问题摘要或其他多余信息。

### 注意
- 配置文件：`${SCRIPT_DIR}/cr_config.json`
- 各项目 log：`${SCRIPT_DIR}/logs/cr_<project-name>.log`
- 版本 cache：`${SCRIPT_DIR}/cache/`
- GitLab token 来自环境变量 `GITLAB_TOKEN`，或 `cr_config.json` 的 `gitlab_token` 字段

---

## 模式 B：交互式 CR 模式

支持三种 URL 格式，全部自动处理无需手动干预：
- **MR URL**：`https://<host>/<group>/<project>/-/merge_requests/<iid>` → MR CR
- **Tags 列表 URL**：`https://<host>/<group>/<project>/-/tags` → 取最新两个 tag 对比
- **指定 Tag URL**：`https://<host>/<group>/<project>/-/tags/<tag-name>` → 以该 tag 为 new_tag，自动查找前一个 tag 作为 old_tag

### Step 1：解析 URL，确定参数

从 URL 提取 project path（格式：`<group>/<project>`）和模式。

- MR 模式：提取 MR IID（URL 中最后的数字）
- Tags 模式：
  - URL 末尾是 `/tags/<tag-name>`：提取 `new_tag=<tag-name>`，old_tag 由 `cr_run.sh` 自动查找
  - URL 末尾是 `/tags`（列表页）：不传 new_tag，`cr_run.sh` 自动取最新两个 tag

### Step 2：调用 cr_run.sh

```bash
SCRIPT_DIR="$HOME/.claude/skills/cc-cr"

# MR 模式（--no-feishu：交互式模式下报告直接输出到 session）
bash "${SCRIPT_DIR}/cr_run.sh" \
  --mode mr \
  --project-path "<group>/<project>" \
  --iid <iid> \
  --no-feishu

# Tags 模式 - 指定 tag（cr_run.sh 自动查找 old_tag）
bash "${SCRIPT_DIR}/cr_run.sh" \
  --mode tag \
  --project-path "<group>/<project>" \
  --new-tag "<tag-name>" \
  --no-feishu

# Tags 模式 - 列表页（cr_run.sh 自动取最新两个 tag）
bash "${SCRIPT_DIR}/cr_run.sh" \
  --mode tag \
  --project-path "<group>/<project>" \
  --no-feishu
```

`cr_run.sh` 会完成：tag 自动解析 → 调用 Claude 子进程执行 CR → 写报告文件 → 更新 cache（交互式模式跳过飞书推送）。  
标准输出最后一行格式：`CR_REPORT_READY:/path/to/report.md`

### Step 3：读取报告，输出到当前 session

从 Step 2 输出中提取报告路径（`CR_REPORT_READY:` 后的内容），然后：

```bash
# 解析报告路径
REPORT_FILE=$(上一步输出 | grep '^CR_REPORT_READY:' | cut -d: -f2-)
```

Read `$REPORT_FILE`，将完整 CR 报告内容输出到当前 session 供用户查看。

---

## Review 关注点（按优先级）

1. **正确性**：逻辑错误、边界条件、NPE/空指针、并发安全
2. **安全性**：注入风险、敏感信息泄露、权限校验
3. **可靠性**：异常处理、降级策略、超时设置、资源泄露
4. **数据一致性**：状态机完整性、事务边界、缓存一致性
5. **可读性**：命名、注释代码（不应提交）、过度复杂的逻辑
6. **性能**：N+1 查询、不必要的循环、内存分配
7. **可维护性**：硬编码、重复代码、过时注释、魔法数字
8. **提交规范**：commit message 质量、是否包含无关变更

### Java / Spring Boot 专项
- Bean 生命周期和作用域
- 事务传播行为
- 线程安全（特别是 @Value 注入的共享状态）
- Stream API 的惰性求值陷阱
- Optional 的正确使用

### Go 专项
- error 是否被正确处理（不要 `_` 掉）
- goroutine 泄露
- channel 死锁
- defer 的执行时机

---

## 注意事项

- 对代码保持敬意，CR 是为了让代码更好，不是为了挑刺
- 区分"必须修"和"建议修"，不要把小问题升级成严重问题
- 发现亮点也要表扬
- MR 超过 500 行 diff，先给整体架构评审，再深入细节
- 注释代码、commit message 质量归为"小问题"，不要过度强调
- **CC 独白是灵魂，不是可选项，每次必须有**

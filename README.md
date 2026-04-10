# cc-cr — GitLab Release Code Review Skill for Claude Code

基于 Claude Code 的 GitLab Release 自动 CR（Code Review）工具。支持 MR 模式和 Tag 模式，自动扫描版本变化、执行 AI CR、推送飞书卡片。

## 功能

- **配置向导**：在 Claude Code session 内交互式完成所有配置，无需打开终端
- **自动检测模式**：批量轮询配置的项目，有新版本才执行 CR，无变化不打扰
- **交互式模式**：直接贴 GitLab MR/Tag URL，立即执行 CR，报告输出到当前 session
- **飞书推送**：CR 报告自动发送到飞书个人或群聊（按 ID 前缀自动区分）
- **增量检测**：通过本地 cache 记录上次版本，只对有变化的项目执行 CR

## 依赖

| 工具 | 必需 | 安装 |
|------|------|------|
| [Claude Code](https://claude.ai/download) | 是 | 官网下载 |
| jq | 是 | `brew install jq` |
| curl | 是 | macOS 自带 |
| python3 | 是 | macOS 自带 / `brew install python3` |
| perl | 是 | macOS 自带 |
| git | 是 | `brew install git` |

### 系统要求

- **macOS**：开箱即用，所有依赖均可通过 Homebrew 安装
- **Linux**：支持，需手动安装 `jq`、`python3`、`perl`、`git`；注意 Linux 系统 awk 不支持 `strftime`，脚本已改用 `perl` 实现时间格式化，无需额外处理
- **Windows**：不支持（依赖 bash 脚本）

### 与 claude-to-im 的关系

cc-cr **不依赖** [claude-to-im](https://github.com/anthropics/claude-code) skill，两者相互独立。

但如果你同时安装了 claude-to-im，飞书凭证（App ID / App Secret）可以自动复用，无需在 cc-cr 中重复填写——cc-cr 会按以下优先级读取：

```
环境变量 CTI_FEISHU_APP_ID/APP_SECRET > cr_config.json > ~/.claude-to-im/config.env
```

即：装了 claude-to-im 且已配置飞书的用户，cc-cr 的飞书配置可以留空，自动继承。

## 快速开始

### 1. 安装到 Claude Code

将 `cc-cr` 目录放到 Claude Code skills 目录：

```bash
~/.claude/skills/cc-cr/
```

### 2. 运行配置向导

在 Claude Code 中输入：

```
/cc-cr setup
```

向导会在 session 内通过对话框引导你完成：

1. **GitLab 配置**：实例地址、Personal Access Token、本地代码库根目录、release 分支名
2. **飞书配置（可选）**：自动检测是否已安装 claude-to-im skill（若已配置则飞书凭证直接继承，无需重复填写），配置推送接收人
3. **notify_no_change**：无版本变化时是否推送飞书通知
4. **监控项目列表**：逐项填写 GitLab 项目路径和检测模式（mr/tag）

**已有配置时的处理**：向导会先询问是否覆盖，选"是"后自动备份原文件（`cr_config.json.bak.时间戳`）并告知路径，然后以现有配置值作为每一步的默认选项，避免重复填写未变更的字段。

### 3. 手动配置（可选）

复制模板并编辑：

```bash
cp ~/.claude/skills/cc-cr/cr_config.json.example ~/.claude/skills/cc-cr/cr_config.json
```

配置说明见下方 [配置文件](#配置文件) 章节。

### 4. 使用

在 Claude Code 中输入：

```
/cc-cr setup                              # 配置向导
cr自动检测                                 # 检测所有项目，推送到个人
cr自动检测 发给群                           # 检测所有项目，推送到群聊
https://gitlab.xxx/-/merge_requests/123   # 对指定 MR 执行 CR
https://gitlab.xxx/-/tags                 # 对最新两个 tag 执行 CR
https://gitlab.xxx/-/tags/v1.2.0          # 对指定 tag 执行 CR
```

## 配置文件

`cr_config.json` 字段说明：

```json
{
  "gitlab_base_url": "https://gitlab.example.com",  // GitLab 实例地址
  "gitlab_token": "",                                // GitLab Token（建议用环境变量 GITLAB_TOKEN）
  "local_base_path": "/path/to/your/repos",         // 本地代码库根目录（项目目录名须与 GitLab 项目名 basename 一致）
  "release_branch": "release",                      // release 分支名
  "notify_no_change": false,                        // 无版本变化时是否推飞书通知（建议 false）
  "feishu_app_id": "",                              // 飞书应用 ID（可选，装了 claude-to-im 可留空自动继承）
  "feishu_app_secret": "",                          // 飞书应用 Secret（同上）
  "feishu_domain": "https://open.feishu.cn",        // 飞书域名（私有化部署时修改）
  "feishu_recipients": [
    "ou_xxx",                                       // ou_ 前缀 = 个人（open_id）
    "oc_xxx"                                        // oc_ 前缀 = 群聊（chat_id）
  ],
  "projects": [
    {
      "gitlab_project_path": "group/project",       // GitLab 项目路径（basename 须与本地目录名一致）
      "mode": "mr"                                  // mr（监控合并请求）或 tag（监控版本标签）
    }
  ]
}
```

### 凭证优先级

**GitLab Token**：环境变量 `GITLAB_TOKEN` > `cr_config.json`.gitlab_token

**飞书凭证**：环境变量 `CTI_FEISHU_APP_ID/APP_SECRET` > `cr_config.json` > `~/.claude-to-im/config.env`

建议生产环境使用环境变量，避免 Token 写入文件：

```bash
export GITLAB_TOKEN=glpat-xxxxxxxxxxxx
export CTI_FEISHU_APP_ID=cli_xxxxxxxxx
export CTI_FEISHU_APP_SECRET=xxxxxxxxxxxxxxxx
```

### 飞书推送目标

`feishu_recipients` 数组中可同时配置个人和群聊 ID，通过 ID 前缀自动区分：
- `ou_` 开头 → 个人消息（`open_id`）
- `oc_` 开头 → 群聊消息（`chat_id`）

触发时根据指令决定推送哪类：
- `cr自动检测` → 推个人（默认）
- `cr自动检测 发给群` → 推群聊

## 文件结构

```
cc-cr/
├── SKILL.md                 # Claude Code skill 定义
├── README.md                # 本文件
├── setup.sh                 # 配置向导（终端版，与 /cc-cr setup 等效）
├── cr_config.json           # 运行时配置（git ignored）
├── cr_config.json.example   # 配置模板
├── cr_monitor.sh            # 自动检测脚本
├── cr_run.sh                # CR 执行器
├── send_feishu_card.py      # 飞书卡片发送
├── cr_report_format.md      # CR 报告格式模板
├── logs/                    # 运行日志（自动创建）
├── cache/                   # 版本缓存（自动创建）
└── tmp/                     # 运行时临时文件（自动创建，运行后自动清理）
```

## 项目 CLAUDE.md

每个被 CR 的项目可在根目录放 `CLAUDE.md`，用于向 CR 提供项目上下文：

```markdown
# 项目架构说明
...

# CR 关注点
- 重点关注 xxx 模块的线程安全
- 数据库操作必须在事务内

# 已知技术债务
- ...
```

## .gitignore 建议

**cc-cr skill 目录**（已内置 `.gitignore`）：

```
cr_config.json
cr_config.json.bak.*
logs/
cache/
tmp/
```

**本地代码库根目录**（`local_base_path` 对应的 git 仓库，如有）：

```
cr-reports/
```

> CR 报告存放在 `{local_base_path}/cr-reports/`，若该目录在某个 git 仓库下，记得把 `cr-reports/` 加到对应仓库的 `.gitignore`。

## License

MIT

# cc-cr — GitLab Release Code Review Skill for Claude Code

An AI-powered GitLab Release CR (Code Review) tool built on Claude Code. Supports MR mode and Tag mode — automatically scans for version changes, runs AI code review, and pushes results to Feishu cards.

## Features

- **Setup Wizard**: Interactive configuration entirely within a Claude Code session — no terminal required
- **Auto-detect Mode**: Polls configured projects in batch; only runs CR when a new version is detected
- **Interactive Mode**: Paste a GitLab MR/Tag URL and get a CR report directly in the current session
- **Feishu Push**: CR reports are automatically sent to Feishu personal chats or group chats (auto-detected by ID prefix)
- **Incremental Detection**: Local cache tracks the last-seen version; CR only runs when something actually changed

## Dependencies

| Tool | Required | Install |
|------|----------|---------|
| [Claude Code](https://claude.ai/download) | Yes | Official download |
| jq | Yes | `brew install jq` |
| curl | Yes | Bundled with macOS |
| python3 | Yes | Bundled with macOS / `brew install python3` |
| perl | Yes | Bundled with macOS |
| git | Yes | `brew install git` |

### System Requirements

- **macOS**: Works out of the box; all dependencies available via Homebrew
- **Linux**: Supported; install `jq`, `python3`, `perl`, `git` manually. Linux `awk` lacks `strftime` — the scripts use `perl` for time formatting instead, no extra steps needed
- **Windows**: Not supported (requires bash)

### Relationship with claude-to-im

cc-cr does **not depend on** the [claude-to-im](https://github.com/op7418/Claude-to-IM) skill — they are independent.

However, if you have claude-to-im installed, Feishu credentials (App ID / App Secret) are automatically reused — no need to configure them again in cc-cr. Credential priority:

```
Env vars CTI_FEISHU_APP_ID/APP_SECRET > cr_config.json > ~/.claude-to-im/config.env
```

In other words: if you already have claude-to-im configured with Feishu, you can leave the Feishu fields in cc-cr empty and it just works.

## Quick Start

### 1. Install into Claude Code

Place the `cc-cr` directory under your Claude Code skills folder:

```bash
~/.claude/skills/cc-cr/
```

### 2. Run the Setup Wizard

In Claude Code, type:

```
/cc-cr setup
```

The wizard walks you through:

1. **GitLab config**: Instance URL, Personal Access Token, local repo root, release branch name
2. **Feishu config (optional)**: Auto-detects if claude-to-im is installed (inherits credentials if so); configure recipient IDs
3. **notify_no_change**: Whether to send a Feishu notification when no version change is detected
4. **Project list**: GitLab project paths and detection mode (mr/tag) for each project

**Updating existing config**: The wizard asks before overwriting, backs up the original file (`cr_config.json.bak.<timestamp>`), and pre-fills all fields with current values so you only need to change what's different.

### 3. Manual Configuration (Optional)

Copy the template and edit:

```bash
cp ~/.claude/skills/cc-cr/cr_config.json.example ~/.claude/skills/cc-cr/cr_config.json
```

See the [Configuration](#configuration) section below.

### 4. Usage

In Claude Code:

```
/cc-cr setup                              # Run setup wizard
cr自动检测                                 # Detect all projects, push to personal chat
cr自动检测 发给群                           # Detect all projects, push to group chat
https://gitlab.xxx/-/merge_requests/123   # CR for a specific MR
https://gitlab.xxx/-/tags                 # CR for the latest two tags
https://gitlab.xxx/-/tags/v1.2.0          # CR for a specific tag
```

## Configuration

`cr_config.json` field reference:

```json
{
  "gitlab_base_url": "https://gitlab.example.com",  // GitLab instance URL
  "gitlab_token": "",                                // GitLab token (recommended: use env var GITLAB_TOKEN)
  "local_base_path": "/path/to/your/repos",         // Local repo root (project dir name must match GitLab project basename)
  "release_branch": "release",                      // Release branch name
  "notify_no_change": false,                        // Notify Feishu when no version change (recommended: false)
  "feishu_app_id": "",                              // Feishu App ID (optional if claude-to-im is configured)
  "feishu_app_secret": "",                          // Feishu App Secret (same as above)
  "feishu_domain": "https://open.feishu.cn",        // Feishu domain (change for self-hosted deployments)
  "feishu_recipients": [
    "ou_xxx",                                       // ou_ prefix = personal (open_id)
    "oc_xxx"                                        // oc_ prefix = group chat (chat_id)
  ],
  "projects": [
    {
      "gitlab_project_path": "group/project",       // GitLab project path (basename must match local dir name)
      "mode": "mr"                                  // mr (monitor merge requests) or tag (monitor version tags)
    }
  ]
}
```

### Credential Priority

**GitLab Token**: env `GITLAB_TOKEN` > `cr_config.json`.gitlab_token

**Feishu credentials**: env `CTI_FEISHU_APP_ID/APP_SECRET` > `cr_config.json` > `~/.claude-to-im/config.env`

For production, use environment variables to keep tokens out of files:

```bash
export GITLAB_TOKEN=glpat-xxxxxxxxxxxx
export CTI_FEISHU_APP_ID=cli_xxxxxxxxx
export CTI_FEISHU_APP_SECRET=xxxxxxxxxxxxxxxx
```

### Feishu Push Targets

`feishu_recipients` can contain both personal and group IDs; the type is inferred from the prefix:
- `ou_` → personal message (`open_id`)
- `oc_` → group chat message (`chat_id`)

Which recipients get notified depends on the trigger:
- `cr自动检测` → personal (default)
- `cr自动检测 发给群` → group chat

## File Structure

```
cc-cr/
├── SKILL.md                 # Claude Code skill definition
├── README.md                # Chinese README
├── README_EN.md             # This file
├── setup.sh                 # Setup wizard (terminal version, equivalent to /cc-cr setup)
├── cr_config.json           # Runtime config (git ignored)
├── cr_config.json.example   # Config template
├── cr_monitor.sh            # Auto-detect script
├── cr_run.sh                # CR executor
├── send_feishu_card.py      # Feishu card sender
├── cr_report_format.md      # CR report format template
├── logs/                    # Run logs (auto-created)
├── cache/                   # Version cache (auto-created)
└── tmp/                     # Runtime temp files (auto-created, auto-cleaned)
```

## Project CLAUDE.md

Each project being reviewed can have a `CLAUDE.md` at its root to provide context to the CR:

```markdown
# Architecture Overview
...

# CR Focus Areas
- Pay special attention to thread safety in the xxx module
- All DB operations must be within a transaction

# Known Technical Debt
- ...
```

## .gitignore Recommendations

**cc-cr skill directory** (`.gitignore` already included):

```
cr_config.json
cr_config.json.bak.*
logs/
cache/
tmp/
```

**Local repo root** (`local_base_path` git repo, if applicable):

```
cr-reports/
```

> CR reports are stored in `{local_base_path}/cr-reports/`. If that directory is inside a git repo, add `cr-reports/` to that repo's `.gitignore`.

## License

MIT

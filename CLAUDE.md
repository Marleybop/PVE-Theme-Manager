# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

PVE Theme Manager is a Bash-based TUI/CLI tool for installing and managing CSS themes for Proxmox Virtual Environment (PVE). It modifies `/usr/share/pve-manager/index.html.tpl` to inject custom stylesheets, creating backups before all changes.

**Key insight**: This tool manipulates Proxmox VE's web UI by injecting `<link>` tags and JavaScript before `</head>` in the index template, while copying CSS files to `/usr/share/pve-manager/images/`.

## Core Architecture

### Main Script: `pve-theme-manager.sh`

Single-file Bash script (~900 lines) organized into sections:

1. **Configuration** (lines 11-29): Constants for paths, markers, version
2. **Utility Functions** (lines 32-79): Logging, error handling, root/Proxmox checks
3. **JSON Helpers** (lines 82-126): jq-based parsing with grep/sed fallbacks
4. **Menu System** (lines 129-178): whiptail TUI with text fallback
5. **Theme Operations** (lines 181-471): Install, uninstall, CSS management
6. **Backup Operations** (lines 474-552): Create/restore backups
7. **TUI Flows** (lines 594-761): Interactive menu workflows
8. **CLI Interface** (lines 764-797): Command-line argument handling

### Theme Structure

Each theme in `themes/<ThemeName>/`:
```
metadata.json      # Name, description, author, version, tested PVE versions
snippet.html       # HTML/JS/CSS to inject into <head>
css/
  └── theme.css    # Main stylesheet
```

**Critical files**:
- `metadata.json`: Defines `css_files[]` array and `inject_file` path
- `snippet.html`: Typically adds body class + `<link>` to CSS file in `/pve2/images/`

### State Management

- `/root/.pve-theme-manager/state.json`: Tracks currently installed theme
- `/root/.pve-theme-manager/backups/`: Timestamped backup directories
- `/var/log/pve-theme-manager.log`: Activity log

## Theme Development

### CSS Variable System

All themes use CSS variables for customization. The `_BaseTemplate` provides scaffolding with 30+ variables:

**Variable categories**:
- `--theme-bg-*`: Background colors (darkest → main → light)
- `--theme-text-*`: Text colors (primary, secondary, disabled, links)
- `--theme-accent-*`: Primary/secondary/tertiary accent colors
- `--theme-success/warning/error`: Status colors
- `--theme-border-*`: Border and separator colors
- `--theme-shadow/glow`: Visual effects

**Light/Dark mode**: Use `@media (prefers-color-scheme: light)` to override variables for automatic switching.

### Proxmox UI Element Targeting

**Key CSS classes to style**:

**Tree/Grid Icons with Status Indicators**:
- `.x-tree-icon-custom`, `.x-tree-icon-leaf`, `.x-tree-icon-parent`: Main item icons
- `.x-tree-icon-custom.running::after`, `.x-tree-icon-custom.online::after`: Status overlay icons (green play button)
- `.x-tree-icon-custom.stopped::after`: Stopped status (stopped icon)
- `.fa.running::after`, `.fa.online::after`: Font Awesome icon status overlays
- **Important**: VMs/containers use `.running`/`.stopped` classes, nodes use `.online` class

**Panels & Windows**:
- `.x-panel`, `.x-window`, `.x-grid-panel`
- `.x-panel-header`, `.x-toolbar`

**Buttons & Forms**:
- `.x-btn`, `.x-form-item`, `.x-form-field`
- `.x-btn-pressed`, `.x-btn-focus`

**Tabs & Menus**:
- `.x-tab`, `.x-tab-active`
- `.x-menu`, `.x-menu-item`

**Grids & Trees**:
- `.x-grid-row`, `.x-grid-cell`
- `.x-tree-node`, `.x-tree-node-expanded`

**Progress & Scrollbars**:
- `.x-progress-bar`, `.x-progress-text`
- `.x-scroller`

## Common Development Commands

### Testing Themes

```bash
# Preview without making changes
./pve-theme-manager.sh --dry-run install ThemeName

# Install theme
./pve-theme-manager.sh install ThemeName

# Check current status
./pve-theme-manager.sh status

# Uninstall (restore default)
./pve-theme-manager.sh uninstall
```

### Creating a New Theme

```bash
# 1. Copy base template
cp -r themes/_BaseTemplate themes/NewTheme

# 2. Rename CSS file
mv themes/NewTheme/css/base-template.css themes/NewTheme/css/new-theme.css

# 3. Edit metadata.json (update name, description, author, css_files[])

# 4. Edit snippet.html (update CSS filename in <link> tag)

# 5. Customize CSS variables in new-theme.css :root { ... }

# 6. Test
./pve-theme-manager.sh --dry-run install NewTheme
```

### Debugging

```bash
# View logs
cat /var/log/pve-theme-manager.log

# Check state
cat /root/.pve-theme-manager/state.json

# List backups
ls -lh /root/.pve-theme-manager/backups/

# Manual inspection of modified template
grep -A 20 "PVE-THEME:" /usr/share/pve-manager/index.html.tpl
```

## Important Implementation Details

### Theme Installation Flow

1. **Backup**: Creates timestamped backup of `index.html.tpl` in `/root/.pve-theme-manager/backups/`
2. **Cleanup**: Removes previous theme's CSS files and snippet markers
3. **Copy CSS**: Copies theme CSS files to `/usr/share/pve-manager/images/`
4. **Inject**: Inserts snippet between `<!-- PVE-THEME: ThemeName -->` and `<!-- /PVE-THEME -->` markers before `</head>`
5. **State**: Updates `state.json` with theme name, timestamp, PVE version
6. **Restart**: Runs `systemctl restart pveproxy` (unless `--no-restart`)

### Injection Mechanism

The script uses AWK to inject theme code before `</head>`:
```bash
awk -v block="$block" '
    /<\/head>/ { print block }
    { print }
' "$target" > "$tmp"
```

Theme markers allow multiple installs to cleanly remove previous themes:
```html
<!-- PVE-THEME: MonokaiPro -->
<script>...</script>
<link rel="stylesheet" href="/pve2/images/monokai-pro.css">
<!-- /PVE-THEME -->
```

### Dual-Mode Support (jq / grep-sed)

All JSON operations have fallbacks:
- `json_get()`: Uses `jq -r ".$key"` OR `grep -o` + `sed` extraction
- `json_get_array()`: Uses `jq -r ".$key[]?"` OR `grep -o` + line-by-line parsing

This allows the script to work without `jq` dependency.

### Remote Installation Support

The script can download themes on-demand when run via curl (no local git clone):
- `ensure_themes_available()` downloads repo tarball to `/tmp/pve-theme-manager-cache/`
- Extracts and sets `THEMES_DIR` to extracted `themes/` folder
- Allows single-command installation: `bash -c "$(curl -fsSL .../pve-theme-manager.sh)"`

## Git Workflow

This repo maintains a clean single-commit history. When making significant updates:

1. Make changes
2. Test thoroughly
3. Create new orphan branch with fresh single commit
4. Force push to master

**Exclude from git**: `AGENTS.md`, `.claude/`, any init files, `css/` directories in stock themes.

## Proxmox Compatibility

Tested on Proxmox VE 7.x and 8.x. The web UI uses ExtJS 7.x framework.

**Critical paths**:
- `/usr/share/pve-manager/index.html.tpl`: Main template (modified)
- `/usr/share/pve-manager/images/`: CSS file destination (web-accessible at `/pve2/images/`)
- Service: `pveproxy` (must restart after changes)

## Current Themes

1. **MonokaiPro** (v2.0.0): Monokai Pro colors with automatic light/dark mode switching via `prefers-color-scheme`
2. **Dracula** (v1.0.0): Official Dracula color palette (dark mode only)
3. **_BaseTemplate** (v2.0.0): Comprehensive template with all CSS variables documented

Both production themes use ~1000 lines of CSS covering all UI elements with proper status icon colors (green for running/online, theme accent for stopped).

# PVE Theme Manager

A lightweight theme manager for Proxmox VE. Install, preview, and manage CSS themes via TUI or command line.

## Quick Start

**Option 1: Run directly via curl**
```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Marleybop/pve-theme-manager/master/pve-theme-manager.sh)"
```

**Option 2: Clone and run locally**
```bash
git clone https://github.com/Marleybop/pve-theme-manager.git
cd pve-theme-manager
./pve-theme-manager.sh
```

### Requirements
- Proxmox VE host (7.x or 8.x)
- Root access
- Optional: `jq` for JSON parsing (falls back to grep/sed)
- Optional: `whiptail` for TUI menus (falls back to text prompts)

## Usage

### TUI Mode (default)
```bash
./pve-theme-manager.sh
```

### Command Line
```bash
# Show current status
./pve-theme-manager.sh status

# List available themes
./pve-theme-manager.sh list

# Install a theme
./pve-theme-manager.sh install CyberpunkNeon

# Preview changes without applying
./pve-theme-manager.sh --dry-run install Dracula

# Uninstall theme (restore default UI)
./pve-theme-manager.sh uninstall

# Create manual backup
./pve-theme-manager.sh backup

# Restore a backup
./pve-theme-manager.sh restore               # Restore latest
./pve-theme-manager.sh restore 20250115-103045-manual  # Restore specific

# Show theme details
./pve-theme-manager.sh info Nord
```

### Options
| Option | Description |
|--------|-------------|
| `--dry-run` | Preview changes without modifying files |
| `--no-restart` | Skip pveproxy restart after changes |
| `-h, --help` | Show help message |
| `-v, --version` | Show version |

## What It Does

1. **Backs up** your current `/usr/share/pve-manager/index.html.tpl` before any changes
2. **Copies** theme CSS files to `/usr/share/pve-manager/images/`
3. **Injects** the theme's HTML snippet before `</head>` in the index template
4. **Restarts** `pveproxy` to apply changes
5. **Tracks** the installed theme in `/root/.pve-theme-manager/state.json`

## Included Themes

| Theme | Description |
|-------|-------------|
| `MonokaiPro` | Monokai Pro with light/dark mode support (auto-switches with system preference) |
| `Dracula` | Official Dracula colors with purple, pink, cyan, and green accents (dark only) |

## Theme Structure

Each theme lives in `themes/<ThemeName>/`:

```
themes/
  └── MonokaiPro/
        ├── metadata.json     # Theme metadata
        ├── css/
        │     └── monokai-pro.css
        └── snippet.html      # HTML to inject
```

### metadata.json
```json
{
  "name": "MonokaiPro",
  "description": "Monokai-inspired theme with bold magenta/green accents",
  "author": "Marleybop",
  "version": "1.0.0",
  "tested_proxmox_versions": ["7.x", "8.x"],
  "css_files": ["css/monokai-pro.css"],
  "inject_file": "snippet.html"
}
```

### snippet.html
```html
<script>
  document.addEventListener('DOMContentLoaded', () => {
    document.body.classList.add('theme-monokai-pro');
  });
</script>
<link rel="stylesheet" href="/pve2/images/monokai-pro.css">
```

## Creating a Theme

### Using the Base Template (Recommended)

The `_BaseTemplate` theme provides a comprehensive CSS file with variables for ALL themeable UI elements:

```bash
# Copy the base template
cp -r themes/_BaseTemplate themes/MyTheme

# Rename the CSS file
mv themes/MyTheme/css/base-template.css themes/MyTheme/css/my-theme.css
```

Then edit the CSS variables at the top of `my-theme.css`:
```css
:root {
    --theme-bg-darkest: #0a0a0a;      /* Darkest background */
    --theme-bg-main: #262626;          /* Main panel background */
    --theme-accent-primary: #0060a4;   /* Primary accent color */
    --theme-text-primary: #f2f2f2;     /* Main text color */
    /* ... 30+ more variables ... */
}
```

Update `metadata.json` and `snippet.html` with your theme name and CSS filename.

### CSS Variable Categories

| Category | Variables | What it styles |
|----------|-----------|----------------|
| **Backgrounds** | `--theme-bg-*` | Panels, windows, inputs, viewport |
| **Text** | `--theme-text-*` | Primary, secondary, disabled, links |
| **Accents** | `--theme-accent-*` | Buttons, selections, active states |
| **Status** | `--theme-success/warning/error` | Status indicators, progress bars |
| **Borders** | `--theme-border-*` | Borders, separators, outlines |
| **Effects** | `--theme-shadow/glow` | Shadows, glow effects |

### Creating Your Own Theme

**Quick Start:**
1. Copy the base template: `cp -r themes/_BaseTemplate themes/MyTheme`
2. Edit `themes/MyTheme/metadata.json`:
   - Change `name` to `"MyTheme"`
   - Update `description`, `author`, `version`
3. Edit `themes/MyTheme/css/base-template.css`:
   - Rename to `my-theme.css`
   - Customize CSS variables in `:root { ... }`
   - Change colors to match your theme
4. Edit `themes/MyTheme/snippet.html`:
   - Update CSS filename to match your renamed file
5. Test: `./pve-theme-manager.sh --dry-run install MyTheme`
6. Install: `./pve-theme-manager.sh install MyTheme`

**What to Customize:**

All colors are controlled by CSS variables in `:root`. Just change the hex values:

```css
:root {
    /* Backgrounds - dark to light progression */
    --theme-bg-darkest: #your-color;  /* Main viewport */
    --theme-bg-main: #your-color;     /* Panels, windows */
    --theme-bg-light: #your-color;    /* Input fields */

    /* Accent colors - your theme's signature colors */
    --theme-accent-primary: #your-color;    /* Buttons, tabs */
    --theme-accent-secondary: #your-color;  /* Running status indicators */
    --theme-accent-tertiary: #your-color;   /* Stopped status indicators */

    /* Status colors - green/orange/red */
    --theme-success: #your-color;  /* Running VMs, online nodes */
    --theme-warning: #your-color;  /* Warnings */
    --theme-error: #your-color;    /* Errors */
}
```

**For Light Mode Support:**

Uncomment and customize the `@media (prefers-color-scheme: light)` section in the template.

**Examples:**

Look at `themes/MonokaiPro` or `themes/Dracula` to see complete implementations.

## File Locations

| Path | Purpose |
|------|---------|
| `/root/.pve-theme-manager/` | Config directory |
| `/root/.pve-theme-manager/state.json` | Current theme state |
| `/root/.pve-theme-manager/backups/` | Backup storage |
| `/var/log/pve-theme-manager.log` | Activity log |
| `/usr/share/pve-manager/index.html.tpl` | Proxmox template (modified) |
| `/usr/share/pve-manager/images/` | Theme CSS files installed here |

## Backups

Backups are created automatically before:
- Installing a theme
- Uninstalling a theme

Each backup includes:
- The `index.html.tpl` file
- Metadata (timestamp, theme name, Proxmox version)

List backups:
```bash
ls /root/.pve-theme-manager/backups/
```

## Troubleshooting

### Theme not showing after install
- Hard refresh your browser: `Ctrl+Shift+R`
- Clear browser cache
- Verify pveproxy restarted: `systemctl status pveproxy`

### Restore default UI
```bash
./pve-theme-manager.sh uninstall
```

Or restore from backup:
```bash
./pve-theme-manager.sh restore
```

### View logs
```bash
cat /var/log/pve-theme-manager.log
```

### Check current state
```bash
./pve-theme-manager.sh status
cat /root/.pve-theme-manager/state.json
```

## Uninstall

To completely remove the theme manager and restore defaults:

```bash
# Uninstall theme
./pve-theme-manager.sh uninstall

# Remove config/backups (optional)
rm -rf /root/.pve-theme-manager
rm -f /var/log/pve-theme-manager.log
```

## License

MIT

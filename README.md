# WP Copy Remote

> **Note:** This repository was formerly named `wp-push-remote`.

Bash scripts to push or pull WordPress sites between servers using WP-CLI and rsync. Works on Ubuntu 22.04 LTS and higher.

- **`wp-push-remote.sh`** — Push a site FROM local TO remote
- **`wp-pull-remote.sh`** — Pull a site FROM remote TO local

## Features

- 🚀 **Persistent Configuration**: Configure once with `--config`, connection settings and per-site options saved automatically
- 🎯 **Smart Auto-Detection**: URLs and table prefixes detected via WP-CLI
- 📁 **Custom Exclusions**: Space-delimited exclusion lists via `-e` flag — saved to conf
- 🔌 **Plugin Installation**: Install multiple plugins with `--install-plugins "plugin1 plugin2"` — saved to conf
- 🪝 **Post-sync Commands**: Run custom commands on the destination after each sync via `remote_commands` in conf
- 🔄 **Database Migration**: Automatic export, transfer, import, and search-replace
- 🧹 **Optional SQL Sanitizing**: Use `-f` to strip privileged SQL statements before import — saved to conf
- 💾 **DB Backup**: Optionally back up the destination DB before import with `--backup-db` — saved to conf
- 🔐 **Modern SSH Keys**: Ed25519 key generation for better security
- ⚙️ **Multiple Modes**: Interactive, unattended, files-only, and dry-run modes
- 🔄 **Table Prefix Sync**: Automatic detection and synchronization of mismatched prefixes

## Requirements

- Ubuntu 22.04 LTS or higher (both servers)
- WP-CLI installed on both servers
- SSH access to the remote server
- `rsync` and `openssh-client` (usually pre-installed)

```bash
sudo apt update && sudo apt install openssh-client rsync
curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp
```

## Installation

```bash
sudo git clone https://github.com/WPNET/wp-copy-remote.git /opt/wp-copy-remote
cd /opt/wp-copy-remote
sudo chmod 700 wp-push-remote.sh wp-pull-remote.sh install.sh
```

Install a script to a site user's directory (run as root):

```bash
sudo /opt/wp-copy-remote/install.sh
# Interactive prompts will ask:
#   1. Push or pull script?
#   2. Which site? (lists /sites/*/files/ directories)
# Script installed as ~/.local/bin/wp-push-remote (or wp-pull-remote)
```

**Important:** Run as the site user, never as root.

## Usage

### wp-push-remote — Push local site to remote

```bash
su - siteuser
cd /sites/yourdomain.com
./.local/bin/wp-push-remote --config    # First time: configure settings
./.local/bin/wp-push-remote              # Push to remote server
```

### wp-pull-remote — Pull remote site to local

```bash
su - siteuser
cd /sites/yourdomain.com
./.local/bin/wp-pull-remote --config    # First time: configure settings
./.local/bin/wp-pull-remote              # Pull from remote server
```

Both scripts use the same options and flags. Configuration is stored separately:
- Push: `~/.wp-push-remote.conf`
- Pull: `~/.wp-pull-remote.conf`

## Command-Line Options

```
-h, --help                   Show help message
-u, --unattended             Run without prompts
-c, --config                 Configure and save settings (loads existing conf first)
-D, --del-ssh-key            Delete SSH key pairs for remote user
-f, --filter-sql             Strip privileged SQL statements before import  [saved to conf]
-e, --exclude "LIST"         Space-delimited paths to exclude from rsync    [saved to conf]
-p, --install-plugins "LIST" Plugins to install after sync                  [saved to conf]
-n, --dry-run                Simulate without making destructive changes
-v, --version                Show version and exit

--search-replace             Run wp search-replace (default: yes)
--no-search-replace          Skip wp search-replace
--files-only                 Skip all database operations
--no-db-import               Skip database import
--exclude-wpconfig           Exclude wp-config.php (default: yes)
--no-exclude-wpconfig        Include wp-config.php in sync
--disable-wp-debug           Disable WP_DEBUG temporarily
--all-tables-with-prefix     Use --all-tables-with-prefix for search-replace (default: yes)
--no-all-tables-with-prefix  Disable --all-tables-with-prefix for search-replace
--backup-db                  Back up destination DB before importing        [saved to conf]
--log FILE                   Write all output to FILE in addition to terminal
```

Options marked `[saved to conf]` are persisted to the conf file on first use and automatically applied on every subsequent run. Edit the conf file directly to remove or change them.

## Examples

```bash
# Configure settings (first time)
./.local/bin/wp-push-remote --config
./.local/bin/wp-pull-remote --config

# Push / pull (uses saved config)
./.local/bin/wp-push-remote
./.local/bin/wp-pull-remote

# Files only (no database)
./.local/bin/wp-push-remote --files-only

# Unattended with exclusions (exclusions saved to conf for future runs)
./.local/bin/wp-pull-remote -u -e "uploads cache .git"

# Install plugins on destination after sync (saved to conf)
./.local/bin/wp-push-remote --install-plugins "woocommerce contact-form-7"

# Enable SQL filtering (saved to conf)
./.local/bin/wp-push-remote -f

# Back up destination DB before import (saved to conf)
./.local/bin/wp-push-remote --backup-db

# Dry run — see what would happen without making changes
./.local/bin/wp-push-remote --dry-run

# Delete SSH key pairs
./.local/bin/wp-push-remote --del-ssh-key
```

## Workflow

### Push (local → remote)

1. Load config / SSH key setup
2. Detect local URL and connection test
3. Export database locally
4. Rsync files local → remote
5. On remote: import DB, search-replace (local URL → remote URL), cache flush
6. Run `remote_commands` if set in conf
7. Cleanup temp files

### Pull (remote → local)

1. Load config / SSH key setup
2. Detect local URL and connection test
3. Export database on remote
4. Rsync files remote → local (includes DB export)
5. Locally: import DB, search-replace (remote URL → local URL), cache flush
6. Run `remote_commands` if set in conf
7. Cleanup temp files on remote and local

## Configuration

Run `--config` once to save connection settings. Existing conf values are shown as defaults, so re-running `--config` only requires updating what has changed.

Fields prompted:

| Field | Example |
|---|---|
| Local/Source path prefix | `/sites/example.com/` |
| Local/Source webroot | `files` |
| Remote IP/hostname | `192.168.1.100` |
| Remote SSH user | `siteuser` |
| Remote path prefix | `/sites/example.com/` |
| Remote webroot | `files` |

URLs, table prefixes, and file paths are auto-detected via WP-CLI.

### Persistent Options

The following options are saved to the conf file and applied on every run:

| Conf key | Set via | Description |
|---|---|---|
| `conf_excludes` | `-e / --exclude` | Extra rsync exclusions beyond the built-in defaults |
| `plugins_to_install` | `-p / --install-plugins` | Plugins to install on destination after sync |
| `backup_db` | `--backup-db` | Back up destination DB before importing |
| `filter_sql` | `-f / --filter-sql` | Strip privileged SQL statements from dump |
| `remote_commands` | conf file only | Commands to run on destination after each sync |

### remote_commands (conf file only)

`remote_commands` is set directly in the conf file — it is not a CLI flag. Use it for commands that should run on the destination server after every push/pull, such as rebuilding plugin caches.

Commands are **newline-delimited** (one per line). Use single quotes within commands to avoid shell expansion issues:

```bash
# ~/.wp-push-remote.conf
remote_commands="wp cache flush
wp eval 'my_plugin_rebuild_cache();'"
```

### Default Exclusions

`.git`, `.maintenance`, `wp-content/cache`, `wp-content/uploads/wp-migrate-db`, `/wp-content/updraft`, `wp-config.php`

## SSH Key Management

SSH keys are generated automatically on first run (Ed25519). To delete them:

```bash
./.local/bin/wp-push-remote --del-ssh-key
```

**Important**: Also manually remove the public key from the remote server's `~/.ssh/authorized_keys`.

## Troubleshooting

**SSH password prompt**: Add the public key to `~/.ssh/authorized_keys` on the remote server.

**WP-CLI not found**: Install from [wp-cli.org](https://wp-cli.org/#installing).

**MySQL privilege errors (ERROR 1227)**: Run with `-f` to strip privileged statements from the dump.

**Database import fails**: Check DB credentials in `wp-config.php` and available disk space.

**Plugin shortcodes/features broken after push**: Some plugins cache state in the database. Use `remote_commands` to rebuild the cache after each push. Example for WPCode:
```bash
remote_commands="wp eval 'wpcode()->cache->cache_all_loaded_snippets();'"
```

## Security

- `wp-config.php` excluded by default to protect remote/local credentials
- Ed25519 SSH keys for better security
- Temporary SQL files cleaned up after import
- Table prefix sync requires confirmation before resetting database

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This script is provided as-is for use in WordPress deployments.

## Author

**gb@wpnet.nz**

#!/bin/bash

# Ubuntu 22.04+ compatible script
# Requires: bash 5.0+, WP-CLI, rsync, openssh-client

# Check bash version (require 5.0+ for Ubuntu 22.04+)
if ((BASH_VERSINFO[0] < 5)); then
    echo "ERROR: This script requires Bash 5.0 or higher (current: $BASH_VERSION)"
    echo "Ubuntu 22.04+ should have bash 5.1+ by default."
    exit 1
fi

script_version="1.1.0"
# Author:       gb@wpnet.nz
# Description:  Pull a site from REMOTE server to LOCAL (SOURCE). Run this script from the LOCAL server.
# Requirements: WP-CLI installed on source (local) and remote servers
#               wp-cli.yml to be configured in the source and remote site owner's home directory, with the correct path to the WP installation
# Target OS:    Ubuntu 22.04 LTS or higher

# Filter PHP constant-redefinition warnings from all WP-CLI output (local and remote via SSH)
exec 2> >(grep -v "^PHP Warning:" >&2)

####################################################################################
# COLOR DEFINITIONS FOR BETTER UX
####################################################################################

# Check if terminal supports colors
if [[ -t 1 ]]; then
    # Colors
    COLOR_RESET='\033[0m'
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[0;33m'
    COLOR_BLUE='\033[0;34m'
    COLOR_MAGENTA='\033[0;35m'
    COLOR_CYAN='\033[0;36m'
    COLOR_WHITE='\033[1;37m'
    # Bold colors
    COLOR_BOLD_GREEN='\033[1;32m'
    COLOR_BOLD_YELLOW='\033[1;33m'
    COLOR_BOLD_BLUE='\033[1;34m'
    COLOR_BOLD_CYAN='\033[1;36m'
else
    # No colors
    COLOR_RESET=''
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_BLUE=''
    COLOR_MAGENTA=''
    COLOR_CYAN=''
    COLOR_WHITE=''
    COLOR_BOLD_GREEN=''
    COLOR_BOLD_YELLOW=''
    COLOR_BOLD_BLUE=''
    COLOR_BOLD_CYAN=''
fi

####################################################################################
# HELPER FUNCTIONS
####################################################################################

# Print functions
print_header() {
    echo -e "\n${COLOR_BOLD_CYAN}==== $1 ====${COLOR_RESET}"
}

print_info() {
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $1"
}

print_success() {
    echo -e "${COLOR_BOLD_GREEN}[SUCCESS]${COLOR_RESET} $1"
}

print_warning() {
    echo -e "${COLOR_BOLD_YELLOW}[WARNING]${COLOR_RESET} $1"
}

print_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $1"
}

_step_count=0
print_step() {
    _step_count=$((_step_count + 1))
    echo -e "\n${COLOR_BOLD_BLUE}++++ Step ${_step_count}: $1${COLOR_RESET}"
}

# Display boolean flag as human-readable YES/NO
bool_display() {
    [[ "${1:-0}" -eq 1 ]] && echo "YES" || echo "NO"
}

# Execute a command, or in dry-run mode just print it
dry_run_exec() {
    if [[ $dry_run -eq 1 ]]; then
        print_info "[DRY-RUN] Would execute: $*"
        return 0
    fi
    "$@"
}

# Acquire a lock file to prevent concurrent runs
_lock_file="/tmp/$(basename "$0" .sh).lock"
acquire_lock() {
    if [[ -f "$_lock_file" ]]; then
        local old_pid
        old_pid=$(cat "$_lock_file" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            print_error "Another instance is already running (PID: ${old_pid}). Remove ${_lock_file} to override."
            exit 1
        fi
        print_warning "Removing stale lock file (PID ${old_pid} is no longer running)"
        rm -f "$_lock_file"
    fi
    echo $$ > "$_lock_file"
}
release_lock() {
    rm -f "$_lock_file"
}

# Check available disk space before a large transfer
# Args: $1 = destination path, $2 = source path to measure
check_disk_space() {
    local dest_path="$1"
    local src_path="$2"
    local avail_kb src_kb

    avail_kb=$(df -k "$dest_path" 2>/dev/null | awk 'NR==2 {print $4}')
    src_kb=$(du -sk "$src_path" 2>/dev/null | awk '{print $1}')

    if [[ -n "$avail_kb" && -n "$src_kb" ]]; then
        local avail_mb=$(( avail_kb / 1024 ))
        local src_mb=$(( src_kb / 1024 ))
        print_info "Disk space: source ~${src_mb}MB, destination has ~${avail_mb}MB free"
        local threshold=$(( src_kb + src_kb / 5 ))  # 120% of source size
        if (( avail_kb < threshold )); then
            print_warning "Destination may not have sufficient disk space!"
            print_warning "  Available: ~${avail_mb}MB  |  Estimated needed: ~$(( threshold / 1024 ))MB (including 20% buffer)"
            return 1
        fi
    fi
    return 0
}

# Help function
show_help() {
    echo -e "${COLOR_BOLD_CYAN}WP Pull Remote v${script_version}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}Pull a WordPress site FROM REMOTE server to LOCAL using WP-CLI and rsync${COLOR_RESET}"
    echo ""
    echo -e "${COLOR_BOLD_GREEN}USAGE:${COLOR_RESET}"
    echo "    $0 [OPTIONS]"
    echo ""
    echo -e "${COLOR_BOLD_GREEN}OPTIONS:${COLOR_RESET}"
    echo -e "    ${COLOR_YELLOW}-h, --help${COLOR_RESET}                   Show this help message"
    echo -e "    ${COLOR_YELLOW}-u, --unattended${COLOR_RESET}             Run in unattended mode (no prompts)"
    echo -e "    ${COLOR_YELLOW}-c, --config${COLOR_RESET}                 Prompt for all configuration settings"
    echo -e "    ${COLOR_YELLOW}-D, --del-ssh-key${COLOR_RESET}            Delete SSH key pairs for remote user (skips pull operation)"
    echo -e "    ${COLOR_YELLOW}-f, --filter-sql${COLOR_RESET}             Filter SQL dump to remove privileged statements (slower import)"
    echo ""
    echo -e "    ${COLOR_YELLOW}-e, --exclude ${COLOR_RESET}LIST           Space-delimited list of paths to exclude (quote the list)"
    echo -e "                                    Example: -e \"wp-content/plugins wp-content/themes/mytheme myfile.js\""
    echo -e "    ${COLOR_YELLOW}-p, --install-plugins${COLOR_RESET} LIST   Space-delimited list of plugins to install locally"
    echo -e "                                    Example: --install-plugins \"woocommerce contact-form-7\""
    echo -e "    ${COLOR_YELLOW}-r, --remote-cmds${COLOR_RESET} CMD        Run custom commands on local site after pull (quote the commands)"
    echo -e "                                    Example: --remote-cmds \"wp theme install twentytwenty\""
    echo ""
    echo -e "    ${COLOR_BOLD_CYAN}Option Flags:${COLOR_RESET}"
    echo -e "    ${COLOR_YELLOW}--search-replace${COLOR_RESET}             Run wp search-replace (default: yes)"
    echo -e "    ${COLOR_YELLOW}--no-search-replace${COLOR_RESET}          Skip wp search-replace"
    echo -e "    ${COLOR_YELLOW}--files-only${COLOR_RESET}                 Skip database operations (default: no)"
    echo -e "    ${COLOR_YELLOW}--no-db-import${COLOR_RESET}               Don't import database locally (default: no)"
    echo -e "    ${COLOR_YELLOW}--exclude-wpconfig${COLOR_RESET}           Exclude wp-config.php (default: yes)"
    echo -e "    ${COLOR_YELLOW}--no-exclude-wpconfig${COLOR_RESET}        Include wp-config.php in sync"
    echo -e "    ${COLOR_YELLOW}--disable-wp-debug${COLOR_RESET}           Disable WP_DEBUG temporarily on local (default: no)"
    echo -e "    ${COLOR_YELLOW}--all-tables-with-prefix${COLOR_RESET}     Use --all-tables-with-prefix for wp search-replace (default: no)"
    echo -e "    ${COLOR_YELLOW}-n, --dry-run${COLOR_RESET}                Simulate the operation without making destructive changes"
    echo -e "    ${COLOR_YELLOW}--backup-db${COLOR_RESET}                  Backup the destination DB before importing (timestamped .sql file)"
    echo -e "    ${COLOR_YELLOW}--log${COLOR_RESET} FILE                   Write all output to FILE in addition to terminal"
    echo -e "    ${COLOR_YELLOW}-v, --version${COLOR_RESET}                Show version and exit"
    echo ""
    echo -e "${COLOR_BOLD_GREEN}EXAMPLES:${COLOR_RESET}"
    echo "    # Run with interactive prompts for configuration"
    echo "    $0 --config"
    echo ""
    echo "    # Run in unattended mode with custom exclusions"
    echo "    $0 -u -e \"uploads .maintenance .git\""
    echo ""
    echo "    # Files only, no database operations"
    echo "    $0 --files-only"
    echo ""
    echo "    # Disable search-replace operation"
    echo "    $0 --no-search-replace"
    echo ""
    echo "    # Delete SSH key pairs for remote user"
    echo "    $0 --del-ssh-key"
    echo ""
    echo -e "${COLOR_BOLD_GREEN}REQUIREMENTS:${COLOR_RESET}"
    echo "    - WP-CLI installed on both local and remote servers"
    echo "    - SSH access to remote server (ssh key pair generator included)"
    echo ""
    echo -e "${COLOR_BOLD_GREEN}CONFIGURATION:${COLOR_RESET}"
    echo "    Configuration is saved to ~/.wp-pull-remote.conf after using --config"
    echo "    and automatically loaded on subsequent runs."
    echo ""
    echo "    Default path structure: /sites/{domain}/files"
    echo "    URLs and search-replace paths are auto-detected from your configuration."
    echo ""
    echo "    Use --config to configure or reconfigure settings interactively."
    echo ""
    exit 0
}

####################################################################################
# DEFAULT CONFIGURATION - Can be overridden via --config option
####################################################################################

# Configuration file location
config_file="${HOME}/.wp-pull-remote.conf"

# LOCAL (destination of pull)
source_path_prefix="" # use trailing slash
source_webroot="files" # no preceding or trailing slash

# REMOTE (source of pull)
remote_ip_address=""
remote_user=""
remote_path_prefix="" # use trailing slash
remote_webroot="files" # no preceding or trailing slash
plugins_to_install="" # space separated list of plugins to install locally after pull

# WP-CLI search-replace (will be auto-derived from paths if not set)
# rewrites for URLs - NOTE: pull reverses direction (remote_url -> source_url)
wp_search_replace_source_url=''
local_url=''  # explicit local URL override (overrides DB detection for search-replace)
wp_search_replace_remote_url=''
# rewrites for file paths
wp_search_replace_source_path=''
wp_search_replace_remote_path=''

# Options flags (1 = YES, 0 = NO)
do_search_replace=1    # run 'wp search-replace' locally after import
files_only=0           # don't do a database dump & import
no_db_import=0         # don't run db import locally
install_plugins=0      # install plugins locally after pull
remote_commands=""     # custom commands to run on local site after pull
exclude_wpconfig=1     # exclude the wp-config.php file from rsync, you probably don't want to change this
unattended_mode=0      # flag for unattended mode
disable_wp_debug=0     # disable WP_DEBUG on local for the duration of the pull, then revert back
prompt_config=0        # flag to prompt for configuration
delete_ssh_keys=0      # flag to delete SSH key pairs
all_tables_with_prefix=0  # use --all-tables-with-prefix option for wp search-replace commands
filter_sql=0           # filter SQL dump to remove privileged statements (can add processing time)
dry_run=0              # dry-run mode: show what would happen without executing destructive steps
backup_db=0            # backup existing destination DB before importing (creates timestamped .sql file)
log_file=""            # optional path to write a copy of all output

# Load saved configuration if it exists
load_config() {
    if [[ -f "$config_file" ]]; then
        print_info "Loading saved configuration from $config_file"
        source "$config_file"
    fi
}

# Save configuration to file
save_config() {
    cat > "$config_file" << EOF
# WP Pull Remote Configuration
# Generated on $(date)

source_path_prefix="$source_path_prefix"
source_webroot="$source_webroot"
remote_ip_address="$remote_ip_address"
remote_user="$remote_user"
remote_path_prefix="$remote_path_prefix"
remote_webroot="$remote_webroot"
local_url="$local_url"
EOF
    chmod 600 "$config_file"
    print_success "Configuration saved to $config_file"
}

# Function to delete SSH key pairs
delete_ssh_key_pairs() {
    print_header "SSH KEY DELETION"
    
    # Check if configuration is loaded
    if [[ -z "$remote_user" ]]; then
        print_error "No configuration found. Please run with --config first."
        exit 1
    fi
    
    # Find matching SSH keys
    local ssh_dir="${HOME}/.ssh"
    local key_pattern="id_*_remote_${remote_user}"
    
    print_info "Searching for SSH key pairs matching pattern: ${key_pattern}"
    
    # Find all matching keys
    local found_keys=0
    local deleted_keys=0
    
    # Look for Ed25519 keys
    if [[ -f "${ssh_dir}/id_ed25519_remote_${remote_user}" ]]; then
        found_keys=$((found_keys + 1))
        print_step "Found Ed25519 key pair: id_ed25519_remote_${remote_user}"
        
        if [[ -f "${ssh_dir}/id_ed25519_remote_${remote_user}.pub" ]]; then
            print_info "  - Private key: ${ssh_dir}/id_ed25519_remote_${remote_user}"
            print_info "  - Public key: ${ssh_dir}/id_ed25519_remote_${remote_user}.pub"
        fi
        
        rm -fv "${ssh_dir}/id_ed25519_remote_${remote_user}" "${ssh_dir}/id_ed25519_remote_${remote_user}.pub"
        deleted_keys=$((deleted_keys + 1))
    fi
    
    # Look for RSA keys
    if [[ -f "${ssh_dir}/id_rsa_remote_${remote_user}" ]]; then
        found_keys=$((found_keys + 1))
        print_step "Found RSA key pair: id_rsa_remote_${remote_user}"
        
        if [[ -f "${ssh_dir}/id_rsa_remote_${remote_user}.pub" ]]; then
            print_info "  - Private key: ${ssh_dir}/id_rsa_remote_${remote_user}"
            print_info "  - Public key: ${ssh_dir}/id_rsa_remote_${remote_user}.pub"
        fi
        
        rm -fv "${ssh_dir}/id_rsa_remote_${remote_user}" "${ssh_dir}/id_rsa_remote_${remote_user}.pub"
        deleted_keys=$((deleted_keys + 1))
    fi
    
    if [[ $found_keys -eq 0 ]]; then
        print_warning "No SSH key pairs found for remote user '${remote_user}'"
    else
        print_success "Deleted ${deleted_keys} SSH key pair(s) for remote user '${remote_user}'"
        print_warning "IMPORTANT: You must MANUALLY remove the public key from the remote server's authorized_keys file:"
        print_warning "  Remote user: ${remote_user}"
        print_warning "  Remote location: ~/.ssh/authorized_keys"
        print_warning "  Look for keys with 'remote_${remote_user}' in the comment"
    fi
    
    exit 0
}

# Extract domain from path (e.g., /sites/example.com/ -> example.com)
extract_domain_from_path() {
    local path="$1"
    # Remove trailing slash and extract domain between /sites/ and next /
    echo "$path" | sed -E 's#^.*/sites/([^/]+).*$#\1#'
}

# Derive URL from path (e.g., /sites/example.com/files -> //example.com)
derive_url_from_path() {
    local path_prefix="$1"
    local domain=$(extract_domain_from_path "$path_prefix")
    if [[ -n "$domain" && "$domain" != "$path_prefix" ]]; then
        echo "//$domain"
    else
        echo ""
    fi
}

# Excludes for rsync from remote (edit as required)
excludes=(.git .maintenance wp-content/cache wp-content/uploads/wp-migrate-db /wp-content/updraft)
# Or just add to the array like this:
# excludes+=(.user.ini)

####################################################################################
# NO MORE EDITING BELOW THIS LINE!
####################################################################################

# Cleanup function for script interruption
cleanup_on_exit() {
    local exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        print_error "\nScript interrupted or failed with exit code: $exit_code"
        # Clean up any temporary database files on local
        if [[ -n "${source_path}" ]] && [[ -n "${db_export_prefix}" ]] && [[ -n "${rnd_str_key}" ]]; then
            if ls "${source_path}/${db_export_prefix}"*"${rnd_str_key}.sql" >/dev/null 2>&1; then
                print_info "Cleaning up temporary database files on local..."
                rm -f "${source_path}/${db_export_prefix}"*"${rnd_str_key}.sql"
            fi
        fi
        # Clean up database export from remote server if it was created
        if [[ -n "${ssh_key_path}" ]] && [[ -n "${remote_user}" ]] && [[ -n "${remote_ip_address}" ]] && \
           [[ -n "${remote_path}" ]] && [[ -n "${db_export_prefix}" ]] && [[ -n "${rnd_str_key}" ]]; then
            print_info "Attempting to clean up database export from remote server..."
            ssh -q -T -i "${ssh_key_path}" ${SSH_OPTS:-} ${remote_user}@${remote_ip_address} \
                "rm -f ${remote_path}/${db_export_prefix}*${rnd_str_key}.sql" 2>/dev/null || true
        fi
    fi
}

# Set trap for cleanup
trap 'release_lock; cleanup_on_exit' EXIT INT TERM

# Validate configuration
validate_config() {
    local errors=0
    
    # Check OS (Ubuntu only)
    if [[ ! -f /etc/os-release ]]; then
        print_error "Cannot detect OS. This script is designed for Ubuntu 22.04+."
        errors=$((errors + 1))
    else
        source /etc/os-release
        if [[ "$ID" != "ubuntu" ]]; then
            print_warning "This script is optimized for Ubuntu. Detected: $ID"
            print_info "Continuing anyway, but some features may not work as expected."
        elif [[ -n "$VERSION_ID" ]]; then
            # Pure bash version comparison (no bc required)
            local version_major="${VERSION_ID%%.*}"
            local version_minor="${VERSION_ID#*.}"
            if (( version_major < 24 || (version_major == 24 && ${version_minor%%.*} < 4) )); then
                print_warning "This script is optimized for Ubuntu 22.04+. Detected: Ubuntu $VERSION_ID"
            fi
        fi
    fi
    
    # Check required commands
    local required_cmds=("wp" "rsync" "ssh" "ssh-keygen")
    for cmd in "${required_cmds[@]}"; do
        if ! command_exists "$cmd"; then
            print_error "Required command not found: $cmd"
            case $cmd in
                wp)
                    print_info "Install WP-CLI: curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && sudo mv wp-cli.phar /usr/local/bin/wp"
                    ;;
                rsync|ssh|ssh-keygen)
                    print_info "Install with: sudo apt install openssh-client rsync"
                    ;;
            esac
            errors=$((errors + 1))
        fi
    done
    
    if [[ -z "$remote_ip_address" ]]; then
        print_error "Remote IP address is not set!"
        errors=$((errors + 1))
    fi
    
    if [[ -z "$remote_user" ]]; then
        print_error "Remote user is not set!"
        errors=$((errors + 1))
    fi
    
    if [[ -z "$source_path_prefix" ]]; then
        print_error "Local path prefix is not set!"
        errors=$((errors + 1))
    fi
    
    if [[ -z "$remote_path_prefix" ]]; then
        print_error "Remote path prefix is not set!"
        errors=$((errors + 1))
    fi
    
    if [[ $errors -gt 0 ]]; then
        print_error "Configuration validation failed. Please set required variables."
        print_info "Use --config to set configuration interactively or edit the script."
        exit 1
    fi
}

# Normalize paths to ensure trailing slashes where needed
normalize_paths() {
    # Add trailing slash if not present
    [[ "$source_path_prefix" != */ ]] && source_path_prefix="${source_path_prefix}/"
    [[ "$remote_path_prefix" != */ ]] && remote_path_prefix="${remote_path_prefix}/"
    
    # Remove leading/trailing slashes from webroot
    source_webroot="${source_webroot#/}"
    source_webroot="${source_webroot%/}"
    remote_webroot="${remote_webroot#/}"
    remote_webroot="${remote_webroot%/}"
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Generate random string using Ubuntu's tools
generate_random_string() {
    # Ubuntu 22.04+ has md5sum by default
    echo "$RANDOM" | md5sum | head -c 12
}

# Function to handle user prompts
function user_prompt() {
    if [[ $unattended_mode -eq 0 ]]; then
        while true; do
            read -p "$(echo -e "\\n${COLOR_YELLOW}CONFIRM:${COLOR_RESET} ${1} ${COLOR_GREEN}Are you sure? [Yes/no]${COLOR_RESET} ") " user_input
            case $user_input in
                [Yy]* ) return 0;;
                "" ) return 0;;
                [Nn]* ) return 1;;
                * ) echo -e "${COLOR_YELLOW}Please respond yes [Y/y/{enter}] or no [n].${COLOR_RESET}";;
            esac
        done
    else
        print_info "CONFIRM: ${1} - Assuming YES in unattended mode."
        return 0
    fi
}

# Function to handle user prompts with default NO
function user_prompt_default_no() {
    if [[ $unattended_mode -eq 0 ]]; then
        while true; do
            read -p "$(echo -e "\\n${COLOR_YELLOW}CONFIRM:${COLOR_RESET} ${1} ${COLOR_GREEN}[y/yes to confirm, Enter to skip]${COLOR_RESET} ") " user_input
            case $user_input in
                [Yy]* ) return 0;;
                "" ) return 1;;
                [Nn]* ) return 1;;
                * ) echo -e "${COLOR_YELLOW}Please respond yes [Y/y] to confirm or press Enter to skip.${COLOR_RESET}";;
            esac
        done
    else
        print_info "CONFIRM: ${1} - Assuming NO in unattended mode."
        return 1
    fi
}

# Function to prompt for configuration
function prompt_for_config() {
    print_header "CONFIGURATION SETUP"
    
    print_info "Let's configure the LOCAL (destination) and REMOTE (source) settings."
    print_info "Press Enter to accept defaults shown in [brackets]"
    echo ""
    
    # LOCAL configuration
    print_step "LOCAL Configuration (destination of pull)"
    
    # Detect current domain from hostname or use saved value
    local current_domain=$(hostname -f 2>/dev/null || hostname)
    local default_source_prefix="${source_path_prefix:-/sites/${current_domain}/}"
    local default_source_webroot="${source_webroot:-files}"
    
    read -p "$(echo -e "${COLOR_CYAN}Local path prefix${COLOR_RESET} [${default_source_prefix}]: ")" input_source_path_prefix
    source_path_prefix="${input_source_path_prefix:-$default_source_prefix}"
    
    read -p "$(echo -e "${COLOR_CYAN}Local webroot${COLOR_RESET} [${default_source_webroot}]: ")" input_source_webroot
    source_webroot="${input_source_webroot:-$default_source_webroot}"
    
    # REMOTE configuration
    print_step "REMOTE Configuration (source of pull)"
    
    # Extract source domain for remote default
    local source_domain=$(extract_domain_from_path "$source_path_prefix")
    local default_remote_prefix="${remote_path_prefix:-/sites/${source_domain}/}"
    local default_remote_webroot="${remote_webroot:-files}"
    
    read -p "$(echo -e "${COLOR_CYAN}Remote IP address or hostname${COLOR_RESET} [${remote_ip_address}]: ")" input_remote_ip
    remote_ip_address="${input_remote_ip:-$remote_ip_address}"
    
    read -p "$(echo -e "${COLOR_CYAN}Remote SSH user${COLOR_RESET} [${remote_user:-$(whoami)}]: ")" input_remote_user
    remote_user="${input_remote_user:-${remote_user:-$(whoami)}}"
    
    read -p "$(echo -e "${COLOR_CYAN}Remote path prefix${COLOR_RESET} [${default_remote_prefix}]: ")" input_remote_path_prefix
    remote_path_prefix="${input_remote_path_prefix:-$default_remote_prefix}"
    
    read -p "$(echo -e "${COLOR_CYAN}Remote webroot${COLOR_RESET} [${default_remote_webroot}]: ")" input_remote_webroot
    remote_webroot="${input_remote_webroot:-$default_remote_webroot}"
    
    # Save configuration
    save_config
}

####################################################################################
# Process command line arguments
####################################################################################

# Parse long options
TEMP=$(getopt -o hucDfe:r:p:nv --long help,unattended,config,del-ssh-key,filter-sql,exclude:,search-replace,no-search-replace,files-only,no-db-import,install-plugins:,remote-cmds:,exclude-wpconfig,no-exclude-wpconfig,disable-wp-debug,all-tables-with-prefix,dry-run,backup-db,log:,version -n "$0" -- "$@" 2>/dev/null)

# Check for getopt errors
if [[ $? -ne 0 ]]; then
    # Fallback to basic getopts if getopt is not available or fails
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            -u|--unattended)
                unattended_mode=1
                shift
                ;;
            -c|--config)
                prompt_config=1
                shift
                ;;
            -D|--del-ssh-key)
                delete_ssh_keys=1
                shift
                ;;
            -f|--filter-sql)
                filter_sql=1
                shift
                ;;
            -e|--exclude)
                if [[ -z "$2" ]]; then
                    print_error "--exclude requires an argument"
                    exit 1
                fi
                # Parse space-delimited list and add to excludes array
                read -ra exclude_items <<< "$2"
                excludes+=("${exclude_items[@]}")
                shift 2
                ;;
            --search-replace)
                do_search_replace=1
                shift
                ;;
            --no-search-replace)
                do_search_replace=0
                shift
                ;;
            --files-only)
                files_only=1
                shift
                ;;
            --no-db-import)
                no_db_import=1
                shift
                ;;
            -p|--install-plugins)
                if [[ -z "$2" ]]; then
                    print_error "--install-plugins requires a space-delimited list of plugins"
                    exit 1
                fi
                plugins_to_install="$2"
                install_plugins=1
                shift 2
                ;;
            -r|--remote-cmds)
                if [[ -z "$2" ]]; then
                    print_error "--remote-cmds requires a quoted string of commands"
                    exit 1
                fi
                remote_commands="$2"
                shift 2
                ;;
            --exclude-wpconfig)
                exclude_wpconfig=1
                shift
                ;;
            --no-exclude-wpconfig)
                exclude_wpconfig=0
                shift
                ;;
            --disable-wp-debug)
                disable_wp_debug=1
                shift
                ;;
            --all-tables-with-prefix)
                all_tables_with_prefix=1
                shift
                ;;
            -n|--dry-run)
                dry_run=1
                shift
                ;;
            --backup-db)
                backup_db=1
                shift
                ;;
            --log)
                if [[ -z "$2" ]]; then
                    print_error "--log requires a file path"
                    exit 1
                fi
                log_file="$2"
                shift 2
                ;;
            -v|--version)
                echo "$(basename "$0") v${script_version}"
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
else
    eval set -- "$TEMP"

    while true; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            -u|--unattended)
                unattended_mode=1
                shift
                ;;
            -c|--config)
                prompt_config=1
                shift
                ;;
            -D|--del-ssh-key)
                delete_ssh_keys=1
                shift
                ;;
            -f|--filter-sql)
                filter_sql=1
                shift
                ;;
            -e|--exclude)
                # Parse space-delimited list and add to excludes array
                read -ra exclude_items <<< "$2"
                excludes+=("${exclude_items[@]}")
                shift 2
                ;;
            --search-replace)
                do_search_replace=1
                shift
                ;;
            --no-search-replace)
                do_search_replace=0
                shift
                ;;
            --files-only)
                files_only=1
                shift
                ;;
            --no-db-import)
                no_db_import=1
                shift
                ;;
            -p|--install-plugins)
                plugins_to_install="$2"
                install_plugins=1
                shift 2
                ;;
            -r|--remote-cmds)
                remote_commands="$2"
                shift 2
                ;;
            --exclude-wpconfig)
                exclude_wpconfig=1
                shift
                ;;
            --no-exclude-wpconfig)
                exclude_wpconfig=0
                shift
                ;;
            --disable-wp-debug)
                disable_wp_debug=1
                shift
                ;;
            --all-tables-with-prefix)
                all_tables_with_prefix=1
                shift
                ;;
            -n|--dry-run)
                dry_run=1
                shift
                ;;
            --backup-db)
                backup_db=1
                shift
                ;;
            --log)
                log_file="$2"
                shift 2
                ;;
            -v|--version)
                echo "$(basename "$0") v${script_version}"
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
fi

####################################################################################
# Set up
####################################################################################

# Clear the screen
clear

# Show banner
print_header "WP Pull Remote v${script_version}"

# Load saved configuration (unless prompting for new config)
if [[ $prompt_config -eq 0 ]]; then
    load_config
fi

# Prompt for configuration if requested
if [[ $prompt_config -eq 1 ]]; then
    prompt_for_config
fi

# Set up log file tee if specified
if [[ -n "$log_file" ]]; then
    exec > >(tee -a "$log_file") 2>&1
    print_info "Logging output to: $log_file"
fi

# Acquire process lock to prevent concurrent runs
acquire_lock

# SSH options applied to all SSH/rsync connections
SSH_OPTS="-o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# Handle SSH key deletion if requested
if [[ $delete_ssh_keys -eq 1 ]]; then
    delete_ssh_key_pairs
fi

# Normalize paths
normalize_paths

# Validate configuration
validate_config

# Check for WP-CLI
if ! command_exists wp; then
    print_error "WP-CLI is not installed or not in PATH"
    print_info "Please install WP-CLI: https://wp-cli.org/#installing"
    exit 1
fi

# Set up random rnd_str for database backup filename
rnd_str=$(generate_random_string)
rnd_str_key="38fh"

# Set paths / prefixes
db_export_prefix="wp_db_export_"
source_path="${source_path_prefix}${source_webroot}"
remote_path="${remote_path_prefix}${remote_webroot}"
source_db_name="${db_export_prefix}${rnd_str}${rnd_str_key}.sql"
current_user=$(whoami)

# Auto-detect local webroot: if wp-config.php not found at configured path, try files/public
if [[ ! -f "${source_path}/wp-config.php" && -f "${source_path_prefix}files/public/wp-config.php" ]]; then
    source_webroot="files/public"
    source_path="${source_path_prefix}${source_webroot}"
    print_info "Auto-detected local webroot: ${source_path}"
fi

# Auto-assign paths for search-replace if not already set
if [[ -z "$wp_search_replace_source_path" ]]; then
    wp_search_replace_source_path="$source_path"
fi
if [[ -z "$wp_search_replace_remote_path" ]]; then
    wp_search_replace_remote_path="$remote_path"
fi

if (( exclude_wpconfig == 1 )); then
    excludes+=(wp-config.php)
fi

# Get hostname IP (handle multiple IPs)
local_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || hostname)

print_step "START WP PULL site FROM ${remote_ip_address} TO ${local_ip}"
print_info "Script: 'wp-pull-remote.sh' v${script_version}"

# Detect LOCAL (destination) URL before any operations - this is what we replace TO after import
if [[ -f "${source_path}/wp-config.php" ]]; then
    source_url=$(wp option get siteurl --path="${source_path}" 2>/dev/null || echo "")
    # Prefer explicit local_url from config over DB-detected URL (DB may contain old remote URL after a prior import)
    if [[ -n "$local_url" ]]; then
        print_info "Local URL: ${local_url} (from config)"
        if [[ -z "$wp_search_replace_source_url" ]]; then
            wp_search_replace_source_url="$local_url"
        fi
    elif [[ -n "$source_url" ]]; then
        print_info "Local URL: ${source_url}"
        if [[ -z "$wp_search_replace_source_url" ]]; then
            wp_search_replace_source_url="$source_url"
        fi
    else
        print_info "Local URL: Unable to detect (WP-CLI may not be configured)"
    fi
else
    print_info "Local URL: Not detected (WordPress not found at ${source_path})"
fi

echo -e "${COLOR_CYAN}Remote (source):${COLOR_RESET} ${remote_user}@${remote_ip_address}:${remote_path}"
echo -e "${COLOR_CYAN}Local (destination):${COLOR_RESET} ${current_user}@${source_path}"
echo -e "${COLOR_CYAN}Excludes:${COLOR_RESET} ${excludes[*]}"
if [[ -n "${plugins_to_install}" ]]; then
    echo -e "${COLOR_CYAN}Plugins to install:${COLOR_RESET} ${plugins_to_install}"
fi
if [[ -n "${remote_commands}" ]]; then
    echo -e "${COLOR_CYAN}Post-pull commands:${COLOR_RESET} ${remote_commands}"
fi

# Display option flags
print_info "Configuration Flags:"
echo -e "  ${COLOR_CYAN}do_search_replace:${COLOR_RESET} $(bool_display $do_search_replace)"
echo -e "  ${COLOR_CYAN}files_only:${COLOR_RESET} $(bool_display $files_only)"
echo -e "  ${COLOR_CYAN}no_db_import:${COLOR_RESET} $(bool_display $no_db_import)"
echo -e "  ${COLOR_CYAN}exclude_wpconfig:${COLOR_RESET} $(bool_display $exclude_wpconfig)"
echo -e "  ${COLOR_CYAN}disable_wp_debug:${COLOR_RESET} $(bool_display $disable_wp_debug)"
echo -e "  ${COLOR_CYAN}all_tables_with_prefix:${COLOR_RESET} $(bool_display $all_tables_with_prefix)"
echo -e "  ${COLOR_CYAN}filter_sql:${COLOR_RESET} $(bool_display $filter_sql)"
echo -e "  ${COLOR_CYAN}dry_run:${COLOR_RESET} $(bool_display $dry_run)"
echo -e "  ${COLOR_CYAN}backup_db:${COLOR_RESET} $(bool_display $backup_db)"

if (( dry_run == 1 )); then
    echo ""
    echo -e "${COLOR_BOLD_YELLOW}╔══════════════════════════════════════════╗${COLOR_RESET}"
    echo -e "${COLOR_BOLD_YELLOW}║  DRY-RUN MODE: No changes will be made  ║${COLOR_RESET}"
    echo -e "${COLOR_BOLD_YELLOW}╚══════════════════════════════════════════╝${COLOR_RESET}"
    echo ""
fi

if (( filter_sql == 1 )); then
    print_warning "SQL filtering is ENABLED (-f/--filter-sql). Import step may take longer."
fi

# Check for existing SSH keys (Ed25519 preferred, RSA fallback)
ssh_key_path=""
if [[ -f ~/.ssh/id_ed25519_remote_${remote_user} ]]; then
    ssh_key_path=~/.ssh/id_ed25519_remote_${remote_user}
    print_info "Using existing Ed25519 SSH key: ${ssh_key_path}"
elif [[ -f ~/.ssh/id_rsa_remote_${remote_user} ]]; then
    ssh_key_path=~/.ssh/id_rsa_remote_${remote_user}
    print_info "Using existing RSA SSH key: ${ssh_key_path}"
fi

# If no key exists, offer to generate one
if [[ -z "$ssh_key_path" ]]; then
    if [[ $unattended_mode -eq 0 ]]; then
        if ( user_prompt "No SSH key found - OK to generate one now?" ); then
            # Generate SSH key (ed25519 is preferred on Ubuntu 22.04+ for better performance and security)
            print_info "Generating Ed25519 SSH key (recommended for Ubuntu 22.04+)..."
            if ssh-keygen -t ed25519 -C "${current_user}@${local_ip} - Added by wp-pull-remote.sh" -f ~/.ssh/id_ed25519_remote_${remote_user} -N ""; then
                # Set proper permissions
                chmod 600 ~/.ssh/id_ed25519_remote_${remote_user}
                chmod 644 ~/.ssh/id_ed25519_remote_${remote_user}.pub
                ssh_key_path=~/.ssh/id_ed25519_remote_${remote_user}
                print_success "SSH key generated: ${ssh_key_path}"
                echo -e "\n${COLOR_BOLD_YELLOW}Public key:${COLOR_RESET}\n"
                cat ${ssh_key_path}.pub
                echo -e "\n\n${COLOR_BOLD_YELLOW}IMPORTANT:${COLOR_RESET} Add this key to the REMOTE server's authorized_keys file for user '${remote_user}'"
            else
                print_error "Failed to generate SSH key"
                exit 1
            fi
        else
            print_error "ABORTED!"
            exit 1
        fi
    else
        print_warning "No SSH key found - Skipping key generation in unattended mode."
        print_warning "Script may fail if SSH authentication is not configured."
        # Set a default path anyway for potential failure later
        ssh_key_path=~/.ssh/id_ed25519_remote_${remote_user}
    fi
fi

if [[ $unattended_mode -eq 0 ]]; then
    print_step "Testing SSH connection to ${remote_user}@${remote_ip_address} ..."
    print_info "If this hangs, check SSH key setup. Timeout: 15s"
    if ssh -q -T -i "${ssh_key_path}" ${SSH_OPTS} ${remote_user}@${remote_ip_address} "echo 'SSH OK'" >/dev/null 2>&1; then
        print_success "SSH connection verified"
    else
        print_error "SSH connection failed to ${remote_user}@${remote_ip_address}"
        print_info "Check: key at ${ssh_key_path}, remote authorized_keys for user '${remote_user}'"
        if ! ( user_prompt "SSH test failed - proceed anyway?" ); then
            print_error "ABORTED!"
            exit 1
        fi
    fi
else
    print_info "Skipping SSH connection test in unattended mode."
fi

# Auto-detect remote webroot: if wp-config.php not found at configured path, try files/public
_remote_wp_check=$(ssh -q -T -i "${ssh_key_path}" ${SSH_OPTS} ${remote_user}@${remote_ip_address} \
    "test -f '${remote_path}/wp-config.php' && echo 'found' || (test -f '${remote_path_prefix}files/public/wp-config.php' && echo 'public' || echo 'notfound')" 2>/dev/null || echo "")
if [[ "$_remote_wp_check" == "public" ]]; then
    _old_remote_path="$remote_path"
    remote_webroot="files/public"
    remote_path="${remote_path_prefix}${remote_webroot}"
    # Only update wp_search_replace_remote_path if it was auto-assigned from remote_path
    # (i.e. the user did not set a custom value). Strict equality is safe here because
    # normalize_paths() has already stripped any leading/trailing slashes.
    [[ "$wp_search_replace_remote_path" == "$_old_remote_path" ]] && wp_search_replace_remote_path="$remote_path"
    print_info "Auto-detected remote webroot: ${remote_path}"
fi
unset _remote_wp_check _old_remote_path

if ( ! user_prompt "Proceed with the site PULL?"); then
    print_error "ABORTED!"
    exit 1
fi

####################################################################################
# Run PULL
####################################################################################

print_header "STARTING PULL OPERATION"

# Record start time
start_time=$(date +%s)

if (( files_only == 0 && dry_run == 1 )); then
    print_info "[DRY-RUN] Would export remote database at ${remote_path}/${source_db_name}"
fi

if (( files_only == 0 && dry_run == 0 )); then
    # Export database on REMOTE server
    print_step "EXPORTING database on REMOTE (${remote_ip_address}) ..."
    if ssh -q -T -i "${ssh_key_path}" ${SSH_OPTS} ${remote_user}@${remote_ip_address} "wp db export ${remote_path}/${source_db_name} --path='${remote_path}'"; then
        print_success "Database exported on remote successfully"
    else
        print_error "Failed to export database on remote"
        exit 1
    fi
fi

# Check local disk space before pulling
if [[ $dry_run -eq 0 ]]; then
    check_disk_space "$(dirname "${source_path}")" "${source_path}" || print_warning "Continuing despite disk space warning..."
fi

# Pull files from remote to local
print_step "RSYNC-ing files FROM REMOTE to LOCAL ..."

# run rsync with exclusions (direction reversed: remote -> local)
rsync_dry_flag=""
(( dry_run == 1 )) && rsync_dry_flag="--dry-run"
if rsync -e "ssh -i \"${ssh_key_path}\" ${SSH_OPTS}" -azhP --delete ${rsync_dry_flag} $(printf -- "--exclude=%q " "${excludes[@]}") ${remote_user}@${remote_ip_address}:${remote_path}/ ${source_path}/; then
    print_success "Files synced successfully"
else
    print_error "Rsync failed"
    exit 1
fi

# Detect REMOTE URL after rsync (remote DB is unchanged; detect before local DB import)
# Used as the search term in search-replace (the URL currently in the imported DB)
if (( do_search_replace == 1 && files_only == 0 && no_db_import == 0 )); then
    if [[ -z "${wp_search_replace_remote_url}" ]]; then
        print_info "Detecting remote site URL for search-replace..."
        wp_search_replace_remote_url=$(ssh -q -T -i "${ssh_key_path}" ${SSH_OPTS} ${remote_user}@${remote_ip_address} "wp option get siteurl --path='${remote_path}' 2>/dev/null" | tr -d '\n')
        if [[ -n "$wp_search_replace_remote_url" ]]; then
            print_info "Remote URL detected: ${wp_search_replace_remote_url}"
        else
            print_warning "Unable to detect remote URL - search-replace may not work correctly"
        fi
    fi
fi

# Check and synchronize table prefixes if database operations are enabled
# For pull: local prefix must match remote prefix (the data being imported)
if (( files_only == 0 && no_db_import == 0 )); then
    print_step "Checking table prefix compatibility ..."
    
    # Get remote table prefix (source of data being imported)
    remote_table_prefix=$(ssh -q -T -i "${ssh_key_path}" ${SSH_OPTS} ${remote_user}@${remote_ip_address} "wp db prefix --path='${remote_path}' 2>/dev/null" | tr -d '\n')
    if [[ -z "$remote_table_prefix" ]]; then
        print_warning "Unable to detect remote table prefix"
    else
        print_info "Remote table prefix: ${remote_table_prefix}"
    fi
    
    # Get local table prefix using wp-cli
    source_table_prefix=$(wp db prefix --path="${source_path}" 2>/dev/null | tr -d '\n')
    if [[ -z "$source_table_prefix" ]]; then
        print_warning "Unable to detect local table prefix"
    else
        print_info "Local table prefix: ${source_table_prefix}"
    fi
    
    # Compare prefixes and synchronize local to match remote if needed
    if [[ -n "$remote_table_prefix" && -n "$source_table_prefix" && "$remote_table_prefix" != "$source_table_prefix" ]]; then
        print_warning "Table prefix mismatch detected!"
        print_warning "  Remote: ${remote_table_prefix}"
        print_warning "  Local:  ${source_table_prefix}"
        echo ""
        
        if (( unattended_mode == 0 )); then
            if ( user_prompt "Synchronize local table prefix to match remote?" ); then
                print_step "Resetting local database and updating table prefix ..."
                wp db reset --yes --path="${source_path}"
                wp config set table_prefix "${remote_table_prefix}" --path="${source_path}"
                if [[ $? -eq 0 ]]; then
                    print_success "Local table prefix synchronized to: ${remote_table_prefix}"
                else
                    print_error "Failed to synchronize local table prefix"
                    exit 1
                fi
            else
                print_warning "Continuing with mismatched table prefixes - import may fail!"
            fi
        else
            print_warning "Unattended mode: Skipping table prefix synchronization"
            print_warning "Database import may fail with mismatched prefixes!"
        fi
    elif [[ -n "$remote_table_prefix" && -n "$source_table_prefix" ]]; then
        print_success "Table prefixes match: ${remote_table_prefix}"
    fi
fi

# Run post-pull commands on LOCAL
print_step "EXECUTING post-pull operations on LOCAL (${local_ip})..."

if (( disable_wp_debug == 1 )); then
    echo -e "\n${COLOR_BLUE}Creating backup of wp-config.php ...${COLOR_RESET}"
    cp -v ${source_path}/wp-config.php ${source_path}/wp-config.php.bak
    echo -e "${COLOR_BLUE}Disabling WP_DEBUG in wp-config.php ...${COLOR_RESET}"
    sed -i "s/define(\s*'WP_DEBUG'.*/define('WP_DEBUG', false);/g" ${source_path}/wp-config.php
fi

if (( files_only == 0 && no_db_import == 0 )); then

    # Optionally filter SQL on local before import
    if (( filter_sql == 1 )); then
        if [[ ! -s "${source_path}/${source_db_name}" ]]; then
            print_error "Database export file not found or empty: ${source_path}/${source_db_name}"
            exit 1
        fi
        print_info "Filtering SQL file to remove privileged statements..."
        local_filtered="${source_path}/${source_db_name}.filtered"
        if awk '
            BEGIN {
                in_gtid_block = 0
                kept_lines = 0
            }
            {
                line = $0
                lower = tolower(line)

                if (in_gtid_block == 1) {
                    if (line ~ /;[[:space:]]*$/) {
                        in_gtid_block = 0
                    }
                    next
                }

                if (lower ~ /set[[:space:]]*@@(global|session)\.gtid_purged/) {
                    if (line !~ /;[[:space:]]*$/) {
                        in_gtid_block = 1
                    }
                    next
                }

                if (lower ~ /^[[:space:]]*set[[:space:]]+@@(session|global)\./) next
                if (lower ~ /^[[:space:]]*set[[:space:]]+@mysqldump_temp_log_bin/) next
                if (lower ~ /set[[:space:]]+sql_log_bin[[:space:]]*=/) next
                if (lower ~ /set[[:space:]]+@old_sql_log_bin[[:space:]]*=/) next
                if (lower ~ /\/\*![0-9]+[[:space:]]*set[[:space:]]+time_zone/) next
                if (lower ~ /\/\*![0-9]+[[:space:]]*set[[:space:]]+session[[:space:]]+sql_mode/) next
                if (lower ~ /\/\*![0-9]+[[:space:]]*set.*system_variables_admin/) next

                print line
                kept_lines++
            }
            END {
                if (kept_lines == 0) {
                    exit 42
                }
            }
        ' "${source_path}/${source_db_name}" > "$local_filtered"; then
            if [[ ! -s "$local_filtered" ]]; then
                print_error "Filtered SQL output is empty"
                rm -f "$local_filtered"
                exit 1
            fi
            mv "$local_filtered" "${source_path}/${source_db_name}"
            print_success "SQL filtered successfully"
        else
            rm -f "$local_filtered"
            print_warning "AWK filter failed - falling back to sed filter"
            sed -i -E \
                '/^[[:space:]]*[Ss][Ee][Tt][[:space:]]*@@[Gg][Ll][Oo][Bb][Aa][Ll]\.[Gg][Tt][Ii][Dd]_[Pp][Uu][Rr][Gg][Ee][Dd]/,/;[[:space:]]*$/d' \
                ${source_path}/${source_db_name}

            sed -i -E \
                -e '/^[[:space:]]*[Ss][Ee][Tt][[:space:]]+([Ss][Ee][Ss][Ss][Ii][Oo][Nn]|[Gg][Ll][Oo][Bb][Aa][Ll])[[:space:]]+/d' \
                -e '/^[[:space:]]*[Ss][Ee][Tt][[:space:]]*@@([Ss][Ee][Ss][Ss][Ii][Oo][Nn]|[Gg][Ll][Oo][Bb][Aa][Ll])\./d' \
                -e '/^[[:space:]]*[Ss][Ee][Tt][[:space:]]*@MYSQLDUMP_TEMP_LOG_BIN/d' \
                -e '/^[[:space:]]*[Ss][Ee][Tt][[:space:]]*@@[Ss][Ee][Ss][Ss][Ii][Oo][Nn]\.[Ss][Qq][Ll]_[Ll][Oo][Gg]_[Bb][Ii][Nn]/d' \
                -e '/\/\*![0-9]*[[:space:]]*[Ss][Ee][Tt][[:space:]]*[Tt][Ii][Mm][Ee]_[Zz][Oo][Nn][Ee]/d' \
                -e '/\/\*![0-9]*[[:space:]]*[Ss][Ee][Tt][[:space:]]*[Ss][Ee][Ss][Ss][Ii][Oo][Nn][[:space:]]*[Ss][Qq][Ll]_[Mm][Oo][Dd][Ee]/d' \
                -e '/\/\*![0-9]*[[:space:]]*[Ss][Ee][Tt].*[Ss][Yy][Ss][Tt][Ee][Mm]_[Vv][Aa][Rr][Ii][Aa][Bb][Ll][Ee][Ss]_[Aa][Dd][Mm][Ii][Nn]/d' \
                ${source_path}/${source_db_name}

            if [[ ! -s "${source_path}/${source_db_name}" ]]; then
                print_error "Legacy SQL filtering produced an empty file"
                exit 1
            fi
            print_success "Database filtered successfully (legacy mode)"
        fi
    fi

    if (( backup_db == 1 && dry_run == 0 )); then
        local_backup="${source_path}/wp-db-backup-$(date +%Y%m%d-%H%M%S).sql"
        print_step "BACKING UP existing local database before import ..."
        if wp db export "${local_backup}" --path="${source_path}"; then
            print_success "Local DB backed up to: ${local_backup}"
        else
            print_warning "Local DB backup failed - continuing anyway"
        fi
    elif (( backup_db == 1 && dry_run == 1 )); then
        print_info "[DRY-RUN] Would backup local database before import"
    fi

    echo -e "\n${COLOR_BLUE}IMPORTING database locally ...${COLOR_RESET}"
    if wp db import ${source_path}/${source_db_name} --path="${source_path}"; then
        echo -e "${COLOR_GREEN}Database imported successfully${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}[ERROR] Database import failed${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}[INFO] If you see 'Access denied' errors related to SUPER privileges, run with -f/--filter-sql to filter the dump.${COLOR_RESET}"
    fi
    echo -e "\n${COLOR_BLUE}DELETING local database import file ...${COLOR_RESET}"
    rm -v ${source_path}/${source_db_name}
fi

if (( do_search_replace == 1 && files_only == 0 && no_db_import == 0 )); then

    # Run search-replace for URLs: replace remote URL with local URL
    if [[ -n "${wp_search_replace_remote_url}" && -n "${wp_search_replace_source_url}" ]]; then
        echo -e "\n${COLOR_BLUE}EXECUTING 'wp search-replace' for URLs ...${COLOR_RESET}"
        echo "Replacing: ${wp_search_replace_remote_url} -> ${wp_search_replace_source_url}"
        if (( all_tables_with_prefix == 1 )); then
            replacement_count=$(wp search-replace --precise "${wp_search_replace_remote_url}" "${wp_search_replace_source_url}" --report-changed-only --format=count --all-tables-with-prefix --path="${source_path}")
        else
            replacement_count=$(wp search-replace --precise "${wp_search_replace_remote_url}" "${wp_search_replace_source_url}" --report-changed-only --format=count --path="${source_path}")
        fi
        echo "Total replacements made: ${replacement_count}"
    else
        echo -e "${COLOR_YELLOW}[WARNING] Skipping URL search-replace - local or remote URL not available${COLOR_RESET}"
    fi

    # Run search-replace for paths: replace remote path with local path
    if [[ -n "${wp_search_replace_remote_path}" && -n "${wp_search_replace_source_path}" ]]; then
        echo -e "\n${COLOR_BLUE}EXECUTING 'wp search-replace' for file PATHs ...${COLOR_RESET}"
        echo "Replacing: ${wp_search_replace_remote_path} -> ${wp_search_replace_source_path}"
        if (( all_tables_with_prefix == 1 )); then
            replacement_count=$(wp search-replace --precise "${wp_search_replace_remote_path}" "${wp_search_replace_source_path}" --report-changed-only --format=count --all-tables-with-prefix --path="${source_path}")
        else
            replacement_count=$(wp search-replace --precise "${wp_search_replace_remote_path}" "${wp_search_replace_source_path}" --report-changed-only --format=count --path="${source_path}")
        fi
        echo "Total replacements made: ${replacement_count}"
    else
        echo -e "${COLOR_YELLOW}[WARNING] Skipping path search-replace - local or remote path not available${COLOR_RESET}"
    fi
fi

# Flush cache once after all database operations
if (( files_only == 0 && no_db_import == 0 )); then
    echo -e "${COLOR_BLUE}FLUSHING WP cache locally ...${COLOR_RESET}"
    wp cache flush --hard --path="${source_path}"
fi

if (( install_plugins == 1 )) && [[ -n "${plugins_to_install}" ]]; then
    echo -e "\n${COLOR_BLUE}INSTALLING plugins locally ...${COLOR_RESET}"
    wp plugin install ${plugins_to_install} --path="${source_path}"
    wp cache flush --path="${source_path}"
fi

if [[ -n "${remote_commands}" ]]; then
    echo -e "\n${COLOR_BLUE}EXECUTING post-pull commands locally ...${COLOR_RESET}"
    # Run commands on local site - split by semicolon and process each one
    IFS=';' read -ra CMD_ARRAY <<< "${remote_commands}"
    for cmd in "${CMD_ARRAY[@]}"; do
        # Trim leading/trailing whitespace
        cmd=$(echo "$cmd" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        # If the command starts with 'wp' and doesn't contain --path, add it automatically
        if [[ "$cmd" =~ ^wp[[:space:]] ]] && [[ ! "$cmd" =~ --path ]]; then
            eval "$cmd --path=${source_path}"
        else
            eval "$cmd"
        fi
    done
fi

if (( disable_wp_debug == 1 )); then
    # Revert wp-config
    echo -e "\n${COLOR_BLUE}Restoring wp-config.php from backup ...${COLOR_RESET}"
    mv -v ${source_path}/wp-config.php.bak ${source_path}/wp-config.php
fi

# Cleanup: delete the database export file from the remote server
if (( files_only == 0 && dry_run == 0 )); then
    print_step "DELETING database backup from remote server ..."
    ssh -q -T -i "${ssh_key_path}" ${SSH_OPTS} ${remote_user}@${remote_ip_address} "rm -f ${remote_path}/${db_export_prefix}*${rnd_str_key}.sql" && print_success "Remote database backup deleted"
fi

# Calculate execution time
end_time=$(date +%s)
execution_time=$((end_time - start_time))
minutes=$((execution_time / 60))
seconds=$((execution_time % 60))
print_success "Total execution time: ${minutes}:$(printf %02d ${seconds})"

print_success "COMPLETED!"
print_info "To delete SSH key pairs later, run with --del-ssh-key"
echo -e "\n${COLOR_BOLD_GREEN}========================================${COLOR_RESET}"
echo -e "${COLOR_BOLD_GREEN}    Pull operation completed!${COLOR_RESET}"
echo -e "${COLOR_BOLD_GREEN}========================================${COLOR_RESET}\n"
exit 0

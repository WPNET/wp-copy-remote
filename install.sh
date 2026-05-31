#!/bin/bash

# WP Copy Remote — Installer
# Must be run as root.
# Installs wp-push-remote or wp-pull-remote to a site user's ~/.local/bin directory.

# Ubuntu 22.04+ compatible script
if ((BASH_VERSINFO[0] < 5)); then
    echo "ERROR: This script requires Bash 5.0 or higher (current: $BASH_VERSION)"
    exit 1
fi

####################################################################################
# COLORS
####################################################################################

if [[ -t 1 ]]; then
    COLOR_RESET='\033[0m'
    COLOR_RED='\033[0;31m'
    COLOR_GREEN='\033[0;32m'
    COLOR_YELLOW='\033[0;33m'
    COLOR_CYAN='\033[0;36m'
    COLOR_WHITE='\033[1;37m'
    COLOR_BOLD_GREEN='\033[1;32m'
    COLOR_BOLD_YELLOW='\033[1;33m'
    COLOR_BOLD_BLUE='\033[1;34m'
    COLOR_BOLD_CYAN='\033[1;36m'
else
    COLOR_RESET=''
    COLOR_RED=''
    COLOR_GREEN=''
    COLOR_YELLOW=''
    COLOR_CYAN=''
    COLOR_WHITE=''
    COLOR_BOLD_GREEN=''
    COLOR_BOLD_YELLOW=''
    COLOR_BOLD_BLUE=''
    COLOR_BOLD_CYAN=''
fi

####################################################################################
# HELPERS
####################################################################################

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

print_step() {
    echo -e "\n${COLOR_BOLD_BLUE}---> $1${COLOR_RESET}"
}

####################################################################################
# ROOT CHECK
####################################################################################

if [[ $EUID -ne 0 ]]; then
    print_error "This installer must be run as root."
    echo "  Try: sudo $0"
    exit 1
fi

####################################################################################
# LOCATE SCRIPTS
####################################################################################

# Scripts are expected to live alongside install.sh
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PUSH_SCRIPT="${SCRIPT_DIR}/wp-push-remote.sh"
PULL_SCRIPT="${SCRIPT_DIR}/wp-pull-remote.sh"

if [[ ! -f "$PUSH_SCRIPT" && ! -f "$PULL_SCRIPT" ]]; then
    print_error "Neither wp-push-remote.sh nor wp-pull-remote.sh found in ${SCRIPT_DIR}"
    exit 1
fi

####################################################################################
# MAIN
####################################################################################

clear

print_header "WP Copy Remote — Installer"
echo -e "${COLOR_WHITE}This installer copies a WP Copy Remote script into a site user's local bin directory.${COLOR_RESET}"
echo ""

# ── Step 1: Choose push or pull ──────────────────────────────────────────────

print_step "Step 1: Which script do you want to install?"
echo ""
echo -e "  ${COLOR_YELLOW}1${COLOR_RESET}  wp-push-remote  (push local site → remote server)"
echo -e "  ${COLOR_YELLOW}2${COLOR_RESET}  wp-pull-remote  (pull remote site → local server)"
echo ""

while true; do
    read -r -p "$(echo -e "${COLOR_CYAN}Enter 1 or 2:${COLOR_RESET} ")" script_choice
    case "$script_choice" in
        1)
            if [[ ! -f "$PUSH_SCRIPT" ]]; then
                print_error "wp-push-remote.sh not found at ${PUSH_SCRIPT}"
                exit 1
            fi
            selected_script="$PUSH_SCRIPT"
            script_name="wp-push-remote"
            break
            ;;
        2)
            if [[ ! -f "$PULL_SCRIPT" ]]; then
                print_error "wp-pull-remote.sh not found at ${PULL_SCRIPT}"
                exit 1
            fi
            selected_script="$PULL_SCRIPT"
            script_name="wp-pull-remote"
            break
            ;;
        *)
            print_warning "Please enter 1 or 2."
            ;;
    esac
done

print_success "Selected: ${script_name}"

# ── Step 2: List and select site ─────────────────────────────────────────────

print_step "Step 2: Select the site to install for"
echo ""

if [[ ! -d /sites ]]; then
    print_error "/sites directory does not exist."
    print_info "This installer expects a /sites directory structure (e.g. /sites/<domain>/files/)."
    exit 1
fi

print_info "Searching for WordPress installations in /sites/*/files/ ..."

sites=()
while IFS= read -r -d '' files_dir; do
    site_dir="$(dirname "$files_dir")"
    [[ -d "$site_dir" ]] && sites+=("$site_dir")
done < <(find /sites -maxdepth 2 -type d -name "files" -print0 2>/dev/null)

if [[ ${#sites[@]} -eq 0 ]]; then
    print_error "No sites found matching /sites/*/files/"
    exit 1
fi

echo ""
for i in "${!sites[@]}"; do
    printf "  ${COLOR_YELLOW}%2d${COLOR_RESET}  %s\n" "$((i+1))" "${sites[$i]}"
done
echo ""

while true; do
    read -r -p "$(echo -e "${COLOR_CYAN}Enter site number [1-${#sites[@]}]:${COLOR_RESET} ")" site_choice
    if [[ "$site_choice" =~ ^[0-9]+$ ]] && (( site_choice >= 1 && site_choice <= ${#sites[@]} )); then
        break
    fi
    print_warning "Please enter a number between 1 and ${#sites[@]}."
done

selected_site="${sites[$((site_choice-1))]}"
print_success "Selected site: ${selected_site}"

# ── Step 3: Determine owner and bin directory ─────────────────────────────────

print_step "Step 3: Determining site user and install path"

# Determine the owner of the site directory
if stat -c '%U' "$selected_site" >/dev/null 2>&1; then
    site_owner="$(stat -c '%U' "$selected_site")"
elif stat -f '%Su' "$selected_site" >/dev/null 2>&1; then
    site_owner="$(stat -f '%Su' "$selected_site")"
else
    site_owner=""
fi

if [[ -z "$site_owner" || "$site_owner" == "root" ]]; then
    print_warning "Could not reliably detect a non-root site owner for ${selected_site}."
    read -r -p "$(echo -e "${COLOR_CYAN}Enter the username to install for:${COLOR_RESET} ")" site_owner
    if [[ -z "$site_owner" ]]; then
        print_error "No username provided."
        exit 1
    fi
fi

# Verify the user exists
if ! id "$site_owner" >/dev/null 2>&1; then
    print_error "User '${site_owner}' does not exist on this system."
    exit 1
fi

site_owner_home="$(getent passwd "$site_owner" | cut -d: -f6)"

bin_dir="${selected_site}/.local/bin"
install_path="${bin_dir}/${script_name}"

print_info "Site user  : ${site_owner}"
if [[ -n "$site_owner_home" ]]; then
    print_info "Home dir   : ${site_owner_home}"
fi
print_info "Install to : ${install_path}"

# ── Step 4: Confirm ───────────────────────────────────────────────────────────

echo ""
echo -e "${COLOR_WHITE}About to install ${COLOR_BOLD_CYAN}${script_name}${COLOR_RESET}${COLOR_WHITE} for user ${COLOR_BOLD_CYAN}${site_owner}${COLOR_RESET}${COLOR_WHITE}.${COLOR_RESET}"
read -r -p "$(echo -e "${COLOR_CYAN}Proceed? [y/N]:${COLOR_RESET} ")" confirm
case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *)
        echo "Aborted."
        exit 0
        ;;
esac

# ── Step 5: Create directory and copy script ──────────────────────────────────

print_step "Step 5: Copying script"

if [[ ! -d "$bin_dir" ]]; then
    print_info "Creating directory: ${bin_dir}"
    if ! mkdir -p "$bin_dir"; then
        print_error "Failed to create ${bin_dir}"
        exit 1
    fi
fi

if ! cp "$selected_script" "$install_path"; then
    print_error "Failed to copy script to ${install_path}"
    exit 1
fi
print_success "Script copied to: ${install_path}"

# ── Step 6: Set ownership and permissions ────────────────────────────────────

print_step "Step 6: Setting ownership and permissions"

if chown -R "${site_owner}:${site_owner}" "$bin_dir"; then
    print_success "Ownership set to ${site_owner}:${site_owner} on ${bin_dir}"
else
    print_warning "Could not set ownership on ${bin_dir} — you may need to fix this manually."
fi

if chmod 0755 "$install_path"; then
    print_success "Permissions set to 0755 on ${install_path}"
else
    print_error "Failed to set permissions on ${install_path}"
    exit 1
fi

# ── Done ──────────────────────────────────────────────────────────────────────

echo ""
print_header "Installation Complete"
print_success "${script_name} installed for user ${site_owner}"
print_info "Location : ${install_path}"
print_info "Run as   : su - ${site_owner} -c '${install_path} --help'"
echo ""

#!/usr/bin/env bash
set -e

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
config_file=$(mktemp)
trap 'rm -f "$config_file"' EXIT

print_info() { :; }
print_success() { :; }

reset_config() {
    local_path_prefix=""
    unset local_webroot source_path_prefix source_webroot
}

for script in "$repo_root/wp-pull-remote.sh" "$repo_root/wp-push-remote.sh"; do
    eval "$(sed -n '/^load_config() {/,/^}/p' "$script")"
    eval "$(sed -n '/^save_config() {/,/^}/p' "$script")"

    reset_config
    : > "$config_file"
    load_config
    [[ $local_webroot == files ]]

    reset_config
    printf 'source_path_prefix="/legacy/"\nsource_webroot="htdocs"\n' > "$config_file"
    load_config
    [[ $local_path_prefix == /legacy/ && $local_webroot == htdocs ]]

    reset_config
    printf 'source_path_prefix="/legacy/"\nsource_webroot=""\n' > "$config_file"
    load_config
    [[ $local_path_prefix == /legacy/ && -z $local_webroot ]]

    reset_config
    printf 'source_path_prefix="/legacy/"\nsource_webroot="htdocs"\nlocal_path_prefix="/new/"\nlocal_webroot=""\n' > "$config_file"
    load_config
    [[ $local_path_prefix == /new/ && -z $local_webroot ]]

    remote_ip_address=example.com remote_user=user remote_path_prefix=/remote/ remote_webroot=public
    local_url="" plugins_to_install="" backup_db=0 filter_sql=0
    excludes=()
    save_config
    grep -qx 'local_path_prefix="/new/"' "$config_file"
    grep -qx 'local_webroot=""' "$config_file"
    ! grep -q '^source_\(path_prefix\|webroot\)=' "$config_file"
    reset_config
    load_config
    [[ $local_path_prefix == /new/ && -z $local_webroot ]]
    printf '%s: config compatibility passed\n' "$(basename "$script")"
done

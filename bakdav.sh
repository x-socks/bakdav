#!/usr/bin/env bash

set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/bakdav"
CRED_FILE="$CONFIG_DIR/credentials.enc"
KEY_FILE="$CONFIG_DIR/credentials.key"
JOB_FILE="$CONFIG_DIR/backup.conf"
BACKUP_TMP_DIR="${TMPDIR:-/tmp}/bakdav"
BIN_DIR="${BAKDAV_BIN_DIR:-$HOME/.local/bin}"
COMMAND_NAME="bakdav"
COMMAND_LINK="$BIN_DIR/$COMMAND_NAME"
CRON_MARKER="# bakdav-managed-job"
DAYS_TO_KEEP=7

WEBDAV_URL=""
WEBDAV_REMOTE_DIR=""
WEBDAV_REMOTE_DIR_CONFIGURED=0
WEBDAV_USER=""
WEBDAV_PASS=""
BACKUP_DIR=""

resolve_script_path() {
    local source_path="${BASH_SOURCE[0]}"
    local script_dir=""

    while [ -L "$source_path" ]; do
        local link_dir
        link_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
        source_path="$(readlink "$source_path")"
        [[ "$source_path" != /* ]] && source_path="$link_dir/$source_path"
    done

    script_dir="$(cd -P "$(dirname "$source_path")" && pwd)"
    printf "%s/%s\n" "$script_dir" "$(basename "$source_path")"
}

SCRIPT_PATH="$(resolve_script_path)"

ensure_config_dir() {
    mkdir -p "$CONFIG_DIR" "$BACKUP_TMP_DIR"
    chmod 700 "$CONFIG_DIR"
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "缺少依赖命令: $1"
        exit 1
    fi
}

ensure_encryption_key() {
    require_command openssl

    if [ ! -f "$KEY_FILE" ]; then
        umask 077
        openssl rand -hex 32 >"$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi
}

install_command() {
    mkdir -p "$BIN_DIR"
    local existing_command=""
    local existing_target=""

    existing_command="$(command -v "$COMMAND_NAME" 2>/dev/null || true)"

    if [ -n "$existing_command" ] && [ "$existing_command" != "$COMMAND_LINK" ] && [ "$existing_command" != "$SCRIPT_PATH" ]; then
        echo "检测到 PATH 中已有 bakdav 命令: $existing_command"
        echo "当前将更新本地命令链接: $COMMAND_LINK"
    fi

    if [ -L "$COMMAND_LINK" ]; then
        existing_target="$(readlink "$COMMAND_LINK" 2>/dev/null || true)"
        echo "检测到旧命令链接: $COMMAND_LINK -> ${existing_target:-unknown}"
        echo "将覆盖为当前脚本: $SCRIPT_PATH"
    elif [ -e "$COMMAND_LINK" ]; then
        echo "检测到旧命令文件: $COMMAND_LINK"
        echo "将覆盖为当前脚本: $SCRIPT_PATH"
    fi

    chmod +x "$SCRIPT_PATH" 2>/dev/null || true
    ln -sfn "$SCRIPT_PATH" "$COMMAND_LINK"

    echo "已安装命令: ${COMMAND_LINK}"
    if [[ ":$PATH:" != *":${BIN_DIR}:"* ]]; then
        echo "当前 PATH 未包含 ${BIN_DIR}。"
        echo "如需直接使用 bakdav，请将以下内容加入 shell 配置文件："
        echo "export PATH=\"${BIN_DIR}:\$PATH\""
    fi
}

read_with_default() {
    local prompt="$1"
    local default_value="${2:-}"
    local result=""

    if [ -n "$default_value" ]; then
        read -r -p "$prompt [$default_value]: " result
        printf "%s" "${result:-$default_value}"
    else
        read -r -p "$prompt: " result
        printf "%s" "$result"
    fi
}

normalize_webdav_url() {
    local url="$1"

    while [[ "$url" == */ ]]; do
        url="${url%/}"
    done

    printf "%s" "$url"
}

normalize_webdav_remote_dir() {
    local remote_dir="$1"

    while [[ "$remote_dir" == /* ]]; do
        remote_dir="${remote_dir#/}"
    done

    while [[ "$remote_dir" == */ ]]; do
        remote_dir="${remote_dir%/}"
    done

    printf "%s" "$remote_dir"
}

join_webdav_url() {
    local remote_path="${1:-}"
    local base_url="${WEBDAV_URL%/}"

    remote_path="$(normalize_webdav_remote_dir "$remote_path")"

    if [ -n "$remote_path" ]; then
        printf "%s/%s" "$base_url" "$remote_path"
    else
        printf "%s" "$base_url"
    fi
}

webdav_request_status() {
    local method="$1"
    local url="$2"
    shift 2

    curl \
        --silent \
        --output /dev/null \
        --write-out "%{http_code}" \
        --user "$WEBDAV_USER:$WEBDAV_PASS" \
        --request "$method" \
        "$@" \
        "$url" || true
}

save_credentials() {
    ensure_config_dir
    ensure_encryption_key

    {
        printf "url=%s\n" "$WEBDAV_URL"
        if [ "$WEBDAV_REMOTE_DIR_CONFIGURED" -eq 1 ]; then
            printf "dir=%s\n" "$WEBDAV_REMOTE_DIR"
        fi
        printf "user=%s\npass=%s\n" "$WEBDAV_USER" "$WEBDAV_PASS"
    } \
        | openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$KEY_FILE" -out "$CRED_FILE"

    chmod 600 "$CRED_FILE"
}

store_credentials() {
    ensure_config_dir
    ensure_encryption_key

    if [ -f "$CRED_FILE" ] && [ -f "$KEY_FILE" ]; then
        load_credentials
    fi

    echo "设置 WebDAV 凭证（使用本地密钥文件加密保存）"

    local local_url
    local local_user
    local local_pass

    local_url="$(read_with_default "WebDAV URL" "${WEBDAV_URL:-}")"
    local_user="$(read_with_default "WebDAV 用户名" "${WEBDAV_USER:-}")"
    read -r -s -p "WebDAV 密码: " local_pass
    echo ""

    local_url="$(normalize_webdav_url "$local_url")"

    if [ -z "$local_url" ] || [ -z "$local_user" ] || [ -z "$local_pass" ]; then
        echo "WebDAV URL、用户名和密码都不能为空。"
        exit 1
    fi

    WEBDAV_URL="$local_url"
    WEBDAV_USER="$local_user"
    WEBDAV_PASS="$local_pass"

    save_credentials
    echo "凭证已保存到 $CRED_FILE"
}

load_credentials() {
    ensure_config_dir

    if [ ! -f "$CRED_FILE" ]; then
        echo "未找到凭证文件，先进行凭证设置。"
        store_credentials
    fi

    if [ ! -f "$KEY_FILE" ]; then
        echo "未找到加密密钥文件: $KEY_FILE"
        exit 1
    fi

    local cred_data
    cred_data="$(openssl enc -aes-256-cbc -pbkdf2 -d -pass "file:$KEY_FILE" -in "$CRED_FILE")"

    WEBDAV_URL=""
    WEBDAV_REMOTE_DIR=""
    WEBDAV_REMOTE_DIR_CONFIGURED=0
    WEBDAV_USER=""
    WEBDAV_PASS=""

    while IFS='=' read -r key value; do
        case "$key" in
            url) WEBDAV_URL="$(normalize_webdav_url "$value")" ;;
            dir)
                WEBDAV_REMOTE_DIR="$(normalize_webdav_remote_dir "$value")"
                WEBDAV_REMOTE_DIR_CONFIGURED=1
                ;;
            user) WEBDAV_USER="$value" ;;
            pass) WEBDAV_PASS="$value" ;;
        esac
    done <<<"$cred_data"

    if [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_USER" ] || [ -z "$WEBDAV_PASS" ]; then
        echo "凭证文件内容不完整，请重新执行 bakdav --credential。"
        exit 1
    fi
}

configure_webdav_remote_dir() {
    ensure_config_dir

    if [ ! -f "$CRED_FILE" ]; then
        echo "未找到凭证文件，先进行凭证设置。"
        store_credentials
        load_credentials
    fi

    local selected_remote_dir=""
    local prompt_suffix=""

    if [ "$WEBDAV_REMOTE_DIR_CONFIGURED" -eq 1 ] && [ -n "$WEBDAV_REMOTE_DIR" ]; then
        prompt_suffix=" [当前: $WEBDAV_REMOTE_DIR，直接回车保留，输入 / 使用根目录]"
    elif [ "$WEBDAV_REMOTE_DIR_CONFIGURED" -eq 1 ]; then
        prompt_suffix=" [当前: 根目录，直接回车保留]"
    else
        prompt_suffix=" [留空表示根目录]"
    fi

    read -r -p "请输入 WebDAV 远端备份目录${prompt_suffix}: " selected_remote_dir

    if [ -z "$selected_remote_dir" ] && [ "$WEBDAV_REMOTE_DIR_CONFIGURED" -eq 1 ]; then
        selected_remote_dir="$WEBDAV_REMOTE_DIR"
    elif [ "$selected_remote_dir" = "/" ]; then
        selected_remote_dir=""
    fi

    WEBDAV_REMOTE_DIR="$(normalize_webdav_remote_dir "$selected_remote_dir")"
    WEBDAV_REMOTE_DIR_CONFIGURED=1

    save_credentials
    echo "WebDAV 远端备份目录已保存到 $CRED_FILE"
}

save_backup_job() {
    ensure_config_dir

    printf "BACKUP_DIR=%q\n" "$BACKUP_DIR" >"$JOB_FILE"

    chmod 600 "$JOB_FILE"
}

configure_backup_job() {
    ensure_config_dir

    if [ -f "$JOB_FILE" ]; then
        # shellcheck disable=SC1090
        source "$JOB_FILE"
    fi

    local selected_backup_dir
    selected_backup_dir="$(read_with_default "请输入要备份的目录" "${BACKUP_DIR:-}")"

    if [ -z "$selected_backup_dir" ] || [ ! -d "$selected_backup_dir" ]; then
        echo "备份目录不存在: $selected_backup_dir"
        exit 1
    fi

    BACKUP_DIR="$selected_backup_dir"
    save_backup_job

    echo "备份配置已保存到 $JOB_FILE"
}

load_backup_job() {
    ensure_config_dir

    if [ ! -f "$JOB_FILE" ]; then
        echo "未找到备份配置，先设置备份目录。"
        configure_backup_job
    fi

    # shellcheck disable=SC1090
    source "$JOB_FILE"

    if [ -z "${BACKUP_DIR:-}" ]; then
        echo "备份配置无效，请重新配置。"
        configure_backup_job
    fi
}

ensure_webdav_remote_dir() {
    if [ -z "$WEBDAV_REMOTE_DIR" ]; then
        return 0
    fi

    local current_path=""
    local path_part
    local status

    IFS='/' read -r -a remote_parts <<<"$WEBDAV_REMOTE_DIR"

    for path_part in "${remote_parts[@]}"; do
        if [ -z "$path_part" ]; then
            continue
        fi

        if [ -n "$current_path" ]; then
            current_path="$current_path/$path_part"
        else
            current_path="$path_part"
        fi

        status="$(webdav_request_status PROPFIND "$(join_webdav_url "$current_path")" --header "Depth: 0")"

        case "$status" in
            2??|3??)
                ;;
            404)
                status="$(webdav_request_status MKCOL "$(join_webdav_url "$current_path")")"

                case "$status" in
                    2??|3??)
                        echo "已创建 WebDAV 目录: $current_path"
                        ;;
                    *)
                        echo "创建 WebDAV 目录失败: $current_path"
                        echo "HTTP 状态码: ${status:-unknown}"
                        echo "请检查 WebDAV URL 和远端目录配置。"
                        exit 1
                        ;;
                esac
                ;;
            *)
                echo "WebDAV 目录检查失败: $current_path"
                echo "HTTP 状态码: ${status:-unknown}"
                echo "请检查 WebDAV URL 和远端目录配置。"
                exit 1
                ;;
        esac
    done
}

check_webdav_credentials() {
    check_webdav_base_url
    ensure_webdav_remote_dir
}

check_webdav_base_url() {
    local status
    status="$(webdav_request_status PROPFIND "$(join_webdav_url)" --header "Depth: 0")"

    case "$status" in
        2??|3??)
            return 0
            ;;
        *)
            echo "WebDAV 连接失败，HTTP 状态码: ${status:-unknown}"
            echo "请执行 bakdav --credential 重新设置凭证。"
            exit 1
            ;;
    esac
}

list_current_crontab() {
    crontab -l 2>/dev/null || true
}

cron_job_exists() {
    list_current_crontab | grep -Fq "$CRON_MARKER"
}

check_cron_job() {
    if cron_job_exists; then
        echo "定时任务已设置。"
    else
        echo "定时任务未设置。"
    fi
}

apply_cron_schedule() {
    local cron_schedule="$1"
    require_command crontab
    load_backup_job

    local existing_crontab
    existing_crontab="$(list_current_crontab | grep -Fv "$CRON_MARKER" || true)"

    {
        [ -n "$existing_crontab" ] && printf "%s\n" "$existing_crontab"
        printf "%s %s --run-backup %s\n" "$cron_schedule" "$COMMAND_LINK" "$CRON_MARKER"
    } | crontab -

    echo "定时任务已更新为: $cron_schedule"
    echo "执行命令: $COMMAND_LINK --run-backup"
}

setup_cron() {
    echo "设置定时备份任务。"
    local cron_schedule
    cron_schedule="$(read_with_default "请输入 cron 表达式（默认每天 00:00）" "0 0 * * *")"

    apply_cron_schedule "$cron_schedule"
}

modify_cron() {
    install_command
    setup_cron
}

get_mtime() {
    local file_path="$1"

    if stat -f "%m" "$file_path" >/dev/null 2>&1; then
        stat -f "%m" "$file_path"
    else
        stat -c "%Y" "$file_path"
    fi
}

cleanup_old_backups() {
    echo "清理本地临时备份，保留最近 $DAYS_TO_KEEP 天。"

    local current_date
    current_date="$(date +%s)"

    shopt -s nullglob
    for backup_file in "$BACKUP_TMP_DIR"/backup_*.tar.gz; do
        local file_date
        local age

        file_date="$(get_mtime "$backup_file")"
        age=$(( (current_date - file_date) / 86400 ))

        if [ "$age" -gt "$DAYS_TO_KEEP" ]; then
            rm -f "$backup_file"
            echo "已删除旧备份: $backup_file"
        fi
    done
    shopt -u nullglob
}

upload_to_webdav() {
    local backup_file="$1"
    local remote_name
    local upload_url

    remote_name="$(basename "$backup_file")"
    upload_url="$(join_webdav_url "$WEBDAV_REMOTE_DIR")/$remote_name"

    curl --fail --silent --show-error \
        --user "$WEBDAV_USER:$WEBDAV_PASS" \
        -T "$backup_file" \
        "$upload_url"
}

run_backup() {
    require_command tar
    require_command curl
    require_command openssl

    load_credentials
    if [ "$WEBDAV_REMOTE_DIR_CONFIGURED" -eq 0 ]; then
        echo "未找到 WebDAV 远端备份目录配置，先进行设置。"
        check_webdav_base_url
        configure_webdav_remote_dir
    fi
    load_backup_job
    check_webdav_credentials

    if [ ! -d "$BACKUP_DIR" ]; then
        echo "备份目录不存在: $BACKUP_DIR"
        echo "请重新执行脚本并更新备份配置。"
        exit 1
    fi

    local timestamp
    local source_name
    local backup_file

    timestamp="$(date +"%Y-%m-%d_%H-%M-%S")"
    source_name="$(basename "$BACKUP_DIR")"
    backup_file="$BACKUP_TMP_DIR/backup_${source_name}_${timestamp}.tar.gz"

    echo "开始创建备份: $BACKUP_DIR"
    tar -czf "$backup_file" -C "$(dirname "$BACKUP_DIR")" "$source_name"

    echo "上传到 WebDAV: $(join_webdav_url "$WEBDAV_REMOTE_DIR")"
    upload_to_webdav "$backup_file"

    echo "备份完成: $backup_file"
    cleanup_old_backups
}

show_help() {
    cat <<EOF
BakDav 使用说明

命令：
  bakdav                 启动交互式菜单，并自动安装 bakdav 命令
  bakdav --credential    修改 WebDAV 凭证
  bakdav --remote-dir    修改 WebDAV 远端备份目录
  bakdav --cron          修改定时任务
  bakdav --run-backup    使用已保存配置执行一次备份
  bakdav --help          显示帮助信息

说明：
  1. 首次运行会自动创建命令链接: ${COMMAND_LINK}
  2. 首次运行会依次询问：
     WebDAV URL、用户名、密码、远端备份目录、本地备份目录、定时任务周期
  3. WebDAV URL 和远端目录分开配置。
     例如 URL 填写 https://domi.teracloud.jp/dav/，远端目录填写 test/
  4. WebDAV 凭证保存在:
     ${CRED_FILE}
  5. 备份目录配置保存在:
     ${JOB_FILE}
EOF
}

check_first_run() {
    ensure_config_dir
    install_command

    if [ ! -f "$CRED_FILE" ]; then
        echo "首次运行，开始设置 WebDAV 凭证。"
        store_credentials
        load_credentials
        check_webdav_base_url
        echo "WebDAV 凭证验证成功。"
    else
        load_credentials
    fi

    if [ "$WEBDAV_REMOTE_DIR_CONFIGURED" -eq 0 ]; then
        echo "首次运行，开始设置 WebDAV 远端备份目录。"
        configure_webdav_remote_dir
        ensure_webdav_remote_dir
        echo "WebDAV 远端备份目录验证成功。"
    fi

    if [ ! -f "$JOB_FILE" ]; then
        echo "首次运行，开始设置本地备份目录。"
        configure_backup_job
    fi

    if ! cron_job_exists; then
        echo "首次运行，开始设置定时任务。"
        setup_cron
    else
        check_cron_job
    fi
}

main() {
    case "${1:-}" in
        --credential)
            install_command
            store_credentials
            load_credentials
            check_webdav_base_url
            if [ "$WEBDAV_REMOTE_DIR_CONFIGURED" -eq 1 ]; then
                ensure_webdav_remote_dir
            fi
            exit 0
            ;;
        --remote-dir)
            install_command
            load_credentials
            check_webdav_base_url
            configure_webdav_remote_dir
            ensure_webdav_remote_dir
            exit 0
            ;;
        --cron)
            modify_cron
            exit 0
            ;;
        --run-backup)
            run_backup
            exit 0
            ;;
        --help)
            install_command
            show_help
            exit 0
            ;;
    esac

    echo "欢迎使用 BakDav 备份工具。"
    check_first_run

    while true; do
        echo ""
        echo "请选择操作："
        echo "1. 手动进行备份"
        echo "2. 修改 WebDAV 凭证"
        echo "3. 修改 WebDAV 远端备份目录"
        echo "4. 修改备份目录配置"
        echo "5. 修改定时任务"
        echo "6. 显示帮助"
        echo "7. 退出"

        read -r -p "输入选项 (1-7): " option

        case "$option" in
            1)
                run_backup
                ;;
            2)
                store_credentials
                load_credentials
                check_webdav_base_url
                if [ "$WEBDAV_REMOTE_DIR_CONFIGURED" -eq 1 ]; then
                    ensure_webdav_remote_dir
                fi
                ;;
            3)
                load_credentials
                check_webdav_base_url
                configure_webdav_remote_dir
                ensure_webdav_remote_dir
                ;;
            4)
                configure_backup_job
                ;;
            5)
                modify_cron
                ;;
            6)
                show_help
                ;;
            7)
                echo "退出程序。"
                exit 0
                ;;
            *)
                echo "无效选项，请重试。"
                ;;
        esac
    done
}

main "$@"

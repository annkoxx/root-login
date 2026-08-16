#!/usr/bin/env bash

# Unattended variant of:
# https://raw.githubusercontent.com/Misaka-blog/root-login/main/root.sh
#
# Fixed settings requested by the user:
#   SSH port: 22
#   root password: embedded below

red() {
    echo -e "\033[31m\033[01m$1\033[0m"
}

green() {
    echo -e "\033[32m\033[01m$1\033[0m"
}

yellow() {
    echo -e "\033[33m\033[01m$1\033[0m"
}

if [[ "$(id -u)" -ne 0 ]]; then
    red "此脚本必须以 root 身份运行：sudo bash $0"
    exit 1
fi

readonly sshport=22
readonly password='xxxxxxxxx325235523'
readonly sshd_config='/etc/ssh/sshd_config'

REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "amazon linux" "alpine")
RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Alpine")
PACKAGE_UPDATE=("apt-get -y update" "apt-get -y update" "yum -y update" "yum -y update" "apk update -f")
PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "apk add -f")
CMD=(
    "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)"
    "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)"
    "$(lsb_release -sd 2>/dev/null)"
    "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)"
    "$(grep . /etc/redhat-release 2>/dev/null)"
    "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')"
)

for item in "${CMD[@]}"; do
    SYS="$item"
    [[ -n "$SYS" ]] && break
done

for ((int=0; int<${#REGEX[@]}; int++)); do
    if [[ "$(echo "$SYS" | tr '[:upper:]' '[:lower:]')" =~ ${REGEX[int]} ]]; then
        SYSTEM="${RELEASE[int]}"
        break
    fi
done

if [[ -z "${SYSTEM:-}" ]]; then
    red "脚本暂不支持当前系统，请使用 Debian、Ubuntu、CentOS、AlmaLinux、Rocky Linux、Amazon Linux 或 Alpine Linux。"
    exit 1
fi

if [[ ! -f "$sshd_config" ]]; then
    ${PACKAGE_UPDATE[int]} || exit 1
    ${PACKAGE_INSTALL[int]} openssh-server || exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    ${PACKAGE_UPDATE[int]} || exit 1
    ${PACKAGE_INSTALL[int]} curl || exit 1
fi

WgcfIPv4Status=$(curl -s4m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
WgcfIPv6Status=$(curl -s6m8 https://www.cloudflare.com/cdn-cgi/trace -k | grep warp | cut -d= -f2)
if [[ "$WgcfIPv4Status" =~ on|plus ]] || [[ "$WgcfIPv6Status" =~ on|plus ]]; then
    wg-quick down wgcf >/dev/null 2>&1 || true
    systemctl stop warp-go >/dev/null 2>&1 || true
    v6=$(curl -s6m8 api64.ipify.org -k || true)
    v4=$(curl -s4m8 api64.ipify.org -k || true)
    wg-quick up wgcf >/dev/null 2>&1 || true
    systemctl start warp-go >/dev/null 2>&1 || true
else
    v6=$(curl -s6m8 api64.ipify.org -k || true)
    v4=$(curl -s4m8 api64.ipify.org -k || true)
fi

if command -v chattr >/dev/null 2>&1; then
    chattr -i /etc/passwd /etc/shadow >/dev/null 2>&1 || true
    chattr -a /etc/passwd /etc/shadow >/dev/null 2>&1 || true
fi

green "无人值守设置：SSH 端口 $sshport，root 密码使用脚本内预设值。"

if ! printf 'root:%s\n' "$password" | chpasswd; then
    red "root 密码设置失败，未修改 SSH 配置。"
    exit 1
fi

dropin=''

set_sshd_option() {
    local key="$1"
    local value="$2"

    if grep -Eq "^[[:space:]#]*${key}[[:space:]]+" "$sshd_config"; then
        sed -i -E "s|^[[:space:]#]*${key}[[:space:]]+.*|${key} ${value}|g" "$sshd_config"
    else
        printf '\n%s %s\n' "$key" "$value" >> "$sshd_config"
    fi
}

set_sshd_option Port "$sshport"
set_sshd_option PermitRootLogin yes
set_sshd_option PasswordAuthentication yes
set_sshd_option KbdInteractiveAuthentication yes

# Ubuntu and some cloud images place an earlier PasswordAuthentication setting
# in sshd_config.d. OpenSSH normally uses the first value it reads, so install
# a lexically early fragment when the main configuration enables that directory.
if grep -Eq '^[[:space:]]*Include[[:space:]]+.*/sshd_config\.d/\*\.conf' "$sshd_config"; then
    mkdir -p /etc/ssh/sshd_config.d
    dropin='/etc/ssh/sshd_config.d/00-root-unattended.conf'
    printf '%s\n' \
        "Port $sshport" \
        'PermitRootLogin yes' \
        'PasswordAuthentication yes' \
        'KbdInteractiveAuthentication yes' > "$dropin"
    chmod 600 "$dropin"
fi

mkdir -p /run/sshd >/dev/null 2>&1 || true
if command -v sshd >/dev/null 2>&1 && ! sshd -t -f "$sshd_config"; then
    red "新的 SSH 配置校验失败。"
    exit 1
fi

restart_ok=0
if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ssh >/dev/null 2>&1 && restart_ok=1
    if [[ "$restart_ok" -eq 0 ]]; then
        systemctl restart sshd >/dev/null 2>&1 && restart_ok=1
    fi
fi
if [[ "$restart_ok" -eq 0 ]] && command -v service >/dev/null 2>&1; then
    service ssh restart >/dev/null 2>&1 && restart_ok=1
    if [[ "$restart_ok" -eq 0 ]]; then
        service sshd restart >/dev/null 2>&1 && restart_ok=1
    fi
fi

if [[ "$restart_ok" -eq 0 ]]; then
    red "SSH 服务重启失败。"
    exit 1
fi

yellow "VPS root 登录信息设置完成。"
if [[ -n "${v4:-}" && -z "${v6:-}" ]]; then
    green "VPS 登录地址：$v4:$sshport"
elif [[ -z "${v4:-}" && -n "${v6:-}" ]]; then
    green "VPS 登录地址：[$v6]:$sshport"
elif [[ -n "${v4:-}" && -n "${v6:-}" ]]; then
    green "VPS 登录地址：$v4:$sshport 或 [$v6]:$sshport"
fi
green "用户名：root"
green "密码：$password"

# 自动清理脚本文件
rm -f "$0" ./root-guding.sh /root/root-guding.sh >/dev/null 2>&1 || true
green "已自动清理本地脚本文件（root-guding.sh）。"

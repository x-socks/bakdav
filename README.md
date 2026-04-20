# BakDav

一个基于 WebDAV 的目录备份脚本。

首次运行时会自动安装 `bakdav` 命令，并引导你设置：

- WebDAV URL
- WebDAV 用户名和密码
- WebDAV 远端备份目录
- 本地备份目录
- 定时任务周期

当前行为：

- WebDAV 凭证使用本地密钥加密保存
- 远端默认只保留最近 30 份备份
- 备份目录内容未变化时，自动跳过本次备份
- 支持手动备份和 cron 定时备份

## 一键安装

下面的命令会直接从 GitHub 下载最新的 `bakdav.sh` 到固定路径，然后运行它：

```bash
mkdir -p ~/.local/share/bakdav \
&& curl -fsSL https://raw.githubusercontent.com/x-socks/bakdav/main/bakdav.sh -o ~/.local/share/bakdav/bakdav.sh \
&& chmod +x ~/.local/share/bakdav/bakdav.sh \
&& bash ~/.local/share/bakdav/bakdav.sh
```

安装完成后，脚本会自动创建命令链接：

- 脚本文件：`~/.local/share/bakdav/bakdav.sh`
- 命令链接：`~/.local/bin/bakdav`
- 配置目录：`~/.config/bakdav`

如果当前 shell 的 `PATH` 里没有 `~/.local/bin`，把下面这行加入你的 shell 配置文件：

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## 常用命令

```bash
bakdav
bakdav --run-backup
bakdav --credential
bakdav --remote-dir
bakdav --cron
bakdav --help
```

## 依赖

运行脚本需要这些命令：

- `bash`
- `curl`
- `openssl`
- `tar`
- `xmllint`

设置定时任务时还需要：

- `crontab`

# chroot-rabbitmq

离线 RabbitMQ 4 发行包，使用 Debian 12 AMD64 chroot 运行环境，供没有外网或宿主发行版不固定的 Linux 服务器使用。

## 构建与发布

`versions.env` 锁定 Team RabbitMQ 官方 APT 仓库（`deb1/deb2.rabbitmq.com`）的精确包版本与 Erlang 依赖。推送分支或 Pull Request 时 GitHub Actions 构建并验证；推送 `v*` tag 后，只有 Ubuntu 24 Hosted Runner 与自建 CentOS 7 / Linux 3.10 Runner 都通过验证，才会创建 GitHub Release。

自建 Runner 必须包含标签：`self-hosted`、`linux`、`x64`、`centos7-kernel310-rabbitmq`，并且允许无交互 `sudo`。它会真实安装、启动 systemd 服务、用密码连接 RabbitMQ、发布/消费消息、重启并验证数据持久化。

非 Release 的工作流和失败工作流都会在结束时删除本次构建 Artifact，避免持续占用仓库空间。

## 安装发行包

```bash
tar -xzf chroot-rabbitmq-<version>-linux-amd64.tar.gz
cd chroot-rabbitmq-<version>-linux-amd64
sudo ./install.sh
sudo systemctl status chroot-rabbitmq
sudo cat /etc/chroot-rabbitmq/credentials
```

默认路径为 `/opt/chroot-rabbitmq`（rootfs）、`/var/lib/chroot-rabbitmq/data`（数据）、`/etc/chroot-rabbitmq/conf`（配置）、`/var/log/chroot-rabbitmq`（日志）和 `/etc/chroot-rabbitmq/credentials`（凭据）；数据和配置目录不会随普通卸载或升级删除。

默认监听 `127.0.0.1:5672`（AMQP）与 `15672`（Management），安装时创建 `admin` 用户并生成随机密码，或通过 `--password` / `CHROOT_RABBITMQ_PASSWORD` 指定。生产使用前若需对外暴露，请修改 `bind-address` 并通过防火墙限制来源地址。

密码来源（仅全新实例）：`--password` > `CHROOT_RABBITMQ_PASSWORD` > 随机生成。已有数据目录时传入密码会被忽略并警告，密码以 credentials 文件为准。自动化场景优先使用环境变量：

```bash
sudo CHROOT_RABBITMQ_PASSWORD='your-secret-here' ./install.sh
```

Management 控制台（需先放开 bind 或使用本机访问）：

```bash
source /etc/chroot-rabbitmq/credentials
echo "http://127.0.0.1:${RABBITMQ_MGMT_PORT}/"
```

## 修改配置

主配置文件是 `/etc/chroot-rabbitmq/conf/rabbitmq.conf`，运行时被 bind mount 到 rootfs 的 `/etc/rabbitmq`。文件开头是 `# BEGIN chroot-rabbitmq managed settings` 到 `# END chroot-rabbitmq managed settings` 的托管区块，每次安装都会重写它。

RabbitMQ 以**最后出现的指令**为准，所以自定义配置要写在托管区块**之后**才能覆盖默认值。环境变量文件 `/etc/chroot-rabbitmq/conf/rabbitmq-env.conf` 由安装脚本生成（含固定 `NODENAME=rabbit@127.0.0.1`），改完执行 `sudo systemctl restart chroot-rabbitmq` 生效。带注释的上游完整配置样例在 rootfs 里的 `/usr/share/rabbitmq/rabbitmq.conf.reference`。

可覆盖默认值：

```bash
sudo ./install.sh --prefix /opt/chroot-rabbitmq --data-dir /var/lib/chroot-rabbitmq/data \
  --conf-dir /etc/chroot-rabbitmq/conf --log-dir /var/log/chroot-rabbitmq \
  --port 5672 --mgmt-port 15672 --bind-address 127.0.0.1 --password 'your-secret-here'
```

`sudo ./uninstall.sh` 删除服务和 rootfs、保留数据与配置；仅在确认不再需要这份数据时使用 `sudo ./uninstall.sh --purge-data`（同时删除数据、配置、日志和凭据）。

## 安全说明

- 默认仅监听本机，避免 RabbitMQ 4 对 `guest` 的远程限制误伤生产环境。
- 使用自建 `admin` 用户，不使用 `guest` 远程访问。
- `loopback_users = none` 允许 `admin` 从本机连接；对外暴露时需配合防火墙与 TLS（v0.1.0 未内置 TLS）。
- epmd 默认端口 4369；对外暴露 AMQP 时需在防火墙中一并规划。

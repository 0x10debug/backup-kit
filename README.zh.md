# VPS 备份简化 — 加密、自动、经过测试的恢复

用加密、自动化的备份保护你的自托管数据，专为 VPS 和 Docker 设计。预配置的 Restic 和 Kopia 策略已处理好加密、保留和清理——你只需填入存储后端凭证。包含 Docker volume 备份脚本、一键恢复、以及自动化的恢复演练来验证你的备份真的可用。因为一个你从未测试过的备份，只是一个愿望，不是备份。

> **已经在 VPS 上跑着应用了？** 这就是你的安全网。用 [compose-recipes](https://github.com/0x10debug/compose-recipes) 部署服务，然后用 backup-kit 保护 `/data/`——你所有的应用数据，加密、异地、经过测试。

## 为什么需要这个项目

Restic、Kopia、Borgmatic 都是优秀的备份**工具**——但它们不是**策略**。它们给你引擎，但不给你路线。你仍然需要决定：

1. **用哪个工具**（Restic vs Kopia vs Borgmatic）？
2. **用哪个后端**（S3 兼容云存储 vs SFTP 到另一台 VPS）？
3. **保留策略是什么**（保留多少个每日、每周、每月快照）？
4. **Docker volume 怎么备份**（不能直接 `cp`）？
5. **怎么证明备份可用**（恢复演练）？

backup-kit 用预配置的策略模板回答了这五个问题。选一个策略，填入存储凭证，你就拥有了一个生产可用的备份系统——加密、保留、自动清理、恢复演练全都有。

## 功能特性

- **默认加密** — Restic 使用 AES-256，Kopia/Borg 使用客户端加密；数据在存储后端是不可读的
- **预配置策略** — Restic + S3、Restic + SFTP、Kopia + S3、Borgmatic；保留策略已设好
- **自动保留** — 每次备份后自动执行 `forget --prune`；旧快照自动清理
- **Docker volume 备份** — 通过临时 alpine 容器将任意命名 volume 导出为 tar.gz，或直接流式传输到 Restic
- **Compose 项目备份** — 备份 compose 项目的每个 volume，外加 `compose.yml` 和 `.env`
- **恢复演练** — `mb backup drill` 执行完整的 备份→恢复→校验 流程，生成通过/失败报告
- **VPS 迁移** — `mb backup export` 打包 `/data/`、compose 配置和 Docker volume，用于迁移到新服务器
- **Cron 模板** — 每日备份、每周校验、每月演练，开箱即用

## 可用策略

| 策略 | 工具 | 后端 | 适用场景 |
|---|---|---|---|
| [restic-s3](strategies/restic-s3/) | Restic | S3 兼容（AWS S3、B2、MinIO、R2） | 默认选择——快速、去重、加密 |
| [restic-sftp](strategies/restic-sftp/) | Restic | SFTP（另一台 VPS） | 没有云存储账号——用第二台 VPS 做存储 |
| [kopia-s3](strategies/kopia-s3/) | Kopia | S3 兼容 | 想要 Web GUI 浏览和恢复快照 |
| [borgmatic](strategies/borgmatic/) | Borgmatic（Borg） | SSH / SFTP | 偏好 YAML 声明式配置和 Borg 压缩 |

所有策略默认保留 **7 个每日 + 4 个每周 + 6 个每月** 快照，默认备份 `/data/`。

## 快速开始

```bash
# 1. 硬化 VPS 并安装 Docker（如果还没做）
# → https://github.com/0x10debug/vps-bootstrap

# 2. 克隆本仓库
git clone https://github.com/0x10debug/backup-kit.git
cd backup-kit

# 3. 初始化备份策略（交互式）
./mb backup init
# → 选择 restic-s3，输入 S3 凭证，设置加密密码

# 4. 运行第一次备份
./mb backup run

# 5. 验证备份完整性
./mb backup verify

# 6. 测试你真的能恢复（恢复演练）
./mb backup drill

# 7. 安装 cron 定时任务（每日备份、每周校验、每月演练）
#    mb backup init 会自动询问是否安装
crontab /etc/mb-backup/backup-cron
```

## 用法

```bash
mb backup init                       # 交互式策略初始化
mb backup init --config .env         # 声明式初始化（从配置文件）
mb backup run                        # 立即执行一次备份
mb backup status                     # 查看最近备份时间、快照数、仓库大小
mb backup verify                     # 验证备份完整性
mb backup restore --snapshot ID      # 从指定快照恢复
mb backup restore --latest           # 从最新快照恢复
mb backup drill                      # 执行恢复演练
mb backup cleanup                    # 执行保留策略（forget + prune）
mb backup export                     # 导出所有数据（用于 VPS 迁移）
mb backup list                       # 列出所有快照
mb backup help                       # 显示帮助
```

### 声明式初始化

创建一个 `.env` 文件，包含策略和凭证：

```bash
MB_STRATEGY=restic-s3
RESTIC_REPOSITORY=s3:s3.amazonaws.com/my-backup-bucket
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
RESTIC_PASSWORD=你的加密密码
BACKUP_PATHS=/data
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=6
```

然后非交互式初始化：

```bash
mb backup init --config .env
```

### 备份 Docker Volume

```bash
# 导出单个 volume 到 /backup/
docker/volume-backup.sh my-app-data /backup/

# 将 volume 直接流式传输到 Restic（不产生中间文件）
docker/volume-backup.sh my-app-data --restic

# 从归档恢复 volume
docker/volume-restore.sh my-app-data /backup/my-app-data-20260101-030000.tar.gz

# 备份整个 compose 项目（所有 volume + compose.yml + .env）
docker/compose-backup.sh /opt/my-app /backup/my-app-$(date +%Y%m%d)
```

## 常见问题

### 如何在 VPS 上备份 Docker volume？

Docker volume 不能直接用 `cp` 复制，因为它们存储在 Docker 管理的存储区里。使用 `docker/volume-backup.sh <volume名>`——它会启动一个临时 alpine 容器，以只读方式挂载 volume，将内容导出为压缩的 tar.gz。恢复时用 `docker/volume-restore.sh <volume名> <归档.tar.gz>`，将归档导入回 volume。详见 [Docker volume 备份指南](docs/docker-volume-backup.md)。

### 如何用 Restic 设置加密备份？

运行 `mb backup init`，选择 `restic-s3`（或 SFTP 后端选 `restic-sftp`）。输入存储凭证和加密密码。Restic 在数据离开你的 VPS 之前用 AES-256 加密所有数据和元数据——存储后端只能看到密文。你的密码永远不会发送到任何地方。备份通过 `mb backup run` 执行，旧快照按保留策略自动清理。

### 如何自动化 VPS 备份到 S3？

`mb backup init` 后，接受 cron 安装提示（或运行 `crontab /etc/mb-backup/backup-cron`）。这会安排每天凌晨 3 点备份、每周日凌晨 4 点完整性校验、每月 1 号凌晨 5 点恢复演练。所有输出记录到 `/var/log/mb-backup.log`。兼容所有 S3 兼容存储：AWS S3、Backblaze B2、Cloudflare R2、Wasabi、MinIO。

### 如何测试备份恢复是否可用？

运行 `mb backup drill`。它会执行完整的恢复演练：做一次新备份，将最新快照恢复到临时目录，比较源数据和恢复数据的文件数和总大小，生成通过/失败报告到 `/var/lib/mb-backup/`。一个你从未恢复过的备份只是愿望——演练把愿望变成证明。详见 [恢复演练指南](docs/restore-drill.md)。

### 如何迁移 VPS 数据到新服务器？

在旧 VPS 上运行 `mb backup export`。它会把 `/data/`（所有应用数据）、compose 配置文件、所有 Docker 命名 volume 打包到 `/backup/` 下的一个导出目录。用 `rsync` 或 `scp` 将该目录传到新 VPS，然后运行 `mb backup restore --latest` 恢复数据。详见 [迁移指南](docs/migration.md)。

## 文档

- [备份策略指南](docs/backup-strategy-guide.md) — 如何在 Restic、Kopia、Borgmatic 之间选择；S3 vs SFTP
- [Docker Volume 备份](docs/docker-volume-backup.md) — Docker volume 备份和恢复的工作原理
- [恢复演练指南](docs/restore-drill.md) — 为什么要做恢复演练以及怎么做
- [迁移指南](docs/migration.md) — 如何将 VPS 数据迁移到新服务器

## 相关项目

- [vps-bootstrap](https://github.com/0x10debug/vps-bootstrap) — 一键 VPS 初始化和安全硬化
- [compose-recipes](https://github.com/0x10debug/compose-recipes) — VPS 自托管应用套件（你要备份的数据来源）
- [monitor-stack](https://github.com/0x10debug/monitor-stack) — 轻量级 VPS 监控栈
- [security-audit](https://github.com/0x10debug/security-audit) — VPS 安全审计工具

## 许可证

[MIT](./LICENSE)

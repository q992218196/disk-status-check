# Disk Status Check

适用于 CentOS/RHEL 系和 Debian/Ubuntu 系的单文件硬盘健康监控脚本。它会自动检查：

- 系统直通的 SATA/SAS 磁盘（`smartctl`）
- NVMe/U.2 磁盘（`nvme smart-log`）
- Linux md 软件 RAID（`/proc/mdstat`）
- Broadcom/LSI MegaRAID 的控制器、虚拟盘、物理盘和缓存保护状态（`storcli`）
- 其他品牌硬件 RAID 会明确提示“后端盘未覆盖”，不会假装检查正常

发现异常后可通过企业微信群机器人 Webhook 推送；相同告警默认一小时最多推送一次，告警变化立即推送，恢复后推送恢复消息。

## curl 一键安装

安装脚本、系统依赖并执行一次不推送消息的检测：

```bash
curl -fsSL https://gitee.com/q992218196/disk-status-check/raw/main/install.sh | sudo bash
```

同时配置企业微信 Webhook，并创建每 5 分钟执行一次的定时任务：

```bash
curl -fsSL https://gitee.com/q992218196/disk-status-check/raw/main/install.sh \
  | sudo bash -s -- --webhook 'https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=你的key' --cron
```

只想临时运行、不安装文件和依赖：

```bash
curl -fsSL https://gitee.com/q992218196/disk-status-check/raw/main/disk_status_check.sh \
  | sudo bash -s -- --check --no-notify
```

> `curl | bash` 会直接执行远程代码。生产环境可先用 `curl -fsSLO URL` 下载并检查内容，再使用 `sudo bash install.sh` 执行。可通过 `--ref 标签名` 固定安装版本。

## 手动安装

```bash
sudo install -m 0755 disk_status_check.sh /usr/local/sbin/disk-status-check
sudo install -m 0600 disk-status-check.conf.example /etc/disk-status-check.conf
sudo vi /etc/disk-status-check.conf
sudo /usr/local/sbin/disk-status-check --install
```

`--install` 会先安装 `smartmontools`、`nvme-cli`、`pciutils`、`curl`。只有检测到 Broadcom/LSI MegaRAID 时才安装 storcli：

- CentOS/RHEL：下载配置中的 RPM 并使用 `rpm -Uvh` 安装。
- Debian/Ubuntu：优先安装 `STORCLI_DEB_URL`；其次从 `STORCLI_ZIP_URL` 自动寻找 `storcli*.deb`；两项都未配置时，从同一个 noarch RPM 中提取 `storcli64` 到 `/usr/local/sbin`，不会污染 dpkg 数据库。

Broadcom 的 Unified StorCLI 下载包通常含 Ubuntu 使用的 `.deb`，但下载直链和版本会更新，因此没有在脚本中固化一个容易失效的官方版本 URL。若已下载官方 ZIP，也可使用 `file:///绝对路径/xxx.zip` 作为 `STORCLI_ZIP_URL`。

## 运行

```bash
sudo /usr/local/sbin/disk-status-check --check
echo $?
```

退出码：

- `0`：所有已检查项目正常
- `1`：发现警告或硬盘/阵列异常
- `2`：脚本执行失败或企业微信推送失败

只查看检测结果、不发消息：

```bash
sudo /usr/local/sbin/disk-status-check --check --no-notify
```

## 定时执行

例如每 5 分钟执行一次：

```cron
*/5 * * * * root /usr/local/sbin/disk-status-check --check >>/var/log/disk-status-check.log 2>&1
```

保存为 `/etc/cron.d/disk-status-check` 即可。脚本自身带重复告警冷却，不需要在 cron 中额外去重。

## 判定规则

- NVMe：`critical_warning != 0`、备用空间低于阈值、`media_errors > 0` 为异常；温度和寿命使用量达到配置阈值为警告。
- SATA/SAS：SMART 总体状态失败，或属性 5/187/197/198 的原始值大于 0 为异常；温度达到阈值为警告。
- MegaRAID：虚拟盘非 `Optl`、物理盘不在 `Onln/UGood/GHS/DHS/JBOD` 中为异常；重建/回拷等过程为警告。
- md RAID：成员状态含 `_` 或阵列 inactive 为异常；恢复、同步、reshape 等后台任务为警告。

首次部署建议先执行 `--check --no-notify`，核对服务器控制器和磁盘型号的输出，再启用 Webhook 与 cron。

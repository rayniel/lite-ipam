# Lite IPAM · 轻量地址管家

面向 OpenWrt 的轻量级 IP 地址与 DHCP 租约管理工具，包含后端
`lite-ipam` 和 LuCI 界面 `luci-app-lite-ipam`。

## 功能

- 按接口、子网和 VLAN 纳管主机与 IPv4 地址。
- 自动发现后固定地址，校验 MAC/IP 冲突，记录地址漂移。
- DHCP Hook 记录事件，后台周期对账租约，保留历史。
- 合并发布固定绑定，预检配置，无变更不 reload，验证实际加载并支持失败回退。
- 健康提示区分当前故障、处理中、未执行及历史异常。
- SQLite 一致性备份、历史清理、数据导出和 Token 认证 API。

有效租约不代表设备在线。对于 no-RTC dnsmasq，租约文件中的总时长不会被误当作
绝对到期时间；仅在 Hook 提供剩余时间时记录估计到期时间。
绑定文件已加载不代表客户端已取得该地址，仍需等待自然续租并观察 DHCPACK。

## 在 OpenWrt 源码树中构建

此仓库是 OpenWrt 源码包，不是可在普通 Linux 上直接运行的独立服务。
在 OpenWrt 源码树中执行：

```sh
git clone https://github.com/rayniel/lite-ipam.git package/lite-ipam
make menuconfig
# 选择 lite-ipam 和 luci-app-lite-ipam
make package/lite-ipam/compile -j2 V=s
```

使用对应目标架构的软件包安装，勿混用其他架构或 OpenWrt 版本的软件包。
运行依赖由包管理器处理，包含 SQLite CLI、flock、mailsend 和 LuCI Lua runtime。

## 初始配置

LuCI 菜单位于“服务 → Lite IPAM”。先在设置页配置持久化数据目录和纳管接口。
默认数据目录为空，API 与邮件发送默认关闭，仓库不包含设备配置或凭据。
启用外部 API 前须配置相应 Token；不要把数据库、运行备份或凭据提交到仓库。

```sh
/etc/init.d/lite-ipam enable
/etc/init.d/lite-ipam restart
lite-ipamctl --help
```

数据目录位于 `/mnt` 或 `/media` 且严格存储检测开启时，存储必须已经挂载。
自动发现会产生固定绑定，部署前请确认纳管范围及已有地址规划。

## 运行机制

procd 监管后台 worker。DHCP Hook 更新数据库并标记待发布变更；后台每分钟读取
租约快照并事务对账。缺失、格式错误或重复的租约快照不会清空已有有效记录。
当前租约限制同一子网每个 MAC/IP 最多一条。

dnsmasq 接入数据目录下的 `dnsmasq/active/` 专用目录，其中只放 `hosts.conf`。
目录挂载避免 ujail 单文件 bind mount 在原子替换后仍读取旧 inode。
每行绑定为 `MAC,IP[,hostname]`；发布前用真实 dnsmasq 解析器预检，
发布后检查本轮日志中的加载确认，失败时尝试恢复上一份有效文件。

健康页直接展示问题原因、影响、时间及处理建议，原始错误折叠在技术详情中。
备份、清理与导出的上次失败作为任务提醒，不等同于 DHCP 故障。
未执行的可选任务和数据库历史失败累计不计入当前故障。
各任务保留最近一次失败和首次恢复时间，不会清零历史错误或补造升级前的恢复记录。

## 测试

主机需要 Python 3、BusyBox、SQLite CLI、dnsmasq、flock、Lua 5.1 和 Node.js：

```sh
LUA_BIN=/path/to/lua5.1 \
DNSMASQ_BIN=/path/to/dnsmasq \
python3 -m unittest discover -s tests -v
```

通过 `PATH` 指定 SQLite CLI。独立副本建议显式设置 `LUA_BIN`。
测试使用临时目录、模拟 UCI 与服务调用，不操作真实 DHCP 服务。
覆盖租约语义、事务回滚、并发、配置发布、备份、worker 生命周期、健康分类、
恢复记录与前端空列表兼容。

当前版本为包 release 9；已在 OpenWrt 25.12、dnsmasq 2.91 环境验证。
其他版本需自行构建验证。

## 许可证

GPL-2.0-only，与包的 Makefile 声明一致。

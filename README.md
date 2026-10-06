# SS-2022：Shadowsocks Rust 一键脚本

一键安装与管理 [shadowsocks-rust](https://github.com/shadowsocks/shadowsocks-rust)（SS-2022），
支持单端口多用户、多端口、出口代理、ShadowTLS 与屏蔽中国大陆的连接。
Debian / Ubuntu、CentOS / RHEL / Rocky / AlmaLinux、Alpine 都能用。

## 安装

```bash
bash <(curl -fsSL https://ss.jinqians.com)
```

Alpine 默认没有 bash，用 sh 运行即可（脚本会自己装上 bash）：

```sh
sh -c "$(curl -fsSL https://ss.jinqians.com)"
```

装好后输入 `ssrust` 打开管理菜单（每次运行都取最新的脚本）。

Snell、SS-2022、ShadowTLS 的多功能菜单：`bash <(curl -fsSL https://menu.jinqians.com)`

## 管理菜单

```
   ____    ____           ____     ___    ____    ____
  / ___|  / ___|         |___ \   / _ \  |___ \  |___ \
  \___ \  \___ \   _____   __) | | | | |   __) |   __) |
   ___) |  ___) | |_____| / __/  | |_| |  / __/   / __/
  |____/  |____/         |_____|  \___/  |_____| |_____|

  SS-2022 Manager v3.0  ·····  ◆ https://jinqians.com
  ──────────────────────────────────────────────
  SS-Rust   ▶  运行中 1/1       IP        ▶  203.0.113.10
  版本      ▶  1.25.0           加密      ▶  2022-blake3-aes-128-gcm
  端口      ▶  30001            用户      ▶  单密钥
  ShadowTLS ▶  未安装           出口      ▶  直连
  大陆屏蔽  ▶  未启用
  ──────────────────────────────────────────────

══════════════════════════════════════════════════════════════
                     JQ's SS-2022 Manager
══════════════════════════════════════════════════════════════
   1. 安装 Shadowsocks Rust   8. 单端口多用户（EIH）
   2. 更新 Shadowsocks Rust   9. 多端口
   3. 卸载 Shadowsocks Rust  10. 出口代理
   4. 查看配置与链接         11. ShadowTLS
   5. 修改配置               12. 屏蔽中国大陆
   6. 启动 / 停止 / 重启     13. 日志设置
   7. 运行状态与日志         14. 更新脚本
──────────────────────────────────────────────────────────────
   0. 退出
══════════════════════════════════════════════════════════════
```

| 选项 | 说明 |
|------|------|
| 1 安装 | 端口、加密方式（默认 2022-blake3-aes-128-gcm）、密钥（回车随机生成）、TFO、DNS、混淆插件。安装的是官方发布的静态链接版（musl），下载后核对官方的 SHA-256；顺带开启时间同步（2022 系列要求服务器与客户端时间差在 30 秒内），不改时区 |
| 2 更新 | 更新到 shadowsocks-rust 的最新版本，主端口与额外端口一起重启 |
| 4 查看配置 | 分享链接（SIP002）、二维码、Surge 配置行；装了 ShadowTLS 时还有组合链接与 Surge 行 |
| 5 修改配置 | 端口、密钥、加密方式、TFO、DNS、混淆插件、入站 UDP 分片。改端口时防火墙、ShadowTLS 的后端、大陆屏蔽的规则跟着改 |
| 8 单端口多用户 | 几个人共用一个端口，各用各的密钥，可以单独删掉某个人（见下文） |
| 9 多端口 | 再开几个端口，沿用主配置，各有密钥与服务（`ss-rust-<端口>`） |
| 10 出口代理 | 服务器发出的 TCP 连接经 SOCKS5 / HTTP / HTTPS 代理出去（比如换出口 IP），可以多跳；UDP 仍直连 |
| 11 ShadowTLS | ShadowTLS v3 套在 SS 前面（systemd 的系统） |
| 12 屏蔽中国大陆 | 丢弃来自中国大陆的入站连接（IPv4 与 IPv6；主端口、额外端口、ShadowTLS 端口）；开机自动恢复，可每天 / 每周更新 IP 库 |
| 13 日志设置 | 日志级别；另写到 `/var/log/ss-rust/`（按天分文件，保留 7 个） |

### 单端口多用户

shadowsocks-rust 1.25 的 Extensible Identity Header（EIH），只支持 `2022-blake3-aes-128-gcm`
与 `2022-blake3-aes-256-gcm`。开启后：

- 客户端的密码是「服务器密钥:用户密钥」，菜单里给每个用户生成分享链接；
- 只用服务器密钥的客户端会被拒绝，原来的链接失效；删光所有用户就回到单密钥。

实测能用的客户端：sing-box 1.14、mihomo 1.19、Xray 26、shadowsocks-rust 的 sslocal。

### 出口代理

shadowsocks-rust 1.25 起 ssserver 可以把出站连接交给别的代理：填 `socks5://[用户:密码@]主机:端口`、
`http://…` 或 `https://…`，多跳用逗号分开。设置时会从服务器经代理访问一次并显示出口 IP。
只有 TCP 经代理，UDP 仍从本机出去。

## 文件

| 位置 | 内容 |
|------|------|
| `/etc/ss-rust/config.json` | 主配置（单服务器格式；PSM 等也读它） |
| `/etc/ss-rust/config-eih.json` | 开了单端口多用户时由脚本生成，主服务跑它 |
| `/etc/ss-rust/ports/<端口>.json` | 额外端口的配置 |
| `/usr/local/bin/ss-rust` | ssserver |
| 服务 | `ss-rust`、`ss-rust-<端口>`（systemd，或 Alpine 的 OpenRC） |

排查：`systemctl status ss-rust`、`journalctl -u ss-rust`（Alpine：`rc-service ss-rust status`、`/var/log/ss-rust.log`），
或菜单里的「7 运行状态与日志」。

链接里的地址是自动查到的公网地址；NAT 的机器等查得不对时，可以指定：`SS_SERVER_IP=1.2.3.4 ssrust`。

## 流量管理

按端口统计流量、设月度上限、超限自动暂停：用 [PSM](https://github.com/jinqians/proxy-stack)
（`bash <(curl -fsSL https://psm.jinqians.com)` → 流量管理 → 添加节点 → SS2022）。

## 仓库结构

根目录的脚本都有人按 raw 地址取，地址不变：

| 文件 | 来源 |
|------|------|
| `ss-2022.sh` | 由 `src/ss-2022.sh` 与 `src/lib/` 生成 |
| `block-mainland.sh` | 由 `src/block-mainland.sh` 与 `src/lib/` 生成 |
| `shadowtls.sh`、`menu.sh` | 与 [jinqians/snell](https://github.com/jinqians/snell) 的同名脚本是同一份 |
| `extract-cn-ip-from-mmdb.py` | 旧版的屏蔽脚本用（新版不再需要 Python） |

改代码请改 `src/`，然后 `bash tools/build.sh` 重新生成（`--check` 检查是否一致）。
与 snell 共用的文件用 `bash tools/sync-shared.sh <snell 仓库目录>` 拷过来。

更新记录见 [CHANGELOG.md](CHANGELOG.md)。

## 作者

jinqians · [jinqians.com](https://jinqians.com)

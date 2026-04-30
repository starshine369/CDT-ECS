# 🛡️ CDT Traffic Manager (云服务器流量防爆闸)

![Version](https://img.shields.io/badge/Version-V2.0-blue.svg)
![Bash](https://img.shields.io/badge/Language-Bash-green.svg)
![Platform](https://img.shields.io/badge/Platform-Linux-lightgrey.svg)

**CDT (Cloud Defender Terminal)** 是一款专为限流量 VPS / ECS 设计的轻量级流量防爆闸。

许多云服务商（如阿里云、腾讯云、AWS 亚马逊等）的流量计费模式极为苛刻，一旦流量被恶意 DdoS 刷超，可能会面临天价账单。CDT 通过调用底层的 `vnstat` 探针，每 5 分钟精准核对一次网卡流量账单。一旦触碰红线，立刻执行系统级 `shutdown -h now` (物理断电关机)，死死守住您的钱包。

---

## ⚡ 核心功能

- 📊 **四大计费模型**：完美适配各大云厂商的计费潜规则（双向相加计费、单向取大计费、仅算流出、仅算流入）。
- 📅 **智能账单日历**：支持“每月 N 号自动清零”或“无限制全局累计”。
- 🛑 **断电级防御**：非侵入式轻量监控（Cron + vnstat），一旦超量，切断网络并强制系统关机挂起。
- 🖥️ **全终端适配 UI**：去除乱码与复杂图标，纯 ASCII 面板，无论多老的 SSH 客户端都能完美显示。

---

## 📦 国内机房一键极速部署

考虑到国内服务器拉取 GitHub 可能被墙，我们使用公益加速节点进行一键安装：

```bash
wget -O cdt.sh https://ghproxy.net/https://raw.githubusercontent.com/starshine369/CDT-ECS/main/cdt.sh && bash cdt.sh

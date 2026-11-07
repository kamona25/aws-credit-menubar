# AWS 余量 · AWS Credit Menubar

在 Mac 菜单栏直接查看 **AWS 剩余抵扣金 + Lightsail 预计剩余流量**。

原生 AppKit + SwiftUI，小尺寸浮层、柔和材质和数字过渡动效，支持减少动态效果设置。只做本机查询和提醒，无服务器端、无 Electron、无自动停机或删除功能。

示意菜单：`$120 · 1.85 TB`。这是虚构示例，安装包不包含任何账户或示例余额。

## 功能

| 项目 | 行为 |
| --- | --- |
| 菜单栏 | 直接显示余额和预计剩余流量；也可仅监控抵扣金 |
| 余额 | 每 24 小时查询；区分预计余额与结算金额 |
| 流量 | 每 10 分钟查询；用量达到 80% 后每 5 分钟查询 |
| 提醒 | 余额 $50 / $20 / $10 / $0；到期前 30 / 7 / 1 天；流量已用 80 / 90 / 95 / 100% |
| 休眠 | 不唤醒 Mac；恢复后补查到期数据，不补跑历史定时任务 |
| 凭证 | 专用只读身份，密钥保存 macOS 钥匙串，不读取全局 AWS 登录配置 |
| 失败处理 | 保留上次成功数据并显示异常；流量监控有缺口时不显示剩余额度 |
| 启动 | 可切换登录后自动启动；日常后台查询不弹终端窗口 |

## 安装

需要 **macOS 14 或更高版本**、支持 `billing get-credits` 的 AWS CLI v2，以及有权读取账单和实例流量的 AWS 身份。

从 [Releases](https://github.com/kamona25/aws-credit-menubar/releases) 下载 Apple Silicon（arm64）压缩包，解压后把 `AWS 余量.app` 放到 `/Applications`。项目未捆绑 AWS CLI，请按照 [AWS 官方安装说明](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) 安装或更新。

当前预编译包使用临时本地签名，**没有 Apple Developer ID 签名或公证**。macOS 首次打开可能拦截；请阅读 [Apple 的应用打开说明](https://support.apple.com/en-us/102445)，自行决定是否允许，或从源码构建。项目不提供关闭 Gatekeeper 的脚本。Intel Mac 目前需在本机从源码构建，没有预编译下载包。

## 首次配置

首次配置需要手动运行一次脚本。配置完成后直接打开原生应用即可，不需要常驻终端。

1. 按 [专用只读身份说明](docs/IAM.md) 准备访问密钥。支持同账户读取，也支持“账单账户 + Lightsail 实例账户”的跨账户角色模式。
2. 下载本仓库源码，或使用以下命令获取源码并开始本机配置：

   ```sh
   git clone https://github.com/kamona25/aws-credit-menubar.git
   cd aws-credit-menubar
   python3 scripts/configure.py --app '/Applications/AWS 余量.app'
   ```

   脚本会询问账户 ID、AWS CLI 路径，以及可选的实例名称、区域和跨账户角色 ARN。密钥隐藏输入，通过管道直接写入应用钥匙串。**脚本不会创建身份、查询 AWS 或创建任何云资源**。

3. 打开 `AWS 余量.app`。首次启动会申请 macOS 通知和登录项权限；请按需要允许。若钥匙串要求授权，请确认条目属于此应用后在系统提示中处理。
4. 点击菜单栏数字展开面板，检查数据和状态。首次无缓存时显示 `—`；账户/API/权限错误会显示在浮层中，不会假报零余额。

已有密钥、只想改实例或区域时，先退出应用，再运行：

```sh
python3 scripts/configure.py --keep-credentials --app '/Applications/AWS 余量.app'
```

脚本会确认替换本地配置，并清除旧账户/实例的缓存，重新打开应用后查询新配置。真实配置位于 `~/Library/Application Support/AWSUsageMonitor/config.json`，不要提交到仓库。[配置示例](examples/config.example.json) 的账户 ID 是占位值，不可直接使用。删除 `traffic` 字段即可只看抵扣金；同账户读取无需 `traffic.roleARN`。

### 密钥轮换

应用不会静默覆盖已存在的钥匙串密钥。先退出应用，在 macOS“钥匙串访问”中找到服务名 `io.github.kamona25.aws-credit-menubar.credentials`、账户 `credit-reader` 的专用条目并删除，再重新运行首次配置脚本。成功换用新密钥后，在 AWS 停用旧密钥。

本地重新编译或更新应用后，macOS 可能再次要求允许访问钥匙串。若使用带 Session Token 的临时基础凭证，它到期后需要自行更新；持续后台监控建议使用可随时撤销的专用只读 IAM 密钥。

## 从源码构建

安装 Xcode Command Line Tools 后，在仓库目录运行：

```sh
bash scripts/build.sh
```

产物位于 `.build/AWS 余量.app` 和 `dist/`，按构建机器架构生成。构建只使用系统框架，不下载 Swift 包，不读取 AWS 凭证，不安装或启动应用。将应用放到固定位置后再配置，便于登录项和钥匙串管理。

## 数据含义与边界

余额来自 [AWS GetCredits](https://docs.aws.amazon.com/cli/latest/reference/billing/get-credits.html)。有完整预计金额时优先显示预计余额，否则显示结算余额；当前面板仅汇总有效的 USD 抵扣金。汇总组织还是单个账户，由 `payerAccount` 和身份实际权限共同决定。空响应按异常处理，请去 AWS 账单核对。

流量使用 [Lightsail NetworkIn / NetworkOut 指标](https://docs.aws.amazon.com/lightsail/2016-11-28/api-reference/API_GetInstanceMetricData.html) 的小时合计，按 UTC 自然月累计，月额度从实例 API 读取。界面沿用 GB/TB 标注，计算基数分别为 1024³ / 1024⁴ 字节。显示的是监控估算，受指标延迟、缺失和套餐变更影响，不是实时逐包计费统计。

[AWS 的流量规则](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-faq-data-transfer-allowance.html) 会把入站和出站都计入额度；超额计费针对符合收费条件的出站流量。相同区域同套餐实例可能共享额度，删除重建也不会重置。因此，多实例、月内换套餐/重建时，**单台实例监控得到的剩余值不等于账户整个共享池的剩余值**，应以 AWS 账单为准。

应用不会阻止 AWS 继续收费，也不会停止或删除资源；抵扣金耗尽、过期或流量超额后，你仍需自行决定并处理云资源。通知需要 Mac 正常运行并允许系统通知，不能替代云端账单告警。

## 隐私与许可

没有埋点和第三方数据上报。账户配置、用量缓存和密钥均由使用者在本机配置，公开仓库及安装包不包含发布者的私人数据。详见 [隐私说明](PRIVACY.md)。

MIT License，见 [LICENSE](LICENSE)。本项目为独立工具，与 Amazon Web Services 无隶属关系。

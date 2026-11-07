# 专用只读身份

应用不会创建 IAM 身份。请由你现有的 AWS 管理入口配置专用查询身份，再把这一个身份的密钥写入本机钥匙串。不要使用根用户密钥或管理员密钥。

## 同一账户

将 [readonly-same-account.json](../examples/readonly-same-account.json) 附加到专用 IAM 查询用户。将 `aws:RequestedRegion` 换成 Lightsail 实例所在区域；如果只看抵扣金，删除 Lightsail 那条 Statement。

组织策略、权限边界及账单可见范围仍会限制读取结果。使用账单控制台核对数据时，账户还需启用 IAM 对控制台的访问；这个控制台开关不能替代 SDK/API 的 IAM 授权。`payerAccount: false` 查询配置账户的抵扣金；管理账户设置为 `true` 时会汇总合并账单组织下的抵扣金。普通成员账户不会因为设置为 `true` 就获得管理账户权限。参见 [GetCredits](https://docs.aws.amazon.com/cli/latest/reference/billing/get-credits.html) 和 [IAM 账单访问说明](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/control-access-billing.html)。

## 账单与实例跨账户

1. 在有权查询抵扣金的账户中建立专用 IAM 用户，附加 [readonly-cross-account-billing.json](../examples/readonly-cross-account-billing.json)。把其中 `000000000000` 换成实例所属账户 ID，角色名换成实际只读角色名。
2. 在实例所属账户中建立角色，权限使用 [readonly-cross-account-traffic.json](../examples/readonly-cross-account-traffic.json)，区域改成实际区域。
3. 角色的信任策略使用 [readonly-cross-account-trust.json](../examples/readonly-cross-account-trust.json)。把 `111111111111` 及用户路径换成第一步那个**专用查询用户的准确 ARN**，不信任整个账户的所有身份。
4. 在应用配置的 `traffic.roleARN` 中填写第二步的角色 ARN。基础用户密钥放钥匙串；角色会话由每次流量查询临时获取，不额外保存。

这是有意保留的只读边界：基础长期身份只用于查询；STS 临时角色凭证的自动获取不会要求日常反复浏览器登录。若基础身份本身使用临时 Session Token，则它仍会到期，应用不负责续签。

## 权限范围

应用正常使用的接口只有 `billing:GetCredits`、可选 `sts:AssumeRole`、`lightsail:GetInstance` 和 `lightsail:GetInstanceMetricData`。示例另包含 `aws-portal:ViewBilling` 以兼容账单访问授权。

这两个 Lightsail 查询动作不支持用实例 ARN 或标签收窄权限，因此示例使用 `Resource: "*"` 加区域条件。这意味着专用身份能通过这两个动作读取所选区域中的其他实例；应用本身只查询配置中的一个实例。参见 [Lightsail 权限支持表](https://docs.aws.amazon.com/service-authorization/latest/reference/list_lightsail.html)。

示例没有服务器创建、修改、停机或删除权限。不要为解决读取失败而直接附加管理员权限。


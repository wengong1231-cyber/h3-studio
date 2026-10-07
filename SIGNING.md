# 本机固定签名与文件授权

正式构建使用同一个证书签名，身份要求同时绑定应用标识符和实际证书。缺少身份时构建失败，不自动生成新证书、不回退临时签名。安装器在覆盖前核对新包是否满足旧包的签名身份要求。

`python3 scripts/create-local-signing-identity.py` 只显示创建计划。明确授权创建本机私钥后，使用 `--create` 创建一次本地开发签名：私钥不可导出，保存在登录钥匙串，允许 Apple 的 `/usr/bin/codesign` 使用；公开指纹配置保存在应用的 Application Support/Signing/identity.json。临时私钥文件只存在于权限为700的临时目录内，导入后清除。配置、证书及私钥不上传源码仓库。

这不是 Developer ID 签名或公证，不能冒充公开分发资格。也不添加受信任根、不修改 TCC、不授予完全磁盘访问、不自动点击系统授权。首次从临时签名切换时，macOS 可能需要重新确认现有目录权限；之后继续使用固定证书与同一应用标识。

1. 运行 `scripts/build.sh`，它先核对持久签名身份。
2. 运行 `scripts/verify.sh`，测试绑定实际签名后的二进制。
3. 审查 `scripts/install-user.sh --plan` 的签名迁移信息。
4. 仅首次迁移使用 `--install-with-initial-signing-migration`；后续使用 `--install`。运行中的应用仍由互斥锁保护，旧版保存为可恢复 ZIP。

固定证书丢失、过期或需要更换时必须停止并重新审查，不能偷偷轮换。系统权限数据库或用户授权发生变化仍由 macOS 决定；固定身份不保证系统永远不再请求新的权限。

依据：[Apple TN3127：身份要求与权限](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)、[Apple 代码签名指南](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html)。

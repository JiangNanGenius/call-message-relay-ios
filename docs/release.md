# CallRelay 发布流程（双变体，Feather 源纯原生）

每次更新同时发布两个**未签名**构建，共用同一营销版本与核心修复；Feather 安装源
永远只指向纯原生版。本文件是公开、可复现的发布流程；当前版本的实测证据记录在
工作区的 `evidence/h28k/build13-repair/`。

| 变体 | Xcode 配置 | 桥接 | 渠道 |
| --- | --- | --- | --- |
| Feather 纯原生 | `Release`（默认） | 无 Bark/快捷指令桥接 | GitHub Release 未签名 IPA + Feather 源；私有签名 IPA 只交给所有者 |
| App Store Bark/快捷指令 | `Release-Bark` | 可选 Bark + Check-incoming-call AppIntent、`callrelay://` | GitHub Release 未签名 IPA；App Store 仅在明确授权后提交 |

桥接由编译条件 `BARK_BRIDGE` 与 `Info-Bark.plist` 隔离；默认构建不含 Bark UI、
deeplink 或 AppIntent 元数据。

## 工具

- `Scripts/package-release-variants.sh` — 构建两个变体（`CODE_SIGNING_ALLOWED=NO`）、
  按版本打包 IPA、逐个校验并生成 `SHA256SUMS.public.txt`。
  默认把编译缓存放在 `~/Library/Caches/CodexBuild/callrelay/release-variants/`
  （可用 `DERIVED_DATA_ROOT` 覆盖）；`--app-native/--app-bark` 可对已有构建产物
  只做打包+校验。
- `Scripts/verify-release-variant.sh` — 验证单个 `.app`/`.ipa`：native 必须无
  `Metadata.appintents`、无 `CFBundleURLTypes`、无 `BarkBridge.strings`、二进制无桥接符号；
  bark 必须具备以上内容；两者都必须未签名（无 `embedded.mobileprovision`、
  无 `_CodeSignature`），版本号可选断言。
- `Scripts/update-feather-source.py` — 从实际原生 IPA 生成/更新 `feather.json`：
  读取真实大小与 SHA-256，拒绝任何含 Bark 内容的 IPA，`--feed` 合并历史版本。
- `.github/workflows/build.yml` — 原生单元/UI 测试、两个变体的无签名真机构建、
  变体身份校验，并运行 Feather 生成器做纯原生自检。

## 发布步骤

1. 在 `project.yml` 同时更新 `MARKETING_VERSION` 与 `CURRENT_PROJECT_VERSION`
   （两个变体共用），提交到 `main`。
2. 构建、打包、校验两个变体：
   ```sh
   ./Scripts/package-release-variants.sh
   # 或对已有构建：
   ./Scripts/package-release-variants.sh \
     --app-native <native CallRelay.app> --app-bark <bark CallRelay.app>
   ```
   产物形如 `build/feather-<version>-<build>/`：
   - `CallRelay-Feather-Native-<version>-<build>-unsigned.ipa`
   - `CallRelay-AppStore-Bark-<version>-<build>-unsigned.ipa`
   - `SHA256SUMS.public.txt`
3. 生成/更新 Feather 源（只能使用原生 IPA；脚本会拒绝 Bark 包）：
   ```sh
   ./Scripts/update-feather-source.py \
     build/feather-<version>-<build>/CallRelay-Feather-Native-<version>-<build>-unsigned.ipa \
     --tag v<version> --feed feather.json --output feather.json
   ```
4. 提交 `feather.json`/文档，打标签并推送：
   ```sh
   git tag v<version> && git push origin main v<version>
   ```
5. 创建 GitHub 预发布（保持与既有版本一致的 prerelease），只上传两个未签名 IPA
   与校验和：
   ```sh
   gh release create v<version> --prerelease \
     --title "CallRelay <version> (<build>)" --notes-file <release-notes.md> \
     CallRelay-Feather-Native-<version>-<build>-unsigned.ipa \
     CallRelay-AppStore-Bark-<version>-<build>-unsigned.ipa \
     SHA256SUMS.public.txt
   ```
   为避免与本地文件名混淆，上传时把 `SHA256SUMS.public.txt` 命名为 `SHA256SUMS`。
6. 用未登录下载复核：`shasum -a 256 -c SHA256SUMS`、逐一打开 Feather 源中的
   下载地址，并核对 `size`/`sha256`/`version` 与实际资产一致。

## 安全红线

- GitHub 公开资产只能包含两个未签名 IPA 与校验和：不得含
  `embedded.mobileprovision`、`_CodeSignature`、`.p12`/`.p8`、描述文件、设备列表
  或签名身份；发布前运行 `Scripts/verify-release-variant.sh` 验证。
- 私有签名 IPA 与 `.xcarchive` 只保留在所有者控制的私有位置，绝不进入公开渠道。
- Feather 源只能指向纯原生未签名 IPA；App Store/TestFlight 上传需要单独的明确授权。
- 已发布版本与其标签/资产视为不可变：下一个版本使用新的补丁版本号，不覆盖旧资产。

## 当前版本 (0.3.6 build 13)

- 原生：456 单元测试 + 12 非视觉 UI 测试通过；Bark：474 单元测试通过；两个
  `Release` 变体真机配置编译通过（本地证据见工作区 `evidence/h28k/build13-repair/release-build-0.3.6-13.md`）。
- 已知物理关卡：原生 APNs 后端（provider）尚未配置，真机锁屏 VoIP 来电未验证；
  Bark 锁屏自动化（iOS 27 通知自动化）未在真机验证，保留手动点按回退。

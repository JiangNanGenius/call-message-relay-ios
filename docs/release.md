# CallRelay 发布流程（双变体，Feather 源纯原生）

每次更新同时发布两个**未签名**构建，共用同一营销版本与核心修复；Feather 安装源
永远只指向纯原生版。本文件是公开、可复现的发布流程；当前版本的实测证据记录在
工作区的 `evidence/h28k/build15-repair/`。

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

## 当前版本 (0.3.8 build 15)

- 配合网关音频修复（H28K `callrelay-worker`：ALSA 采集周期 128 ms → 20 ms 语音帧，
  消除下行 6–7 帧突发导致的持续丢帧与静音，实测修复前管道读间隔中位数 0.01 ms +
  128 ms 空洞、修复后中位数 20.0 ms）：修复 0.3.7(14) 真机反馈的直连与中继通话
  声音断续、中继几乎无声。
- App：解除配对不再清除设备级 VoIP 令牌（修复重新配对后后台来电可能一直不响、
  需重启应用才恢复的路径）；诊断新增双向音频电平聚合、节拍间隔证据、PushKit
  接收→决定→上报生命周期日志（详见 `evidence/h28k/build15-repair/app-diagnostics.md`）。
- 测试：原生 486 单元 + 15 UI 通过；Bark 504 单元通过；网关 `go test ./...` 绿
  （含确定性突发/匀速对比回归）。本地证据见工作区 `evidence/h28k/build15-repair/`。
- 发布：`v0.3.8` 预发布包含两个未签名 IPA 与 `SHA256SUMS`；私有签名原生 IPA
  仅交付 iCloud Drive 根目录（保留 0.3.7-14 签名包作回滚）。
- 已知物理关卡（诚实边界）："通话安静"投诉的方向性根因依赖新电平计数器在真机
  复测后确认；后台来电系统级响铃的根因尚未观测确认（本版本提供贯通判定日志，
  不声称已修复）；构建 15 的真机通话与锁屏验收由用户完成。

## 历史版本 (0.3.7 build 14)

- 修复 0.3.6(13) 真机反馈：CallKit 音频激活转发到全部媒体会话（中继通话不再无声）、
  路由切换可取消且有界（不再卡死/被旧候选覆盖）、设置→关于→诊断新增有界脱敏日志与
  一键导出（两版本均含）。
- 测试：原生 480 单元 + 15 UI 通过；Bark 498 单元 + 15 UI 通过；两个 `Release` 变体
  无签名真机配置编译通过；CI run `37132684112`（commit `5948948`）全绿。
  本地证据见工作区 `evidence/h28k/build14-repair/`。
- 发布：`v0.3.7` 预发布包含两个未签名 IPA（Feather 纯原生、AppStore Bark）与
  `SHA256SUMS`；Feather 源只指向纯原生 IPA。
- 已知物理关卡（诚实边界）：构建 14 尚未在物理真机完成通话与锁屏验收，不声称真实
  通话已通过；H28K 个人网关已配置沙箱 APNs provider（生产/TestFlight 推送未配置）；
  Bark 锁屏自动化未在真机验证，保留手动点按回退。

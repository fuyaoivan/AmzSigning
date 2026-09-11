# AmzSigning

原生 macOS 自动续签工具。通过 Xcode 命令行工具，为已配对 iPhone 上的原生项目更新开发签名并覆盖安装；运行期间无需打开 Xcode 图形界面。

## 运行要求

- macOS 14 或更新版本，完整 Xcode（Swift 5.10 或更新版本），命令行开发目录指向该 Xcode。
- Xcode 已完成初始化并登录使用者自己的 Apple 账号。
- 工程使用 Automatic Signing 和 Personal Team。
- iPhone 已完成设备信任、开发者模式配置和首次配对。
- iPhone 已安装目标 App，Bundle ID 与 Team 和源码一致。

本工具处理本地 Xcode 工程，不处理任意 IPA 或 App Store 应用。首次 Apple 登录、双重认证、设备信任和配对仍需使用者完成。应用不保存 Apple 账号密码。

## 构建与安装

下载源码并解压，或克隆仓库。在目标 Mac 双击 `Install.command`，或在源码根目录执行：

```sh
./scripts/install.sh
```

安装程序在当前目录生成 `AmzSigning.app`，校验签名并完整替换旧应用。替换前等待后台任务结束、关闭该安装位置的设置窗口；失败时恢复原应用。安装结束清理 `.build/`、`.swiftpm/`、`dist/` 并打开应用。

应用使用本机临时代码签名，无 Developer ID 分发签名或 Apple 公证。在其他 Mac 使用时，应复制或下载源码，在该 Mac 构建并配置自己的 Apple 账号与 iPhone。不要复制已有安装的 `Data/`。

仅构建可运行应用：

```sh
./scripts/build.sh
```

构建产物位于 `dist/AmzSigning.app`。正式安装使用 `scripts/install.sh`；直接运行构建产物会在其同级目录创建独立数据目录。

## 项目管理

首次启动的项目列表为空，没有内置项目、Team、设备或扫描目录。

1. 在“我的项目”点击“扫描项目”，选择源码目录，可多选。
2. 扫描 `.xcodeproj`、`.xcworkspace`，读取原生 iPhone App Target、Scheme、构建配置、Bundle ID、签名 Team 和本机签名到期时间。
3. 新发现的项目默认关闭。开启项目后纳入自动续签。
4. 项目卡片的移除按钮停止管理该项目，不删除源码、不卸载手机 App。再次手动扫描可重新添加，默认关闭。

扫描是一次性添加或刷新操作。打开窗口、登录、唤醒和时间经过均不会创建扫描请求。已添加项目独立管理，其续签资格不依赖扫描目录。

扫描期间新增的请求会保留；旧请求的结果不会覆盖新请求。移除项目后，执行中的旧扫描不能将其重新加入；旧续签结果不能写入重新添加的管理记录。扫描其他目录不会使已有项目失效。

## 运行模式与调度

| 模式 | 行为 |
| --- | --- |
| 自动模式 | 已开启项目以上次成功覆盖安装时间为基准，满 6 天自动续签；失败后每 6 小时重试，成功后重置 6 天周期 |
| 离开模式 | 停止自动续签、手动续签和重试；返回自动模式后补查到期项目 |

“立即续签”对已启用项目立即执行，仍遵守当前模式和安装校验。模式切换或移除项目会在后续安装检查点阻止旧任务；已提交给设备的安装不能撤回。

当前用户的 LaunchAgent 使用 `RunAtLoad` 和分钟级 `StartCalendarInterval`。用户登录后补查，睡眠期间错过的日历事件由 macOS 在唤醒后合并触发。每次执行先检查状态与资源保留期限；无显式扫描请求或到期项目时立即退出，不连接设备或遍历项目目录。没有 `KeepAlive` 或常驻菜单栏进程，关闭最后一个设置窗口后应用退出。

设备通过 Apple `devicectl` 连接。同一可互通网络支持无线连接，也支持 USB。首次续签绑定唯一匹配的已配对 iPhone，重试不会自动换机。已信任 USB 设备可通过 `xcdevice enable` 启用当前 Mac 的无线调试。Mac 关机、设备离线或 Apple 签名服务不可用时无法完成续签。

## 覆盖安装与签名校验

安装仅调用 `devicectl device install app`。安装前确认原 App 存在；代码不提供卸载、清空数据容器或删除设备文件的接口。

开启项目时记录 Bundle ID 与 Team。每次续签读取该项目的实时构建设置，并校验 Automatic Signing、Personal Team、签名身份、源码版本、原 App、描述文件中的设备和有效期。构建后验证代码签名及嵌套扩展签名，拒绝身份变化、版本回退及有效期不足的产物。

工程未显式设置 `DEVELOPMENT_TEAM` 时，仅在现有描述文件唯一确认 Personal Team 后将其传入本次构建，不改写工程。请求新签名时，精确匹配本次 Bundle ID 和 Team 的本机 Personal Team 描述文件暂存至恢复区，由 Xcode 请求签名。正常结束后恢复，异常退出后由下一次任务恢复；不撤销证书。

新签名有效期必须大于 6 天加 1 小时。安装返回成功且再次查到目标 App 后才记录成功时间。界面区分最近一次已验证安装的到期时间与尚未验证安装的本机描述文件到期时间。

## 本地文件与资源回收

正式安装的全部应用文件和工具运行数据位于 AmzSigning 目录：

```text
AmzSigning/
├── AmzSigning.app/
├── Data/
│   ├── state.json
│   ├── AmzSigningAgent.plist
│   ├── Logs/
│   ├── Builds/
│   ├── Temp/
│   └── ProfileBackups/
├── Sources/
├── Tests/
└── scripts/
```

| 文件或目录 | 保留策略 |
| --- | --- |
| `Data/state.json` | 项目、设备绑定、续签时间、运行摘要；原子写入，权限 0600 |
| `Data/Logs/` | 最多 20 份、14 天、总计 20 MB，单份上限 2 MB |
| `Data/Builds/` | 专用 DerivedData；成功或失败后删除，异常残留下次执行回收 |
| `Data/Temp/` | 命令输出和设备查询文件完成即删除，超过 1 小时的异常临时残留回收 |
| `Data/ProfileBackups/` | 描述文件恢复区，恢复后删除；恢复失败保留原材料 |

macOS 要求在 `~/Library/LaunchAgents/org.amzsigning.agent.plist` 注册登录调度。该位置仅为指向 `Data/AmzSigningAgent.plist` 的符号链接。移动整个目录后应重新打开应用，以更新调度路径。Apple 账号、钥匙串、系统窗口状态与 Xcode 自行管理的签名材料遵循系统存储位置。

命令输出超过 32 MB 时停止执行。设备探测通常限时 20 秒、构建 10 分钟、安装 2 分钟；超时结束子进程组。构建要求至少 2 GB 空闲磁盘。后台任务由文件锁串行执行，设置写入通过独立短锁合并最新状态。配置损坏或未知版本时停止操作。

`Data/`、`AmzSigning.app/`、构建缓存、日志与签名材料均不纳入版本控制。发布仅包含源码、测试、构建脚本和技术文档；不包含使用者的项目列表、真实 Team、设备标识、账号或本地绝对路径。

## 开发接口

```sh
swift test --cache-path .build/Cache --manifest-cache local
.build/debug/AmzSigningAgent status
.build/debug/AmzSigningAgent scan /path/to/projects
.build/debug/AmzSigningAgent tick
.build/debug/AmzSigningAgent renew
```

`scan` 可指定多个目录，仅执行扫描；无参数时处理已经提交的扫描请求。`renew` 可附加项目 ID。`tick` 处理显式请求和到期项目。调试执行程序的数据位于源码根目录的 `Data/`，与正式安装共享；开发验证应使用测试提供的隔离 `Paths`。

| 模块 | 职责 |
| --- | --- |
| `AmzSigningCore` | 项目发现、签名、设备连接、状态、进程管理、资源回收 |
| `AmzSigningAgent` | 一次性命令入口、任务锁和调度 |
| `AmzSigning` | SwiftUI 设置界面与状态同步 |
| `BrandArtwork.swift` | 图标和窗口标识共用的矢量源与品牌色 |

状态格式 v2 自动迁移 v1 项目记录，保留开关、身份、设备和成功时间。旧扫描范围与预设项目逻辑不再使用；旧自动模式迁移为自动模式，其余暂停状态迁移为离开模式。

版本由 `Resources/Info.plist` 统一提供。初始基线为 v1.0.0，修复递增 Patch，兼容新功能递增 Minor；`CFBundleVersion` 单独递增。详见 [版本记录](CHANGELOG.md) 和 [验证说明](docs/verification.md)。

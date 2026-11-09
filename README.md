# AmzSigning

原生 macOS 自动续签工具。通过 Xcode 命令行工具，为原生项目更新开发签名，支持向已配对 iPhone 首次安装及后续覆盖续签；运行期间无需打开 Xcode 图形界面。

## 运行要求

- macOS 14 或更新版本，完整 Xcode（Swift 5.10 或更新版本），命令行开发目录指向该 Xcode。
- Xcode 已完成初始化并登录使用者自己的 Apple 账号。
- 工程使用 Automatic Signing 和 Personal Team。
- iPhone 已完成设备信任、开发者模式配置和首次配对。
- 自动续签要求 iPhone 已安装目标 App，Bundle ID 与 Team 和源码一致；首次安装须通过“安装到 iPhone”明确选择设备。

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

## 安装到新 iPhone

1. 用 USB 连接新 iPhone，完成设备信任、开发者模式和首次配对。之后可使用已经配置好的 Wi-Fi 连接。
2. 在“我的项目”开启需要安装的项目，点击“安装到 iPhone”。
3. 选择设备并勾选项目，点击“安装并绑定”。同名设备可通过标识尾号区分；设备不会自动选中。

该操作允许目标手机尚未安装 App。目标已有同一 App 时进行覆盖安装，安装前再次检查版本，拒绝回退。签名仍使用项目现有 Automatic Signing 与 Personal Team；必要时通过 Xcode 注册所选设备，保留 Apple 账号的设备及 App 数量限制。

每个项目分别提交安装结果：只有安装成功且再次查询到 App 后，才将该项目绑定至所选设备，并从成功时间开始计算六天续签周期。失败项目保留原设备绑定、成功记录和重试期限；成功项目不回滚。旧手机 App 不会卸载，工具不迁移业务数据；数据由 App 自身的备份或同步机制恢复。

首次安装为一次性手动请求，不持久化到后台队列、不自动重试。设备离线时不会改用另一台设备；进程中断后不会自动在新手机重复安装。离开模式、停用、移除、重新添加项目或更改签名身份会使旧请求失效。已提交给设备的安装无法撤回；此后若项目记录改变，不把结果写入替换记录。

设备发现只在打开安装窗口或点击刷新时执行，不扫描源码目录。没有连接新设备时，旧配对记录可能仍显示；正式安装前会重新确认所选设备及原有 App 状态。

## 运行模式与调度

| 模式 | 行为 |
| --- | --- |
| 自动模式 | 已开启项目以上次成功覆盖安装时间为基准，满 6 天自动续签；失败后每 6 小时重试，成功后重置 6 天周期 |
| 离开模式 | 停止自动续签、手动续签和重试；返回自动模式后补查到期项目 |

“立即续签”对已启用项目立即执行，仍遵守当前模式和安装校验。处理错误时的“立即重试”仅处理已有失败记录的启用项目，不重复构建正常项目。模式切换或移除项目会在后续安装检查点阻止旧任务；已提交给设备的安装不能撤回。

当前用户的 LaunchAgent 使用 `RunAtLoad` 和分钟级 `StartCalendarInterval`。用户登录后补查，睡眠期间错过的日历事件由 macOS 在唤醒后合并触发。每次执行先检查状态与资源保留期限；根据缓存及更新状态完成必要的只读环境检查；无显式扫描请求或到期项目时退出，不连接设备或遍历项目目录。没有 `KeepAlive` 或常驻菜单栏进程，关闭最后一个设置窗口后应用退出。

设备通过 Apple `devicectl` 连接。同一可互通网络支持无线连接，也支持 USB。首次续签绑定唯一匹配的已配对 iPhone，重试不会自动换机。首次无线连接在 Xcode 的设备管理界面完成配对；已配对设备通过 CoreDevice 自动选择可用连接，不依赖旧版 `xcdevice enable`。Mac 关机、设备离线或 Apple 签名服务不可用时无法完成续签。

## 更新后的运行环境检查

自动模式下，有已启用项目时会检查当前开发工具路径和系统、Xcode、许可状态文件的变化。优先使用系统选定的完整 Xcode；选中 Command Line Tools 或原路径失效时，查找已安装的完整 Xcode，通过本次进程的 `DEVELOPER_DIR` 使用，不修改系统选择或项目配置。

检查使用 `xcodebuild -version`、`-checkFirstLaunchStatus`、iPhone SDK 定位和 `devicectl` 定位命令。健康结果缓存 6 小时；系统或工具标识变化立即重新检查，实际续签前也复检。阻塞期间每 5 分钟执行只读环境检查，不启动构建或连接 iPhone。许可状态变化可提前触发复检。

| 更新后的状态 | 处理方式 |
| --- | --- |
| 工具路径变化 | 自动定位完整 Xcode，并统一传给本次全部子进程 |
| 新许可尚未确认 | 显示具体原因并通知使用者，等待本人阅读、确认 |
| 首次启动或平台组件未完成 | 提示在 Xcode 完成初始化或组件安装 |
| 环境恢复 | 自动清除属于该环境问题的等待期限，补做已到期续签 |
| 设备列表信息不完整 | 读取设备详情，核对原设备身份、真机类型、配对和开发者模式 |
| 更新后设备锁定 | 提示解锁目标 iPhone，完成首次开发镜像准备后重试 |
| Apple 登录、设备信任或开发者模式失效 | 给出对应操作提示，保持覆盖安装限制及失败重试规则 |

环境阻塞独立于项目安装失败。离线、构建失败等普通错误仍按 6 小时重试，环境检查不会提前清除这些等待期限，也不会重置上次成功时间。升级旧配置时，已知的旧 Xcode 环境错误可在检查通过后恢复。

设置窗口仅在环境检查与调度均正常时显示“自动续签已就绪”。需要本人处理时，显示原因及“打开 Xcode”“检查并恢复”或“立即重试”操作。Xcode 未配置账号或会话失效时需要本人登录；登录服务的网络连接失败不直接判定为账号失效。错误分类保留 `xcodebuild` 多行错误中的目标设备原因，识别超时后附带的解锁要求；排除无关账号警告与编译器源码摘录。设备开发连接暂不可用时按普通失败重试，不自动取消配对或改变信任。

首次打开设置窗口会请求 macOS 通知授权。未获授权时，设置页显示“问题提醒未开启”及系统通知设置入口；应用不会自行更改系统授权。通知仅在系统接受提交后记录提交时间，持续问题成功提交后不重复发送。权限未开放、发送失败或进程中断均保留待处理状态，每六小时短暂重试；重新授权并返回设置窗口后可立即补交仍有效的提醒。通知进程不创建设置窗口，完成后退出。系统接受提交不代表使用者已经看到提醒，实际展示仍受系统通知与专注模式设置影响。

Xcode 账号缺失属于外部授权阻塞，不能通过重建缓存或自动重复启动 Xcode 恢复。工具不修改 Xcode 账号列表、存储登录凭据或清理钥匙串；无法保证外部程序、系统或账号状态变化后仍保有登录。

工具不会代替使用者接受协议、输入账号密码或取消设备安全要求。完成必要授权后可继续自动续签，无需保持 Xcode 图形界面打开。更新后的设备协议使用 Xcode 27 的 `properties` 结构，同时兼容旧字段；缺失字段表示状态未知，不能作为开发者模式关闭或设备不存在的依据。

## 覆盖安装与签名校验

安装仅调用 `devicectl device install app`。自动续签在安装前确认原 App 存在；显式“安装到 iPhone”请求允许首次安装。两种操作共用签名和版本校验，代码不提供卸载、清空数据容器或删除设备文件的接口。

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
| `Data/Temp/` | 每次命令的独立临时目录、输出、Xcode 结果包和设备查询文件完成即删除，超过 1 小时的异常残留回收 |
| `Data/ProfileBackups/` | 描述文件恢复区，恢复后删除；恢复失败保留原材料 |

macOS 要求在 `~/Library/LaunchAgents/org.amzsigning.agent.plist` 注册登录调度。该位置仅为指向 `Data/AmzSigningAgent.plist` 的符号链接。移动整个目录后应重新打开应用，以更新调度路径。Apple 账号、钥匙串、系统窗口状态与 Xcode 自行管理的签名材料遵循系统存储位置。

每次命令拥有独立 `TMPDIR`。工程查询与构建显式指定 `-resultBundlePath`，使成功及失败结果包均位于该命令的临时目录；正常返回、非零退出、启动失败或超时后统一回收。不会以清理本工具为由删除共享 Xcode 缓存、账号配置或钥匙串。

命令输出超过 32 MB 时停止执行。超时使用包含系统睡眠时间的 [ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock) 单调时钟，唤醒后终止已超过期限的运行任务。设备探测通常限时 20 秒、构建 10 分钟、安装 2 分钟；超时结束子进程组。构建要求至少 2 GB 空闲磁盘。后台任务由文件锁串行执行，设置写入通过独立短锁合并最新状态。配置损坏或未知版本时停止操作。

`Data/`、`AmzSigning.app/`、构建缓存、日志与签名材料均不纳入版本控制。发布仅包含源码、测试、构建脚本和技术文档；不包含使用者的项目列表、真实 Team、设备标识、账号或本地绝对路径。

## 开发接口

```sh
swift test --cache-path .build/Cache --manifest-cache local
amz_bin="$(swift build --show-bin-path)"
"$amz_bin/AmzSigningAgent" status
"$amz_bin/AmzSigningAgent" check
"$amz_bin/AmzSigningAgent" scan /path/to/projects
"$amz_bin/AmzSigningAgent" tick
"$amz_bin/AmzSigningAgent" renew
"$amz_bin/AmzSigningAgent" retry
"$amz_bin/AmzSigningAgent" devices
```

`devices` 返回当前 iPhone 列表 JSON，包含本机设备标识，不应公开。`install-device <request-json>` 是设置界面的内部一次性接口，请求包含精确设备 UDID 和项目身份快照；进程持有任务锁时执行，忙碌时返回非零退出码，取消的请求不会被静默排队。

`scan` 可指定多个目录，仅执行扫描；无参数时处理已经提交的扫描请求。`renew` 可附加项目 ID；`retry` 只立即重试失败的启用项目。`tick` 处理环境检查、显式请求和到期项目；`check` 强制检查环境，并在自动模式下恢复已到期项目。调试执行程序的数据位于源码根目录的 `Data/`，与正式安装共享；开发验证应使用测试提供的隔离 `Paths`。

| 模块 | 职责 |
| --- | --- |
| `AmzSigningCore` | 项目发现、签名、设备连接、状态、进程管理、资源回收 |
| `AmzSigningAgent` | 一次性命令入口、任务锁和调度 |
| `AmzSigning` | SwiftUI 设置界面与状态同步 |
| `BrandArtwork.swift` | 图标和窗口标识共用的矢量源与品牌色 |

运行环境和通知使用 v2 状态中的可选字段，兼容已有 v2 配置。v1.2.0 的通知 `attempted` 标记没有提交回执，升级时作为未确认处理，保留问题标识并允许再次提交。状态格式 v2 自动迁移 v1 项目记录，保留开关、身份、设备和成功时间。旧扫描范围与预设项目逻辑不再使用；旧自动模式迁移为自动模式，其余暂停状态迁移为离开模式。

版本由 `Resources/Info.plist` 统一提供。初始基线为 v1.0.0，修复递增 Patch，兼容新功能递增 Minor；`CFBundleVersion` 单独递增。详见 [版本记录](CHANGELOG.md) 和 [验证说明](docs/verification.md)。

## Apple 技术参考

- [安装 Xcode 组件与设备支持更新](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components)
- [设备配对与无线连接](https://developer.apple.com/documentation/xcode/pairing-your-devices-with-your-mac)
- [设备开发者模式](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
- 当前 Xcode 随附的 `xcodebuild(1)` 手册和 `xcrun devicectl help device info details`。

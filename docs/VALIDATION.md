# 验证记录

日期：2026-10-30。此记录区分编译、本机协议测试、真机界面和实际接收效果。

| 项目 | 状态 |
|---|---|
| Theos rootless arm64 / arm64e 编译、签名、deb 打包 | 已通过 |
| iPad Pro iPad8,9 / iPadOS 15.2 / Dopamine 安装加载 | 已通过 |
| 微信 8.0.75 基础运行时接口检查 | 已通过，runtime.json |
| 微信 8.0.76 相关类和发送回调静态分析 | 已完成，未在该版本真机发送 |
| 聊天照片入口弹出来源选择 | 用户真机确认通过 |
| 飞牛登录并看到 NAS 照片 | 用户真机确认通过 |
| 系统相册原始入口、iPad 分屏和旋转 | 待真机逐项确认 |
| 普通图片最终上传及接收 | 用户真机确认发送完成，聊天中能打开 |
| GIF 原始字节与接收端动画 | 用户真机确认发送成功、动画正常 |
| 实况预览、发送及聊天中播放 | 用户真机确认预览与发送后的实况均正常 |
| 免越狱签名注入启动、钥匙串和发送 | 待签名工具与设备验证 |

## 已运行的本机测试

`tests/test_native.py` 编译实际 `FNProtocol.m`，运行 4 个测试组：

- IP/域名/IPv6/端口地址解析与无效地址拒绝；GET 签名与桌面端/NAS 网页向量一致，包含中文、空值、加号和重复参数。
- Security RSA PKCS#1 v1.5 与 CommonCrypto AES-CBC/PKCS7；由独立 Python 实现解密验证。
- 本地 HTTP/WebSocket 服务边界验证密码登录、两步验证、接口必填参数、跨天与收藏分页、跨域凭据保护和重定向拒绝。
- 测试钥匙串持久化、HMAC-SHA256 令牌恢复、短令牌失效后长期令牌续期。

测试不连接真实 NAS，不打印或读取真实 NAS 密码/令牌。

## 真机发现并修复的问题

1. 全屏相册展示会使底层聊天视图暂离窗口。原来的 `chat.view.window` 防误发条件造成误拦截，已改用相册展示关系、导航状态、delegate 与接收会话验证。
2. `MMAssetForLocalImage` 只具备本地预览能力，其父类大图回调是空实现，原始数据回调报告不支持。消息提交后上传因此无法完成；已增加自有素材子类，实现原始字节、大图及独立 EXIF 信息回调，最终发送已由用户真机确认。
3. 大图回调的第二参数是 NSData，不能传 EXIF 信息对象；已从真机回调签名确认并纠正。原生要求 ProcessBlock 先于 ResultBlock 执行，已补齐两个阶段，并增加顺序测试。
4. 微信本地素材类默认不识别 GIF；自有子类按原始文件识别，保留 GIF 字节。
5. 真机 8.0.75 的实况视频大小 setter 使用 `q`，兼容 `q/Q`；静态核对实况视频成功回调实际传 NSURL，已按该类型实现。

插件仅在用户点击“发送”时进入原生发送接口。联调不自动向联系人发消息。

## 最终验收边界

用户在测试聊天逐项确认普通图片、GIF 动画、实况预览与发送后播放正常；未独立读取其他联系人的聊天内容。跨设备接收方兼容性、未提供的免越狱签名环境、分屏与旋转仍分别列为待验证，不扩展已有结果。

0.1.0 正式构建曾重新安装至测试 iPad；读取安装目录 dylib 与 rootless deb 内 payload 比较，字节完全一致，SHA-256：`f433fb352f7985b99e195f9ca97f7f4897d338473e3c38e1098b7f618a28c3d0`。正式包已排除素材自检和回调跟踪代码，重启后微信进程正常，8.0.75 接口检查通过。两种 deb 的目录布局、架构、系统框架依赖及签名注入包的独立性已自动检查。

## 0.1.1：预览后切换原图的闪退修复

排查中发现图片处理回调此前以 `id` 跨异步保存，没有明确复制微信传入的栈 Block；一份故障记录的 PC 落在栈地址，与这类悬空回调风险一致。新增 `FNImageDelivery`，在原调用返回前复制处理和完成回调，并维持处理在先、完成在后的顺序；两个素材适配入口统一使用此持有对象。

新增原生回归用例：创建捕获局部变量的回调，退出创建函数、扰动栈后异步执行，检查参数、处理/完成顺序，并检查两个回调都已经复制到堆。当前原生测试共 5 组通过。0.1.1 已部署到测试 iPad，安装的 dylib 已与新版 deb 内 payload 比较一致。用户完成“预览 → 多次切换原图 → 发送”的真机复测，确认不闪退、原图发送成功且聊天中可正常打开。

补充：宿主机 AddressSanitizer 模式运行超时，未计为通过；普通编译下的堆 Block 持有、异步生命周期与顺序回归测试通过。


## 0.2.0：日期快滑和 AI 搜索

- 日期条在照片、收藏、相册内使用 `/gallery/timeline` 完整日期索引，拖动显示年月日，松开通过日期范围直接读取 `/gallery/getList`；相册带 `album_id`，收藏带 `is_collect`，不依赖已加载页数。选中素材不随日期跳转清空，旧列表请求通过界面 generation 丢弃。
- AI 搜索移植 APK `PhotoSearchViewModel$submitAi` 的 `POST /magic-search/do`，请求体 `keyword` 与 `viewMode=simple`。非 GET 签名按 `SignerInterceptor.getRequestParamContent` 对实际发送的 JSON 字节做 MD5，避免中文、空格与 JSON 序列化次序不一致。
- 按结果 `idList` 使用 `POST /gallery/batchGetByIds` 每批 60 个获取完整素材详情，恢复 NAS 返回顺序；删除或无权限的条目允许缺失。成功后才提交分页游标，失败允许重试。搜索结果与普通列表共用预览、勾选与发送适配层。
- 明确处理 20701 模型不存在、4031 模型不一致、20703 模型准备中；不调用模型安装或重置接口。
- 本机 5 个原生测试组扩展覆盖：实际 HTTP POST 请求体签名、中文/引号/加号、AI 内层与外层模型错误、65 项分批详情和顺序恢复、跳转旧日期及返回最新日期、相册内日期过滤；原登录、MFA、持久化、跨天分页与 Block 生命周期用例继续通过。
- 0.2.0 新功能的拖动手感、分屏布局、真实 NAS AI 结果及从搜索结果发送，仍需真机交互确认。此前 0.1.1 的媒体验证不等同于新增界面验收。

0.2.0 两类 deb 编译、签名与依赖检查通过，并已通过 SSH 覆盖安装至同一台 Dopamine iPad。微信重开后主进程在运行；从设备读回已安装 dylib，与 rootless deb 内文件逐字节一致（SHA-256 `199a88f5dcb7ffd441d775bf2ee789268f0ed1d5e3691ed5d2f4b2aec4aece26`）。新增功能仍等待用户界面复测；没有自动向聊天发送测试消息。


## 0.2.1：日期条拖动与搜索输入修复

用户在 0.2.0 真机复测发现“滑块可见但不能拖动”“点击搜索框没有键盘”，因此 0.2.0 新功能不能计为验收通过。

修正浏览器容器层级：日期条移到 UICollectionView 外，与列表同级，避免列表 pan 手势取消 UIControl 跟踪；装饰轨道关闭触摸交互。搜索改为页面内直接嵌入 UISearchBar，移除 navigationItem.searchController 与 UISearchController 的二次展示。

`tests/test_browser_ui.py` 将实际 FNBrowser.m / FNTimelineScrubber.m 编译成独立模拟器测试 App，在 iPad Pro 11 英寸 / iOS 26 模拟器运行；使用合成照片和替代的 reload/loadMore，不连接 NAS，不调用微信或发送消息。10 项检查通过：滑块/轨道命中 UIControl、日期条在滚动视图外、滑块纵向位置可变、搜索栏在滚动视图外且不覆盖网格、无搜索模态层、输入框接受并保持第一响应者、收到软件键盘显示通知。检查不合成手指拖动事件，不能代替微信真机触摸手感验证。运行方式：先启动一个 iOS 模拟器，再运行 `../.venv/bin/python tests/test_browser_ui.py`；可用 FN_UI_SIMULATOR 指定设备 UUID。

原生协议与异步回调生命周期测试 5 组通过；rootless arm64/arm64e 与 injection arm64 两类 deb 编译、依赖检查通过。新增界面修正仍需在 iPadOS 15.2 / 微信 8.0.75 实机复测。

0.2.1 已通过 SSH 安装并重开微信。设备中 dylib 与新版 deb 内 payload 字节一致，SHA-256 `e9a5353f21eeb42260e982c767e43ffb1c52414f47403ac160d7f903a8708461`。


## 0.2.2：修正日期条触摸回调签名

0.2.1 用户复测仍报告两项交互异常；随后安装只增加视图诊断的同版开发包，用户确认搜索框已能弹出输入法，但日期条仍不能拖动。真机诊断显示搜索框成为第一响应者、系统键盘窗口存在，滑块所在位置的 UIWindow hitTest 正确命中 FNTimelineScrubber，且它不在 UICollectionView 内。因此仅改变布局并未解决日期条的直接原因。

对照 UIKit UIControl.h 发现三个方法误写成 `beginTracking:withEvent:`、`continueTracking:withEvent:`、`endTracking:withEvent:`；它们只是新增方法，系统不会调用。现改为 SDK 声明的 `beginTrackingWithTouch:withEvent:`、`continueTrackingWithTouch:withEvent:`、`endTrackingWithTouch:withEvent:`。这是日期条未处理拖动的直接代码缺陷。

模拟器回归补充使用合成 UITouch 子类，通过 UIControl 声明的系统回调驱动实际 FNTimelineScrubber，检查开始/继续产生值变化、移动到 75% 位置、松手恰好提交一次；原先的纯布局/命中测试无法发现错误回调签名，此前验证不足。测试仍不向系统注入手势，也不连接 NAS或调用微信发送。

正式包不包含 ui-probe.json 诊断逻辑，打包检查已增加对此的断言。真机拖动日期条、真实 AI 搜索与结果发送仍单独等待用户确认。

0.2.2 扩展后的模拟器检查共 12 项通过，包含系统回调驱动的值变化与单次松手提交。

0.2.2 已通过 SSH 覆盖安装并重开微信。已安装 dylib 与 rootless deb 中字节一致，SHA-256 `60a0799c1e23c38e7db10040170cdabaa5cc8aac6dccc4bad2bef42f7c566056`；正式二进制已移除视图诊断逻辑。


## 0.2.3：搜索输入使用独立弹窗

用户确认 0.2.2 日期拖动与日期跳转均正常；搜索栏点击后键盘再次未出现。此反馈说明先前诊断包中一次键盘成功不足以证明内嵌搜索栏稳定恢复。

现以标准 UIButton 打开 UIAlertController 的独立 UITextField，弹窗呈现完成后明确调用 becomeFirstResponder。输入框及弹窗由当前插件页面直接展示；不依赖 UISearchBar / UISearchController 的嵌套输入状态。搜索按钮提交查询，取消保留原查询和列表；列表搜索入口右侧 × 清空查询并恢复原分类。没有更改日期条、NAS 协议或媒体发送实现。

模拟器 UI 测试由搜索按钮 sendActionsForControlEvents 触发真实入口，测试本身不再调用 becomeFirstResponder；13 项检查通过，包含弹窗实际呈现、输入框进入窗口并成为第一响应者、系统键盘显示通知，以及日期条原有触摸回调与单次松手提交。真实微信键盘、NAS 搜索和结果发送仍需分别确认。

0.2.3 两类 deb 编译与依赖检查通过；已通过 SSH 安装并重开微信。设备已安装 dylib 与新版 rootless deb 字节一致，SHA-256 `f61566b791a714f2c00e2285579f8ebbfa22e37070ed95b0c6313d6721a820b6`。


### 0.2.3 后续真机反馈与键盘服务排查

用户再次确认日期拖动与跳转正常；搜索输入弹窗能显示，但键盘仍未出现。进一步询问后，用户说明微信原生聊天输入框也不弹屏幕键盘，且没有连接实体键盘。因此不能把本次现象仅归因为插件搜索控件，也不能仅凭模拟器键盘测试宣布修复。其他应用的键盘表现尚未核对。

通过 SSH 确认 system/com.apple.TextInput.kbd 服务存在并处于 running，随后单独执行 launchctl kickstart -k 重启此键盘服务；新进程已启动。未重置键盘设置、未重启整机、未改动 NAS 登录凭据。键盘恢复情况待用户复测。

用户复测确认：单独重启键盘服务后，微信原生聊天输入框与插件搜索输入框的屏幕键盘都已恢复。这支持本次输入异常与键盘服务状态有关，但不据此推断服务异常的最初原因。当前真机已确认日期拖动、日期跳转及搜索输入正常；真实 AI 搜索结果与从结果发送仍待确认。

### 0.2.3 新增功能真机验收结果

2026-10-30，用户在同一台 Dopamine iPadOS 15.2 / 微信 8.0.75 确认：日期条能拖动、日期变化与松手跳转正常；键盘服务恢复后搜索输入正常；真实 NAS AI 搜索能返回照片，从搜索结果选择图片后发送成功，聊天中能正常打开。此次反馈覆盖真实搜索到发送的完整流程。微信 8.0.76、免越狱注入环境、分屏旋转等未覆盖项目继续保持待验证，不扩展此次结果。
## 0.2.4：全能签修改 Bundle ID 后入口不出现

用户在全能签中给微信 8.0.76 注入 0.2.3 dylib 并修改 Bundle ID，点击聊天照片直接进入系统相册。所选 dylib 与正式 injection 产物字节一致；参考 IPA 的三个基础媒体接口及参数类型符合当前检查。

直接原因：旧 Tweak.xm 构造函数要求主包 ID 等于 com.tencent.xin；修改包名后，整个缓存准备和 Logos 初始化分支被跳过。该问题发生在入口 Hook 注册之前，不是缺少资源图片导致。

0.2.4 新增 FNHost，以主 .app、CFBundlePackageType=APPL、CFBundleExecutable=WeChat 识别宿主，允许自定义 Bundle ID；通知/分享扩展和无关应用仍排除。媒体接口签名及聊天会话校验保留。原始参考 IPA 未修改，已验证的 iPad 8.0.75 安装仍保留 0.2.3。

原生测试覆盖原包名、自定义包名、扩展、非微信可执行文件、错误包类型和缺少元数据，共 6 组通过；两类 deb 的编译、架构及依赖检查通过。全能签修改包名后的实际加载和微信 8.0.76 发送仍待签名设备验证。

新增只读 tools/check_injected_ipa.py，检查签名输出 IPA 的包名、dylib 位置、架构及主程序加载引用。原始参考 IPA 不含本插件属预期；签名输出目前不在 Mac 上，尚未检查该输出。



## 0.2.5: Bidirectional date browsing

The user reported that swiping toward newer photos after seeking to January 2024 reset the list to the latest date. The refresh control directly invoked reload, and the pager only supported older pages. Historical browsing now suppresses full refresh and loads adjacent newer pages with an independent head cursor. Prepending rows preserves the visible anchor at response time; older pagination remains independent. Failures commit neither head cursor nor partial rows.

Native tests cover a newer day with 65 photos across two reverse pages, a simulated HTTP 503 and successful retry, no duplicate IDs or skipped rows, the latest boundary, and preservation of the older cursor. Existing login, signatures, AI search, host detection and callback tests remain included. Real WeChat interaction for this release is pending.

0.2.5: Six native test groups and 16 simulator UI assertions passed, including disabled historical refresh and stable visible anchor during newer-photo insertion. Both package targets passed architecture and dependency checks. No new package was installed onto the previously validated iPad during this signing-only delivery.

## 0.3.0：普通视频与分类

对照 APK 接口新增人物、地点和媒体类型分类。人物使用 ai-person/list，地点使用 explore/geos；分类以 search/results 的结构化 filters 获取 ID，再分批 batchGetByIds 获取详情，保留服务端结果顺序。媒体类型包括视频、实况、GIF、截图、全景、RAW 和 360° 照片。“任务分类”按“人物分类”实现。

普通视频可以下载原文件后用 AVPlayer 预览；发送使用 MMAssetForLocalVideo 本地素材，不写入系统相册。要求系统可播放且具有有效视频轨道和时长；本版没有 NAS 转码，不支持的编码明确报错。

七组原生测试与 18 项模拟器 UI 断言通过，覆盖分类参数、POST 签名、详情顺序、视频缩略图不回退原文件、分类入口及媒体类型路由，并保留原有协议和界面回归。

Dopamine iPadOS 15.2 / 微信 8.0.75 使用自有 1 秒 H.264 合成视频进行独立素材自检，不发送消息。微信原生基类复制后会丢失本地视频路径；动态 ACFNLocalVideoAsset 子类修复后，素材创建、isVideo、NSURL 路径、缩略图、时长及复制后路径均正常。该结果不等于上传成功。

两类正式 deb 编译、架构、依赖和开发探针排除检查通过。真实 NAS 分类内容、视频预览、聊天上传和接收端播放仍待用户验证；8.0.76 与全能签环境保持待验证。开发自检不进入交付包。


## 0.3.1：人物头像与视频缓存读取权限

用户确认人物、地点与媒体类型分类均正常，但大量人物没有命名。APK 的 C2014Un0.a 使用 faceId 组成 /p/api/v1/stream/face/{faceId}。人物行现显示 64 点圆形头像，整行可点；头像按需加载、后台缩图、限量缓存并校验复用行身份，缺少 faceId 时使用占位图，不改动 NAS 上的人物名称。

用户反馈视频被报编码不支持。检查实际预览缓存为有效 HEVC MOV，随后在同一 iPad、同一文件复现：0600 权限下 AVFoundation 报 NSCocoaErrorDomain 257 / NSOSStatusErrorDomain -12203，无法读视频轨道；改为 0644 后 playable/readable/exportable 均为 true，可读到视频轨道。根因是 NSURLSession 临时文件直接移动后保留 0600 权限，媒体服务读取失败；此前直接把 playable=false 归因为编码不支持的提示不准确。

下载成功移动到微信私有缓存后明确设置 0644，保留容器隔离及文件保护属性；设置失败向调用方返回错误。预览和发送区分 AVFoundation 读取错误与不支持格式。本次不增加 NAS 转码。

七组原生测试通过，新增真实 HTTP 下载后的权限及字节一致性断言、人脸 URL 和占位条件验证。20 项模拟器 UI 断言通过，新增未命名人物头像与缺头像占位。实际 NAS 头像加载和视频完整发送播放继续等待用户复测。


## 0.3.2：普通视频取错资源字段

用户确认 0.3.1 人物头像显示及进入人物照片正常；视频仍报“无法打开”。安装仅记录本插件预览诊断的开发包后，用户再次复现。实际失败文件权限为 0644、应用可读取 261284 字节，但文件头为 FFD8FFE0 / JFIF（JPEG），扩展名来自条目而为 MOV。AVFoundation 报 -11829，下层 -12848。该条目存在独立 videoUrl，且与 originalUrl 不同。此前将另一段 MOV 的权限实验作为这次视频的直接原因，证据不足；0.3.1 的权限修复没有解决资源字段错误。

APK 的 PhotoDetail.PhotoInfo.getVideoUrl 与 C2706b51.b0 均表明普通视频原始播放走 additional.thumbnail.videoUrl。FNMediaURL 在普通视频的原文件请求优先取 videoUrl，缺失才兼容旧有 originalUrl；照片及实况的静态原图不受影响，网格仍只请求缩略图。预览和发送共用该函数，因此同时修正两条路径。

原生回归加入封面 URL 与视频 URL 分离的条目、实况静态原图保持不变，以及真实 HTTP 分类详情返回分离 URL 后的选择断言。正式包排除 video-read.json 开发诊断代码；真实视频预览、上传、接收端播放待用户复测确认。


## 0.3.3：视频误入图片发送入口

用户确认 0.3.2 视频预览正常，但发送后卡住。首轮外部诊断遇到短函数无法挂接；后续微信进程变化导致外部附着遗漏，改为随插件加载的开发诊断。实际用户发送记录显示：89999506 字节、13.548 秒视频已准备，随后 didSelectMMAsset:finish:fromImagePicker: 调用 getBigImageWithCompressConfig:ProcessBlock:ResultBlock:ErrorBlock:；本地视频继承的基类实现为空，没有完成回调。这证明该入口将素材按图片处理，不能把补一张封面当作视频发送成功。

原生 ImageController 的视频选择完成逻辑使用 CaptureVideoInfo 并调用当前 delegate 的 CameraControllerDidTakeVideo:。0.3.3 为视频准备兼容 MP4 与 JPEG 封面，填写 CaptureVideoInfo 的尺寸、时长、文件大小和路径，通过相同的视频消息回调交接；图片继续使用已验收的图片回调。普通兼容版本上限 1080p，原图模式额外保留原文件路径、大小和本地 asset，原视频接收结果保持待验证。未调用原包插件代码，未修改原 IPA。

同时发现 MMAsset 的 asyncGetVideoFileSizeWithBlock: 默认返回 nil，原生 PHAsset 实现回调为 NSNumber；本地视频子类补齐真实文件大小回调。

八组原生测试通过，新增真实交接函数对图片/视频混选、末张图片完成标识、纯视频关闭选图页以及接口不兼容时零提交的测试，均使用测试替身，不发送消息。Dopamine iPadOS 15.2 / 微信 8.0.75 合成素材自检确认 CaptureVideoInfo 创建、视频/封面/原文件路径、NSNumber 文件大小回调及复制路径均正常。实际视频上传、接收端播放仍需用户验收；原视频模式、多视频及混选也需真机覆盖。


### 0.3.3 普通视频真机验收

2026-10-30，用户在 Dopamine iPadOS 15.2 / 微信 8.0.75 确认：不勾选“原图”，从飞牛相册选择此前失败的同一视频，经过处理后发送完成，聊天中能够打开并播放。此次反馈覆盖普通视频从 NAS 选择到接收端播放的完整流程，0.3.3 的普通视频发送验收通过。

人物头像与进入对应照片已在 0.3.1 由用户确认正常；三类分类内容也已确认。原视频模式、多视频与图片混选的真机发送、微信 8.0.76 及全能签免越狱环境仍需单独验证，不将本次结果扩展到这些场景。


## 0.3.4：预览加载进度

预览页面新增半透明遮罩、活动指示器、百分比和进度条；利用当前 NSURLSessionTask 的 countOfBytesReceived / countOfBytesExpectedToReceive 计算真实下载进度，每 0.1 秒在主线程刷新。总大小未知时显示“加载中”，不编造百分比；接收完成后显示 100% 与解析阶段文案，直到图片解码、视频播放器就绪或 GIF 页面导航完成。能命中账号及登录代际对应的缩略图缓存时，先显示该缩略图作为遮罩背景。

每次加载持有独立标识，切换、返回和关闭会取消旧计时器；迟到的下载或解码回调不能覆盖新素材的进度。网络失败和解码失败均关闭遮罩；GIF 还处理导航失败。实况播放的加载使用独立标识，不被同时完成的静态封面下载提前关闭。

模拟器 24 项 UI 断言通过，新增未知大小占位、实际字节对应 25% 进度、滑动切换后旧请求不能隐藏新 50% 进度，以及解码完成关闭遮罩和计时器。既有日期条、搜索、分类和头像检查同时通过。真机实际下载百分比与显示手感待用户复测；0.3.3 已确认的视频发送结果保持原记录，本次未修改发送路径。


### 0.3.4 预览加载进度真机验收

用户在既有 Dopamine iPadOS 15.2 / 微信 8.0.75 测试设备上确认“进度显示和预览都正常”。据此记录加载进度与预览通过真机验收；该反馈不扩展为所有媒体类型、未知总大小、断网和快速连续切换场景均已逐项真机验证，这些边界仍以已有模拟器检查和后续实测为准。


## 0.3.5：运行中令牌自动续期

用户反馈短时间内反复要求登录。代码检查发现：已有 longToken 与 user.tokenLogin 恢复协议，但只在 restore 中调用；运行中 HTTP 401 直接 logout，删除短令牌、长令牌、secret 和 Keychain，使后续无法免密恢复。没有据此推断 NAS 的具体令牌有效期。

新 HTTP 操作在首次 401 后合并一次续期，使用当前 longToken，经签名 WebSocket user.tokenLogin 获取新令牌并保存，按原方法、URL、查询参数和完整 POST 字节重新签名，最多重试一次。迟到的旧令牌 401 若已有新令牌则直接重试，不再次轮换。所有相册请求、搜索、缩略图和文件下载共用处理。FNTransfer 保留逻辑请求的取消能力及当前下载字节计数，重试时切换底层任务，避免已完成的旧任务导致预览进度冻结。

同账号续期不增加 generation，避免中断当前选图和发送上下文；退出、更换账号仍增加 generation 并拒绝迟到的续期结果。断网、NAS 暂时拒绝或缺失新令牌保留凭据；只有明确 errno 135168 的最终认证失败才清除。续期成功但相册继续返回 HTTP 401 时结束重试并保留凭据，不无限循环。

九组原生测试通过，其中新增八种真实本地 HTTP/WebSocket 情景：并发 GET/POST/缩略图/文件、迟到 401、轮换凭据恢复、续期时断网、NAS 暂时拒绝、无效续期响应、长令牌明确失效、重试后仍 401、退出和换账号期间的迟到响应（部分在同一情景覆盖）。另验证下载进度继续变化、取消仅完成一次且无遗留文件、重签后的 POST 字节及全部认证头、下载文件 0644 权限。全部为合成账号和测试专用 Keychain 服务。

24 项模拟器界面回归通过，包括预览百分比、切换素材隔离、搜索、日期条及分类。真实 NAS 的下一次令牌过期及 8.0.76/签名环境续期仍需观察。旧版若已删除凭据，本版不能恢复已删除内容，需先手动登录一次。


## 0.3.6：视频时长与 Wi-Fi 内外网分流

APK `PhotoDetail.PhotoInfo.mediaDuration` 经 `MediaTypeBadgeView.a` 传入 `LI.d`，按秒拆分时分秒。网格增加右下角独立时长标签，覆盖全部照片、相册、搜索与媒体分类使用的共用单元格；缺失、非正值或无效字段隐藏，复用时清除。未下载视频获取时长。

设置增加内外网访问页，精确匹配家中 SSID；未知 SSID 明确提示并选择外网，另有手动内网、外网和关闭模式。读取使用 NEHotspotNetwork.fetchCurrent，最多等待三秒；定位授权只在主程序有用途说明时请求。官方权限约束见 https://developer.apple.com/documentation/networkextension/nehotspotnetwork/fetchcurrent(completionhandler:) 。未修改主程序签名、权限或用途说明。SSH 检查测试 iPad 的微信主程序签名含 wifi-info，但是否能取得名称还取决于定位等运行条件；签名注入设备需单独验证。

别名切换重新验证短令牌/长令牌，代际变化阻止旧请求继续交接；只向用户配置的同一 NAS 地址复用凭据。NAS 返回另一个已配置别名的绝对媒体 URL 时，保留路径和查询，重绑定到活动地址后重新签名。未配置来源、带用户信息或片段的 URL 继续拒绝。只在新建浏览页及保存配置时切换，避免发送过程中自动更换。

九组原生测试通过，新增双端口 HTTP/WebSocket 别名来回切换、轮换令牌保存与恢复、可信媒体别名、外部来源拒绝、SSID 精确匹配与未知回退、时长单位与无效值。真机实际 Wi-Fi 读取及家中/外出切换待验收。

模拟器 26 项 UIKit 检查通过，包括实际网格底部右侧时长位置、单元格复用后清除时长，既有日期条、搜索键盘、分类、头像与预览进度回归同时通过。首次新增测试不当手动调用 dequeue 导致测试程序断言，改由 collection view 正常展示后检查实际单元格，正式插件代码未发生该异常。

0.3.6 已经 SSH 安装到测试 iPad，安装后回读的 rootless dylib 与对应发布包逐字节一致。尚未由用户验收本次视频时长显示和网络配置。


## 0.3.7：预览只有画面没有声音

用户反馈视频可预览但无声。代码此前直接 AVPlayer.play，未显式建立预览音频会话，可能继承微信的静音/听筒音频配置。新增 FNPreviewAudio，在播放前设置 AVAudioSessionCategoryPlayback / AVAudioSessionModeMoviePlayback 并 setActive:YES；视频和实况共用，播放器初始化 muted=NO、volume=1，不修改系统音量或强制覆盖耳机输出。参考 Apple 官方 AVAudioSession 文档 https://developer.apple.com/documentation/avfaudio/avaudiosession 。

离开页面、切换素材、应用失活和销毁时先暂停，再撤销本插件音频会话，恢复旧 category/mode/options。若微信已切换到其他会话配置则不覆盖；录音或通话模式拒绝接管并提示。激活失败回滚配置，不错误停用原会话。应用回到前台、预览仍可见时重新准备声音，保持暂停供用户播放。

新增模拟音频设备检查：建立可听媒体会话、重复准备/结束只恢复一次、微信通话接管后不覆盖、拒绝中断通话、激活失败回滚、对象销毁时恢复。真实视频是否含可解码音轨、当前输出设备及实际出声仍需真机验收，不以编译或模拟会话检查代替。

本次两类正式 deb 的编译、架构与依赖检查通过，32 项模拟器 UI/音频会话断言通过。既有日期条、搜索键盘、视频时长、分类与预览加载进度回归通过；实际音频输出等待真机复测。


## 0.3.8：蜂窝流量静默走外网

移除 FNPrepareNetworkRoute 为未知 SSID 人为追加 warning 的回调包装，直接返回 NAS 路由结果。自动模式 SSID 缺失仍通过已有 FNRouteUsesLocal 返回 NO 选择外网，不弹 Wi-Fi 不可读提示。真实 NAS 连接/认证失败及凭据保存警告保留；设置页主动检查 Wi-Fi 的结果保留。不新增网络检测或额外权限依赖，Wi-Fi 名称读取仍有原三秒上限。

0.3.8 两类正式包编译及架构、依赖检查通过，已安装到测试 iPad。此次仅移除路由的额外 warning 包装并更新设置文案，SSID 到地址的选择规则未更改，未新增重复实现的测试；蜂窝网络的无弹窗体验待真机复测。


## 0.3.9：照片预览缩放

新增 FNZoomImageView，以 UIScrollView 原生 pinch / zoom 承载图片。初始按比例适配居中，最大 5 倍，双击围绕点击位置放大至 3 倍、再次双击还原。放大或双指缩放期间父级左右滑动不识别，缩回 1 倍恢复切图；1 倍时 scroll pan 等待切图手势判定。新图片与视口尺寸改变时重置缩放。

图片改为 scroll view 子视图后，视频/实况播放器与 GIF 的插入层级和布局使用独立视口，避免使用缩放后图片的 frame 或非同层 aboveSubview。网格及发送路径不变。

两类正式包编译、架构与依赖检查通过；38 项模拟器 UIKit/音频检查通过。新增原生 pinch 目标、图片初始适配居中、放大可平移、放大拖动不切图、更换图片重置并恢复切图、视口尺寸变化重置适配。真实双指手感与双击体验待 iPad 复测。


## 0.4.0：默认流畅视频边缓冲边看

用户希望大视频无需完整下载才预览，随后补充可默认加载较小版本，勾选原图再加载原视频。对照已有 APK 的 InterfaceC6350rm0（decode/info、play、record、quit）、C2706b51（bitrate/resolution/audioIndex=-2 与播放链接）及 BT1.e（decode/stream）实现 NAS 流畅预览。TZ.a 的播放器数据源配置同时携带 token/Authorization/cookie；本插件使用 iOS 公开的 AVURLAssetHTTPCookiesKey 提供路径限定 Cookie，需实际 NAS 验证仅 Cookie 是否足够。

新增纯原生转码生命周期测试：优先选择小清晰度、拒绝原始或无效配置、完整请求参数、心跳、结束只释放一次、取消后迟到链接释放、换账号不向旧会话带入新账号、Cookie 主机/路径/HTTPS 限制及非转码地址拒绝；token 轮换通知只在值变化时触发。10 组原生检查通过。

38 项既有 UIKit 检查通过。另新增真实 AVPlayer 集成测试：用合成 48 秒 HLS 和本地模拟 NAS，验证播放器使用 Cookie 成功播放，并在原文件下载数为 0、HLS 全部分片未取完时已出画；再点击原图，确认使用本地完整原视频播放、旧转码会话只退出一次。测试不访问用户媒体，不链接微信发送接口。

模拟器集成通过不等于用户 NAS 或 iPadOS 15.2 播放已验收；NAS 实际转码能力、Cookie 验证、编码支持和内网穿透代理的流媒体路径仍需真机覆盖。开发自检只读取本人账号下的视频转码接口，不向聊天发送内容；正式包必须排除 video-stream-probe.json。

0.4.0 正式 rootless 与 injection 包的编译、架构、依赖及开发探针排除检查通过。正式 rootless 已 SSH 安装，回读 dylib 与对应 deb payload 完全一致。测试时未检测到微信进程，开发版 NAS 自检未生成结果；随后已覆盖为不含自动自检的正式版。真实 NAS 的流畅播放仍待解锁并打开微信后人工验收，不记为已通过。


## 2026-11-01 · 0.4.1 流畅视频黑屏修正

- 0.4.0 真机黑屏时 AVPlayer 仅识别 AAC 音轨，presentationSize 为 0；实际 NAS 分片包含 HEVC Main + AAC，封装为 MPEG-TS。原视频完整下载画面正常。
- 对照 NAS 网页端 `B1nUlRlneE3A5d9i.js` 的 decode/play 请求，增加 videoEncoder=h264、audioEncoder=aac、channels=2。实际 NAS 重新返回的首分片经 ffprobe 确认为 H.264 400×848 + AAC，证明服务端采用兼容参数。
- 模拟器集成检查要求 readyForDisplay 和非零画面尺寸，防止只播放声音也被判定成功。首播前缓冲按实际已缓存秒数显示百分比；该百分比表示首播缓冲目标，并非整段视频下载比例。原图按钮显示当前素材或已选素材总大小；缺少信息显示大小未知。
- 原生协议 10 组、浏览器 UI 39 项、真实 AVPlayer HLS/原图切换集成通过。实际 iPad 的画面、进度和大小显示待用户复测。
- 一次外部异步 Frida 诊断发生对象生命周期崩溃，已停止此方式，改用编译进开发包的 ARC 原生诊断；正式包不含探针。


## 2026-11-01 · 0.4.2 视频启动等待优化

- 用户确认 0.4.1 画面、声音、缓冲进度、原图大小均正常，但申请流畅视频慢。原生真机计时：decode/info 0.0177 秒、decode/play 5.9909 秒；从恢复账号到读到首个分片共 7.4411 秒。瓶颈主要是服务端启动转码，不能承诺冷启动秒开。
- 页面停稳 0.7 秒后，在可见项中最多预热一段视频；每个浏览页实例最多一次，不抓取媒体分片。缓存仅一个 NAS 任务，20 秒到期清理；进入后台或关闭选择页清理闲置任务，切账号/地址时 generation 阻止复用。预热占用最多一个服务端转码会话，首段仍需 NAS 生成。
- 预热中点击共用一个 info/play 流程；准备好的流畅视频短暂保留，切回或再次打开时复用。失败会话不缓存，原图/发送保持原有下载流程。流畅首播目标缓冲从 5 秒降至 2 秒，已有可播放数据时调用 playImmediatelyAtRate，后续仍保留播放器自动缓冲恢复机制。
- 原生 10 组测试包含预热中取得对象、并发回调、任务只创建一次、重新取得同一任务、清理恰好 quit 一次。AVPlayer 集成验证流畅→原图→流畅仍有画面，服务端 play 一次，发送路径未改。浏览器 UI 39 项回归通过。实际页面预热命中率和体感速度待用户复测。另一次真机自检确认复用同一任务成功，取回已准备对象约 0.05ms（仅本地对象/地址复用耗时，不代表首帧时间），冷创建仍约 6.22 秒。


## 2026-11-01 · 0.4.3 改为原视频边下载边预览

- 用户反馈 0.4.2 仍慢，并明确要求取消模糊版，仅支持边下载边预览。取消转码与预热，正式编译不再包含 FNNASVideoPreview；打包检查断言正式 dylib 不含 decode/play 接口路径。
- 真机 NAS 原视频 Cookie-only Range 请求返回 HTTP 206，64 KiB 耗时 0.1048 秒，Content-Range 表明原文件 112747943 字节，MIME video/mp4。不依赖转码任务。
- 真实 AVPlayer 模拟器限速 HTTP 测试：约 0.83 秒出画面，传输量小于完整文件；验证按 Range 拉取、Cookie 限定媒体路径、无转码请求。勾选原图不会重新创建 playerItem，也不会改为完整下载。媒体第一次拒绝访问后通过 photoDetails 重取地址并重试，约 1.23 秒出画面，重连遮罩能关闭。此为合成样本数据，不代表实际 NAS 首帧耗时。
- 原有原生协议 10 组与浏览器 UI 39 项通过。原图按钮保持文件大小显示，失败仅提示可手动完整下载，不静默转码。视频发送流程不改；当前 iOS 不支持的原始编码/容器仍可能无法播放。
- 另验证 MP4 索引在文件尾部的情况，模拟器约 0.83 秒出画面，依靠 Range 读取尾部索引，仍未完整传输文件。rootless arm64/arm64e 与 injection arm64 编译、架构/依赖检查通过，正式包不含探针和 decode/play 路径；iPad 回读 dylib 与 0.4.3 rootless 包一致。
- 2026-11-02 用户真机确认：打开明显变快，原视频画面、声音和拖动播放进度均正常。未提供首帧具体秒数；连续切换、其他编码/容器和签名注入环境仍未由本轮反馈验证。

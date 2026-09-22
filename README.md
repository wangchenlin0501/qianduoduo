# 钱多多 · QianDuoDuo

一个用 SwiftUI 编写的 iPhone / iPad 视频拍摄与合作账单管理工具。

## 为什么做这个软件

这个软件最初是我为自己和女朋友做的小工具，用来一起管理视频拍摄、品牌合作和账单。拍摄安排、发布进度、哪些款已经收到、哪些还需要跟进，都希望能放在同一个地方，少一点来回确认，多一点专心创作的时间。

现在把代码分享出来，希望有类似需求的人也能用上，按自己的习惯修改。欢迎反馈问题、提出需求或参与改进。

## 功能

- **汇总**：合作金额、回款进度、月均金额参考线，以及手工记录的粉丝和作品点赞趋势。
- **池子**：维护品牌合作、联系人、产品、金额和拍摄安排。
- **视频**：组织一期视频中的合作内容，跟进拍摄和发布状态。
- **账本**：记录待回款与已回款，管理收款时间和备注。
- **协作**：使用 Core Data + CloudKit 在授权的设备和协作者之间共享数据。
- **提醒**：本地评论提醒、声音和实时活动，发布后显示庆祝动画。
- **数据管理**：导入、导出，以及临时隐藏数据的展示模式。

数据采用手工录入和修改；没有接入小红书爬虫，也不需要提供平台密码或 Cookie。

## 运行环境

- macOS + Xcode 26.2（此次编译验证版本）。
- iOS / iPadOS 18.6 或更高版本。
- 真机安装需要配置自己的 Apple 开发者签名；CloudKit 共享需要相应的开发者账号与容器能力。
- 不依赖第三方 Swift Package、后端服务器或 API 密钥。

这里提供的是源码，不是可直接安装的 App Store / TestFlight 版本。

## 配置与启动

1. 克隆仓库，打开 `钱多多.xcodeproj`。
2. 将 `Config/Signing.local.xcconfig.example` 复制成 `Config/Signing.local.xcconfig`，填写自己的 Team ID、唯一的 Bundle ID 和 CloudKit 容器 ID。这个本地文件已经被 Git 忽略，不要提交。
3. 在 Apple 开发者账号和 Xcode 的 Signing & Capabilities 中配置主应用的 iCloud / CloudKit、Push Notifications 和 Time Sensitive Notifications，创建匹配的 CloudKit 容器；评论提醒扩展也需要签名。
4. 顶部 Scheme 选择 **钱多多**，选择自己的 iPhone 后运行。`CommentReminderWidget` 只有实时活动，日常不要直接运行该扩展。
5. 首次共享前先用自己的容器验证数据保存与邀请。分发 Release 版本时还需在 CloudKit Console 检查并部署对应的生产 schema。

主应用、测试和扩展的 Bundle ID 由同一个配置派生；代码和 entitlement 使用同一个 CloudKit 容器配置。仓库中的 `com.example.qianduoduo` 仅为占位值，不能代替你自己的签名配置。

**不要给已经存有重要数据的安装随意更换 Bundle ID 或 CloudKit 容器。** 新身份对应不同的应用与数据空间；本仓库的公开配置不连接作者正在使用的云容器。

设置入口沿用原来的设计：在“汇总”标签已选中时，再连续点该标签 5 次，可进入设置页管理共享、导入导出、提醒和日志。

## 验证

只编译 iOS 目标，不启动模拟器：

```sh
xcodebuild -project 钱多多.xcodeproj -scheme 钱多多 \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/qianduoduo-build CODE_SIGNING_ALLOWED=NO build
```

独立计算检查：

```sh
xcrun swiftc 钱多多/MonthlyAmountTrend.swift scripts/verify-monthly-amount.swift -o /tmp/qianduoduo-monthly-check
/tmp/qianduoduo-monthly-check
```

提醒验收步骤见 [检查清单](scripts/comment-reminder-checklist.md)。无签名编译不能验证真机手势、通知权限、实时活动或跨账号 CloudKit 共享，这些需要在自己的设备上测试。

## 隐私与使用提醒

- 此仓库只包含程序代码、通用示例和已获分发授权的界面素材，不包含作者的真实账单、联系人、设备数据或原始 Git 历史。
- 用户录入的信息保存在设备的 Core Data 数据库，并通过配置的 CloudKit 私有／共享数据库同步。共享邀请请只发送给你信任的人。
- 导出文件会包含账单、联系人和其他业务字段；不要把真实导出、运行日志或带私人内容的截图上传到公开 Issue。
- 设置里的展示模式只是隐藏页面数据，不是删除数据，也不是脱敏导出。
- 当前代码会清理超过三个月的合作截图，记录字段仍然保留；重要图片请自行备份。
- 这是从日常使用中整理出的个人项目，功能仍在完善。重要账单请做好备份，软件不能代替专业财务核算。

更详细的检查范围见 [隐私检查说明](PRIVACY_REVIEW.md)。

## 许可证

使用 [MIT License](LICENSE)，允许商业使用、修改和分发；请保留版权与许可证声明。软件按现状提供，不作担保。

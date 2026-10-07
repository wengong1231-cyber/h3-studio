# 镜生 H3

原生 macOS 本地视频生成工作台，使用 SwiftUI 与 AppKit。桌面悬浮球显示当前任务和真实生成进度，工作台按镜头展示队列、素材、日志和候选输出，并显示可取得的 GPU 使用信息。

应用名称固定为「镜生 H3」，Bundle ID 为 `com.wengong.WanshenjiH3Studio`，默认安装位置为 `~/Applications/镜生 H3.app`。默认串行执行，暂停只暂停后续队列。生成结果先保存为候选，保留已完成输出和任务历史。

## 分支与验证边界

`main` 是最后已经验证并安装的 0.4.10(16) 源码基线快照，与原仓库归档的 78 个业务文件逐字节相同。该基线此前通过 211 项 CPU 断言；此次拆仓没有重新构建。待合入的静态输入改动未包含在基线中。

完整静态图绑定、CPU 原图复制与 768×448 contain 归一化、独立输入 QA、整镜重做和验收来源修复在 `feature/static-input-binding` 开发。S05 保留河谷→闭目→睁眼顺序，正式阶段分配尚待明确。S10 三张图片是身份与动作参考，不能直接登记为连续端点或视为用户已接受。

## 构建与运行

需要 Apple Silicon Mac、macOS 14 或以上，以及带 Swift 编译器的 Xcode。本项目此前在 Xcode 27、Swift 6.4 环境验证；开发分支的新改动仍有下述待验项。

```sh
zsh scripts/build.sh
```

构建产物固定为 `build/first-shot/镜生 H3.app`。构建脚本会对产物使用本地临时签名。运行前结束已有的镜生 H3 进程；生成任务运行期间不要覆盖或替换应用。更换临时签名的构建可能影响已有 macOS 文件授权，安装和签名需单独协调。

可在独立临时工作区试用合成队列：

```sh
"build/first-shot/镜生 H3.app/Contents/MacOS/WanshenjiH3Studio" \
  --workspace /tmp/jingsheng-h3-fixture --demo --skip-planned-queue
```

本仓库不包含模型、原生 VPIPE 引擎、MV 素材、视频、用户任务数据或凭据。正式 H3 输入和引擎绑定仍使用已经核对的本机外部接口；图库导入会校验实际文件及 SHA。仓库拆分没有修改这些接口，也没有下载或安装引擎。

## CPU 验证

已有 CPU 合成验证入口见 `scripts/verify.sh` 和 `Sources/*SelfTests.swift`。开发分支另有静态输入协议测试：

```sh
"build/first-shot/镜生 H3.app/Contents/MacOS/WanshenjiH3Studio" \
  --static-input-self-test /tmp/jingsheng-h3-static-input-test
```

静态输入测试需已存在的本机图库交接清单，只读核对素材，在独立测试工作区写入；不启动原生 H3 或 GPU。请使用新建的测试目录。完整构建和相关 CPU 回归仍须在资源空闲窗口完成，不以语法解析代替编译或实际 UI 验收。

MV 项目与素材继续保存在原私有仓库 `wengong1231-cyber/wanshenji-mv`，本仓库只承载应用源码、测试和必要脚本。未增加许可证、协作者或公开访问。

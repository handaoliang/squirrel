# han-rime 自定义说明

本分支(`han-rime`)在官方 [rime/squirrel](https://github.com/rime/squirrel) 基础上增加了三项**前端原生**自定义功能,全部集中在少量 Swift 源码里,便于随官方更新 rebase。

涉及文件:

- `sources/SquirrelInputController.swift`
- `sources/SquirrelApplicationDelegate.swift`
- `sources/SquirrelConfig.swift`(新增 `open(config:)`)

> 设计原则:能力放在**前端**(Squirrel),因为前端是整条链路里唯一能向宿主 App 查询「光标前真实字符」的一层。这比 Rime 引擎层 / Lua 脚本(只能看自己的输入/上屏历史)更准,对鼠标移光标、粘贴都鲁棒。

---

## 1. Command + Space 切换中英文

按 `⌘Space` 切换 `ascii_mode`(中 ↔ 英)。

实现两条路径,互为兜底:

- **`handle()` 内拦截**:在 keyDown 里识别「纯 ⌘ + 空格」,toggle `ascii_mode`,消费事件。
  适用于走标准文本输入协议(IMKit)的 App。
- **全局 `CGEventTap`**(`SquirrelApplicationDelegate`):在系统会话层(`.cgSessionEventTap` + `.headInsertEventTap`)抢在 App 之前截获 `⌘Space`,toggle 后吞掉事件。
  这样在 **iTerm2 / Ghostty 等不完整遵守 IMKit 协议的终端**里也能统一生效。

状态提示(中/En)复用 librime 的 option 通知自动弹出。

### 前置条件

1. **系统里必须先释放 `⌘Space`**:系统设置 → 键盘 → 键盘快捷键 → 输入法 / 聚焦,取消 `⌘Space` 绑定。否则它是系统 symbolic hotkey,事件到不了输入法。
2. **CGEventTap 需要「辅助功能」权限**:首次启动会弹授权框;在 *系统设置 → 隐私与安全性 → 辅助功能* 勾选 Squirrel,然后**重启 Squirrel 进程**(`killall Squirrel`)使 tap 生效。未授权时自动降级为仅 `handle()` 路径(GUI App 可用,终端不可用)。

---

## 2. 中英文自动空格(盘古空格)

在 汉字 ↔ ASCII 字母/数字 的边界自动补半角空格。判定依据是**光标前的真实字符**。

两条路径覆盖两个方向:

- **上屏时**(`commit(string:)` → `needsPanguSpace`):上屏内容与光标前字符构成边界时,给上屏串前补空格。覆盖「英文 → 中文」。
  用 `markedRange` 定位组字前的位置,避免把正在组的拼音误当成前一个字。
- **ascii 直通时**(`insertPanguSpaceForPassthroughIfNeeded`):ascii 模式下打字母/数字、且光标前是汉字时,先插一个空格。覆盖「中文 → 直通英文」。

判定规则(白名单):仅当**一侧是汉字、另一侧是 ASCII 字母/数字**才加。空格、标点、换行等都不在白名单内 → 天然不会重复加空格,也不会在标点旁误加。

| 前一字符 | 上屏/输入 | 加空格 |
|---|---|---|
| 汉字 | 字母/数字 | ✅ |
| 字母/数字 | 汉字 | ✅ |
| 英文 | 英文 | ❌ |
| 数字 | 数字 | ❌ |
| 汉字 | 汉字 | ❌ |
| 空格/标点 | 任意 | ❌ |

### 开关

配置项 **`pangu_spacing/enabled`**(布尔)。读取顺序:当前方案(schema)配置 → `default` 配置 → 缺省视为开启。切换方案 / 重新部署后生效。

---

## 3. 智能全角 / 半角空格

中文模式下、未组字时按空格,根据**光标两侧真实字符**决定输出:

- **任一侧是英文就给半角** `" "`:光标前一字符是 ASCII(`0x20`–`0x7E`,英文/数字/英文符号),**或**光标后一字符是 ASCII 字母/数字。
- 否则给全角 `"　"`(U+3000)。

这样把光标停在「中英之间」按空格(如 `中文|English`)也会得到半角空格;`中文|中文` 仍是全角。

不干预的场景:**正在组字**(空格用于选词上屏)、**ascii 模式**(空格恒半角)、**行首 / 读不到光标前字符**(回退给 Rime/punctuator 默认)。读不到光标后字符(如文末)时,退回只看前一字符的判断。

### 开关

配置项 **`smart_space/enabled`**(布尔),读取规则同上,缺省开启。

---

## 4. 五笔无候选时自动转英文(前端接管)

针对**码表方案(如五笔)未开整句**的场景:打到「没有候选词」的状态时,前端接管,把已打的原始字母**累积**起来,**回车才上屏**,中途空格 / 英文符号都并入。从根上绕开「空格之后引擎又去匹配中文」的问题(这点纯 Lua 做不到)。

流程:

- **触发**:`组字中 && 候选数为 0`(典型如无效五笔编码)。前端读出当前原始码当种子,`clear_composition` 让引擎撒手,之后这串字由前端自己显示和累积。
- **累积**:此后字母 / 数字 / 英文符号 / **空格**都进缓冲;**回车**整串上屏(复用盘古空格,中文后自动补半角);**退格**删字符;**Esc** 放弃;**左 / 右方向键**在缓冲内移动光标改错。
- **显示**:跟随 `style/inline_preedit`——内嵌(marked text)或浮窗(候选区上方)显示待转串。
- 其它键(上 / 下方向键、带 ⌘ 的组合等):先把缓冲上屏,再放行该键。

### 开关

配置项 **`auto_english/enabled`**(布尔),**默认关**。读取规则同上(当前方案 → `default` → 缺省关闭)。本仓库只在 `wubi86_jidian.custom.yaml` 里打开。

### 局限

- 只有真正「0 候选」才触发;像 `cat` 这种在五笔里**本身就有候选**的串不会进英文模式(符合「0 候选才转」的定义)。
- 进入英文模式后退格只在缓冲里删,**不会回退到五笔候选**;要重打按 Esc 清空。
- 若同时还启用了 `english_sentence.lua`(大写触发英文累积),两者在大写串上可能都想接管;如有冲突,保留其一即可。

---

## 配置项汇总

放在方案的 `*.custom.yaml`(对该方案生效)或 `default.custom.yaml`(全局)里:

```yaml
patch:
  pangu_spacing/enabled: true   # 中英自动空格
  smart_space/enabled: true     # 智能全/半角空格
  auto_english/enabled: true    # 五笔无候选时转前端英文(默认关,建议只在五笔方案开)
```

> 这两个 key 与原来的 Lua 脚本同名复用。启用前端版后,请**移除对应的 Lua**(`pangu_spacing_filter` / `english_sentence.lua` 的补空格段 / `smart_space.lua`),否则会重复加空格。

---

## 通用局限

读取「光标前字符」依赖宿主 App 实现 `IMKTextInput` 的 `selectedRange` / `attributedSubstring` / `markedRange`。**终端(iTerm2/Ghostty)、部分 Electron/网页编辑器**可能读不到 → 相关功能在这些 App 里**安全降级**(不加 / 走默认),不会出错。`⌘Space` 切换因为走 CGEventTap,不受此限制。

---

## 构建与安装

依赖与构建见官方 `INSTALL.md`。简要:

```sh
# 准备依赖(首次)
bash librime/install-boost.sh
export BOOST_ROOT="$(pwd)/librime/deps/boost-1.89.0"
export CMAKE_POLICY_VERSION_MINIMUM=3.5   # 兼容 cmake 4.x
make librime         # 含插件:bash librime/install-plugins.sh 后再 make
make data sparkle

# 构建 app
make release
```

安装(本机已拥有 `/Library/Input Methods` 时无需 sudo):

```sh
SQ_APP="/Library/Input Methods/Squirrel.app"
killall Squirrel 2>/dev/null
rm -rf "$SQ_APP"; cp -R build/Build/Products/Release/Squirrel.app "/Library/Input Methods/"
"$SQ_APP/Contents/MacOS/Squirrel" --register-input-source
( cd "$SQ_APP/Contents/SharedSupport" && "$SQ_APP/Contents/MacOS/Squirrel" --build )
```

首次安装后如部分 App 打不出字,注销重登一次。

---

## 跟随官方更新

`origin` = 你的 fork,`upstream` = 官方 `rime/squirrel`。

```sh
git fetch upstream
git switch han-rime
git rebase upstream/master      # 或指定 tag
git submodule update --init --recursive
# 重新构建
```

改动集中在上述 3 个 Swift 文件,除非官方大改按键处理,一般不冲突。仓库根目录的 `HAN-RIME.patch` 是这套改动的完整补丁,必要时可在干净检出上 `git am HAN-RIME.patch` 重放。

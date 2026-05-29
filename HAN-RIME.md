# han-rime 自定义说明

本分支(`han-rime`)在官方 [rime/squirrel](https://github.com/rime/squirrel) 基础上增加了若干**前端原生**自定义功能,全部集中在少量 Swift 源码里,便于随官方更新 rebase。

涉及文件:

- `sources/SquirrelInputController.swift`
- `sources/SquirrelApplicationDelegate.swift`
- `sources/SquirrelConfig.swift`(新增 `open(config:)`、`getMap(_:)`)

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
- **直通时**(`insertPanguSpaceForPassthroughIfNeeded`):光标前是汉字、且按键会「直通」上屏(不经 `commit()`)时先补空格。覆盖两种直通:**ascii 模式下的字母/数字**,以及**中文模式下未组字时打的数字**(数字键在中文模式不进引擎,会直接落到 App)。即覆盖「中文 → 直通英文 / 数字」。

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

- **触发**:候选数**从「有」跌到「0」的那一刻**(不是任何时候的 0 候选)——典型如「打了几码本来有候选,再补一码变成 0」。这样像 `z` / `` ` `` 反查、大写英文这种**一上来就是 0 候选**的输入不会被误抢。前端读出当前原始码当种子,`clear_composition` 让引擎撒手,之后由前端自己显示和累积。
- **累积**:字母 / 数字 / 英文符号 / **空格**进缓冲;**回车**整串上屏(复用盘古空格,中文后自动补半角);**Esc** 放弃;**左 / 右方向键**在缓冲内移动光标改错。
- **退格**:删一个字符后,若剩下的是**纯字母**,用 `set_input` 喂回引擎试探——引擎若又有候选(五笔候选 / 反查)就**交还引擎**;否则继续留在英文模式。缓冲里已混入空格/符号时,退格只在缓冲内删;删空则退出。
- **显示**:跟随 `style/inline_preedit`——内嵌用系统真实光标;浮窗模式自己插入 RIME 同款软光标 `‸`(U+2038),左右键移动时跟随。
- 其它键(上 / 下方向键、带 ⌘ 的组合等):先把缓冲上屏,再放行该键。

### 开关

配置项 **`auto_english/enabled`**(布尔),**默认关**。读取规则同上(当前方案 → `default` → 缺省关闭)。本仓库只在 `wubi86_jidian.custom.yaml` 里打开。

### 局限

- 只有「候选从有跌到 0」才触发:**一上来就 0 候选**的(`z` 反查、大写英文)和**本身有候选**的(如 `cat`,五笔里有候选)都不会进英文模式。
- 退格可回引擎,但只在缓冲为**纯字母**时试探;混入空格/符号后无法回退,需 Esc 清空重打。
- 与 `english_sentence.lua`(大写触发英文累积)基本不冲突——大写串一上来即 0 候选,被「跌落」触发条件排除,交给 lua 处理。

---

## 5. Command + 数字 直切方案

`⌘0`–`⌘9` 可绑定到任意输入方案,按下即切(如 `⌘8` → 雾凇拼音、`⌘9` → 极点五笔)。切到哪个方案的提示走 librime 自带的方案通知,自动弹出。

实现两条路径,与 `⌘Space` 同构、互为兜底:

- **`handle()` 内拦截**:keyDown 里识别「纯 ⌘ + 数字」,查映射表命中就调 `select_schema` 切换、消费事件。走 IMKit 协议的 App 适用。
- **全局 `CGEventTap`**(`SquirrelApplicationDelegate`):在系统会话层抢在 App 之前截获 `⌘数字`,命中即切换并吞掉事件。这样在**终端等不完整遵守 IMKit 协议的 App**里也统一生效,且优先于 App 自己的 `⌘数字` 快捷键。

映射表按 macOS 键码存储,两条路径共用同一份 `handleSchemaHotkey(keyCode:)`。配置从 **`default`** 读(切方案是全局动作,不挂某个 schema)。处于前端英文模式(见 §4)时按下会先复位再切。

### 前置条件

同 `⌘Space`:全局生效依赖**辅助功能**权限;未授权时降级为仅 `handle()` 路径(GUI App 可用,终端不可用)。绑定的 `⌘数字` 若被某 App 占用(如浏览器切标签),授权后经 CGEventTap 会**优先给输入法**。

### 开关与配置

配置项 **`schema_hotkeys/enabled`**(布尔,默认关)与 **`schema_hotkeys/bindings`** 映射表(`数字字符: 方案id`)。读取规则:仅从 `default` 配置读。

```yaml
patch:
  schema_hotkeys:
    enabled: true
    bindings:
      "8": rime_ice          # ⌘8 → 雾凇拼音
      "9": wubi86_jidian     # ⌘9 → 极点五笔
```

非数字键、空方案 id 会被忽略;`enabled` 为假或无 `bindings` 时整条特性不生效(`⌘数字` 原样放行给 App)。

---

## 6. 浮窗 Preedit 前显示当前方案名

输入时在**浮窗 preedit** 前加 `〔方案名〕` 前缀(如 `〔极点五笔〕 nihao`),方便多方案(配合 §5 的 `⌘数字` 切换)时一眼看清当前方案。方案名取自当前方案配置的 `schema/name`。

实现:`rimeUpdate` 给浮窗 `showPanel` 的 preedit 串前拼上前缀,并把选区 / 软光标的 utf16 偏移整体右移前缀长度,避免错位。三重守卫:**开关开 + 浮窗模式 + preedit 非空** 才加。

仅**浮窗模式**(`style/inline_preedit: false`)生效;内联模式下 preedit 是以 marked text 塞进宿主 App 文本框的,加前缀会污染正在编辑的文档,故不处理。

### 开关

配置项 **`schema_name_in_preedit/enabled`**(布尔,**默认关**),读取规则同 §2/§3(当前方案 → `default` → 缺省关闭)。

---

## 7. Preedit / 候选显示微调

两个纯样式项,放 `squirrel.custom.yaml` 的 `style/` 下:

- **`style/preedit_placeholder`**:`inline_preedit: false` 时,组字区在宿主 App 里留一个占位字符(被宿主画成下划线)。取值 `half`(半角空格,**默认**,下划线短)/ `full`(全角空格 U+3000,组中文基线稳)/ `none`(空串,不显示;终端类 App 可能回显码字)。在控制器侧从 squirrel 基础配置读,作用于普通组字与英文模式两处占位。
- **`style/candidate_left_padding`**(pt,默认 0):只给**候选区**加左缩进(`firstLineHeadIndent`/`headIndent`),preedit 不动。用于让候选与「以全角字形(如 §6 的 `〔`)打头的 preedit」左对齐——全角标点自带左边距会让 preedit 视觉右移,把候选右移即可对齐。注:`firstLineHeadIndent` 不接受负值,只能正向推候选,不能负向拉 preedit。

```yaml
patch:
  "style/preedit_placeholder": half   # half | full | none
  "style/candidate_left_padding": 10
```

---

## 配置项汇总

放在方案的 `*.custom.yaml`(对该方案生效)或 `default.custom.yaml`(全局)里:

```yaml
patch:
  pangu_spacing/enabled: true   # 中英自动空格
  smart_space/enabled: true     # 智能全/半角空格
  auto_english/enabled: true    # 五笔无候选时转前端英文(默认关,建议只在五笔方案开)
  schema_hotkeys:               # ⌘数字 直切方案(默认关,放 default.custom.yaml 全局生效)
    enabled: true
    bindings:
      "8": rime_ice
      "9": wubi86_jidian
  schema_name_in_preedit/enabled: true   # 浮窗 preedit 前显示〔方案名〕(默认关)
```

样式项放 `squirrel.custom.yaml` 的 `style/` 下:

```yaml
patch:
  "style/preedit_placeholder": half      # 组字占位:half(默认) | full | none
  "style/candidate_left_padding": 10     # 候选区左缩进(pt),与〔方案名〕打头的 preedit 对齐
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

### 安装包不再强制注销

`package/PackageInfo` 的 `postinstall-action` 由官方默认的 `logout` 改为 `none`。`make package` 生成的 `.pkg` 装完只停在「安装成功」页(点「关闭」退出安装器),不再注销当前登录会话——`scripts/postinstall` 本就会自己 `killall Squirrel` 并重新注册/部署/启用输入源,重启输入法这步不依赖系统注销。

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

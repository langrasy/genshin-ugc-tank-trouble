# 坦克动荡（千星奇域小游戏）

原神「千星奇域」UGC 地图小游戏 —— 坦克动荡（Tank Trouble）。本仓库是本地开发工作区。

玩法逻辑逐行对照 4399 Flash 版（TankTrouble2）反编译 ActionScript 2.0 源码移植，
数值（迷宫尺寸、SCALE、坦克物理、9 种武器、敌方 AI、回合计时 125/50/5）均未改动。

## 架构

源码分为「纯逻辑」与「平台层」两部分，由打包器内联成单文件产物：

```
src/*.lua            纯逻辑（迷宫 / 坦克物理 / 武器 / AI / 回合），可脱离游戏运行时单测
platform/game.lua    千星奇域平台层（控件渲染 / 按键事件 / 生命周期 / 逐帧驱动）
        │
        │  tools\bundle.ps1  （内联 src/ + 附加平台层，注入 require 垫片）
        ▼
tank_trouble.lua     单文件产物 —— 部署到游戏的就是它
```

> 千星奇域运行时**没有 `require`**，所以最终必须是一份单文件。`bundle.ps1` 在产物顶部
> 注入一个 `local require` 垫片，各模块体注册进 `__defs`，模块内的 `require` 经词法作用域
> 解析到垫片（不污染全局）。**不要手改 `tank_trouble.lua`**，改 `src/` 或 `platform/` 后重新打包。

## 目录结构

| 路径 | 作用 |
| --- | --- |
| `src/constants.lua` | 全局常量（尺寸、颜色、舞台 MOVIEWIDTH/MOVIEHEIGHT 等） |
| `src/maze.lua` | 迷宫生成 + 8 向 BFS 距离场寻路 |
| `src/tank.lua` | 坦克物理（5 子步移动、碰撞、脱困） |
| `src/weapons.lua` | 9 种武器行为 |
| `src/ai.lua` | 敌方 AI（目标优先级、寻路跟随、避障） |
| `src/round.lua` | 回合管理、计分、补给箱生成 |
| `platform/game.lua` | 千星奇域平台层（渲染 / 输入 / 菜单 / 舞台布局） |
| `tank_trouble.lua` | **单文件产物**（由 `tools\bundle.ps1` 生成，勿手改） |
| `tests/` | 纯逻辑单测 + 平台层冒烟测试（标准 Lua 桩件模拟运行时） |
| `types/` | LuaLS 类型桩：`game_api.lua`（自动生成）+ `project.lua`（手写补充） |
| `tools/setup.cmd` | 环境安装 / 自检（可反复运行，无需管理员权限） |
| `tools/bundle.cmd` | 打包：`src/` + `platform/` → `tank_trouble.lua` |
| `tools/check.cmd` | 语法检查（`luac -p`）+ 静态检查（LuaLS） |
| `tools/test.cmd` | 运行 `tests/` 下全部单测 |
| `tools/deploy.cmd` | 打包 → 语法检查 → 复制到映射目录 → 校验 MD5 一致 |
| `docs/ugc_official/` | 千星奇域官方文档离线归档（知识库 / 教程课程 / 常见问题） |
| `reference/` | 参考素材（不参与构建，已被 `.gitignore` 忽略） |
| `reference/tank_trouble2_decompiled/` | 原版 TankTrouble2 Flash 反编译素材（AS2 源码 / 素材 / 解包工具） |
| `reference/screenshots/` | 编辑器实机截图 |
| `客户端控件API文档` | 官方控件 / API 文档（Markdown，无扩展名） |
| `.luarc.json` / `.editorconfig` / `.gitignore` | 检查器、编码换行、忽略规则 |

## 编辑器控件模板（必需）

美术**不依赖任何外部贴图**：脚本在运行时靠拉伸 / 旋转 / 上色 + 多控件拼接，用编辑器自带的
形状控件模板画出全部对象（墙、坦克、炮弹、特效……）。因此地图里必须预置下列控件模板，
且索引须与代码一致（见 `platform/game.lua` 顶部的 `PREFAB`）：

| 名称 | 索引 | 代码键 | 典型用途 |
| --- | --- | --- | --- |
| 文本框 | `1073741884` | `TEXT` | HUD 文字（分数 / 武器 / 提示） |
| 正方形 | `1073741886` | `SQUARE` | 墙 / 地板 / 车体 / 履带 / 炮管 / 补给箱 / 遮罩 |
| 圆形 | `1073741888` | `CIRCLE` | 炮弹 / 炮塔 / 导弹头 / 高光 / 烟 |
| 三角形 | `1073741890` | `TRI` | 碎片 / 残骸 |
| 四芒星 | `1073741892` | `STAR4` | 炮口闪光 / 火花 |
| 五角星 | `1073741894` | `STAR5` | 击杀爆炸星芒 |
| 同心圆 | `1073741896` | `RINGS` | 地雷 |

形状名 ↔ 模板的映射集中在 `SHAPE_PREFAB`；部件池按形状名分桶，`acquire` / `release`
可自动为未知形状建桶，新增形状只需补一行映射。

## 环境依赖

| 工具 | 用途 | 版本 |
| --- | --- | --- |
| Lua（`luac` / `lua`） | 语法检查 `luac -p`、运行单测 | 5.4.6 |
| lua-language-server | 静态检查（抓方法名 / 字段名错误） | 3.19.1 |
| Git | 版本控制 | — |

一键安装 / 自检（用户级安装，**不需要管理员权限**）：

```
tools\setup.cmd
```

> 脚本会自动定位工具，即使不配置 PATH 也能工作。若想在任意终端直接敲 `luac`，可把
> `%LOCALAPPDATA%\Programs\Lua\bin` 加入用户 PATH。

## 常用命令

```
tools\bundle.cmd    :: 打包 src/ + platform/ → tank_trouble.lua
tools\check.cmd     :: 语法检查 + 静态检查（对 tank_trouble.lua）
tools\test.cmd      :: 运行 tests/ 下全部单测（先自动打包）
tools\deploy.cmd    :: 打包 → 语法检查 → 复制到映射目录 → 校验 MD5 一致
tools\setup.cmd     :: 安装 / 自检依赖
```

部署目标（映射目录）：

```
%USERPROFILE%\AppData\LocalLow\miHoYo\<原神>\BeyondLocal\100267668\
  Beyond_Local_Save_Level\1073741827\external_lua_file\tt2.lua
```

`deploy.cmd` 通过“遍历 miHoYo 下各游戏目录、取真正包含目标路径的那个”来定位，不硬编码
“原神”目录名（机器上同时存在《绝区零》等目录，硬编码 / 取最后一个都会抓错）。

## 建议工作流

1. 编辑 `src/*.lua`（逻辑）或 `platform/game.lua`（平台层）
2. `tools\check.cmd` —— 语法 / 静态检查，先消灭告警
3. `tools\test.cmd` —— 单测 + 平台层冒烟测试
4. `tools\deploy.cmd` —— 打包、部署并校验哈希一致
5. 进游戏验证
6. `git commit`（建议小步提交，便于回滚）

## 编码与换行约定（重要）

| 文件类型 | 编码 | 换行 |
| --- | --- | --- |
| `*.lua` | UTF-8（无 BOM） | LF |
| `*.cmd` | **UTF-8 带 BOM** | **CRLF** |
| `*.md` / `*.json` | UTF-8 | LF |

- `.cmd` 必须是 **CRLF** 换行：LF 会让 `cmd.exe` 解析错乱（命令被拦腰截断）。
- `.cmd` 建议 **UTF-8 BOM**：配合当前控制台代码页 65001 可正确显示中文。
- `.cmd` 的 `if (...)` 代码块内**不要出现英文括号**，会被当成代码块结束符；中文全角括号无此问题。

## 静态检查与类型桩

游戏 API（`script`、`game`、`Enum`、`Color`、`host` 等）不在标准 Lua 中，LuaLS 默认会
报 `undefined-field` / `inject-field` 之类的误报。`types/` 下的类型桩通过 `.luarc.json`
的 `workspace.library` 引入，用于消除这些误报。当前基线为**零告警**。

- `types/game_api.lua` —— 由 `客户端控件API文档` **自动生成**，请勿手改。
- `types/project.lua` —— **手写**补充。目前定义 `ClientUIControl` 联合类型，用于
  `createControl` 的返回标注：文档只声明工厂返回基类，而运行时按模板创建的是图片/文本
  控件，脚本会给它赋子类字段。合并类型可在**保留 `inject-field`（字段名拼写检查）**的
  前提下消除误报。

源码中与之配套的标注（均为注释，不影响运行）：

- `createControl` 上 `---@return ClientUIControl|nil`
- `host` 上 `---@type ClientUIContainerControl|nil`（脚本挂在容器控件上）

若修改了 API 文档，重新生成 `types/game_api.lua` 即可；`project.lua` 需手工维护。

## 本地化说明（相对原版 Flash 的差异）

原版依赖外部服务器的功能，在千星奇域内改为等价本地方案，游戏内「关于 / 说明」页有同样说明：

- **联机对战** → 本地单人对战 AI。
- **成就与统计上传**（pixvi.net）→ 本地记录，不联网、不上传。
- **我的 / 他人自定义迷宫** → 依赖外部数据源，本地暂无，仅随机迷宫生效。
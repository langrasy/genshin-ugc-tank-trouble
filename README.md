# 坦克动荡（千星奇域小游戏）

原神「千星奇域」UGC 地图小游戏 —— 坦克动荡（Tank Trouble）。本仓库是本地开发工作区。

## 目录结构

| 路径 | 作用 |
| --- | --- |
| `tank_trouble.lua` | **主源码**（唯一需要编辑的游戏脚本） |
| `客户端控件API文档` | 官方控件 / API 文档（Markdown，无扩展名） |
| `types/` | LuaLS 类型桩：`game_api.lua`（自动生成，勿手改）+ `project.lua`（手写补充） |
| `tools/setup.cmd` | 环境安装 / 自检（可反复运行） |
| `tools/check.cmd` | 语法检查 + 静态检查 |
| `tools/deploy.cmd` | 部署到千星奇域映射目录并校验 |
| `.luarc.json` | LuaLS 配置（Lua 5.3 运行时、全局变量、库路径） |
| `.editorconfig` | 编码 / 换行 / 缩进约定（编辑器自动遵循） |
| `.gitignore` | Git 忽略规则 |
| `游戏截图/` | 游戏内截图，仅作参考，不参与构建 |

## 环境依赖

| 工具 | 用途 | 版本 |
| --- | --- | --- |
| Lua（`luac`） | 语法检查 `luac -p` | 5.4.6 |
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
tools\check.cmd     :: 语法检查 + 静态检查
tools\deploy.cmd    :: 语法检查 → 复制到映射目录 → 校验 MD5 一致
tools\setup.cmd     :: 安装 / 自检依赖
```

部署目标（映射目录）：

```
%USERPROFILE%\AppData\LocalLow\miHoYo\<原神>\BeyondLocal\100267668\
  Beyond_Local_Save_Level\1073741827\external_lua_file\tt2.lua
```

`deploy.cmd` 通过“遍历 miHoYo 下各游戏目录、取真正包含目标路径的那个”来定位，不硬编码
“原神”目录名（机器上同时存在《绝区零》等目录，硬编码 / 取最后一个都会抓错）。

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

## 建议工作流

1. 编辑 `tank_trouble.lua`
2. `tools\check.cmd` —— 语法 / 静态检查，先消灭告警
3. `tools\deploy.cmd` —— 部署并校验哈希一致
4. 进游戏验证
5. `git commit`（建议小步提交，便于回滚）
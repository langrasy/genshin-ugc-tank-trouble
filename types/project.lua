---@meta

-- 本文件为“手写”类型补充，不属于自动生成内容。
-- 与 game_api.lua 的区别：game_api.lua 由「客户端控件API文档」生成，勿手改；
-- 本文件用于补足文档无法表达、但项目实际用法需要的类型。

---项目内动态控件工厂的返回类型。
---`game.InstantiateClientUIControl` 按文档只声明返回基类 `ClientUIBaseControl`，
---但运行时按模板实际创建的是“图片控件”或“文本控件”，脚本会给它赋
---`imageColor`/`imageType`/`text`/`fontSize` 等子类字段。
---这里把各子类字段合并成一个类型，专供 `createControl` 的返回标注使用，
---从而在保留 `inject-field`（字段名拼写检查）的前提下消除误报。
---@class ClientUIControl : ClientUIBaseControl, ClientUIImageControl, ClientUITextBoxControl, ClientUITextWindowControl
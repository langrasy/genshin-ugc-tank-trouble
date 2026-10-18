--[[ 骨架冒烟测试：确认 src 模块能被普通 Lua 加载（不需要千星奇域）
  跑法：在 minigames/template 目录下执行 tools\test.cmd]]

package.path = package.path .. ";./?.lua"

local ok, C = pcall(require, "src.constants")
if not ok then
  print("[FAIL] src.constants 加载失败：" .. tostring(C))
  os.exit(1)
end
if type(C) ~= "table" then
  print("[FAIL] src.constants 应返回 table，实为 " .. type(C))
  os.exit(1)
end

print("[ok] src.constants 可加载")
print("")
print("全部通过。")
os.exit(0)

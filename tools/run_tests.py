"""Run every test_*.lua in this folder against the addon under Lua 5.1 (the dialect WoW uses).
Each test file gets a fresh Lua state. Usage: run_tests.py <addon dir>"""
import glob
import os
import sys

import lupa.lua51 as L

HERE = os.path.dirname(os.path.abspath(__file__))
addon_dir = sys.argv[1].replace("\\", "/")
mock = os.path.join(HERE, "mock_wow.lua").replace("\\", "/")

total = 0
for test in sorted(glob.glob(os.path.join(HERE, "test_*.lua"))):
    test = test.replace("\\", "/")
    print(f"== {os.path.basename(test)}")
    rt = L.LuaRuntime(unpack_returned_tuples=True)
    rt.globals().ADDON_DIR = addon_dir
    failures = rt.execute(f'''
      dofile("{mock}")
      local chunk, err = loadfile("{test}")
      if not chunk then error(err) end
      local ok, res = xpcall(chunk, function(e) return debug.traceback(tostring(e), 2) end)
      if not ok then
        io.write("ERROR: ", tostring(res), "\\n")
        for _, p in ipairs(MOCK.prints) do io.write("  > ", p, "\\n") end
        io.flush()
        return 99
      end
      io.flush()
      return res
    ''')
    total += int(failures or 0)
    sys.stdout.flush()
sys.exit(total)

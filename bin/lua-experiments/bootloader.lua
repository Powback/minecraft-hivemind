-- BOOTLOADER. A disk's startup takes precedence over the host's own, so anything booted beside
-- this drive runs THIS first — which is what makes a floppy a bootstrap medium.
local id = os.getComputerID()
local isTurtle = turtle ~= nil
if not os.getComputerLabel() then
  os.setComputerLabel((isTurtle and 'turtle-' or 'computer-') .. id)
end

-- Install the payload: every non-startup file on the floppy, overwritten. This is the 'update'.
local copied = {}
for _, name in ipairs(fs.list('/disk')) do
  if name ~= 'startup.lua' and not fs.isDir('/disk/' .. name) then
    if fs.exists('/' .. name) then fs.delete('/' .. name) end
    fs.copy('/disk/' .. name, '/' .. name)
    copied[#copied + 1] = name
  end
end

local f = fs.open('/boot-report.txt', 'w')
f.write(('booted id=%d label=%s turtle=%s\n'):format(id, os.getComputerLabel(), tostring(isTurtle)))
f.write('installed: ' .. (#copied > 0 and table.concat(copied, ', ') or 'nothing') .. '\n')
f.close()

-- Hand control to the payload. Without this the machine sits at a prompt after initialising,
-- because the DISK's startup ran instead of its own — the thing that makes a bootloader useful
-- is that it does not stop at installing.
if fs.exists('/main.lua') then
  print('bootloader: installed ' .. #copied .. ' file(s), running /main.lua')
  shell.run('/main.lua')
else
  print('bootloader: installed ' .. #copied .. ' file(s); no /main.lua to run')
end

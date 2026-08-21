local function log(s) local f=fs.open('/relay.log','a'); f.write(s..'\n'); f.close() end
local m = peripheral.find('modem')
if m then rednet.open(peripheral.getName(m)) end
log('relay up, modem='..tostring(m ~= nil))
while true do
  local ev = { os.pullEvent('computer_command') }
  local target = tonumber(ev[2])
  local rest = table.concat({ table.unpack(ev, 3) }, ' ')
  if target then
    rednet.send(target, rest)
    log('sent to '..target..': '..rest)
  else
    log('bad target: '..tostring(ev[2]))
  end
end

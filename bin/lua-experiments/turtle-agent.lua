local function log(s) local f=fs.open('/commands.log','a'); f.write(s..'\n'); f.close() end
local m = peripheral.find('modem')
if m then rednet.open(peripheral.getName(m)) end
log('listening as '..(os.getComputerLabel() or '?')..' rednet='..tostring(m ~= nil))
while true do
  local sender, msg = rednet.receive()
  log('rednet from '..tostring(sender)..': '..tostring(msg))
  if msg == 'fwd' and turtle then log('  fwd -> '..tostring(turtle.forward())..' fuel='..turtle.getFuelLevel()) end
  if msg == 'back' and turtle then log('  back -> '..tostring(turtle.back())) end
  if msg == 'dig' and turtle then log('  dig -> '..tostring(turtle.dig())) end
end

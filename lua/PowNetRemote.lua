-- THE HUMAN OVERRIDE PATH.
--
-- This is the pocket-computer client for the callable registry: every module registers its
-- functions with MainFrame alongside a `params` schema, and this program is the only thing that
-- lets a person call one of them by hand. It installs itself as `/p`:
--
--     p DockingMan add -name dock2 -height 4 -pos <x> <y> <z>
--
-- Two front ends over the same schema. Flags (`ResolveVars`) for a function whose params are simple
-- scalars, and an interactive wizard (`RunInstaller`) for a callable marked `installer`, which is
-- how a nested `option`/`list` param gets filled in. It fills `params.gps` from its own position,
-- which is why handlers like `OnAddDockingTower` accept `gps` as a stand-in for `pos`.
local tArgs = {...}
local m_Callable = {}
os.loadAPI("PowNet")
-- OPEN REDNET
if(os.getComputerLabel() == nil) then
    print("Please set the label first.")
    return
end
for _, side in ipairs({"left", "right"}) do
    if peripheral.getType(side) == "modem" then
        rednet.open(side)
    end
end
if not rednet.isOpen() then
    printError("Could not open rednet")
    return
end

s_Connected, DATA = PowNet.Connect()
if not s_Connected then
    -- SAY IT ONCE, HERE. Every call below is a rednet round-trip to a host this line failed to
    -- find; without this the remote looks alive and each command dies of its own timeout with no
    -- shared explanation, which reads as "the module is broken" rather than "there is no server".
    printError("PowNet.Connect found no server -- calls will time out.")
end

PowNet.UpdateModule("PowNet")
PowNet.UpdateModule("PowNetRemote.lua", "p")

-- THE GUARD GOES BEFORE THE ARITHMETIC, AND THERE IS ONE COPY OF IT.
--
-- `gps.locate()` returns nil when there is no fix, and `math.floor(nil)` THROWS -- so the copy that
-- lived in ParseValue floored first and checked `if not x` afterwards, making its own
-- "no gps signal available." message unreachable: every fixless call raised instead of reporting
-- it. CallCallable had the order right. This is that version, and both call it.
--
-- y - 1 because the remote reports the block BELOW itself: that is the position a handler means by
-- `gps`, and getting it wrong puts a docking tower one block high.
function LocateBelow()
    local x, y, z = gps.locate()
    if not x then
        return nil
    end
    return {x = math.floor(x), y = math.floor(y) - 1, z = math.floor(z)}
end

function CallCallable(module, func, params)
    if(params == nil) then
        print("No params specified")
        return
    end
    local s_Pos = LocateBelow()
    if(s_Pos ~= nil) then
        params.gps = s_Pos
    else
        -- A MISSING POSITION IS NOT AN ABSENT ONE. Handlers accept `gps` as a stand-in for `pos`,
        -- so dropping it silently makes the module report a missing param for something the user
        -- never typed -- the fault has to name itself here, where the reason is known.
        printError("No gps fix -- sending without a position.")
    end

    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.CALL, func, params)
    local s_Result = PowNet.sendAndWaitForResponse(module, s_Message)
    if(type(s_Result) == "table") then
        print(s_Result.message)
    elseif(s_Result == nil or s_Result == false) then
        -- SAY WHICH HALF FAILED. A bare nil here is a TIMEOUT -- the module never answered at all
        -- -- and printing it verbatim gave a screen reading "nil", indistinguishable from a handler
        -- that answered with nothing to say.
        printError("No answer from " .. tostring(module) .. " for " .. tostring(func))
    else
        print(s_Result)
    end
end

local numArgs = # tArgs


function ResolveVars(p_Callable)
    local s_Vars = {}
    local s_Known = {}
    if(p_Callable.params == nil) then
        return s_Vars
    end
    for l_paramName,l_param in pairs(p_Callable.params) do
        s_Known["-" .. l_paramName:lower()] = true
        for i,value in pairs(tArgs) do
            if value:lower() == "-"..l_paramName:lower() then
                -- Param has a length of 1

                if(l_param.length ~= nil and l_param.length ~= 1) then
                    -- Flag
                    if(l_param.length == 0) then
                        s_Vars[l_paramName] = true
                    elseif tArgs[i + l_param.length] ~= nil then
                        s_Vars[l_paramName] = {}
                        for argIndex = 1, l_param.length, 1 do
                            s_Vars[l_paramName][argIndex] = tArgs[i + argIndex]:lower()
                        end
                    end
                else
                    -- Single var
                    if( tArgs[i + 1] ~= nil) then
                        s_Vars[l_paramName] = tArgs[i + 1]:lower()
                    end
                end
            end
        end
    end
    WarnUnknownParams(s_Known)
    return s_Vars
end

-- A MISTYPED FLAG IS INVISIBLE AT EVERY OTHER LAYER.
--
-- PowNet drops params the endpoint did not declare and the call still SUCCEEDS, so `-hight 4`
-- reaches nobody, changes nothing, and reports fine -- the exact shape that swallowed the MapServer
-- bounds push and every Handover for hours. This is the last place the spelling the user actually
-- typed still exists, so it is named here or never.
--
-- `-534` is a coordinate, not a flag: only a dash followed by a LETTER can be one.
function WarnUnknownParams(p_Known)
    for i,value in ipairs(tArgs) do
        if(i > 2 and value:match("^%-%a") ~= nil and p_Known[value:lower()] == nil) then
            printError("Unknown param " .. value .. " -- it will be dropped, not sent.")
        end
    end
end

-- ONE LIST OF RESERVED KEYS, NOT THREE.
--
-- `message`/`type`/`optional` are metadata ON an option table, not options a user may pick.
-- ParseOptions filtered them out of the DISPLAY while IsOption went on accepting them from the
-- KEYBOARD, so typing `type` selected a string and the next line indexed it as a table. The now
-- deleted RunInstallerOld carried a third copy of this list that had already drifted -- it filtered
-- `list` and not `type`. One list, and both the display and the input use it.
local RESERVED = {message = true, type = true, optional = true}

function IsOption(p_Input, p_Options)
    if(p_Input == nil or p_Options == nil) then
        return false
    end
    if (RESERVED[p_Input] == true) then
        return false
    end
    if (p_Options[p_Input] == nil) then
        return false
    end
    return true
end
function getVal(p_Val)
    if(type(p_Val) == "table") then
        local s_Ret = ""
        for k,v in pairs(p_Val) do
            if(type(v) == "table") then
                s_Ret = s_Ret .. "-: " .. k .."\n".. getVal(v) .. "\n"
            else
                s_Ret = s_Ret .. " " .. k ..": " .. tostring(v)
            end
        end
        return s_Ret
    end
    -- EVERY TYPE, NOT JUST STRINGS. This returned nil for numbers and for the booleans a
    -- zero-length flag param produces, so an answered flag printed as "nil" in the review list --
    -- which is the one screen a user reads before committing to a call.
    return tostring(p_Val)
end
function ParseOptions(p_Options, p_Answers)
    for optionName,option in pairs(p_Options) do
        if(RESERVED[optionName] ~= true) then
            if(option.optional == true) then
                term.setTextColor( colors.yellow )

            elseif(option.optional == false) then
                term.setTextColor( colors.red )

            elseif(option.optional == nil) then
                term.setTextColor( colors.white )
            end
            if(p_Answers[optionName] ~= nil) then
                term.setTextColor( colors.green )
            end
            print("-" ..optionName)
            if(p_Answers[optionName] ~= nil) then

                term.setTextColor( colors.gray )
                print(getVal(p_Answers[optionName]))
            end
            term.setTextColor( colors.white )
        end
    end
end

function SelectOption(p_Options, s_Answers)
    local s_OptionName = nil
    while(IsOption(s_OptionName, p_Options) == false) do
        print("")
        print("Options:")
        ParseOptions(p_Options, s_Answers)
        print("Enter option:")
        s_OptionName = read()

        if(s_OptionName == "") then
            return false
        end
        if(IsOption(s_OptionName, p_Options) == false) then
            print("Invalid option.")
        end
    end
    return s_OptionName, p_Options[s_OptionName]
end

-- ONE WIZARD LOOP, NOT TWO.
--
-- `SelectSingleOption` and `RunInstaller` were the same eight lines written out twice, and the only
-- difference that was ever intended is how many answers they collect: an `option` param is a choice
-- of ONE, a `list` param keeps going until the user presses enter. That is the only thing that
-- varies here.
--
-- The copies had also DRIFTED, and the single-answer one carried the bug: on enter-to-back-out it
-- returned `false` rather than the answers, and ParseValue writes that straight over
-- `p_Answers[name]` -- so opening an option you had already filled in and changing your mind
-- replaced the whole sub-table with a boolean. RunInstaller's `return p_Answers` is the correct
-- half and is what both do now.
function CollectAnswers(p_Options, p_Answers, p_Once)
    if(p_Answers == nil) then
        p_Answers = {}
    end
    while(true) do
        local s_OptionName, s_CurrentOption = SelectOption(p_Options, p_Answers)
        if(s_OptionName == false) then
            return p_Answers
        end
        p_Answers[s_OptionName] = ParseValue(s_CurrentOption.type, s_CurrentOption, p_Answers[s_OptionName])
        if(p_Once == true) then
            return p_Answers
        end
    end
end

function SelectSingleOption(p_Installer, p_Answers)
    print("Select an option")
    return CollectAnswers(p_Installer, p_Answers, true)
end

function RunInstaller(p_Installer, p_Answers)
    print("")--empty line
    return CollectAnswers(p_Installer, p_Answers, false)
end

function ParseValue(p_Type, p_CurrentOption, p_Answers)
    if(p_Type == "string") then
        print("Enter value:")
        return read()
    end
    if(p_Type == "int") then
        while(true) do
            print("Enter value:")
            local s_Value = read()
            if(tonumber(s_Value) ~= nil) then
                return s_Value
            end
            print("Not a number.")
        end
    end
    if p_Type == "option" then
        return SelectSingleOption(p_CurrentOption, p_Answers)
    end
    if p_Type == "list" then
        return RunInstaller(p_CurrentOption, p_Answers)
    end
    if(p_Type == "vec3") then
        while true do
            print("VEC3: x y z")
            print("GPS: enter")
            local s_Vec3TypeInput = read()
            if(s_Vec3TypeInput == "" or s_Vec3TypeInput == nil) then
                local s_Pos = LocateBelow()
                if(s_Pos ~= nil) then
                    return s_Pos
                end
                print("No gps signal available.")
            else
                -- THE PROMPT PROMISED `x y z` AND NOTHING READ IT. A typed position was assigned to
                -- a local and dropped, so the loop re-prompted forever with nothing on screen
                -- saying why -- and underground, where a fix is normally absent, that was the only
                -- way left to enter one.
                local s_X, s_Y, s_Z = s_Vec3TypeInput:match("^%s*(-?%d+)%s+(-?%d+)%s+(-?%d+)%s*$")
                if(s_X ~= nil) then
                    return {x = tonumber(s_X), y = tonumber(s_Y), z = tonumber(s_Z)}
                end
                print("Not a position. Expected: x y z")
            end
        end
    end
    -- NAME THE TYPE, DO NOT RETURN NOTHING. A module may declare a param type this remote does not
    -- implement; returning nil recorded no answer, so the wizard reprinted the same menu forever
    -- and the option never went green. That is a WIRING fault between a module and its client and
    -- it has to say so rather than look like a stuck menu.
    printError("Unsupported param type: " .. tostring(p_Type))
    return nil
end


-- The wizard path, out of Start on its own: filling in a nested schema and sending it is a step of
-- its own, and it is the only part of this program that touches the disk.
function RunInstallerCall(p_Module, p_Func, p_Callable)
    local s_Args = RunInstaller(p_Callable.params)
    print(PowNet.dump(s_Args))
    -- The dump is a breadcrumb, the CALL is the point. `fs.open` returns nil on a read-only or full
    -- mount and indexing that killed the call the user had just spent two minutes filling in -- so
    -- a failed dump is reported and stepped over, never fatal.
    local s_File = fs.open("out.bin", "w")
    if(s_File ~= nil) then
        s_File.write(textutils.serialize(s_Args))
        s_File.close()
    else
        printError("Could not write out.bin -- answers not saved, sending anyway.")
    end
    CallCallable(p_Module, p_Func, s_Args)
end

function PrintParams(p_Callable)
    print("Params:")
    -- A callable may declare none; `pairs(nil)` throws, and it threw on the one screen whose whole
    -- job is to tell the user what to type.
    if(p_Callable.params == nil) then
        return
    end
    for k,v in pairs(p_Callable.params) do
        print(" -" .. k)
    end
end

function Start()
    local s_Message = PowNet.newMessage(PowNet.MESSAGE_TYPE.REGISTER, "GetCallable")
    local s_Result = PowNet.sendAndWaitForResponse(-1, s_Message)
    if(type(s_Result) == "table") then
        m_Callable = s_Result
        if numArgs == 0 then
            print("Modules: ")
        end
        for k,v in pairs(s_Result) do
            if(numArgs == 0) then
                print(" -" .. k)
            end
        end
        if tArgs[1] == nil then
            return
        end
    else
        -- A DEAD REGISTRY IS NOT AN UNKNOWN MODULE. This printed the failure and then fell through
        -- into the lookup below against an EMPTY m_Callable, so an unreachable MainFrame reported
        -- "Module not found" -- a transport fault dressed up as a typo, and the user retypes the
        -- name instead of looking at the host.
        printError("GetCallable failed: " .. tostring(s_Result))
        return
    end

    if not m_Callable[tArgs[1]] then
        print("Module not found")
        return
    end

    local s_Callable = m_Callable[tArgs[1]]
    --print(PowNet.dump(s_Callable))
    if tArgs[2] == nil then
        print("Functions:")
        for k,v in pairs(s_Callable) do
            print(" -" .. v.name)
        end
        return
    end
    if not s_Callable[tArgs[2]] then
        print("Function not found")
        return
    end
    if(s_Callable[tArgs[2]].installer) then
        RunInstallerCall(tArgs[1], tArgs[2], s_Callable[tArgs[2]])
        return
    end
    if (tArgs[3] == nil or tArgs [3] == "?") then
        PrintParams(s_Callable[tArgs[2]])
        return
    end
    local s_Params = ResolveVars(s_Callable[tArgs[2]])
    CallCallable(tArgs[1], tArgs[2], s_Params)
end

Start()

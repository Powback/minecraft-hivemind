m_Min = {}
m_Max = {}



local function getDist(min, max)
	local distX = math.abs(max.x - min.x)
	local distY = math.abs(max.y - min.y)
	local distZ = math.abs(max.z - min.z)
	return {x = distX, y = distY, z = distZ}
end


local function GetOrientation(min,max)
	local s_Dist = getDist(min,max)
	if(s_Dist.x <= s_Dist.z) then
		return "x"
	else
		return "z"
	end
end

function round(x)
	if x%2 ~= 0.5 then
		return math.floor(x+0.5)
	end
	return x-0.5
end

function GetMinMax(p_Min, p_Max)
	local s_Min = p_Min
	local s_Max = p_Max
	if(p_Min.x > p_Max.x) then
		s_Min.x = p_Max.x;
		s_Max.x = p_Min.x;
	end
	if(p_Min.y > p_Max.y) then
		s_Min.y = p_Max.y;
		s_Max.y = p_Min.y;
	end
	if(p_Min.z > p_Max.z) then
		s_Min.z = p_Max.z;
		s_Max.z = p_Min.z;
	end
end

local function ZigZag(worker, distanceA, distanceB, flip, push)
	local x = 0
	local z = push

	local xInvert = false
	print("a: " .. distanceA)
	print("b: " .. distanceB)
	for i = 0, distanceA, 1 do
		for i2 = push, distanceB, 1 do

			if (x == distanceB) then
				xInvert = true
			end
			if (x == push) then
				xInvert = false
			end


			if (flip == false) then
				-- add this value?
				worker.path[#worker.path + 1] = {worker.start.x + x, worker.start.z + z} -- Draw current pos
			else
				worker.path[#worker.path + 1] = {worker.start.x + z, worker.start.z + x} -- Draw current pos
			end
			if(xInvert) then
				x = x - 1
				worker.turn[#worker.turn + 1] = "south"
			else
				x = x + 1
				worker.turn[#worker.turn + 1] = "north"
			end

			if (flip == false) then
				-- add this value?
				worker.path[#worker.path + 1] = {worker.start.x + x, worker.start.z + z} -- Draw current pos
			else
				worker.path[#worker.path + 1] = {worker.start.x + z, worker.start.z + x} -- Draw current pos
			end
		end
		if(z == distanceA) then
			return -- Wait what?
		end
		worker.turn[#worker.turn + 1] = "left"
		-- push left?
		z = z + 1

		-- Why?
		if(flip == false) then
			worker.path[#worker.path + 1] = {worker.start.x + x, worker.start.z + z} -- Draw current pos
		else
			worker.path[#worker.path + 1] = {worker.start.x + z, worker.start.z + x} -- Draw current pos
		end


	end

end


local function GeneratePath(p_Workers, p_Orientation)
	for k,worker in pairs(p_Workers) do

		local s_Distance = {
			x = math.abs(worker.start.x - worker.stop.x),
			y = math.abs(worker.start.y - worker.stop.y),
			z = math.abs(worker.start.z - worker.stop.z)
		}

		local s_Orientation = GetOrientation(worker.start, worker.stop)
		local safeZone = 2

		if(s_Orientation == "x") then
			ZigZag(worker, 1, s_Distance.x, false, 0)
			ZigZag(worker, s_Distance.x , s_Distance.z, true, 2)
		else
			ZigZag(worker, 1, s_Distance.z, true, 0)
			ZigZag(worker, s_Distance.z, s_Distance.x, false, 2)
		end
	end
	return p_Workers
end

function PrepareTask(p_Params)
	local s_Min, s_Max = GetMinMax(p_Params.start, p_Params.stop)

	local s_Orientation = GetOrientation(s_Min, s_Max)
	local s_Dist = getDist(s_Min, s_Max)

	--TODO: Calculate optimal number of workers
	local s_WorkerCount = 1

	if(s_Orientation == "x" and s_Dist.x < s_WorkerCount) then
		s_WorkerCount = s_Dist.x
	end
	if(s_Orientation == "z" and s_Dist.z < s_WorkerCount) then
		s_WorkerCount = s_Dist.x
	end

	local increment = {x = 0, z = 0}
	increment.x = round(s_Dist.x / s_WorkerCount);
	increment.z = round(s_Dist.z / s_WorkerCount);

	local s_Workers = {}
	for i = 0, s_WorkerCount, 1 do
		local s_Start = { x = 0, z = 0, y = 0}
		local s_Stop = { x = 0, z = 0, y = 0}

		if(s_Orientation == "x") then
			s_Start.x = s_Min.x + (i * increment.x)
			s_Start.z = s_Min.z

			s_Stop.x = s_Max.x + (i + 1) * increment.x
			s_Stop.z = s_Max.z
		else

			s_Start.x = s_Min.x
			s_Start.z = s_Min.z + (i * increment.z)

			s_Stop.x = s_Max.x
			s_Stop.z = s_Min.z + (i + 1) * increment.z - 1
		end


		s_Workers[#s_Workers + 1] ={start = s_Start, stop = s_Stop, path = {}, turn = {}}

	end

	return GeneratePath(s_Workers, s_Orientation)

end

-- Upstream ends here with a scratch harness: it hardcoded a start/stop pair, called
-- PrepareTask at LOAD time and wrote the result to a file called "out". That makes the
-- file unloadable as an API -- os.loadAPI executes the chunk, so TaskMan died on
-- `attempt to index local 'max' (a nil value)` before it ever ran, and left an "out"
-- file on the computer as the only clue. Removed; the module is a library.

----------------------------------------------------------------------------------------------
-- Splitting a site across several miners
----------------------------------------------------------------------------------------------
-- A turn costs a full step, exactly like a move. So a w x l sweep is not w*l steps, it is
--
--     w*l  moves  +  2*(l-1)  turns
--
-- because every row transition is turn, advance, turn. That single fact decides the geometry:
--
--   * Rows must run along the LONG axis. A 32x4 box swept in 4 long rows costs 128+6 = 134
--     steps; the same box swept in 32 short rows costs 128+62 = 190. Same blocks, 42% more work.
--   * Workers must be split across the SHORT axis, so each one keeps WHOLE rows. Splitting along
--     the row axis would cut every row in half and double the turn count.
--   * Slabs are disjoint by construction, so miners cannot dig each other. That is not a nicety:
--     D1 mined D2 out of existence because its dig box contained D2's parking spot, and nothing
--     noticed -- the registry still listed D2 as idle.
--
-- Returns one payload per worker, each a plain Dig job over its own slab.
function SplitRegion(p_Min, p_Max, p_Workers, p_Depth)
    local s_MinX, s_MaxX = math.min(p_Min.x, p_Max.x), math.max(p_Min.x, p_Max.x)
    local s_MinZ, s_MaxZ = math.min(p_Min.z, p_Max.z), math.max(p_Min.z, p_Max.z)
    local s_MinY        = math.min(p_Min.y, p_Max.y)

    local s_DX = s_MaxX - s_MinX + 1
    local s_DZ = s_MaxZ - s_MinZ + 1

    -- Long axis carries the rows; the short axis is what we cut into slabs.
    local s_RowAlongX = s_DX >= s_DZ
    local s_RowLen    = s_RowAlongX and s_DX or s_DZ     -- cells per row
    local s_Rows      = s_RowAlongX and s_DZ or s_DX     -- number of rows to share out

    -- Never more workers than rows: a worker with no rows has nothing to do, and two workers in
    -- one row is the collision we are trying to prevent.
    local s_N = math.max(1, math.min(p_Workers or 1, s_Rows))

    local s_Base, s_Extra = math.floor(s_Rows / s_N), s_Rows % s_N
    local s_Out, s_Cursor = {}, 0

    for i = 1, s_N do
        local s_Slab = s_Base + ((i <= s_Extra) and 1 or 0)   -- spread the remainder, not all on one
        local s_Start
        if s_RowAlongX then
            s_Start = {x = s_MinX, y = s_MinY, z = s_MinZ + s_Cursor}
        else
            s_Start = {x = s_MinX + s_Cursor, y = s_MinY, z = s_MinZ}
        end
        s_Out[#s_Out + 1] = {
            pos   = s_Start,
            w     = s_RowLen,
            l     = s_Slab,
            depth = p_Depth or 1,
            -- Reported so a human can sanity-check the plan without re-deriving it.
            cost  = (s_RowLen * s_Slab) + 2 * math.max(0, s_Slab - 1),
            slab  = i,
            of    = s_N,
        }
        s_Cursor = s_Cursor + s_Slab
    end
    return s_Out
end

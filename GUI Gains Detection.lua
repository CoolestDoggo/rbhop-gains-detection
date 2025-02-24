--Causes a little bit of lag
--Saves the file in the workspace folder
local logRun = false

--NOTE: Gain guessing is automatic. Only use this for testing
--Do not use results given with a changed value
local gains = 2.7 * 1

-- Where it should warn about fps limit
local fpsWarnAt = 600

--Disable to prevent auto-scanning when spectating a bot
_G.AutoScan = true

print("--{", tick(), "}-- > Loading")

local botManager, movement, NWVars, styles, remote
local cos = math.cos
local sin = math.sin
local floor = math.floor
local r_round = math.round
local insert = table.insert

for _, t in next, getgc(true) do
	if type(t) == "table" then
		if rawget(t, "Bots") then
			botManager = t
		end
		if rawget(t, "GetPlayerFrames") then
			movement = t
		end
		if rawget(t, "GetNWInt") then
			NWVars = t
		end
		if rawget(t, "GetStyle") then
			styles = t
		end
		if rawget(t, "Add") and rawget(t, "InitLast") then
			remote = t
		end
	end
end

--[[
	frames[1] == {1:Tick,2:Position,3:Velocity,4:?}
	frames[1] is every physics tick (0.01)
	frames[2] == {1:Tick,2:Angles}
	frames[2] is every frame of the runner (presumably) (Varies in length)
	frames[3] == {1:Date,2:Gravity}
	frames[3] only occurs once
	frames[4] == {1:Time,2:HeldKeys}
	frames[4] only updates when theres a change of keys
]]

local function map()
	return workspace:FindFirstChild("DisplayName", true).Parent
end

local function numToKeys(number, keys)
	local returnKeys = {}

	for i, v in next, {" ", "d", "s", "a", "w"} do
		local keyPower = 2 ^ (5 - i)
		if number - keyPower >= 0 then
			returnKeys[v] = 1
			number = number - keyPower
		else
			returnKeys[v] = 0
		end
	end

	for key, valid in next, keys do --Ignore invalid/impossible keys
		returnKeys[key] = math.min(returnKeys[key], valid)
	end

	return returnKeys
end

local function round(n, precision)
	precision = precision or 1e5 -- 4 decimal places, good enough for gains

	return r_round(n * precision) / precision
end

local function isNaN(n)
	return n ~= n -- NaN is the only number that isn't equal to itself
end

local function UPS(v)
	return (v.X * v.X + v.Z * v.Z) ^ 0.5
end

local dot = Vector3.new().Dot

local function calculateGains(speed, angles)
	local var = dot(speed, angles)

	if not (var < gains) then
		return speed
	end

	return speed + (gains - var) * angles
end

local function guessGains(lastVel, curVel, angles)
	return round(((curVel - lastVel).X / angles.X + dot(lastVel, angles)) / 2.7)
end

local results = {}

local function checkBot(botID)
	local botInstance = botManager.GetBotFromId(botID)
	local frames = movement.GetPlayerFrames(botInstance)

	if not frames then
		return
	end

	local frames2 = frames[2]
	local style = styles.Type[NWVars.GetNWInt(botInstance, "Style")]
	local indexedAngles = {}
	local totalFPS, squareTotalFPS = 0, 0
	local warns = 0
	local fpsStats = {min=9e9, mint=0, max=0, maxt=0}
	local startTime = frames[1][1][1]
	local fpsValues = {}

	for i, t in next, frames2 do
		local prevFrame = frames2[i - 1]

		if prevFrame then
			local roundedTick = round(t[1] - startTime)
			local curFPS = 1 / (t[1] - prevFrame[1])

			fpsValues[i] = {roundedTick, curFPS}

			if curFPS > fpsWarnAt then
				warns = warns + 1

				if warns <= 20 then
					warn(botInstance.Name, "just hit", curFPS, "FPS (Warning threshold:", fpsWarnAt, ") on tick", roundedTick)
				elseif warns == 21 then
					warn(botInstance.Name, "passed maximum warn limit for FPS of 20 on", roundedTick)
				end
			end

			totalFPS = totalFPS + curFPS
			squareTotalFPS = squareTotalFPS + (curFPS * curFPS)

			if curFPS < fpsStats.min then
				fpsStats.min = curFPS
				fpsStats.mint = roundedTick
			end

			if curFPS > fpsStats.max then
				fpsStats.max = curFPS
				fpsStats.maxt = roundedTick
			end
		end

		local floored = floor(t[1] * 5)

		if not indexedAngles[floored] then
			indexedAngles[floored] = {}
		end

		insert(indexedAngles[floored], t)
	end

	local lastVel
	local tickCount, accurateCount, failedTicks = 0, 0, 0
	local prevHeld = 1
	local accuracyScore = {}
	local gainGuesses = {}
	local suspectedGains = {}
	local calculationStart = tick()
	local frames1Len = #frames[1]

	--[[
		{key, value(s)}
		keys:
			0 = Broken tick
			1 = No relevant movement
			2 = Tick data
			3 = Just text
	]]
	local logInfo = {}

	for i, t in next, frames[1] do
		if i % 5000 == 0 then
			local progress = (i / frames1Len) * 100
			print("\nProgress: ", progress, "%\n[" .. string.rep("#", floor(progress)) .. string.rep("-", 100 - floor(progress)).."]")
			task.wait(0.2)
		end

		local curTick = t[1]

		if curTick < 1 then continue end

		local roundedTick = round(curTick, 100)
		local curVel = t[3]

		if not lastVel then
			lastVel = curVel

			continue
		end

		local angleBefore, angleAfter
		local floored = floor(curTick * 5)

		for a = -1, 1, 1 do
			a = floored + a
			local prevIndexed = 1

			if indexedAngles[a] then
				for k = prevIndexed, #indexedAngles[a] do
					local v = indexedAngles[a][k]

					if v[1] < curTick then
						angleBefore = v
						prevIndexed = k
					else
						angleAfter = v
						break
					end
				end
			end

			if angleAfter then
				break
			end
		end

		if not angleBefore or not angleAfter then
			failedTicks = failedTicks + 1
			lastVel = curVel

			if logRun then
				insert(logInfo, {0, roundedTick})
			end

			continue
		end

		local heldKeys
		for k = prevHeld, #frames[4] do
			local v = frames[4][k]

			if v[1] < curTick then
				heldKeys = v[2]
				prevHeld = k
			else
				break
			end
		end

		local keys = numToKeys(heldKeys, style["keys"])
		local curAngle = angleBefore[2]:Lerp(angleAfter[2], (-angleBefore[1] + curTick) / (angleAfter[1] - angleBefore[1]))
		local yCos = cos(curAngle.Y)
		local ySin = sin(curAngle.Y)
		local SmW = keys["s"] - keys["w"]
		local DmA = keys["d"] - keys["a"]
		local projectedGain = Vector3.new(DmA * yCos + SmW * ySin, 0, SmW * yCos - DmA * ySin).unit

		if isNaN(projectedGain.X) then
			lastVel = curVel

			if logRun then
				insert(logInfo, {1, roundedTick})
			end

			continue
		end

		local projectedUPS = UPS(calculateGains(lastVel, projectedGain))
		local curUPS = UPS(curVel)
		local guessedGains = (curUPS == projectedUPS and 1) or guessGains(lastVel, curVel, projectedGain)

		if not suspectedGains[guessedGains] then
			suspectedGains[guessedGains] = 0
		end

		suspectedGains[guessedGains] = suspectedGains[guessedGains] + 1

		if logRun then
			insert(logInfo, {2, roundedTick, UPS(lastVel), curUPS, projectedUPS, guessedGains})
		end

		lastVel = curVel
		tickCount = tickCount + 1
		accurateCount = accurateCount + (curUPS == projectedUPS and 1 or 0)
		insert(accuracyScore, accurateCount / tickCount)
		gainGuesses[roundedTick] = guessedGains
	end

	table.sort(fpsValues, function(a, b) -- Sort from low to high in fps
		if a and b then
			return a[2] < b[2]
		else
			return false
		end
	end)

	local numFrames = #frames2 - 1 -- Subtract 1 because we don't use the first frame
	local meanFPS = totalFPS / numFrames
	local stdDevFPS = ((squareTotalFPS - totalFPS ^ 2 / numFrames) / (numFrames - 1)) ^ 0.5
	local calculationTime = tick() - calculationStart
	local medianFPS = fpsValues[round(#fpsValues / 2, 1)][2]

	local summaryMessage = "Summary for " .. botInstance.Name .. " (ID " .. botID .. ") (" .. gains .. ")" ..
		"\nMap:            " .. map().DisplayName.Value .. " / " .. map().name ..
		"\nStyle:          " .. style.name ..
		"\nChecked Ticks:  " .. tickCount ..
		"\nAccurate Ticks: " .. accurateCount ..
		"\nBroken Ticks:   " .. failedTicks ..
		"\nAverage FPS:    " .. meanFPS ..
		"\nMedian FPS:     " .. medianFPS ..
		"\nstdDev FPS:     " .. stdDevFPS ..
		"\nMinimum FPS:    " .. fpsStats.min .. " (" .. fpsStats.mint .. ")" ..
		"\nMaximum FPS:    " .. fpsStats.max .. " (" .. fpsStats.maxt .. ")" ..
		"\n>" .. fpsWarnAt .. "FPS Frames: " .. warns .. " / " .. numFrames ..
		"\nAccuracy%:      " .. accurateCount / tickCount * 100 ..
		"\nCalculation time: " .. calculationTime .. " seconds"

	print(summaryMessage)

	if logRun then
		insert(logInfo, {3, summaryMessage})
	end

	if accurateCount / tickCount < 0.5 then --Not looking good
		local totalWeight = 0
		local bestValue = {0, 0}

		for guess, weight in next, suspectedGains do
			totalWeight = totalWeight + weight

			if weight > bestValue[2] then
				bestValue = {guess, weight}
			end
		end

		local extraMessage = "Extra Info for " .. botInstance.Name .. " (ID " .. botID .. ")" ..
			"\nAccuracy% mid way (" .. floor(#accuracyScore / 2) / 100 .."): " .. accuracyScore[floor(#accuracyScore / 2)] * 100 ..
			"\nPredicted Gains:      " .. bestValue[1] .. " (" .. bestValue[1] * gains .. ") at " .. (bestValue[2] / totalWeight) * 100 .. "%"

		warn(extraMessage)

		if logRun then
			insert(logInfo, {3, extraMessage})
		end
	end

	-- Previously this was done in a single string, but now the data is instead put into a table
	-- Based on the key of the table, the data is written to a string in chunks of a certain size
	-- These chunks are then individually written to the file
	if writefile and logRun then
		if not isfolder("rbhop-gains-detection") then
			makefolder("rbhop-gains-detection")
		end

		local displayName = map().DisplayName.Value

		-- Parse for invalid characters
		local invalidChars = {"/", "\\", ":", "*", "?", '"', "<", ">", "|"}

		for _, v in next, invalidChars do
			displayName = displayName:gsub(v, "")
		end

		local name = "rbhop-gains-detection/gs-" .. displayName .. "-" .. style.name .. "-" .. botInstance.Name:sub(7)
					.. ((accurateCount / tickCount < 0.5) and "-suspicious.txt" or "-legit.txt")

		writefile(name, tick() .. "\n" .. gains .. "\n" .. #frames[1] .. "\nL=Last\nC=Current\nP=Predicted\nBT=Bot Tick")

		-- This could just be done in the loop, but it's neater this way
		local function formatInfo(info)
			local key = info[1]

			if key == 0 then
				return "\nBT: " .. info[2] .. "\nBroken Tick"
			elseif key == 1 then
				return "\nBT: " .. info[2] .. "\nNo Relevant Movement"
			elseif key == 2 then
				return "\nBT: " .. info[2] ..
						"\nL UPS: " .. info[3] ..
						"\nC UPS: " .. info[4] ..
						"\nP UPS: " .. info[5] ..
						"\nGuessed gains: " .. info[6]
			elseif key == 3 then
				return "\n" .. info[2]
			end
		end

		-- Break up log text into chunks of 100 logs per append
		for i = 1, #logInfo, 100 do
			local chunk = ""

			for j = 0, 99 do
				if logInfo[i + j] then
					chunk = chunk .. formatInfo(logInfo[i + j])
				end
			end

			appendfile(name, chunk)
		end
	end

	table.sort(fpsValues, function(a, b) -- Sort from low to high in fps timestamp
		if a and b then
			return a[1] < b[1]
		else
			return false
		end
	end)

	results[botID] = {gainGuesses=gainGuesses, fpsValues=setmetatable(fpsValues, {
		__index = function(self, k) -- Get nearest value if its not there wow!
			local low, high = 1, #self

			for _ = 1, math.ceil(math.sqrt(#self)) do
				if low == high then break end

				local mid = r_round((low + high) / 2)

				if self[mid][1] < k then
					low = mid
				elseif self[mid][1] > k then
					high = mid
				end
			end

			local localSum = 0
			local index = r_round((low + high) / 2)

			for i = 0, 29 do
				localSum = localSum + self[index - i][2]
			end

			return localSum / 30 -- take average of last 30 frames
		end
	})}

	return true
end

local text = Instance.new("TextLabel", Instance.new("ScreenGui", game.CoreGui))
text.Size = UDim2.fromOffset(200, 100)
text.Position = UDim2.new(0.5, -100, 0, 0)
text.TextSize = 30

local specTarget
remote.Subscribe("SetSpectating", function(u)
	specTarget = type(u) == "table" and u
end)

game:GetService("RunService").RenderStepped:Connect(function()
	local values = results[specTarget and specTarget.BotId]

	if not (specTarget and values) then
		text.Visible = false
		return
	end

	local gainGuesses, fpsValues = values.gainGuesses, values.fpsValues
	local curTime = round(NWVars.GetNWFloat(specTarget, "TimeNow"), 100) + 1

	if gainGuesses[curTime] then
		local fps = fpsValues[curTime]

		if fps then
			text.Text = round(tonumber(gainGuesses[curTime])) .. "\n" .. round(fps, 1)
		else
			text.Text = round(tonumber(gainGuesses[curTime]))
		end
	end

	text.Visible = true
end)

if _G.AutoScan and not _G.Subscribed then
	local scanned = {}

	botManager.BotAdded(function(p)
		if type(p) == "table" and _G.AutoScan and not scanned[p.BotId] then
			print("Autoscan start:", p.BotId)

			while task.wait(0.5) do
				if scanned[p.BotId] then
					break
				end

				if checkBot(p.BotId) then
					scanned[p.BotId] = true
					break
				end

				if not _G.AutoScan then
					break
				end
			end

			print("Autoscan done:", p.BotId)
		end
	end)

	_G.Subscribed = true
end

print("--{", tick(), "}-- > Loaded")

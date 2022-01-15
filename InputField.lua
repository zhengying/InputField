--[[============================================================
--=
--=  InputField v3.1 (for LÖVE 0.10.2+)
--=  - Written by Marcus 'ReFreezed' Thunström
--=  - MIT License (See the bottom of this file)
--=
--==============================================================

	1. Functions
	2. Enums
	3. Basic usage



	1. Functions
	----------------------------------------------------------------

	-- Search through the file for more info about each individual function.

	-- Settings:
	getDimensions, getWidth, getHeight, setDimensions, setWidth, setHeight
	getDoubleClickMaxDelay, setDoubleClickMaxDelay
	getFilter, setFilter
	getFont, setFont
	getMouseScrollSpeed, getMouseScrollSpeedX, getMouseScrollSpeedY, setMouseScrollSpeed, setMouseScrollSpeedX, setMouseScrollSpeedY
	getType, isPassword, isMultiline
	isEditable, setEditable
	isFontFilteringActive, setFontFilteringActive

	-- Events:
	update
	mousepressed, mousemoved, mousereleased
	keypressed, textinput

	-- Other:
	clearHistory
	eachVisibleLine, eachSelection, eachSelectionOptimized
	getBlinkPhase, resetBlinking
	getCursor, setCursor, moveCursor, getCursorSelectionSide, getAnchorSelectionSide
	getCursorLayout
	getMaxHistory, setMaxHistory
	getScroll, getScrollX, getScrollY, setScroll, setScrollX, setScrollY, scroll
	getScrollLimits
	getSelection, setSelection, selectAll, getSelectedText, getSelectedVisibleText
	getText, setText, getVisibleText, insert
	getTextDimensions, getTextWidth, getTextHeight
	getTextLength
	getTextOffset
	isBusy
	releaseMouse
	reset



	2. Enums
	----------------------------------------------------------------

	InputFieldType
		"normal"      -- Simple single-line input.
		"password"    -- Single-line input where all characters are obscured.
		"multiwrap"   -- Multi-line input where text wraps by the width of the field.
		"multinowrap" -- Multi-line input with no wrapping.

	SelectionSide
		"start" -- The start (left side) of the text selection.
		"end"   -- The end (right side) of the text selection.

	TextCursorAlignment
		"left"  -- Align cursor to the left.
		"right" -- Align cursor to the right.



	3. Basic usage
	----------------------------------------------------------------

	local InputField = require("InputField")
	local field      = InputField("Initial text.")

	local fieldX = 80
	local fieldY = 50

	love.keyboard.setKeyRepeat(true)

	function love.keypressed(key, scancode, isRepeat)
		field:keypressed(key, isRepeat)
	end
	function love.textinput(text)
		field:textinput(text)
	end

	function love.mousepressed(mx, my, mbutton, pressCount)
		field:mousepressed(mx-fieldX, my-fieldY, mbutton, pressCount)
	end
	function love.mousemoved(mx, my)
		field:mousemoved(mx-fieldX, my-fieldY)
	end
	function love.mousereleased(mx, my, mbutton)
		field:mousereleased(mx-fieldX, my-fieldY, mbutton)
	end

	function love.draw()
		love.graphics.setColor(0, 0, 1)
		for _, x, y, w, h in field:eachSelection() do
			love.graphics.rectangle("fill", fieldX+x, fieldY+y, w, h)
		end

		love.graphics.setColor(1, 1, 1)
		for _, text, x, y in field:eachVisibleLine() do
			love.graphics.print(text, fieldX+x, fieldY+y)
		end

		local x, y, h = field:getCursorLayout()
		love.graphics.rectangle("fill", fieldX+x, fieldY+y, 1, h)
	end



--============================================================]]

local InputField = {
	_VERSION = "InputField 3.1.0",
}



local LK   = require"love.keyboard"
local LS   = require"love.system"
local LT   = require"love.timer"
local utf8 = require"utf8"

local InputField   = {}
InputField.__index = InputField



--==============================================================
--= Internal functions =========================================
--==============================================================



local function noop() end



local function clamp(n, min, max)
	return math.max(math.min(n, max), min)
end



local function isInteger(v)
	return (type(v) == "number" and v == math.floor(v))
end



local function nextCodepoint(s, i)
	if i > 0 then
		local b = s:byte(i)
		if not b then
			return
		elseif b >= 240 then
			i = i + 4
		elseif b >= 224 then
			i = i + 3
		elseif b >= 192 then
			i = i + 2
		else
			i = i + 1
		end
	elseif i == 0 then
		i = 1
	elseif i < 0 then
		return
	end
	if i > #s then  return  end

	return i, utf8.codepoint(s, i)
end

local function utf8Codes(s) -- We don't use utf8.codes() as it creates garbage!
	return nextCodepoint, s, 0
end

local function utf8GetEndOffset(line, pos)
	return (utf8.offset(line, pos+1) or #line+1) - 1
end



local function cleanString(field, s)
	s = s:gsub((field:isMultiline() and "[%z\1-\9\11-\31]+" or "[%z\1-\31]+"), "") -- Should we allow horizontal tab?

	if field.fontFilteringIsActive then
		local font      = field.font
		local hasGlyphs = font.hasGlyphs

		s = s:gsub(utf8.charpattern, function(c)
			if not hasGlyphs(font, c) then  return ""  end
		end)
	end

	return s
end



--
-- boundPosition = getNextWordBound( string, startPosition, direction )
-- direction     = -1 | 1
--
-- Cursor behavior examples:
--   a|a bb  ->  aa| bb
--   aa| bb  ->  aa bb|
--   aa |bb  ->  aa bb|
--   cc| = dd+ee  ->  cc =| dd+ee
--   cc =| dd+ee  ->  cc = dd|+ee
--   cc = dd|+ee  ->  cc = dd+|ee
--   f|f(-88  ->  ff|(-88
--   ff|(-88  ->  ff(-|88
--   ff(|-88  ->  ff(-|88
--
local getNextWordBound
do
	local function newSet(values)
		local set = {}
		for _, v in ipairs(values) do
			set[v] = true
		end
		return set
	end

	local ASCII_PUNCTUATION = "!\"#$%&'()*+,-./:;<=>?@[\\]^`{|}~"; ASCII_PUNCTUATION = newSet{ ASCII_PUNCTUATION:byte(1, #ASCII_PUNCTUATION) }
	local ASCII_WHITESPACE  = newSet{ 9,10,11,12,13,32 } -- Horizontal tab, line feed, vertical tab, form feed, carriage return, space.

	-- Generated by tools/generateUnicodeInfo.lua:

	-- PUNCTUATION (8330, 97+230)
	local UNICODE_PUNCTUATION = newSet{180,187,191,215,247,749,885,894,903,1014,1154,1470,1472,1475,1478,1563,1748,1758,1769,2142,2416,2557,2678,2928,3191,3199,3204,3407,3449,
		3572,3647,3663,3892,3894,3896,3973,4347,5120,6464,7379,8125,8468,8485,8487,8489,8494,8527,11632,12336,12448,12539,12880,42611,42622,43260,43359,43867,44011,64297,
		65952,66463,66512,66927,67671,67871,67903,68223,68296,69293,70093,70107,70313,70749,70854,71739,72162,73727,92917,94178,113820,113823,119365,120513,120539,120571,120597,120629,120655,120687,
		120713,120745,120771,123215,123647,126124,126128,126254}
	local ranges = {161,169,171,172,174,177,182,184,706,709,722,735,741,747,751,767,900,901,1370,1375,1417,1418,
		1421,1423,1523,1524,1542,1551,1566,1567,1642,1645,1789,1790,1792,1805,2038,2041,2046,2047,2096,2110,2404,2405,2546,2547,
		2554,2555,2800,2801,3059,3066,3674,3675,3841,3863,3866,3871,3898,3901,4030,4037,4039,4044,4046,4058,4170,4175,4254,4255,
		4960,4968,5008,5017,5741,5742,5787,5788,5867,5869,5941,5942,6100,6102,6104,6107,6144,6154,6468,6469,6622,6655,6686,6687,
		6816,6822,6824,6829,7002,7018,7028,7036,7164,7167,7227,7231,7294,7295,7360,7367,8127,8129,8141,8143,8157,8159,8173,8175,
		8189,8190,8208,8231,8240,8286,8314,8318,8330,8334,8352,8383,8448,8449,8451,8454,8456,8457,8470,8472,8478,8483,8506,8507,
		8512,8516,8522,8525,8586,8587,8592,9254,9280,9290,9372,9449,9472,10101,10132,11123,11126,11157,11159,11263,11493,11498,11513,11516,
		11518,11519,11776,11822,11824,11858,11904,11929,11931,12019,12032,12245,12272,12283,12289,12292,12296,12320,12342,12343,12349,12351,12443,12444,
		12688,12689,12694,12703,12736,12771,12800,12830,12842,12871,12896,12927,12938,12976,12992,13311,19904,19967,42128,42182,42238,42239,42509,42511,
		42738,42743,42752,42774,42784,42785,42889,42890,43048,43051,43062,43065,43124,43127,43214,43215,43256,43258,43310,43311,43457,43469,43486,43487,
		43612,43615,43639,43641,43742,43743,43760,43761,43882,43883,64434,64449,64830,64831,65020,65021,65040,65049,65072,65106,65108,65126,65128,65131,
		65281,65295,65306,65312,65339,65344,65371,65381,65504,65510,65512,65518,65532,65533,65792,65794,65847,65855,65913,65929,65932,65934,65936,65948,
		66000,66044,67703,67704,68176,68184,68336,68342,68409,68415,68505,68508,69461,69465,69703,69709,69819,69820,69822,69825,69952,69955,70004,70005,
		70085,70088,70109,70111,70200,70205,70731,70735,70746,70747,71105,71127,71233,71235,71264,71276,71484,71487,72004,72006,72255,72262,72346,72348,
		72350,72354,72769,72773,72816,72817,73463,73464,73685,73713,74864,74868,92782,92783,92983,92991,92996,92997,93847,93850,118784,119029,119040,119078,
		119081,119140,119146,119148,119171,119172,119180,119209,119214,119272,119296,119361,119552,119638,120832,121343,121399,121402,121453,121460,121462,121475,121477,121483,
		125278,125279,126704,126705,126976,127019,127024,127123,127136,127150,127153,127167,127169,127183,127185,127221,127245,127405,127462,127490,127504,127547,127552,127560,
		127568,127569,127584,127589,127744,128727,128736,128748,128752,128764,128768,128883,128896,128984,128992,129003,129024,129035,129040,129095,129104,129113,129120,129159,
		129168,129197,129200,129201,129280,129400,129402,129483,129485,129619,129632,129645,129648,129652,129656,129658,129664,129670,129680,129704,129712,129718,129728,129730,
		129744,129750,129792,129938,129940,129994}
	for i = 1, #ranges, 2 do  for cp = ranges[i], ranges[i+1] do UNICODE_PUNCTUATION[cp] = true end  end

	-- WHITESPACE (18, 5+2)
	local UNICODE_WHITESPACE = newSet{160,5760,8239,8287,12288}
	local ranges = {8192,8202,8232,8233}
	for i = 1, #ranges, 2 do  for cp = ranges[i], ranges[i+1] do UNICODE_WHITESPACE[cp] = true end  end



	local function getCodepointCharType(cp)
		return ASCII_PUNCTUATION[cp]   and "punctuation"
		    or ASCII_WHITESPACE[cp]    and "whitespace"
		    or cp <= 127               and "word"
		    or UNICODE_PUNCTUATION[cp] and "punctuation"
		    or UNICODE_WHITESPACE[cp]  and "whitespace"
		    or                             "word"
	end

	local codepoints = {}

	function getNextWordBound(s, pos, direction)
		assert(type(s)   == "string")
		assert(direction == 1 or direction == -1)
		assert(isInteger(pos))

		local len = 0

		for _, cp in utf8Codes(s) do
			len             = len + 1
			codepoints[len] = cp
		end
		for i = len+1, #codepoints do
			codepoints[i] = nil
		end

		pos = clamp(pos, 0, len)
		if direction < 0 then  pos = pos+1  end

		while true do
			pos = pos + direction

			-- Check for end of string.
			local prevCp = codepoints[pos]
			local nextCp = codepoints[pos+direction]

			if not (prevCp and nextCp) then
				pos = pos + direction
				break
			end

			-- Check for word bound.
			local prevType = getCodepointCharType(prevCp)
			local nextType = getCodepointCharType(nextCp)

			if nextType ~= prevType and not (nextType ~= "whitespace" and prevType == "whitespace") then
				if direction < 0 then  pos = pos-1  end
				break
			end
		end

		return clamp(pos, 0, len)
	end
end



local function updateWrap(field)
	local text = field:getVisibleText()
	if field.lastWrappedText == text then  return  end

	field.lastWrappedText = text

	if field:isMultiline() then
		field.wrappedWidth = 0

		local wrapWidth = (field.type == "multiwrap") and field.width or 1/0
		local lineCount = 0
		local processed = 0

		for line, i in text:gmatch"([^\n]*)()" do
			if i > processed then
				processed = i

				if line == "" then
					lineCount                    = lineCount + 1
					field.wrappedText[lineCount] = ""
					field.softBreak[lineCount]   = false

				else
					local w, subLines  = field.font:getWrap(line, wrapWidth)
					local subLineCount = #subLines

					for subLineI, subLine in ipairs(subLines) do
						lineCount                    = lineCount + 1
						field.wrappedText[lineCount] = subLine
						field.softBreak[lineCount]   = subLineI < subLineCount
					end

					field.wrappedWidth = math.max(field.wrappedWidth, w)
				end
			end
		end

		for lineI = lineCount+1, #field.wrappedText do
			field.wrappedText[lineI] = nil
			field.softBreak[lineI]   = nil
		end

	else
		field.wrappedText[1] = text
		field.softBreak[1]   = false
		field.wrappedWidth   = field.font:getWidth(text)

		for lineI = 2, #field.wrappedText do
			field.wrappedText[lineI] = nil
			field.softBreak[lineI]   = nil
		end
	end

	--[[ DEBUG
	print("--------------------------------")
	for i = 1, #field.wrappedText do
		print(i, field.softBreak[i], field.wrappedText[i])
	end
	--]]
end



local function getCursorPositionAtX(font, line, x)
	if line == "" or x <= 0 then
		return 0
	elseif x <= font:getWidth(line:sub(1, utf8GetEndOffset(line, 1)))/2 then
		return 0
	end

	local lineW = font:getWidth(line)
	if x >= lineW then
		return utf8.len(line)
	end

	-- Binary search.
	local posL = 1
	local posR = utf8.len(line)

	local closestDist = math.abs(x - lineW)
	local closestPos  = posR

	while posL < posR do
		local pos      = math.floor((posL+posR)/2)
		local linePart = line:sub(1, utf8GetEndOffset(line, pos)) -- @Memory (We could maybe use font:getKerning() in LÖVE 11.4+ to traverse one character at a time. Might be slower though.)

		local dx = x - font:getWidth(linePart)
		if dx == 0 then  return pos  end

		local dist = math.abs(dx)

		if dist < closestDist then
			closestDist = dist
			closestPos  = pos
		end

		if dx < 0 then
			posR = pos
		else
			posL = pos
			if posL == posR-1 then  break  end -- Because pos is rounded down we'd get stuck without this (as pos would be posL again and again).
		end
	end

	return closestPos
end

local function getLineStartPosition(field, targetLineI)
	local linePos1 = 1

	for lineI = 1, targetLineI-1 do
		linePos1 = linePos1 + utf8.len(field.wrappedText[lineI])

		if not field.softBreak[lineI] then
			linePos1 = linePos1 + 1
		end
	end

	return linePos1
end

local function getCursorPositionAtCoordinates(field, x, y)
	updateWrap(field)

	if not field:isMultiline() then
		return getCursorPositionAtX(field.font, field.wrappedText[1], x)
	end

	local fontH     = field.font:getHeight()
	local lineDist  = math.ceil(fontH*field.font:getLineHeight())
	local lineSpace = lineDist - fontH
	local lineI     = clamp(math.floor(1 + (y+lineSpace/2) / lineDist), 1, #field.wrappedText)
	local line      = field.wrappedText[lineI]

	if not line then  return 0  end

	local linePos1  = getLineStartPosition(field, lineI)
	local posOnLine = getCursorPositionAtX(field.font, line, x)

	return linePos1 + posOnLine - 1
end

-- line, positionOnLine, lineIndex, linePosition1, linePosition2 = getLineInfoAtPosition( field, position )
local function getLineInfoAtPosition(field, pos)
	updateWrap(field)

	pos            = math.min(pos, utf8.len(field.text))
	local linePos1 = 1

	for lineI, line in ipairs(field.wrappedText) do
		local linePos2  = linePos1 + utf8.len(line) - 1
		local softBreak = field.softBreak[lineI]

		if pos <= (softBreak and linePos2-1 or linePos2) then -- Any trailing newline counts as being on the next line.
			return line, pos-linePos1+1, lineI, linePos1, linePos2
		end

		linePos1 = linePos2 + (softBreak and 1 or 2) -- Jump over any newline.
	end

	-- We should never get here!
	return getLineInfoAtPosition(field, 0)
end



local LCTRL = (LS.getOS() == "OS X") and "lgui" or "lctrl"
local RCTRL = (LS.getOS() == "OS X") and "rgui" or "rctrl"

-- modKeys = getModKeys( )
-- modKeys = "cas" | "ca" | "cs" | "c" | "a" | "s" | ""
local function getModKeys()
	local c = LK.isDown(LCTRL,    RCTRL   )
	local a = LK.isDown("lalt",   "ralt"  )
	local s = LK.isDown("lshift", "rshift")

	if     c and a and s then  return "cas"
	elseif c and a       then  return "ca"
	elseif c and s       then  return "cs"
	elseif c             then  return "c"
	elseif a             then  return "a"
	elseif s             then  return "s"
	else                       return ""  end
end



local function limitScroll(field)
	local limitX, limitY = field:getScrollLimits()
	field.scrollX        = clamp(field.scrollX, 0, limitX)
	field.scrollY        = clamp(field.scrollY, 0, limitY)
end

local function scrollToCursor(field)
	local line, posOnLine, lineI = getLineInfoAtPosition(field, field.cursorPosition)

	do
		local fontH    = field.font:getHeight()
		local lineDist = math.ceil(fontH*field.font:getLineHeight())
		local y        = (lineI - 1) * lineDist
		field.scrollY  = clamp(field.scrollY, y-field.height+fontH, y)
	end

	if not field:isMultiline() then
		local visibleText = field:getVisibleText()
		local preText     = visibleText:sub(1, utf8GetEndOffset(visibleText, field.cursorPosition))
		local x           = field.font:getWidth(preText)
		field.scrollX     = clamp(field.scrollX, x-field.width, x)

	elseif field.type == "multinowrap" then
		local preText = line:sub(1, utf8GetEndOffset(line, posOnLine))
		local x       = field.font:getWidth(preText)
		field.scrollX = clamp(field.scrollX, x-field.width, x)
	end

	limitScroll(field)
end



local function applyFilter(field, s)
	local filterFunc = field.filterFunction
	if not filterFunc then  return s  end

	s = s:gsub(utf8.charpattern, function(c)
		if filterFunc(c) then  return ""  end
	end)

	return s
end



-- pushHistory( field, group|nil )
local function pushHistory(field, group)
	local history = field.editHistory
	local i, state

	-- Never save history for password fields.
	if field.type == "password" then
		i     = 1
		state = history[1]

	-- Update last entry if group matches.
	elseif group and group == field.editHistoryGroup then
		i     = field.editHistoryIndex
		state = history[i]

	-- History limit reached.
	elseif field.editHistoryIndex >= field.editHistoryMax then
		i          = field.editHistoryIndex
		state      = table.remove(history, 1)
		history[i] = state

	-- Expand history.
	else
		i          = field.editHistoryIndex + 1
		state      = {}
		history[i] = state
	end

	for i = i+1, #history do
		history[i] = nil
	end

	state.text           = field.text
	state.cursorPosition = field.cursorPosition
	state.selectionStart = field.selectionStart
	state.selectionEnd   = field.selectionEnd

	field.editHistoryIndex = i
	field.editHistoryGroup = group
end



local function finilizeHistoryGroup(field)
	field.editHistoryGroup = nil
end



local function applyHistoryState(field, offset)
	field.editHistoryIndex = field.editHistoryIndex + offset

	local state = field.editHistory[field.editHistoryIndex] or assert(false)

	field.text           = state.text
	field.cursorPosition = state.cursorPosition
	field.selectionStart = state.selectionStart
	field.selectionEnd   = state.selectionEnd
end

-- @UX: Improve how the cursor and selection are restored on undo.
local function undoEdit(field)
	if field.editHistoryIndex == 1 then  return  end

	finilizeHistoryGroup(field)
	applyHistoryState(field, -1)

	field:resetBlinking()
	scrollToCursor(field)
end

local function redoEdit(field)
	if field.editHistoryIndex == #field.editHistory then  return  end

	finilizeHistoryGroup(field)
	applyHistoryState(field, 1)

	field:resetBlinking()
	scrollToCursor(field)
end



--==============================================================
--= Exported functions =========================================
--==============================================================



-- InputField( [ initialText="", type:InputFieldType="normal" ] )
local function newInputField(text, fieldType)
	fieldType = fieldType or "normal"

	if not (fieldType == "normal" or fieldType == "password" or fieldType == "multiwrap" or fieldType == "multinowrap") then
		error("[InputField] Invalid field type '"..tostring(fieldType).."'.", 2)
	end

	local field = setmetatable({
		type = fieldType,

		blinkTimer = LT.getTime(),

		cursorPosition = 0,
		selectionStart = 0,
		selectionEnd   = 0,

		doubleClickMaxDelay       = 0.40, -- Only used if the 'pressCount' argument isn't supplied to mousepressed().
		doubleClickExpirationTime = 0.00,
		doubleClickLastX          = 0.0,
		doubleClickLastY          = 0.0,

		editHistoryMax   = 100,
		editHistory      = {},
		editHistoryIndex = 1,
		editHistoryGroup = nil, -- nil | "insert" | "remove"

		font                  = require"love.graphics".getFont(),
		fontFilteringIsActive = false,

		filterFunction = nil,

		mouseScrollSpeedX = 6.0, -- Per pixel per second.
		mouseScrollSpeedY = 8.0,

		dragMode           = "", -- "" | "character" | "word"
		dragStartPosition1 = 0,
		dragStartPosition2 = 0,
		dragLastX          = 0,
		dragLastY          = 0,

		editingEnabled = true,

		scrollX = 0.0,
		scrollY = 0.0,

		text = "",

		width  = 1/0,
		height = 1/0,

		-- These are updated by updateWrap():
		lastWrappedText = "",
		wrappedText     = {""}, -- []line
		softBreak       = {false}, -- []bool
		wrappedWidth    = 0,
	}, InputField)

	text       = cleanString(field, tostring(text == nil and "" or text))
	field.text = text
	local len  = utf8.len(text)

	field.editHistory[1] = {
		text           = text,
		cursorPosition = len,
		selectionStart = 0,
		selectionEnd   = len,
	}

	return field
end



-- phase = field:getBlinkPhase( )
-- Get current phase for an animated cursor.
function InputField.getBlinkPhase(field)
	return LT.getTime() - field.blinkTimer
end

-- field:resetBlinking( )
function InputField.resetBlinking(field)
	field.blinkTimer = LT.getTime()
end



-- position = field:getCursor( )
-- Position 0 is before first character, position 1 is between first and second etc.
function InputField.getCursor(field)
	return field.cursorPosition
end

-- field:setCursor( position [, selectionSideToAnchor:SelectionSide=none ] )
function InputField.setCursor(field, pos, selSideAnchor)
	finilizeHistoryGroup(field)

	pos                  = clamp(pos, 0, field:getTextLength())
	field.cursorPosition = pos

	local selStart       = (selSideAnchor == "start" and field.selectionStart or pos)
	local selEnd         = (selSideAnchor == "end"   and field.selectionEnd   or pos)
	field.selectionStart = math.min(selStart, selEnd)
	field.selectionEnd   = math.max(selStart, selEnd)

	field:resetBlinking()
	scrollToCursor(field)
end

-- field:moveCursor( amount [, selectionSideToAnchor:SelectionSide=none ] )
function InputField.moveCursor(field, amount, selSideAnchor)
	field:setCursor(field.cursorPosition+amount, selSideAnchor)
end

-- side:SelectionSide = field:getCursorSelectionSide( )
function InputField.getCursorSelectionSide(field)
	return (field.cursorPosition < field.selectionEnd and "start" or "end")
end

-- side:SelectionSide = field:getAnchorSelectionSide( )
function InputField.getAnchorSelectionSide(field)
	return (field.cursorPosition < field.selectionEnd and "end" or "start")
end



-- font = field:getFont( )
function InputField.getFont(field)
	return field.font
end

-- field:setFont( font )
function InputField.setFont(field, font)
	if field.font == font then  return  end

	if not font then  error("Missing font argument.", 2)  end

	field.font            = font
	field.lastWrappedText = "\0" -- Make sure wrappedText updates.

	limitScroll(field)
end



-- scrollX, scrollY = field:getScroll( )
-- scrollX = field:getScrollX( )
-- scrollY = field:getScrollY( )
function InputField.getScroll(field)
	return field.scrollX, field.scrollY
end
function InputField.getScrollX(field)
	return field.scrollX
end
function InputField.getScrollY(field)
	return field.scrollY
end

-- field:setScroll( scrollX, scrollY )
-- field:setScrollX( scrollX )
-- field:setScrollY( scrollY )
function InputField.setScroll(field, scrollX, scrollY)
	field.scrollX = scrollX
	field.scrollY = scrollY
	limitScroll(field)
end
function InputField.setScrollX(field, scrollX)
	field.scrollX = scrollX
	limitScroll(field)
end
function InputField.setScrollY(field, scrollY)
	field.scrollY = scrollY
	limitScroll(field)
end

-- field:scroll( deltaX, deltaY )
function InputField.scroll(field, dx, dy)
	field.scrollX = field.scrollX + dx
	field.scrollY = field.scrollY + dy
	limitScroll(field)
end



-- limitX, limitY = field:getScrollLimits( )
function InputField.getScrollLimits(field)
	updateWrap(field)

	local fontH    = field.font:getHeight()
	local lineDist = math.ceil(fontH*field.font:getLineHeight())

	return (field.type == "multiwrap") and 0 or math.max((field.wrappedWidth                   ) - field.width,  0),
	       (not field:isMultiline()  ) and 0 or math.max(((#field.wrappedText-1)*lineDist+fontH) - field.height, 0)
end



-- speedX, speedY = field:getMouseScrollSpeed( )
-- speedX = field:getMouseScrollSpeedX( )
-- speedY = field:getMouseScrollSpeedY( )
function InputField.getMouseScrollSpeed(field)
	return field.mouseScrollSpeedX, field.mouseScrollSpeedY
end
function InputField.getMouseScrollSpeedX(field)
	return field.mouseScrollSpeedX
end
function InputField.getMouseScrollSpeedY(field)
	return field.mouseScrollSpeedY
end

-- field:setMouseScrollSpeed( speedX, speedY )
-- field:setMouseScrollSpeedX( speedX )
-- field:setMouseScrollSpeedY( speedY )
function InputField.setMouseScrollSpeed(field, speedX, speedY)
	field.mouseScrollSpeedX = math.max(speedX, 0)
	field.mouseScrollSpeedY = math.max(speedY, 0)
end
function InputField.setMouseScrollSpeedX(field, speedX)
	field.mouseScrollSpeedX = math.max(speedX, 0)
end
function InputField.setMouseScrollSpeedY(field, speedY)
	field.mouseScrollSpeedY = math.max(speedY, 0)
end



-- delay = field:getDoubleClickMaxDelay( )
function InputField.getDoubleClickMaxDelay(field)
	return field.doubleClickMaxDelay
end

-- field:setDoubleClickMaxDelay( delay )
-- This value is only used if the 'pressCount' argument isn't supplied to mousepressed().
function InputField.setDoubleClickMaxDelay(field, delay)
	field.doubleClickMaxDelay = math.max(delay, 0)
end



-- fromPosition, toPosition = field:getSelection( )
-- Position 0 is before first character, position 1 is between first and second etc.
function InputField.getSelection(field)
	return field.selectionStart, field.selectionEnd
end

-- field:setSelection( fromPosition, toPosition [, cursorAlign:TextCursorAlignment="right" ] )
function InputField.setSelection(field, from, to, cursorAlign)
	finilizeHistoryGroup(field)

	local len = field:getTextLength()
	from = clamp(from, 0, len)
	to   = clamp(to,   0, len)

	from, to = math.min(from, to), math.max(from, to)

	field.selectionStart = from
	field.selectionEnd   = to
	field.cursorPosition = (cursorAlign == "left") and from or to

	field:resetBlinking()
	scrollToCursor(field)
end

-- field:selectAll( )
function InputField.selectAll(field)
	field:setSelection(0, field:getTextLength())
end

-- text = field:getSelectedText( )
function InputField.getSelectedText(field)
	local text = field.text
	return text:sub(
		utf8.offset(text, field.selectionStart+1),
		utf8GetEndOffset(text, field.selectionEnd)
	)
end

-- text = field:getSelectedVisibleText( )
function InputField.getSelectedVisibleText(field)
	return (field.type == "password") and ("*"):rep(field.selectionEnd-field.selectionStart) or field:getSelectedText()
end



-- text = field:getText( )
function InputField.getText(field)
	return field.text
end

-- field:setText( text )
function InputField.setText(field, text)
	text = cleanString(field, tostring(text))
	if field.text == text then  return  end

	local len = utf8.len(text)

	field.text           = text
	field.cursorPosition = math.min(len, field.cursorPosition)
	field.selectionStart = math.min(len, field.selectionStart)
	field.selectionEnd   = math.min(len, field.selectionEnd)

	pushHistory(field, nil)
end

-- text = field:getVisibleText( )
function InputField.getVisibleText(field)
	return (field.type == "password") and ("*"):rep(field:getTextLength()) or field.text -- @Speed: Maybe cache the repeated text.
end



-- length = field:getTextLength( )
-- Returns the number of characters in the UTF-8 text string.
function InputField.getTextLength(field)
	return utf8.len(field.text)
end



-- offsetX, offsetY = field:getTextOffset( )
-- Note: The coordinates are relative to the field's position.
function InputField.getTextOffset(field)
	return -math.floor(field.scrollX),
	       -math.floor(field.scrollY)
end



-- x, y, height = field:getCursorLayout( )
-- Note: The coordinates are relative to the field's position.
function InputField.getCursorLayout(field)
	local line, posOnLine, lineI = getLineInfoAtPosition(field, field.cursorPosition)

	local preText  = line:sub(1, utf8GetEndOffset(line, posOnLine))
	local fontH    = field.font:getHeight()
	local lineDist = math.ceil(fontH*field.font:getLineHeight())

	return field.font:getWidth(preText) - math.floor(field.scrollX),
	       (lineI-1)*lineDist           - math.floor(field.scrollY),
	       fontH
end



-- width, height = field:getDimensions( )
-- width  = field:getWidth( )
-- height = field:getHeight( )
function InputField.getDimensions(field)
	return field.width, field.height
end
function InputField.getWidth(field)
	return field.width
end
function InputField.getHeight(field)
	return field.height
end

-- field:setDimensions( width, height )
-- field:setDimensions( math.huge, math.huge ) -- Disable scrolling on both axes.
function InputField.setDimensions(field, w, h)
	w = math.max(w, 0)
	h = math.max(h, 0)
	if field.width == w and field.height == h then  return  end

	field.width           = w
	field.height          = h
	field.lastWrappedText = "\0" -- Make sure wrappedText updates.

	limitScroll(field)
end

-- field:setWidth( width )
-- field:setWidth( math.huge ) -- Disable scrolling on the x axis.
function InputField.setWidth(field, w)
	w = math.max(w, 0)
	if field.width == w then  return  end

	field.width           = w
	field.lastWrappedText = "\0" -- Make sure wrappedText updates.

	limitScroll(field)
end

-- field:setHeight( height )
-- field:setHeight( math.huge ) -- Disable scrolling on the y axis.
function InputField.setHeight(field, h)
	h = math.max(h, 0)
	if field.height == h then  return  end

	field.height = h -- Note: wrappedText does not need to update because of this change.

	limitScroll(field)
end




-- width, height = field:getTextDimensions( )
function InputField.getTextDimensions(field)
	updateWrap(field)

	local fontH    = field.font:getHeight()
	local lineDist = math.ceil(fontH*field.font:getLineHeight())

	return field.wrappedWidth, (#field.wrappedText-1)*lineDist+fontH
end

-- width = field:getTextWidth( )
function InputField.getTextWidth(field)
	updateWrap(field)
	return field.wrappedWidth
end

-- height = field:getTextHeight( )
function InputField.getTextHeight(field)
	updateWrap(field)

	local fontH    = field.font:getHeight()
	local lineDist = math.ceil(fontH*field.font:getLineHeight())

	return (#field.wrappedText - 1) * lineDist + fontH
end



-- field:insert( text )
-- Insert text at cursor, or replace selected text.
function InputField.insert(field, newText)
	newText = cleanString(field, tostring(newText))

	local text     = field.text
	local selStart = field.selectionStart
	local iLeft    = utf8GetEndOffset(text, selStart)
	local iRight   = utf8.offset(text, field.selectionEnd+1)

	if newText == "" then
		field.text           = text:sub(1, iLeft) .. text:sub(iRight)
		field.cursorPosition = selStart
		field.selectionEnd   = selStart

		pushHistory(field, "remove")

	else
		field.text           = text:sub(1, iLeft) .. newText .. text:sub(iRight)
		field.cursorPosition = selStart + utf8.len(newText)
		field.selectionStart = field.cursorPosition
		field.selectionEnd   = field.cursorPosition

		pushHistory(field, "insert")
	end

	field:resetBlinking()
	scrollToCursor(field)
end



-- field:reset( [ initialText="" ] )
function InputField.reset(field, text)
	field:releaseMouse()

	field.cursorPosition = 0
	field.selectionStart = 0
	field.selectionEnd   = 0

	field:setText(text == nil and "" or text)
	field:clearHistory()
end



--
-- bool = field:isFontFilteringActive( )
-- field:setFontFilteringActive( bool )
--
-- Filter out characters that the font doesn't have glyphs for.
--
function InputField.isFontFilteringActive(field)          return field.fontFilteringIsActive   end
function InputField.setFontFilteringActive(field, state)  field.fontFilteringIsActive = state  end

-- bool = field:isEditable( )
-- field:setEditable( bool )
function InputField.isEditable(field)          return field.editingEnabled   end
function InputField.setEditable(field, state)  field.editingEnabled = state  end



-- type:InputFieldType = field:getType( )
-- bool = field:isPassword( )
-- bool = field:isMultiline( )
function InputField.getType(field)      return field.type  end
function InputField.isPassword(field)   return field.type == "password"  end
function InputField.isMultiline(field)  return field.type == "multiwrap" or field.type == "multinowrap"  end



-- filterFunction = field:getFilter( )
function InputField.getFilter(field)
	return field.filterFunction
end

--
-- setFilter( filterFunction )
-- setFilter( nil ) -- Remove filter.
-- removeCharacter = filterFunction( character )
--
-- Filter out entered characters.
--
-- Note: The filter is only applied in text input events, like textinput().
-- Functions like setText() are unaffected (unlike with font filtering).
--
function InputField.setFilter(field, filterFunc)
	field.filterFunction = filterFunc
end



-- field:clearHistory( )
function InputField.clearHistory(field)
	local history = field.editHistory

	history[1] = history[#history]
	for i = 2, #history do  history[i] = nil  end

	field.editHistoryGroup = nil
	field.editHistoryIndex = 1
end



-- maxHistory = field:getMaxHistory( )
function InputField.getMaxHistory(field)
	return field.editHistoryMax
end

-- field:setMaxHistory( maxHistory )
-- Limit entry count for the undo/redo history.
function InputField.setMaxHistory(field, maxHistory)
	maxHistory = math.max(maxHistory, 1)
	if maxHistory == field.editHistoryMax then  return  end

	field:clearHistory()
	field.editHistoryMax = maxHistory
end



----------------------------------------------------------------



-- field:update( deltaTime )
function InputField.update(field, dt)
	if field.dragMode ~= "" then
		local mx         = field.dragLastX
		local my         = field.dragLastY
		local oldScrollX = field.scrollX
		local oldScrollY = field.scrollY
		local scrollX    = oldScrollX
		local scrollY    = oldScrollY
		local w          = field.width
		local h          = field.height

		field.scrollX = (mx < 0 and scrollX+field.mouseScrollSpeedX*mx*dt) or (mx > w and scrollX+field.mouseScrollSpeedX*(mx-w)*dt) or (scrollX)
		field.scrollY = (my < 0 and scrollY+field.mouseScrollSpeedY*my*dt) or (my > h and scrollY+field.mouseScrollSpeedY*(my-h)*dt) or (scrollY)
		limitScroll(field)

		if not (field.scrollX == oldScrollX and field.scrollY == oldScrollY) then
			field:mousemoved(mx, my) -- This should only update selection stuff.
		end
	end
end



-- eventWasHandled = field:mousepressed( mouseX, mouseY, mouseButton [, pressCount=auto ] )
-- Note: The coordinates must be relative to the field's position on the screen.
function InputField.mousepressed(field, mx, my, mbutton, pressCount)
	if mbutton ~= 1 then  return false  end

	-- Check if double click.
	local isDoubleClick = false

	if mbutton == 1 then
		local time = LT.getTime()

		if pressCount then
			isDoubleClick = pressCount%2 == 0
		else
			isDoubleClick = (
				time < field.doubleClickExpirationTime
				and math.abs(field.doubleClickLastX-mx) <= 1 -- @Incomplete: Make max distance into a setting?
				and math.abs(field.doubleClickLastY-my) <= 1
			)
		end

		field.doubleClickExpirationTime = isDoubleClick and 0 or time+field.doubleClickMaxDelay
		field.doubleClickLastX          = mx
		field.doubleClickLastY          = my

	else
		field.doubleClickExpirationTime = 0
	end

	-- Handle mouse press.
	local pos = getCursorPositionAtCoordinates(field, mx+field.scrollX, my+field.scrollY)

	if isDoubleClick then
		local visibleText = field:getVisibleText()
		local pos1        = getNextWordBound(visibleText, pos+1, -1)
		local pos2        = getNextWordBound(visibleText, pos1,   1)

		field:setSelection(pos1, pos2)

		field.dragMode           = "word"
		field.dragStartPosition1 = pos1
		field.dragStartPosition2 = pos2
		field.dragLastX          = mx
		field.dragLastY          = my

	elseif getModKeys() == "s" then
		local anchorPos = (field:getAnchorSelectionSide() == "start" and field.selectionStart or field.selectionEnd)

		field:setSelection(pos, anchorPos, (pos < anchorPos and "left" or "right"))

		field.dragMode           = "character"
		field.dragStartPosition1 = anchorPos
		field.dragLastX          = mx
		field.dragLastY          = my

	else
		field:setCursor(pos)

		field.dragMode           = "character"
		field.dragStartPosition1 = pos
		field.dragLastX          = mx
		field.dragLastY          = my
	end

	return true
end

-- eventWasHandled = field:mousemoved( mouseX, mouseY )
-- Note: The coordinates must be relative to the field's position on the screen.
function InputField.mousemoved(field, mx, my)
	if field.dragMode == "" then  return false  end

	local scrollX = field.scrollX
	local scrollY = field.scrollY
	local pos     = getCursorPositionAtCoordinates(field, mx+field.scrollX, my+field.scrollY)

	if field.dragMode == "word" then
		local visibleText = field:getVisibleText()
		local pos1        = getNextWordBound(visibleText, pos+1, -1)
		local pos2        = getNextWordBound(visibleText, pos1,   1)

		if pos1 < field.dragStartPosition1 then
			field:setSelection(pos1, field.dragStartPosition2, "left")
		else
			field:setSelection(field.dragStartPosition1, pos2, "right")
		end

	else
		field:setSelection(field.dragStartPosition1, pos, (pos < field.dragStartPosition1 and "left" or "right"))
	end

	field.scrollX = scrollX -- Prevent scrolling to cursor while dragging.
	field.scrollY = scrollY

	field.dragLastX = mx
	field.dragLastY = my
	return true
end

-- eventWasHandled = field:mousereleased( mouseX, mouseY, mouseButton )
-- Note: The coordinates must be relative to the field's position on the screen.
function InputField.mousereleased(field, mx, my, mbutton)
	if mbutton ~= 1         then  return false  end
	if field.dragMode == "" then  return false  end

	field.dragMode = ""

	scrollToCursor(field)
	return true
end



-- field:releaseMouse( )
-- Release mouse buttons that are held down (i.e. stop drag-selecting).
function InputField.releaseMouse(field)
	field.dragMode = ""
end



-- bool = field:isBusy( )
-- Returns true if the user is currently drag-selecting.
function InputField.isBusy(field)
	return field.dragMode ~= ""
end



local KEY_HANDLERS = { ["cas"]={}, ["ca"]={}, ["cs"]={}, ["c"]={}, ["a"]={}, ["s"]={}, [""]={} }

--            Left: Move cursor to the left.
--      Shift+Left: Move cursor to the left and preserve selection.
--       Ctrl+Left: Move cursor to the previous word.
-- Ctrl+Shift+Left: Move cursor to the previous word and preserve selection.
KEY_HANDLERS[""]["left"] = function(field, isRepeat)
	if field.selectionStart ~= field.selectionEnd then
		field:setCursor(field.selectionStart)
	else
		field:moveCursor(-1)
	end
	return true, false
end
KEY_HANDLERS["s"]["left"] = function(field, isRepeat)
	field:moveCursor(-1, field:getAnchorSelectionSide())
	return true, false
end
KEY_HANDLERS["c"]["left"] = function(field, isRepeat)
	field:setCursor(getNextWordBound(field:getVisibleText(), field.cursorPosition, -1))
	return true, false
end
KEY_HANDLERS["cs"]["left"] = function(field, isRepeat)
	field:setCursor(getNextWordBound(field:getVisibleText(), field.cursorPosition, -1), field:getAnchorSelectionSide())
	return true, false
end

--            Right: Move cursor to the right.
--      Shift+Right: Move cursor to the right and preserve selection.
--       Ctrl+Right: Move cursor to the next word.
-- Ctrl+Shift+Right: Move cursor to the next word and preserve selection.
KEY_HANDLERS[""]["right"] = function(field, isRepeat)
	if field.selectionStart ~= field.selectionEnd then
		field:setCursor(field.selectionEnd)
	else
		field:moveCursor(1)
	end
	return true, false
end
KEY_HANDLERS["s"]["right"] = function(field, isRepeat)
	field:moveCursor(1, field:getAnchorSelectionSide())
	return true, false
end
KEY_HANDLERS["c"]["right"] = function(field, isRepeat)
	field:setCursor(getNextWordBound(field:getVisibleText(), field.cursorPosition, 1))
	return true, false
end
KEY_HANDLERS["cs"]["right"] = function(field, isRepeat)
	field:setCursor(getNextWordBound(field:getVisibleText(), field.cursorPosition, 1), field:getAnchorSelectionSide())
	return true, false
end

--            Home: Move cursor to line start.
--      Shift+Home: Move cursor to line start and preserve selection.
--       Ctrl+Home: Move cursor to absolute start.
-- Ctrl+Shift+Home: Move cursor to absolute start and preserve selection.
KEY_HANDLERS[""]["home"] = function(field, isRepeat)
	local line, posOnLine, lineI, linePos1, linePos2 = getLineInfoAtPosition(field, field.cursorPosition)
	field:setCursor(linePos1-1)
	return true, false
end
KEY_HANDLERS["s"]["home"] = function(field, isRepeat)
	local line, posOnLine, lineI, linePos1, linePos2 = getLineInfoAtPosition(field, field.cursorPosition)
	field:setCursor(linePos1-1, field:getAnchorSelectionSide())
	return true, false
end
KEY_HANDLERS["c"]["home"] = function(field, isRepeat)
	field:setCursor(0)
	return true, false
end
KEY_HANDLERS["cs"]["home"] = function(field, isRepeat)
	field:setCursor(0, field:getAnchorSelectionSide())
	return true, false
end

--            End: Move cursor to line end.
--      Shift+End: Move cursor to line end and preserve selection.
--       Ctrl+End: Move cursor to absolute end.
-- Ctrl+Shift+End: Move cursor to absolute end and preserve selection.
KEY_HANDLERS[""]["end"] = function(field, isRepeat)
	local line, posOnLine, lineI, linePos1, linePos2 = getLineInfoAtPosition(field, field.cursorPosition)
	field:setCursor(linePos2)
	return true, false
end
KEY_HANDLERS["s"]["end"] = function(field, isRepeat)
	local line, posOnLine, lineI, linePos1, linePos2 = getLineInfoAtPosition(field, field.cursorPosition)
	field:setCursor(linePos2, field:getAnchorSelectionSide())
	return true, false
end
KEY_HANDLERS["c"]["end"] = function(field, isRepeat)
	field:setCursor(field:getTextLength())
	return true, false
end
KEY_HANDLERS["cs"]["end"] = function(field, isRepeat)
	field:setCursor(field:getTextLength(), field:getAnchorSelectionSide())
	return true, false
end

local function navigateVertically(field, dirY, anchor)
	if not field:isMultiline() then  return false, false  end

	local anchorSide = (anchor and field:getAnchorSelectionSide() or nil)

	-- Get info about the current line.
	local oldLine, oldPosOnLine, oldLineI, oldLinePos1, oldLinePos2 = getLineInfoAtPosition(field, field.cursorPosition)

	if dirY < 0 and oldLineI == 1 then
		field:setCursor(0, anchorSide)
		return true, false
	elseif dirY > 0 and oldLineI >= #field.wrappedText then
		field:setCursor(utf8.len(field.text), anchorSide)
		return true, false
	end

	-- Get info about the target line.
	local newLine, newPosOnLine, newLineI, newLinePos1, newLinePos2
	if dirY < 0 then
		newLine, newPosOnLine, newLineI, newLinePos1, newLinePos2 = getLineInfoAtPosition(field, oldLinePos1-2)
	else
		newLine, newPosOnLine, newLineI, newLinePos1, newLinePos2 = getLineInfoAtPosition(field, oldLinePos2+1)
	end

	-- Avoid some work if we're at the start of a line.
	if oldPosOnLine == 0 or newLine == "" then
		field:setCursor(newLinePos1-1, anchorSide)
		return true, false
	end

	local linePart  = oldLine:sub(1, utf8GetEndOffset(oldLine, oldPosOnLine))
	local targetX   = field.font:getWidth(linePart)
	local posOnLine = getCursorPositionAtX(field.font, newLine, targetX)

	-- Going from the end of a long line to the end of a short soft-wrapped line would put
	-- the cursor at the start of the previous long line or two lines down. No good!
	if posOnLine == utf8.len(newLine) and field.softBreak[newLineI] then
		posOnLine = posOnLine - 1
	end

	field:setCursor(newLinePos1+posOnLine-1, anchorSide)
	return true, false
end

--         Up: Move cursor to the previous line.
--       Down: Move cursor to the next line.
--   Shift+Up: Move cursor to the previous line and preserve selection.
-- Shift+Down: Move cursor to the next line and preserve selection.
KEY_HANDLERS[""]["up"] = function(field, isRepeat)
	return navigateVertically(field, -1, false)
end
KEY_HANDLERS[""]["down"] = function(field, isRepeat)
	return navigateVertically(field, 1, false)
end
KEY_HANDLERS["s"]["up"] = function(field, isRepeat)
	return navigateVertically(field, -1, true)
end
KEY_HANDLERS["s"]["down"] = function(field, isRepeat)
	return navigateVertically(field, 1, true)
end

-- Return: Insert newline (if multiline).
KEY_HANDLERS[""]["return"] = function(field, isRepeat)
	if not field.editingEnabled then  return false, false  end
	if not field:isMultiline()  then  return false, false  end

	field:insert("\n")
	return true, true
end
KEY_HANDLERS[""]["kpenter"] = KEY_HANDLERS[""]["return"]

--      Backspace: Remove selection or previous character.
-- Ctrl+Backspace: Remove selection or previous word.
KEY_HANDLERS[""]["backspace"] = function(field, isRepeat)
	if not field.editingEnabled then
		return false, false

	elseif field.selectionStart ~= field.selectionEnd then
		-- void

	elseif field.cursorPosition == 0 then
		field:resetBlinking()
		scrollToCursor(field)
		return true, false

	else
		field.selectionStart = field.cursorPosition - 1
		field.selectionEnd   = field.cursorPosition
	end

	field:insert("")
	return true, true
end
KEY_HANDLERS["c"]["backspace"] = function(field, isRepeat)
	if not field.editingEnabled then
		return false, false
	elseif field.selectionStart ~= field.selectionEnd then
		-- void
	else
		field.cursorPosition = getNextWordBound(field:getVisibleText(), field.cursorPosition, -1)
		field.selectionStart = field.cursorPosition
	end
	field:insert("")
	return true, true
end

--      Delete: Remove selection or next character.
-- Ctrl+Delete: Remove selection or next word.
KEY_HANDLERS[""]["delete"] = function(field, isRepeat)
	if not field.editingEnabled then
		return false, false

	elseif field.selectionStart ~= field.selectionEnd then
		-- void

	elseif field.cursorPosition == field:getTextLength() then
		field:resetBlinking()
		scrollToCursor(field)
		return true, false

	else
		field.selectionStart = field.cursorPosition
		field.selectionEnd   = field.cursorPosition + 1
	end

	field:insert("")
	return true, true
end
KEY_HANDLERS["c"]["delete"] = function(field, isRepeat)
	if not field.editingEnabled then
		return false, false
	elseif field.selectionStart ~= field.selectionEnd then
		-- void
	else
		field.cursorPosition = getNextWordBound(field:getVisibleText(), field.cursorPosition, 1)
		field.selectionEnd   = field.cursorPosition
	end
	field:insert("")
	return true, true
end

-- Ctrl+A: Select all text.
KEY_HANDLERS["c"]["a"] = function(field, isRepeat)
	field:selectAll()
	return true, false
end

-- Ctrl+C, Ctrl+Insert: Copy selected text.
KEY_HANDLERS["c"]["c"] = function(field, isRepeat)
	local text = field:getSelectedVisibleText()

	if text ~= "" then
		LS.setClipboardText(text)
		field:resetBlinking()
	end

	return true, false
end
KEY_HANDLERS["c"]["insert"] = KEY_HANDLERS["c"]["c"]

-- Ctrl+X, Shift+Delete: Cut selected text (or copy if not editable).
KEY_HANDLERS["c"]["x"] = function(field, isRepeat)
	local text = field:getSelectedVisibleText()
	if text == "" then  return true, false  end

	LS.setClipboardText(text)

	if field.editingEnabled then
		field:insert("")
		return true, true
	else
		field:resetBlinking()
		return true, false
	end
end
KEY_HANDLERS["s"]["delete"] = KEY_HANDLERS["c"]["x"]

-- Ctrl+V, Shift+Insert: Paste copied text.
KEY_HANDLERS["c"]["v"] = function(field, isRepeat)
	if not field.editingEnabled then  return false, false  end

	local text = cleanString(field, LS.getClipboardText())
	if text ~= "" then
		field:insert(applyFilter(field, text))
	end

	field:resetBlinking()
	return true, true
end
KEY_HANDLERS["s"]["insert"] = KEY_HANDLERS["c"]["v"]

-- Ctrl+Z: Undo text edit.
-- Ctrl+Shift+Z, Ctrl+Y: Redo text edit.
KEY_HANDLERS["c"]["z"] = function(field, isRepeat)
	if not field.editingEnabled then  return false, false  end

	-- @Robustness: Filter and/or font filter could have changed after the last edit.
	if field.type ~= "password" then  undoEdit(field)  end

	return true, true
end
KEY_HANDLERS["cs"]["z"] = function(field, isRepeat)
	if not field.editingEnabled then  return false, false  end

	-- @Robustness: Filter and/or font filter could have changed after the last edit.
	if field.type ~= "password" then  redoEdit(field)  end

	return true, true
end
KEY_HANDLERS["c"]["y"] = KEY_HANDLERS["cs"]["z"]

-- Escape while dragging: Stop dragging.
KEY_HANDLERS[""]["escape"] = function(field, isRepeat)
	if field.dragMode == "" then  return false, false  end
	field:releaseMouse()
	return true, false
end



-- eventWasHandled, textWasEdited = field:keypressed( key, isRepeat )
function InputField.keypressed(field, key, isRepeat)
	local keyHandler = KEY_HANDLERS[getModKeys()][key]

	if keyHandler then
		return keyHandler(field, isRepeat)
	else
		return false, false
	end
end

-- eventWasHandled, textWasEdited = field:textinput( text )
function InputField.textinput(field, text)
	if not field.editingEnabled then  return true, false  end
	field:insert(applyFilter(field, text))
	return true, true
end



local function nextLine(field, lineI)
	lineI      = lineI + 1
	local line = field.wrappedText[lineI]

	if not line then  return nil  end

	local fontH    = field.font:getHeight()
	local lineDist = math.ceil(fontH*field.font:getLineHeight())

	return lineI,
		line,
		-math.floor(field.scrollX),
		(lineI - 1) * lineDist - math.floor(field.scrollY),
		field.font:getWidth(line),
		fontH
end

-- for index, line, lineX, lineY, lineWidth, lineHeight in field:eachVisibleLine( )
-- Note: The coordinates are relative to the field's position.
function InputField.eachVisibleLine(field)
	updateWrap(field)
	return nextLine, field, 0
end



local versionMajor, versionMinor = love.getVersion()
local hasGetKerningMethod        = false--(versionMajor > 11) or (versionMajor == 11 and versionMinor >= 4)
local cache                      = {}

local getSelectionLayoutOnLine = (
	hasGetKerningMethod and function(font, line, posOnLine1, posOnLine2) -- Currently worse than the fallback!
		local pos    = 0
		local x      = 0
		local x1     = 0
		local lastCp = 0

		for _, cp in utf8Codes(line) do
			pos = pos + 1

			if lastCp > 0 then
				x = x + font:getKerning(lastCp, cp)
			end
			cache[cp] = cache[cp] or utf8.char(cp) ; x = x + font:getWidth(cache[cp]) -- Not sure if the cache is doing anything...
			-- x = x + font:getWidth(utf8.char(cp))

			if pos == posOnLine1-1 then
				x1 = x
			end
			if pos == posOnLine2 then
				return x1, x -- @Polish: Handle kerning on the right end of the selection.
			end

			lastCp = cp
		end

		return x, x
	end

	or function(font, line, posOnLine1, posOnLine2)
		local preText       = line:sub(1, utf8.offset     (line, posOnLine1)-1) -- @Speed @Memory
		local preAndMidText = line:sub(1, utf8GetEndOffset(line, posOnLine2)  ) -- @Speed @Memory
		local x1            = font:getWidth(preText)
		local x2            = font:getWidth(preAndMidText) -- @Polish: Handle kerning on the right end of the selection.
		return x1, x2
	end
)

local function nextSelection(selections, i)
	i          = i + 1
	local line = selections[3*i-2]

	if not line then  return nil  end

	local field = selections.field
	local font  = field.font

	local posOnLine1 = selections[3*i-1]
	local posOnLine2 = selections[3*i  ]
	local x1, x2     = getSelectionLayoutOnLine(font, line, posOnLine1, posOnLine2)

	local fontH    = font:getHeight()
	local lineDist = math.ceil(fontH*font:getLineHeight())

	if selections[3*(i+1)] then
		x2 = x2 + font:getWidth(" ")
		-- x2 = math.min(x2, field.width) -- Eh, this is a bad idea. Any scissoring should be done by the user.
	end

	return i,
		x1 - math.floor(field.scrollX),
		(selections.lineOffset + i) * lineDist - math.floor(field.scrollY),
		x2 - x1,
		fontH
end

local selectionsReused = {field=nil, lineOffset=0, --[[ line1, startPositionOnLine1, endPositionOnLine1, ... ]]}

local function _eachSelection(field, selections)
	-- updateWrap(field) -- getLineInfoAtPosition() calls this.

	local startLine, startPosOnLine, startLineI, startLinePos1, startLinePos2 = getLineInfoAtPosition(field, field.selectionStart)
	local   endLine,   endPosOnLine,   endLineI,   endLinePos1,   endLinePos2 = getLineInfoAtPosition(field, field.selectionEnd)

	-- Note: We include selections that are empty.
	selections.field      = field
	selections.lineOffset = startLineI - 2

	if startLineI == endLineI then
		selections[1] = startLine
		selections[2] = startPosOnLine + 1
		selections[3] = endPosOnLine

	else
		selections[1] = startLine
		selections[2] = startPosOnLine + 1
		selections[3] = startLinePos2 - startLinePos1 + 1

		for lineI = startLineI+1, endLineI-1 do
			local line = field.wrappedText[lineI]
			table.insert(selections, line)
			table.insert(selections, 1)
			table.insert(selections, utf8.len(line))
		end

		table.insert(selections, endLine)
		table.insert(selections, 1)
		table.insert(selections, endPosOnLine)
	end

	return nextSelection, selections, 0
end



-- for index, selectionX, selectionY, selectionWidth, selectionHeight in field:eachSelection( )
-- Note: The coordinates are relative to the field's position.
-- Warning: This function may chew through lots of memory if many lines are selected! Consider using field:eachSelectionOptimized() instead.
function InputField.eachSelection(field)
	if field.selectionStart == field.selectionEnd then  return noop  end

	return _eachSelection(field, {}) -- @Speed @Memory: Don't create a new table every call!
end

-- for index, selectionX, selectionY, selectionWidth, selectionHeight in field:eachSelectionOptimized( )
-- Same as field:eachSelection() but more optimized. However, this function must not be called recursively!
-- Note: The coordinates are relative to the field's position.
function InputField.eachSelectionOptimized(field)
	if field.selectionStart == field.selectionEnd then  return noop  end

	for i = 4, #selectionsReused do
		selectionsReused[i] = nil
	end

	return _eachSelection(field, selectionsReused)
end



--==============================================================
--==============================================================
--==============================================================

return setmetatable(InputField, {

	-- InputField( [ initialText="", type:InputFieldType="normal" ] )
	__call = function(InputField, text, fieldType)
		return newInputField(text, fieldType)
	end,

})

--==============================================================
--=
--=  MIT License
--=
--=  Copyright © 2017-2022 Marcus 'ReFreezed' Thunström
--=
--=  Permission is hereby granted, free of charge, to any person obtaining a copy
--=  of this software and associated documentation files (the "Software"), to deal
--=  in the Software without restriction, including without limitation the rights
--=  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
--=  copies of the Software, and to permit persons to whom the Software is
--=  furnished to do so, subject to the following conditions:
--=
--=  The above copyright notice and this permission notice shall be included in all
--=  copies or substantial portions of the Software.
--=
--=  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
--=  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
--=  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
--=  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
--=  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
--=  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
--=  SOFTWARE.
--=
--==============================================================

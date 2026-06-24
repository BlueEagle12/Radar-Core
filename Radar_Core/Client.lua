

local DEFAULT_CONFIG_RESOURCE = "Radar_Files";   -- resource that owns Settings.lua + images
local CIRCLE_MASK_SHADER = "CircleMask.fx";
local DEFAULT_CIRCLE_MASK_ENABLED = true;
local DEFAULT_CIRCLE_MASK_FEATHER = 2;
local DEFAULT_MINIMAP_BORDER_WIDTH = 6;
local MINIMAP_BORDER_SEGMENTS = 96;
local MIN_MINIMAP_SIZE = 90;
local DEFAULT_MINIMAP_REFERENCE_WIDTH = 1280;
local DEFAULT_MINIMAP_REFERENCE_HEIGHT = 960;
local DEFAULT_MAX_MINIMAP_SCALE = 2.0;
local MAX_MINIMAP_SHORT_EDGE_SHARE = 0.30;
local MAP_DOUBLE_CLICK_MS = 350;
local MAP_DOUBLE_CLICK_DISTANCE = 12;

local cfg;                 -- config table (populated on start)
local activeConfigResource = DEFAULT_CONFIG_RESOURCE;
local WORLD_HALF;          -- cfg.worldSize / 2
local widthA, heightA;     -- screen scale factors vs the 1024x768 design
local initialized = false;
local retryTimer;

local playerX, playerY, playerZ = 0, 0, 0;
local mapOffsetX, mapOffsetY, mapIsMoving = 0, 0, false;
local targetBlip;
local activeBlipInfoBlip;
local selectedBlipInfoBlip;
local blipInfoPanelBounds;
local blipInfoWaypointButton;
local blipInfoWaypointBlip;
local blipInfoActionButton;
local blipInfoActionBlip;
local setWaypointToBlip;
local lastMapClickTick, lastMapClickX, lastMapClickY = 0, 0, 0;
local teleportConfirmWindow, teleportConfirmLabel, teleportConfirmYes, teleportConfirmNo;
local pendingTeleportX, pendingTeleportY, pendingTeleportZ;
local closeTeleportConfirm;

-- Returns true if `key` is in the given key list (used for multi-key binds).
local function keyInList(list, key)
	for _, k in ipairs(list) do
		if (k == key) then return true; end
	end
	return false;
end

local function getMinimapResponsiveScale()
	local referenceWidth = cfg.minimap.referenceWidth or DEFAULT_MINIMAP_REFERENCE_WIDTH;
	local referenceHeight = cfg.minimap.referenceHeight or DEFAULT_MINIMAP_REFERENCE_HEIGHT;
	local maxScale = cfg.minimap.maxScale or DEFAULT_MAX_MINIMAP_SCALE;
	local designScale = math.min(Display.Width / referenceWidth, Display.Height / referenceHeight, maxScale);
	local maxFootprint = math.min(Display.Width, Display.Height) * MAX_MINIMAP_SHORT_EDGE_SHARE;
	local baseFootprint = math.max(cfg.minimap.baseWidth, cfg.minimap.baseHeight);
	local footprintScale = maxFootprint / baseFootprint;

	return math.min(designScale, footprintScale);
end

local function scaleMinimapValue(value, minimum)
	return math.max(minimum or 1, math.floor(value * Minimap.Scale + 0.5));
end

local function destroyRadarState()
	if (Minimap) then
		local elements = {
			Minimap.MapTarget,
			Minimap.RenderTarget,
			Minimap.MaskTarget,
			Minimap.MaskShader,
			Minimap.MapTexture,
		};

		for _, element in ipairs(elements) do
			if (element and isElement(element)) then
				destroyElement(element);
			end
		end
	end

	Minimap = nil;
	Bigmap = nil;
	Stats = nil;
	cfg = nil;
	activeBlipInfoBlip = nil;
	selectedBlipInfoBlip = nil;
	blipInfoPanelBounds = nil;
	blipInfoWaypointButton = nil;
	blipInfoWaypointBlip = nil;
	blipInfoActionButton = nil;
	blipInfoActionBlip = nil;
	initialized = false;
end

-- Build all runtime state from the fetched config. Runs once, after cfg is set.
local function buildState()
	Display = {};
	Display.Width, Display.Height = guiGetScreenSize();

	widthA  = Display.Width  / 1024;   -- horizontal scale vs 1024px design
	heightA = Display.Height / 768;    -- vertical   scale vs 768px design

	Minimap = {};
	Minimap.Scale  = getMinimapResponsiveScale();
	Minimap.Width  = scaleMinimapValue(cfg.minimap.baseWidth, MIN_MINIMAP_SIZE);
	Minimap.Height = scaleMinimapValue(cfg.minimap.baseHeight, MIN_MINIMAP_SIZE);
	Minimap.MarginX = scaleMinimapValue(cfg.minimap.marginX or cfg.minimap.margin, 8);
	Minimap.MarginY = scaleMinimapValue(cfg.minimap.marginY or cfg.minimap.margin, 8);
	Minimap.PosX   = Minimap.MarginX;
	Minimap.PosY   = (Display.Height - Minimap.MarginY) - Minimap.Height;

	Minimap.IsVisible   = true;
	Minimap.TextureSize = cfg.mapTextureSize;
	Minimap.NormalTargetSize, Minimap.BiggerTargetSize = math.max(Minimap.Width, Minimap.Height), math.max(Minimap.Width, Minimap.Height) * 2;
	Minimap.MapTarget    = dxCreateRenderTarget(Minimap.BiggerTargetSize, Minimap.BiggerTargetSize, true);
	Minimap.RenderTarget = dxCreateRenderTarget(Minimap.NormalTargetSize * 3, Minimap.NormalTargetSize * 3, true);
	Minimap.MaskWidth    = math.max(1, math.floor(Minimap.Width + 0.5));
	Minimap.MaskHeight   = math.max(1, math.floor(Minimap.Height + 0.5));
	Minimap.MaskTarget   = dxCreateRenderTarget(Minimap.MaskWidth, Minimap.MaskHeight, true);
	Minimap.MaskShader   = dxCreateShader(CIRCLE_MASK_SHADER);
	Minimap.MapTexture   = dxCreateTexture(cfg.mapTexture);

	Minimap.CurrentZoom = cfg.minimap.zoom;
	Minimap.MaximumZoom = cfg.minimap.maxZoom;
	Minimap.MinimumZoom = cfg.minimap.minZoom;
	Minimap.CircleMaskEnabled = DEFAULT_CIRCLE_MASK_ENABLED;
	Minimap.CircleMaskFeather = DEFAULT_CIRCLE_MASK_FEATHER;
	Minimap.BorderWidth = math.max(2, DEFAULT_MINIMAP_BORDER_WIDTH * Minimap.Scale);

	Minimap.WaterColor      = cfg.mapWaterColor;
	Minimap.MapColor        = cfg.mapColor or { 255, 255, 255 };
	Minimap.MapColorScale   = cfg.mapColorScale or 1;
	Minimap.Alpha           = cfg.alpha;
	Minimap.PlayerInVehicle = false;
	Minimap.LostRotation    = 0;
	Minimap.MapUnit         = Minimap.TextureSize / cfg.worldSize;
	Minimap.LastZoomTick    = getTickCount();   -- for frame-time-based minimap zoom

	Bigmap = {};
	Bigmap.Width, Bigmap.Height = Display.Width - cfg.bigmap.margin * 2, Display.Height - cfg.bigmap.margin * 2;
	Bigmap.PosX, Bigmap.PosY = cfg.bigmap.margin, cfg.bigmap.margin;
	Bigmap.IsVisible   = false;
	Bigmap.CurrentZoom = cfg.bigmap.zoom;
	Bigmap.MinimumZoom = cfg.bigmap.minZoom;
	Bigmap.MaximumZoom = cfg.bigmap.maxZoom;

	Stats = {};
	Stats.Bar = {};
	Stats.Bar.Width  = Minimap.Width;
	Stats.Bar.Height = scaleMinimapValue(cfg.statsBarHeight, 4);

	if (not Minimap.MaskTarget or not Minimap.MaskShader) then
		outputDebugString('[Radar_Core] Circular minimap mask could not be initialized; using normal minimap drawing.', 2);
	end
end

local function destroyMinimapMask()
	closeTeleportConfirm();
	if (not Minimap) then return; end
	if (Minimap.MaskShader and isElement(Minimap.MaskShader)) then
		destroyElement(Minimap.MaskShader);
	end
	if (Minimap.MaskTarget and isElement(Minimap.MaskTarget)) then
		destroyElement(Minimap.MaskTarget);
	end
	Minimap.MaskShader = nil;
	Minimap.MaskTarget = nil;
end

local function drawMinimapComposite(sourceX, sourceY, sourceWidth, sourceHeight)
	if (Minimap.CircleMaskEnabled and Minimap.MaskShader and Minimap.MaskTarget) then
		dxSetRenderTarget(Minimap.MaskTarget, true);
		dxDrawImageSection(0, 0, Minimap.MaskWidth, Minimap.MaskHeight, sourceX, sourceY, sourceWidth, sourceHeight, Minimap.RenderTarget, 0, -90, 0, tocolor(255, 255, 255, 255));
		dxSetRenderTarget();

		dxSetShaderValue(Minimap.MaskShader, "sTexture", Minimap.MaskTarget);
		dxSetShaderValue(Minimap.MaskShader, "sTextureSize", Minimap.MaskWidth, Minimap.MaskHeight);
		dxSetShaderValue(Minimap.MaskShader, "sFeather", Minimap.CircleMaskFeather);
		dxDrawImage(Minimap.PosX, Minimap.PosY, Minimap.Width, Minimap.Height, Minimap.MaskShader, 0, 0, 0, tocolor(255, 255, 255, 255));
		return;
	end

	dxDrawImageSection(Minimap.PosX, Minimap.PosY, Minimap.Width, Minimap.Height, sourceX, sourceY, sourceWidth, sourceHeight, Minimap.RenderTarget, 0, -90, 0, tocolor(255, 255, 255, 255));
end

local function drawMinimapBorder()
	local color = cfg.colors.border or { 0, 0, 0, 255 };
	local centerX, centerY = Minimap.PosX + Minimap.Width / 2, Minimap.PosY + Minimap.Height / 2;
	local lineWidth = Minimap.BorderWidth;
	local radius = math.max(1, (math.min(Minimap.Width, Minimap.Height) / 2) - (lineWidth / 2));
	local borderColor = tocolor(color[1] or 0, color[2] or 0, color[3] or 0, color[4] or 255);

	for i = 0, MINIMAP_BORDER_SEGMENTS - 1 do
		local startAngle = (i / MINIMAP_BORDER_SEGMENTS) * math.pi * 2;
		local endAngle = ((i + 1) / MINIMAP_BORDER_SEGMENTS) * math.pi * 2;
		local startX, startY = centerX + math.cos(startAngle) * radius, centerY + math.sin(startAngle) * radius;
		local endX, endY = centerX + math.cos(endAngle) * radius, centerY + math.sin(endAngle) * radius;

		dxDrawLine(startX, startY, endX, endY, borderColor, lineWidth, false);
	end
end

local function clampMinimapBlipToCircle(x, y, size)
	local center = Minimap.NormalTargetSize * 1.5;
	local halfSize = size / 2;
	local offsetX, offsetY = (x + halfSize) - center, (y + halfSize) - center;
	local distance = math.sqrt(offsetX * offsetX + offsetY * offsetY);
	local maxDistance = math.max(0, (math.min(Minimap.Width, Minimap.Height) / 2) - halfSize - Minimap.CircleMaskFeather);

	if (distance > maxDistance and distance > 0) then
		local scale = maxDistance / distance;
		offsetX, offsetY = offsetX * scale, offsetY * scale;
	end

	return center + offsetX - halfSize, center + offsetY - halfSize;
end

local function getCleanPlayerName(player)
	return (getPlayerName(player) or ""):gsub("#%x%x%x%x%x%x", "");
end

local function drawPlayerNameLabel(name, x, y, color)
	local padding = 5;
	local textScale = 1;
	local font = "default-bold";
	local width = dxGetTextWidth(name, textScale, font) + padding * 2;
	local height = dxGetFontHeight(textScale, font);
	local left, top = x + padding, y - height / 2;

	dxDrawText(name, left + 1, top + 1, left + width + 1, top + height + 1, tocolor(0, 0, 0, 180), textScale, font, "left", "center", false, false, false, false, false);
	dxDrawText(name, left, top, left + width, top + height, color, textScale, font, "left", "center", false, false, false, false, false);
end

function setBlipInfo(blip, name, description)
	if (not isElement(blip) or getElementType(blip) ~= "blip") then
		return false;
	end

	setElementData(blip, "blipName", type(name) == "string" and name or nil);
	setElementData(blip, "blipDescription", type(description) == "string" and description or nil);
	return true;
end

function getBlipInfo(blip)
	if (not isElement(blip) or getElementType(blip) ~= "blip") then
		return false;
	end

	return getElementData(blip, "blipName"), getElementData(blip, "blipDescription");
end

local function blipHasInfo(blip)
	local name, description = getBlipInfo(blip);
	return type(name) == "string" and name ~= "" and type(description) == "string" and description ~= "";
end

local function getDescribedBlipAtBigmapPosition(cursorX, cursorY)
	local closestBlip, closestDistance;

	for _, blip in ipairs(getElementsByType('blip')) do
		if (blipHasInfo(blip) and getElementDimension(blip) == getElementDimension(localPlayer) and getElementInterior(blip) == getElementInterior(localPlayer) and localPlayer ~= getElementAttachedTo(blip)) then
			local blipX, blipY = getElementPosition(blip);
			local blipSize = getElementData(blip, 'blipSize') or cfg.defaultBlipSize;
			local icon = getBlipIcon(blip);
			local mapX, mapY = getMapFromWorldPosition(blipX, blipY);

			if ((getElementData(blip, 'exclusiveBlip') or false) or icon == 41) then
				local centerX, centerY = (Bigmap.PosX + (Bigmap.Width / 2)), (Bigmap.PosY + (Bigmap.Height / 2));
				local leftFrame = (centerX - Bigmap.Width / 2) + (blipSize / 2);
				local rightFrame = (centerX + Bigmap.Width / 2) - (blipSize / 2);
				local topFrame = (centerY - Bigmap.Height / 2) + (blipSize / 2);
				local bottomFrame = (centerY + Bigmap.Height / 2) - (blipSize / 2);
				mapX = math.max(leftFrame, math.min(rightFrame, mapX));
				mapY = math.max(topFrame, math.min(bottomFrame, mapY));
			end

			if (mapX >= Bigmap.PosX and mapX <= Bigmap.PosX + Bigmap.Width and mapY >= Bigmap.PosY and mapY <= Bigmap.PosY + Bigmap.Height) then
				local hitRadius = math.max(blipSize, cfg.markerHoverSize) / 2;
				local distance = getDistanceBetweenPoints2D(cursorX, cursorY, mapX, mapY);

				if (distance <= hitRadius and (not closestDistance or distance < closestDistance)) then
					closestBlip, closestDistance = blip, distance;
				end
			end
		end
	end

	return closestBlip;
end

local function drawBlipInfoPanel(blip)
	local name, description = getBlipInfo(blip);
	if (not name or not description) then return; end

	local margin = 22 * widthA;
	local padding = 12 * widthA;
	local panelWidth = math.min(260 * widthA, Display.Width - margin * 2);
	local adminTeleport = getElementData(blip, "garageAdminTeleport") == true and getElementData(localPlayer, "garageAdminAccess") == true;
	local panelHeight = adminTeleport and 108 * heightA or 76 * heightA;
	local panelX = Display.Width - panelWidth - margin;
	local panelY = 54 * heightA;

	blipInfoActionButton = nil;
	blipInfoActionBlip = nil;
	blipInfoWaypointButton = nil;
	blipInfoWaypointBlip = nil;
	blipInfoPanelBounds = { x = panelX, y = panelY, w = panelWidth, h = panelHeight };

	dxDrawRectangle(panelX + 2, panelY + 2, panelWidth, panelHeight, tocolor(0, 0, 0, 90), false);
	dxDrawRectangle(panelX, panelY, panelWidth, panelHeight, tocolor(10, 15, 21, 218), false);
	dxDrawRectangle(panelX, panelY, 3 * widthA, panelHeight, tocolor(130, 210, 255, 220), false);
	dxDrawText(name, panelX + padding, panelY + 7 * heightA, panelX + panelWidth - padding, panelY + 25 * heightA, tocolor(245, 249, 252, 245), 0.88, "default-bold", "left", "center", true, false, false, false, false);
	dxDrawText(description, panelX + padding, panelY + 27 * heightA, panelX + panelWidth - padding, panelY + 51 * heightA, tocolor(190, 204, 218, 225), 0.78, "default", "left", "top", true, true, false, false, false);
	local waypointX = panelX + padding;
	local waypointY = panelY + 55 * heightA;
	local waypointW = panelWidth - padding * 2;
	local waypointH = adminTeleport and 18 * heightA or 20 * heightA;
	local cursorOverWaypoint = isCursorShowing();

	if (cursorOverWaypoint) then
		local cursorX, cursorY = getCursorPosition();
		cursorX, cursorY = cursorX * Display.Width, cursorY * Display.Height;
		cursorOverWaypoint = cursorX >= waypointX and cursorX <= waypointX + waypointW and cursorY >= waypointY and cursorY <= waypointY + waypointH;
	end

	dxDrawRectangle(waypointX, waypointY, waypointW, waypointH, cursorOverWaypoint and tocolor(44, 82, 112, 215) or tocolor(21, 31, 43, 190), false);
	dxDrawText("Set waypoint", waypointX, waypointY, waypointX + waypointW, waypointY + waypointH, tocolor(130, 210, 255, 235), 0.76, "default-bold", "center", "center", true, false, false, false, false);
	blipInfoWaypointButton = { x = waypointX, y = waypointY, w = waypointW, h = waypointH };
	blipInfoWaypointBlip = blip;

	if (adminTeleport) then
		local buttonX = panelX + padding;
		local buttonY = panelY + panelHeight - 31 * heightA;
		local buttonW = panelWidth - padding * 2;
		local buttonH = 23 * heightA;
		local cursorOver = isCursorShowing();

		if (cursorOver) then
			local cursorX, cursorY = getCursorPosition();
			cursorX, cursorY = cursorX * Display.Width, cursorY * Display.Height;
			cursorOver = cursorX >= buttonX and cursorX <= buttonX + buttonW and cursorY >= buttonY and cursorY <= buttonY + buttonH;
		end

		dxDrawRectangle(buttonX, buttonY, buttonW, buttonH, cursorOver and tocolor(72, 125, 164, 235) or tocolor(39, 55, 76, 230), false);
		dxDrawText("Admin: teleport to garage", buttonX, buttonY, buttonX + buttonW, buttonY + buttonH, tocolor(245, 249, 252, 245), 0.76, "default-bold", "center", "center", true, false, false, false, false);
		blipInfoActionButton = { x = buttonX, y = buttonY, w = buttonW, h = buttonH };
		blipInfoActionBlip = blip;
	end
end

local function isCursorInBlipInfoPanel(cursorX, cursorY)
	if (not blipInfoPanelBounds) then return false; end

	return cursorX >= blipInfoPanelBounds.x and cursorX <= blipInfoPanelBounds.x + blipInfoPanelBounds.w
		and cursorY >= blipInfoPanelBounds.y and cursorY <= blipInfoPanelBounds.y + blipInfoPanelBounds.h;
end

local function isCursorInBlipInfoWaypoint(cursorX, cursorY)
	if (not blipInfoWaypointButton or not blipInfoWaypointBlip or not isElement(blipInfoWaypointBlip)) then
		return false;
	end

	return cursorX >= blipInfoWaypointButton.x and cursorX <= blipInfoWaypointButton.x + blipInfoWaypointButton.w
		and cursorY >= blipInfoWaypointButton.y and cursorY <= blipInfoWaypointButton.y + blipInfoWaypointButton.h;
end

local function isCursorInBlipInfoAction(cursorX, cursorY)
	if (not blipInfoActionButton or not blipInfoActionBlip or not isElement(blipInfoActionBlip)) then
		return false;
	end

	return cursorX >= blipInfoActionButton.x and cursorX <= blipInfoActionButton.x + blipInfoActionButton.w
		and cursorY >= blipInfoActionButton.y and cursorY <= blipInfoActionButton.y + blipInfoActionButton.h;
end

local function triggerBlipInfoAction()
	if (not blipInfoActionBlip or not isElement(blipInfoActionBlip)) then return false; end
	if (getElementData(blipInfoActionBlip, "garageAdminTeleport") ~= true or getElementData(localPlayer, "garageAdminAccess") ~= true) then return false; end

	triggerServerEvent("garageAdminTeleportRequest", localPlayer);
	playSoundFrontEnd(1);
	return true;
end

setWaypointToBlip = function(blip)
	if (targetBlip and isElement(targetBlip)) then
		destroyElement(targetBlip);
	end

	local x, y, z = getElementPosition(blip);
	targetBlip = createBlip(x, y, z, 41, 2);
	blipAAAA = targetBlip;
	setElementDimension(targetBlip, getElementDimension(blip));
	setElementInterior(targetBlip, getElementInterior(blip));
	playSoundFrontEnd(1);
	return true;
end

local function triggerBlipInfoWaypoint()
	if (not blipInfoWaypointBlip or not isElement(blipInfoWaypointBlip)) then return false; end

	return setWaypointToBlip(blipInfoWaypointBlip);
end

local function clearBlipInfoSelection()
	selectedBlipInfoBlip = nil;
	activeBlipInfoBlip = nil;
	blipInfoPanelBounds = nil;
	blipInfoWaypointButton = nil;
	blipInfoWaypointBlip = nil;
	blipInfoActionButton = nil;
	blipInfoActionBlip = nil;
end

local function getPlayerAtBigmapPosition(cursorX, cursorY)
	local closestPlayer, closestDistance;
	local hitRadius = math.max(cfg.playerBlipSize, cfg.markerSize) / 2 + 6;

	for _, player in ipairs(getElementsByType('player')) do
		if (player ~= localPlayer and not getElementData(player, "dontshow") and getElementDimension(player) == getElementDimension(localPlayer)) then
			local playerWorldX, playerWorldY = getElementPosition(player);
			local mapX, mapY = getMapFromWorldPosition(playerWorldX, playerWorldY);

			if (mapX >= Bigmap.PosX and mapX <= Bigmap.PosX + Bigmap.Width and mapY >= Bigmap.PosY and mapY <= Bigmap.PosY + Bigmap.Height) then
				local distance = getDistanceBetweenPoints2D(cursorX, cursorY, mapX, mapY);

				if (distance <= hitRadius and (not closestDistance or distance < closestDistance)) then
					closestPlayer, closestDistance = player, distance;
				end
			end
		end
	end

	return closestPlayer;
end

function setMinimapCircleMask(enabled, feather)
	if (not Minimap) then return false; end

	Minimap.CircleMaskEnabled = enabled and true or false;

	if (feather ~= nil) then
		Minimap.CircleMaskFeather = math.max(0, tonumber(feather) or DEFAULT_CIRCLE_MASK_FEATHER);
	end

	return true;
end

function isMinimapCircleMaskEnabled()
	return Minimap and Minimap.CircleMaskEnabled or false;
end

-- Fetch config from the files resource and finish setup. Returns true on success.
function initRadar()
	if (initialized) then return true; end

	local provider = getResourceFromName(activeConfigResource);
	if (not provider or getResourceState(provider) ~= "running") then
		return false;
	end

	local settings = call(provider, "getRadarSettings");
	if (type(settings) ~= "table") then
		-- The files resource may not have started yet; caller will retry.
		return false;
	end

	cfg = settings;
	WORLD_HALF = cfg.worldSize / 2;   -- 3000 for a 6000-unit world
	buildState();

	setPlayerHudComponentVisible('radar', false);
	if (Minimap.MapTexture) then
		dxSetTextureEdge(Minimap.MapTexture, 'border', tocolor(Minimap.WaterColor[1], Minimap.WaterColor[2], Minimap.WaterColor[3], Minimap.WaterColor[4]));
	end

	initialized = true;
	if (isTimer(retryTimer)) then killTimer(retryTimer); end
	return true;
end

function setRadarConfigResource(resourceName)
	if (type(resourceName) ~= "string" or resourceName == "") then
		return false;
	end

	if (activeConfigResource == resourceName and initialized) then
		return true;
	end

	activeConfigResource = resourceName;
	if (isTimer(retryTimer)) then killTimer(retryTimer); end
	destroyRadarState();

	if (not initRadar()) then
		retryTimer = setTimer(initRadar, 250, 0);
	end

	return true;
end

function resetRadarConfigResource()
	return setRadarConfigResource(DEFAULT_CONFIG_RESOURCE);
end

function getRadarConfigResource()
	return activeConfigResource;
end

addEventHandler('onClientResourceStart', resourceRoot,
	function()
		if (not initRadar()) then
			-- Files resource not ready yet -- keep retrying until it is.
			retryTimer = setTimer(initRadar, 250, 0);
		end
	end
);

addEventHandler('onClientResourceStop', resourceRoot, destroyMinimapMask);

function isCursorOnElement(x, y, w, h)
	local mx, my = getCursorPosition();
	local fullx, fully = guiGetScreenSize();
	cursorx, cursory = mx * fullx, my * fully;
	if (cursorx > x and cursorx < x + w and cursory > y and cursory < y + h) then
		return true;
	else
		return false;
	end
end

addEventHandler('onClientKey', root,
	function(key, state)
		if (not initialized) then return; end
		if (state) then
			if (key == cfg.keys.toggleBigmap) then
				cancelEvent();
				Bigmap.IsVisible = not Bigmap.IsVisible;
				showCursor(false);

				if (Bigmap.IsVisible) then
					setPlayerHudComponentVisible('radar', false);
					showChat(false);
					playSoundFrontEnd(1);
					Minimap.IsVisible = false;
				else
					setPlayerHudComponentVisible('radar', false);
					showChat(true);
					playSoundFrontEnd(2);
					Minimap.IsVisible = true;
					mapOffsetX, mapOffsetY, mapIsMoving = 0, 0, false;
					clearBlipInfoSelection();
					closeTeleportConfirm();
				end
			elseif (keyInList(cfg.keys.zoomOut, key) and Bigmap.IsVisible) then
				Bigmap.CurrentZoom = math.min(Bigmap.CurrentZoom + 0.5, Bigmap.MaximumZoom);
			elseif (keyInList(cfg.keys.zoomIn, key) and Bigmap.IsVisible) then
				Bigmap.CurrentZoom = math.max(Bigmap.CurrentZoom - 0.5, Bigmap.MinimumZoom);
			elseif (key == cfg.keys.unlockCursor and Bigmap.IsVisible) then
				showCursor(not isCursorShowing());
			end
		end
	end
);

addEventHandler('onClientClick', root,
	function(button, state, cursorX, cursorY)
		if (not initialized) then return; end
		if (not Minimap.IsVisible and Bigmap.IsVisible) then
			if (button == 'left' and state == 'down') then
				if (isCursorInBlipInfoAction(cursorX, cursorY) or isCursorInBlipInfoWaypoint(cursorX, cursorY) or isCursorInBlipInfoPanel(cursorX, cursorY)) then
					return;
				end
				if (selectedBlipInfoBlip) then
					return;
				end
				if (cursorX >= Bigmap.PosX and cursorX <= Bigmap.PosX + Bigmap.Width) then
					if (cursorY >= Bigmap.PosY and cursorY <= Bigmap.PosY + Bigmap.Height) then
						if (getDescribedBlipAtBigmapPosition(cursorX, cursorY)) then
							return;
						end
						mapOffsetX = cursorX * Bigmap.CurrentZoom + playerX;
						mapOffsetY = cursorY * Bigmap.CurrentZoom - playerY;
						mapIsMoving = true;
					end
				end
			elseif (button == 'left' and state == 'up') then
				mapIsMoving = false;
			end
		end
	end
);

addEventHandler('onClientRender', root,
	function()
	if (not initialized) then return end
	if getElementDimension(localPlayer) > 0 then return end
		if (not Minimap.IsVisible and Bigmap.IsVisible) then

			local absoluteX, absoluteY = 0, 0;
			local zoneName = 'Unknown';
			local hoveredInfoBlip = nil;

			if (getElementInterior(localPlayer) == 0) then
				if (isCursorShowing()) then
					local cursorX, cursorY = getCursorPosition();
					local mapX, mapY = getWorldFromMapPosition(cursorX, cursorY);

					absoluteX = cursorX * Display.Width;
					absoluteY = cursorY * Display.Height;

					if (getKeyState('mouse1') and mapIsMoving) then
						playerX = -(absoluteX * Bigmap.CurrentZoom - mapOffsetX);
						playerY = absoluteY * Bigmap.CurrentZoom - mapOffsetY;

						playerX = math.max(-cfg.bigmap.panClamp, math.min(cfg.bigmap.panClamp, playerX));
						playerY = math.max(-cfg.bigmap.panClamp, math.min(cfg.bigmap.panClamp, playerY));
					end

					if (not mapIsMoving) then
						if (Bigmap.PosX <= absoluteX and Bigmap.PosY <= absoluteY and Bigmap.PosX + Bigmap.Width >= absoluteX and Bigmap.PosY + Bigmap.Height >= absoluteY) then
							zoneName = getZoneName(mapX, mapY, 0);
							hoveredInfoBlip = getDescribedBlipAtBigmapPosition(absoluteX, absoluteY);
						else
							zoneName = 'Unknown';
						end
					else
						zoneName = 'Unknown';
					end
				else
					playerX, playerY, playerZ = getElementPosition(localPlayer);
					zoneName = getZoneName(playerX, playerY, playerZ);
				end

				local playerRotation = getPedRotation(localPlayer);
				local mapX = (((WORLD_HALF + playerX) * Minimap.MapUnit) - (Bigmap.Width / 2) * Bigmap.CurrentZoom);
				local mapY = (((WORLD_HALF - playerY) * Minimap.MapUnit) - (Bigmap.Height / 2) * Bigmap.CurrentZoom);
				local mapWidth, mapHeight = Bigmap.Width * Bigmap.CurrentZoom, Bigmap.Height * Bigmap.CurrentZoom;

				local mapColor = tocolor(
					(Minimap.MapColor[1] or 255) * Minimap.MapColorScale,
					(Minimap.MapColor[2] or 255) * Minimap.MapColorScale,
					(Minimap.MapColor[3] or 255) * Minimap.MapColorScale,
					Minimap.Alpha
				);
				dxDrawImageSection(Bigmap.PosX, Bigmap.PosY, Bigmap.Width, Bigmap.Height, mapX, mapY, mapWidth, mapHeight, Minimap.MapTexture, 0, 0, 0, mapColor);

				--> Radar area
				for _, area in ipairs(getElementsByType('radararea')) do
					local areaX, areaY = getElementPosition(area);
					local areaWidth, areaHeight = getRadarAreaSize(area);
					local areaR, areaG, areaB, areaA = getRadarAreaColor(area);

					if (isRadarAreaFlashing(area)) then
						areaA = areaA * math.abs(getTickCount() % 1000 - 500) / 500;
					end

					local areaX, areaY = getMapFromWorldPosition(areaX, areaY + areaHeight);
					local areaWidth, areaHeight = areaWidth / Bigmap.CurrentZoom * Minimap.MapUnit, areaHeight / Bigmap.CurrentZoom * Minimap.MapUnit;

					--** Width
					if (areaX < Bigmap.PosX) then
						areaWidth = areaWidth - math.abs((Bigmap.PosX) - (areaX));
						areaX = areaX + math.abs((Bigmap.PosX) - (areaX));
					end

					if (areaX + areaWidth > Bigmap.PosX + Bigmap.Width) then
						areaWidth = areaWidth - math.abs((Bigmap.PosX + Bigmap.Width) - (areaX + areaWidth));
					end

					if (areaX > Bigmap.PosX + Bigmap.Width) then
						areaWidth = areaWidth + math.abs((Bigmap.PosX + Bigmap.Width) - (areaX));
						areaX = areaX - math.abs((Bigmap.PosX + Bigmap.Width) - (areaX));
					end

					if (areaX + areaWidth < Bigmap.PosX) then
						areaWidth = areaWidth + math.abs((Bigmap.PosX) - (areaX + areaWidth));
						areaX = areaX - math.abs((Bigmap.PosX) - (areaX + areaWidth));
					end

					--** Height
					if (areaY < Bigmap.PosY) then
						areaHeight = areaHeight - math.abs((Bigmap.PosY) - (areaY));
						areaY = areaY + math.abs((Bigmap.PosY) - (areaY));
					end

					if (areaY + areaHeight > Bigmap.PosY + Bigmap.Height) then
						areaHeight = areaHeight - math.abs((Bigmap.PosY + Bigmap.Height) - (areaY + areaHeight));
					end

					if (areaY + areaHeight < Bigmap.PosY) then
						areaHeight = areaHeight + math.abs((Bigmap.PosY) - (areaY + areaHeight));
						areaY = areaY - math.abs((Bigmap.PosY) - (areaY + areaHeight));
					end

					if (areaY > Bigmap.PosY + Bigmap.Height) then
						areaHeight = areaHeight + math.abs((Bigmap.PosY + Bigmap.Height) - (areaY));
						areaY = areaY - math.abs((Bigmap.PosY + Bigmap.Height) - (areaY));
					end

					--** Draw
					dxDrawRectangle(areaX, areaY, areaWidth, areaHeight, tocolor(areaR, areaG, areaB, areaA), false);
				end

				--> Race route lines (big map)
				if getElementData(localPlayer,"Race") or getElementData(localPlayer,"SelectedRace") or Hover then

				local RaceMarkers = getElementsByType('RaceMarker')
					for i=1,#RaceMarkers do
							local v = RaceMarkers[i]
						if (getElementData(localPlayer,"Race") == getElementData(v,"RaceName")) or (getElementData(localPlayer,"SelectedRace") == getElementData(v,"RaceName")) or (Hover == getElementData(v,"RaceName")) then
							local Link = getElementData(v,"StartPoint") or i-1
								if RaceMarkers[Link] then
									if (getElementData(RaceMarkers[Link],"RaceName") == getElementData(v,"RaceName")) then
													local xa,ya = getElementPosition(RaceMarkers[Link])
														local x,y = getElementPosition(v)
												local Xa, Ya = getMapFromWorldPosition(xa,ya)
											local X, Y = getMapFromWorldPosition(x,y)
										local zoom = math.min(1/Bigmap.CurrentZoom,2)
									dxDrawLine(Xa, Ya,X, Y, tocolor(cfg.colors.raceLineBig[1], cfg.colors.raceLineBig[2], cfg.colors.raceLineBig[3], cfg.colors.raceLineBig[4]),zoom*3)
								end
							end
						end
					end
				end
				Hover = nil

				--> Race start markers (big map)
				local raceStarts = getElementsByType('RaceStart')
				if #raceStarts>0 then
				for i=1,#raceStarts do
						local v = raceStarts[i]
						local x,y = getElementPosition(v)
						local X, Y = getMapFromWorldPosition(x,y)
							if isCursorShowing() then
								if isCursorOnElement(X - (cfg.markerSize/2), Y - (cfg.markerSize/2), cfg.markerSize, cfg.markerSize) then
									if getKeyState ("mouse1") then
										setElementData(localPlayer,"SelectedRace",getElementData(v,"RaceName"))
							setElementData(localPlayer,"RaceElement",v)
					end
						dxDrawImage(X - (cfg.markerHoverSize/2), Y - (cfg.markerHoverSize/2), cfg.markerHoverSize, cfg.markerHoverSize, cfg.raceStartImage,0,0,0,tocolor(cfg.colors.marker[1], cfg.colors.marker[2], cfg.colors.marker[3], cfg.colors.marker[4]) )
							Hover = getElementData(v,"RaceName")
						else
							dxDrawImage(X - (cfg.markerSize/2), Y - (cfg.markerSize/2), cfg.markerSize, cfg.markerSize, cfg.raceStartImage,0,0,0,tocolor(cfg.colors.marker[1], cfg.colors.marker[2], cfg.colors.marker[3], cfg.colors.marker[4]) )
						end
					else
							dxDrawImage(X - (cfg.markerSize/2), Y - (cfg.markerSize/2), cfg.markerSize, cfg.markerSize, cfg.raceStartImage,0,0,0,tocolor(cfg.colors.marker[1], cfg.colors.marker[2], cfg.colors.marker[3], cfg.colors.marker[4]) )
						end
					end
				end

				--> Warp points (big map)
				local warppoints = getElementsByType('WarpPoint')

				if #warppoints>0 then
				for i=1,#warppoints do
						local v = warppoints[i]
					local x,y,z = getElementPosition(v)
						local X, Y = getMapFromWorldPosition(x,y)
							local xa,ya,za = getElementPosition(localPlayer)
								if (z > za + cfg.warpAltitudeThreshold) or (z < za - cfg.warpAltitudeThreshold) then
									Alpha = 180
								else
									Alpha = 240
								end
					if isCursorShowing() then
						if isCursorOnElement(X - (cfg.markerSize/2), Y - (cfg.markerSize/2), cfg.markerSize, cfg.markerSize) then
							if getKeyState ("mouse1") then
							setElementData(localPlayer,"SelectedWarp",getElementData(v,"WarpName"))
						setElementData(localPlayer,"WarpElement",v)
					end
						dxDrawImage(X - (cfg.markerHoverSize/2), Y - (cfg.markerHoverSize/2), cfg.markerHoverSize, cfg.markerHoverSize, cfg.warpImage,0,0,0,tocolor(cfg.colors.warp[1], cfg.colors.warp[2], cfg.colors.warp[3], Alpha) )
						else
							dxDrawImage(X - (cfg.markerSize/2), Y - (cfg.markerSize/2), cfg.markerSize, cfg.markerSize, cfg.warpImage,0,0,0,tocolor(cfg.colors.warp[1], cfg.colors.warp[2], cfg.colors.warp[3], Alpha) )
						end
					else
							dxDrawImage(X - (cfg.markerSize/2), Y - (cfg.markerSize/2), cfg.markerSize, cfg.markerSize, cfg.warpImage,0,0,0,tocolor(cfg.colors.warp[1], cfg.colors.warp[2], cfg.colors.warp[3], Alpha) )
						end
					end
				end

				--> Blips
				for _, blip in ipairs(getElementsByType('blip')) do
					if getElementDimension(blip) == getElementDimension(localPlayer) then
					local blipX, blipY, blipZ = getElementPosition(blip);

					if (localPlayer ~= getElementAttachedTo(blip)) then
						local blipSettings = {
							['color'] = {255, 255, 255, 255},
							['size'] = getElementData(blip, 'blipSize') or cfg.defaultBlipSize,
							['icon'] = getBlipIcon(blip),
							['exclusive'] = getElementData(blip, 'exclusiveBlip') or false
						};

						if (blipSettings['icon'] == 0 or blipSettings['icon'] == 1) then
							blipSettings['color'] = {getBlipColor(blip)};
						end

						centerX, centerY = getMapFromWorldPosition(blipX, blipY);

						if blipSettings['exclusive'] or (blipSettings['icon'] == 41) then
						local centerX, centerY = (Bigmap.PosX + (Bigmap.Width / 2)), (Bigmap.PosY + (Bigmap.Height / 2));
						local leftFrame = (centerX - Bigmap.Width / 2) + (blipSettings['size'] / 2);
						local rightFrame = (centerX + Bigmap.Width / 2) - (blipSettings['size'] / 2);
						local topFrame = (centerY - Bigmap.Height / 2) + (blipSettings['size'] / 2);
						local bottomFrame = (centerY + Bigmap.Height / 2) - (blipSettings['size'] / 2);
						local blipX, blipY = getMapFromWorldPosition(blipX, blipY);

						centerX = math.max(leftFrame, math.min(rightFrame, blipX));
						centerY = math.max(topFrame, math.min(bottomFrame, blipY));
						end

						local drawSize = blipSettings['size'];
						if (hoveredInfoBlip == blip or selectedBlipInfoBlip == blip) then
							drawSize = blipSettings['size'] * 1.25;
						end

						dxDrawImage(centerX - (drawSize / 2), centerY - (drawSize / 2), drawSize, drawSize, cfg.imageFolder .. blipSettings['icon'] .. '.png', 0, 0, 0, tocolor(blipSettings['color'][1], blipSettings['color'][2], blipSettings['color'][3], blipSettings['color'][4]));
					end
				end
				end

				--> Other players
				for _, player in ipairs(getElementsByType('player')) do
				if not getElementData(player,"dontshow") then
									if getElementDimension(player) == getElementDimension(localPlayer) then
					local otherPlayerX, otherPlayerY, otherPlayerZ = getElementPosition(player);

					if (localPlayer ~= player) then
						local playerIsVisible = false;
						local blipSettings = {
							['color'] = {255, 255, 255, 255},
							['size'] = cfg.playerBlipSize,
							['icon'] = 'player'
						};

						blipSettings['color'] = {getPlayerNametagColor(player)};

						local blipX, blipY = getMapFromWorldPosition(otherPlayerX, otherPlayerY);

							if (blipX >= Bigmap.PosX and blipX <= Bigmap.PosX + Bigmap.Width) then
								if (blipY >= Bigmap.PosY and blipY <= Bigmap.PosY + Bigmap.Height) then
									dxDrawImage(blipX - (blipSettings['size'] / 2), blipY - (blipSettings['size'] / 2), blipSettings['size'], blipSettings['size'], cfg.playerBlipImage, -getPedRotation(player), 0, 0, tocolor(blipSettings['color'][1], blipSettings['color'][2], blipSettings['color'][3], blipSettings['color'][4]));
									drawPlayerNameLabel(getCleanPlayerName(player), blipX + (blipSettings['size'] / 2), blipY, tocolor(blipSettings['color'][1], blipSettings['color'][2], blipSettings['color'][3], 255));
								end
							end
						end
				end
				end
				end

				--> Local player
				local localX, localY, localZ = getElementPosition(localPlayer);
				local blipX, blipY = getMapFromWorldPosition(localX, localY);

				if (blipX >= Bigmap.PosX and blipX <= Bigmap.PosX + Bigmap.Width) then
					if (blipY >= Bigmap.PosY and blipY <= Bigmap.PosY + Bigmap.Height) then
						dxDrawImage(blipX - (cfg.arrowSize/2), blipY - (cfg.arrowSize/2), cfg.arrowSize, cfg.arrowSize, cfg.arrowImage, 360 - playerRotation);
					end
				end

					if (selectedBlipInfoBlip and not isElement(selectedBlipInfoBlip)) then
						clearBlipInfoSelection();
					end

					if (selectedBlipInfoBlip and isElement(selectedBlipInfoBlip)) then
						activeBlipInfoBlip = selectedBlipInfoBlip;
					elseif (hoveredInfoBlip and isElement(hoveredInfoBlip)) then
						activeBlipInfoBlip = hoveredInfoBlip;
					elseif (activeBlipInfoBlip and isElement(activeBlipInfoBlip) and isCursorShowing() and isCursorInBlipInfoPanel(absoluteX, absoluteY)) then
						hoveredInfoBlip = activeBlipInfoBlip;
					else
						clearBlipInfoSelection();
					end

					if (activeBlipInfoBlip and isElement(activeBlipInfoBlip)) then
						drawBlipInfoPanel(activeBlipInfoBlip);
					end

			else
				if (Minimap.LostRotation > 360) then
					Minimap.LostRotation = 0;
				end
				Minimap.LostRotation = Minimap.LostRotation + 1;
			end
				dxDrawText("Hit Ctrl to unlock mouse\n\n Drag Cursor to move around map.", (Display.Width - 321) / 2, 634*heightA, ((Display.Width - 321) / 2) + 321, 734*heightA, tocolor(cfg.colors.hint[1], cfg.colors.hint[2], cfg.colors.hint[3], cfg.colors.hint[4]), 1.00, "default-bold", "center", "center", false, false, false, false, false)

		elseif (Minimap.IsVisible and not Bigmap.IsVisible) then
			setElementData(localPlayer,"SelectedWarp",nil)
				setElementData(localPlayer,"WarpElement",nil)
					setElementData(localPlayer,"SelectedRace",nil)
						setElementData(localPlayer,"RaceElement",nil)
		if getElementData(localPlayer,"radar") then return end
			if (cfg.showStats) then
				Minimap.PosY = ((Display.Height - Minimap.MarginY) - Stats.Bar.Height) - Minimap.Height;
			else
				Minimap.PosY = (Display.Height - Minimap.MarginY) - Minimap.Height;
			end

			if (getElementInterior(localPlayer) == 0) then
				Minimap.PlayerInVehicle = getPedOccupiedVehicle(localPlayer);
				playerX, playerY, playerZ = getElementPosition(localPlayer);

				--> Calculate positions
				local playerRotation = getPedRotation(localPlayer);
				local playerMapX, playerMapY = (WORLD_HALF + playerX) / cfg.worldSize * Minimap.TextureSize, (WORLD_HALF - playerY) / cfg.worldSize * Minimap.TextureSize;
				local streamDistance, pRotation = getRadarRadius(), getRotation();
				local mapRadius = streamDistance / cfg.worldSize * Minimap.TextureSize * Minimap.CurrentZoom;
				local mapX, mapY, mapWidth, mapHeight = playerMapX - mapRadius, playerMapY - mapRadius, mapRadius * 2, mapRadius * 2;

				--> Set world
				dxSetRenderTarget(Minimap.MapTarget, true);
				dxDrawRectangle(0, 0, Minimap.BiggerTargetSize, Minimap.BiggerTargetSize, tocolor(Minimap.WaterColor[1], Minimap.WaterColor[2], Minimap.WaterColor[3], Minimap.WaterColor[4]*Minimap.Alpha), false);
				local mapColor = tocolor(
					(Minimap.MapColor[1] or 255) * Minimap.MapColorScale,
					(Minimap.MapColor[2] or 255) * Minimap.MapColorScale,
					(Minimap.MapColor[3] or 255) * Minimap.MapColorScale,
					Minimap.Alpha
				);
				dxDrawImageSection(0, 0, Minimap.BiggerTargetSize, Minimap.BiggerTargetSize, mapX, mapY, mapWidth, mapHeight, Minimap.MapTexture, 0, 0, 0, mapColor, false);

				--> Draw radar areas
				for _, area in ipairs(getElementsByType('radararea')) do
					local areaX, areaY = getElementPosition(area);
					local areaWidth, areaHeight = getRadarAreaSize(area);
					local areaMapX, areaMapY, areaMapWidth, areaMapHeight = (WORLD_HALF + areaX) / cfg.worldSize * Minimap.TextureSize, (WORLD_HALF - areaY) / cfg.worldSize * Minimap.TextureSize, areaWidth / cfg.worldSize * Minimap.TextureSize, -(areaHeight / cfg.worldSize * Minimap.TextureSize);

					if (doesCollide(playerMapX - mapRadius, playerMapY - mapRadius, mapRadius * 2, mapRadius * 2, areaMapX, areaMapY, areaMapWidth, areaMapHeight)) then
						local areaR, areaG, areaB, areaA = getRadarAreaColor(area);

						if (isRadarAreaFlashing(area)) then
							areaA = areaA * math.abs(getTickCount() % 1000 - 500) / 500;
						end

						local mapRatio = Minimap.BiggerTargetSize / (mapRadius * 2);
						local areaMapX, areaMapY, areaMapWidth, areaMapHeight = (areaMapX - (playerMapX - mapRadius)) * mapRatio, (areaMapY - (playerMapY - mapRadius)) * mapRatio, areaMapWidth * mapRatio, areaMapHeight * mapRatio;

						dxSetBlendMode('modulate_add');
						dxDrawRectangle(areaMapX, areaMapY, areaMapWidth, areaMapHeight, tocolor(areaR, areaG, areaB, areaA), false);
						dxSetBlendMode('blend');
					end
				end

				--> Race route lines (minimap)
				if getElementData(localPlayer,"Race") or getElementData(localPlayer,"SelectedRace") then

				local EA = getElementsByType('RaceMarker')
				for i=1,#EA do
					local v = EA[i]
						if (getElementData(localPlayer,"Race") == getElementData(v,"RaceName")) then
							local Connector = getElementData(v,"StartPoint") or i-1
								if EA[Connector] then
									if (getElementData(EA[Connector],"RaceName") == getElementData(v,"RaceName")) then
										local xa,ya = getElementPosition(EA[Connector])
										local x,y = getElementPosition(v)

											local XXa,YYa = (WORLD_HALF + xa) / cfg.worldSize * Minimap.TextureSize, (WORLD_HALF - ya) / cfg.worldSize * Minimap.TextureSize
											local XXb,YYb = (WORLD_HALF + x) / cfg.worldSize * Minimap.TextureSize, (WORLD_HALF - y) / cfg.worldSize * Minimap.TextureSize
											local mapRatio = Minimap.BiggerTargetSize / (mapRadius * 2);

										local XXA,YYA = (XXa - (playerMapX - mapRadius)) * mapRatio, (YYa - (playerMapY - mapRadius)) * mapRatio
											local XXB,YYB = (XXb - (playerMapX - mapRadius)) * mapRatio, (YYb - (playerMapY - mapRadius)) * mapRatio
									dxDrawLine( XXA,YYA,XXB,YYB, tocolor(cfg.colors.raceLineSmall[1], cfg.colors.raceLineSmall[2], cfg.colors.raceLineSmall[3], cfg.colors.raceLineSmall[4]), scaleMinimapValue(4, 2) )
								end
							end
						end
					end
				end

				--> Draw blip
				dxSetRenderTarget(Minimap.RenderTarget, true);
				dxDrawImage(Minimap.NormalTargetSize / 2, Minimap.NormalTargetSize / 2, Minimap.BiggerTargetSize, Minimap.BiggerTargetSize, Minimap.MapTarget, math.deg(-pRotation), 0, 0, tocolor(255, 255, 255, 255), false);

				local serverBlips = getElementsByType('blip');

				table.sort(serverBlips,
					function(b1, b2)
						return getBlipOrdering(b1) < getBlipOrdering(b2);
					end
					);

					local postBorderBlips = {};

					for _, blip in ipairs(serverBlips) do
						local blipX, blipY, blipZ = getElementPosition(blip);

					if (localPlayer ~= getElementAttachedTo(blip) and getElementInterior(localPlayer) == getElementInterior(blip) and getElementDimension(localPlayer) == getElementDimension(blip)) then
						local blipDistance = getDistanceBetweenPoints2D(blipX, blipY, playerX, playerY);
						local blipRotation = math.deg(-getVectorRotation(playerX, playerY, blipX, blipY) - (-pRotation)) - 180;
						local blipRadius = math.min((blipDistance / (streamDistance * Minimap.CurrentZoom)) * Minimap.NormalTargetSize, Minimap.NormalTargetSize);
						local distanceX, distanceY = getPointFromDistanceRotation(0, 0, blipRadius, blipRotation);

						local blipSettings = {
							['color'] = {255, 255, 255, 255},
							['size'] = scaleMinimapValue(getElementData(blip, 'blipSize') or cfg.defaultBlipSize, 8),
							['exclusive'] = getElementData(blip, 'exclusiveBlip') or false,
							['icon'] = getBlipIcon(blip)
						};

						local blipX, blipY = Minimap.NormalTargetSize * 1.5 + (distanceX - (blipSettings['size'] / 2)), Minimap.NormalTargetSize * 1.5 + (distanceY - (blipSettings['size'] / 2));

							if (blipSettings['icon'] == 0 or blipSettings['icon'] == 1) then
								blipSettings['color'] = {getBlipColor(blip)};
							end

							local drawAboveBorder = (blipSettings['exclusive'] == true) or (blipSettings['icon'] == 41);

							if (drawAboveBorder) then
								if (Minimap.CircleMaskEnabled) then
									blipX, blipY = clampMinimapBlipToCircle(blipX, blipY, blipSettings['size']);
								else
								local calculatedX, calculatedY = ((Minimap.PosX + (Minimap.Width / 2)) - (blipSettings['size'] / 2)) + (blipX - (Minimap.NormalTargetSize * 1.5) + (blipSettings['size'] / 2)), (((Minimap.PosY + (Minimap.Height / 2)) - (blipSettings['size'] / 2)) + (blipY - (Minimap.NormalTargetSize * 1.5) + (blipSettings['size'] / 2)));
								blipX = math.max(blipX + (Minimap.PosX - calculatedX), math.min(blipX + (Minimap.PosX + Minimap.Width - blipSettings['size'] - calculatedX), blipX));
								blipY = math.max(blipY + (Minimap.PosY - calculatedY), math.min(blipY + (Minimap.PosY + Minimap.Height - blipSettings['size'] - 25 - calculatedY), blipY));
								end
							end

							if (drawAboveBorder) then
								postBorderBlips[#postBorderBlips + 1] = {
									x = blipX,
									y = blipY,
									size = blipSettings['size'],
									icon = blipSettings['icon'],
									color = blipSettings['color']
								};
							else
								dxSetBlendMode('modulate_add');
								dxDrawImage(blipX, blipY, blipSettings['size'], blipSettings['size'], cfg.imageFolder .. blipSettings['icon'] .. '.png', 0, 0, 0, tocolor(blipSettings['color'][1], blipSettings['color'][2], blipSettings['color'][3], blipSettings['color'][4]), false);
								dxSetBlendMode('blend');
							end
						end
					end

				for _, player in ipairs(getElementsByType('player')) do
				if not getElementData(player,"dontshow") then
					local otherPlayerX, otherPlayerY, otherPlayerZ = getElementPosition(player);

					if (localPlayer ~= player and streamDistance * Minimap.CurrentZoom) then
						local playerDistance = getDistanceBetweenPoints2D(otherPlayerX, otherPlayerY, playerX, playerY);
						local playerRotation = math.deg(-getVectorRotation(playerX, playerY, otherPlayerX, otherPlayerY) - (-pRotation)) - 180;
						local playerRadius = math.min((playerDistance / (streamDistance * Minimap.CurrentZoom)) * Minimap.NormalTargetSize, Minimap.NormalTargetSize);
						local distanceX, distanceY = getPointFromDistanceRotation(0, 0, playerRadius, playerRotation);

						local playerDotSize = scaleMinimapValue(cfg.playerDotSize, 6);
						local halfDot = playerDotSize / 2;
						local otherPlayerX, otherPlayerY = Minimap.NormalTargetSize * 1.5 + (distanceX - halfDot), Minimap.NormalTargetSize * 1.5 + (distanceY - halfDot);
						local calculatedX, calculatedY = ((Minimap.PosX + (Minimap.Width / 2)) - halfDot) + (otherPlayerX - (Minimap.NormalTargetSize * 1.5) + halfDot), (((Minimap.PosY + (Minimap.Height / 2)) - halfDot) + (otherPlayerY - (Minimap.NormalTargetSize * 1.5) + halfDot));
						local playerR, playerG, playerB = getPlayerNametagColor(player);

						dxSetBlendMode('modulate_add');
						dxDrawImage(otherPlayerX, otherPlayerY, playerDotSize, playerDotSize, cfg.playerBlipImage, math.deg(-pRotation)-getPedRotation(player), 0, 0, tocolor(playerR, playerG, playerB, 255), false);
						dxSetBlendMode('blend');
					end
				end
				end

					--> Draw fully minimap
					dxSetRenderTarget();
					local minimapSourceX = Minimap.NormalTargetSize / 2 + (Minimap.BiggerTargetSize / 2) - (Minimap.Width / 2);
					local minimapSourceY = Minimap.NormalTargetSize / 2 + (Minimap.BiggerTargetSize / 2) - (Minimap.Height / 2);
					drawMinimapComposite(minimapSourceX, minimapSourceY, Minimap.Width, Minimap.Height);
					drawMinimapBorder();

					for _, blip in ipairs(postBorderBlips) do
						dxSetBlendMode('modulate_add');
						dxDrawImage(Minimap.PosX + blip.x - minimapSourceX, Minimap.PosY + blip.y - minimapSourceY, blip.size, blip.size, cfg.imageFolder .. blip.icon .. '.png', 0, 0, 0, tocolor(blip.color[1], blip.color[2], blip.color[3], blip.color[4]), false);
						dxSetBlendMode('blend');
					end

				--> Local player
				local arrowSize = scaleMinimapValue(cfg.arrowSize, 8);
				dxDrawImage((Minimap.PosX + (Minimap.Width / 2)) - (arrowSize/2), (Minimap.PosY + (Minimap.Height / 2)) - (arrowSize/2), arrowSize, arrowSize, cfg.arrowImage, math.deg(-pRotation) - playerRotation);

				--> Zoom (minimap) -- FIX: original used (getTickCount()-(getTickCount()+50))
				--  which is always -50, giving a fixed +/-0.5 step regardless of
				--  frame rate. Now we scale by real elapsed time (seconds).
				if (getKeyState('num_add') or getKeyState('num_sub')) then
					local now = getTickCount();
					local dt = (now - Minimap.LastZoomTick) / 1000;          -- seconds since last frame
					local dir = getKeyState('num_sub') and 1 or -1;          -- num_add zooms in, num_sub zooms out
					Minimap.CurrentZoom = math.max(Minimap.MinimumZoom, math.min(Minimap.MaximumZoom, Minimap.CurrentZoom + dir * cfg.minimapZoomSpeed * dt));
				end
				Minimap.LastZoomTick = getTickCount();
			else
				if (Minimap.LostRotation > 360) then
					Minimap.LostRotation = 0;
				end
				Minimap.LostRotation = Minimap.LostRotation + 1;
		end
	end
end
);

-- AABB overlap test. Width/height may be negative (radar areas can have
-- negative extents), so normalize first, then do a standard rectangle test.
function doesCollide(x1, y1, w1, h1, x2, y2, w2, h2)
	if (w1 < 0) then x1, w1 = x1 + w1, -w1; end
	if (h1 < 0) then y1, h1 = y1 + h1, -h1; end
	if (w2 < 0) then x2, w2 = x2 + w2, -w2; end
	if (h2 < 0) then y2, h2 = y2 + h2, -h2; end

	return (x1 < x2 + w2) and (x1 + w1 > x2) and (y1 < y2 + h2) and (y1 + h1 > y2);
end

-- Streamed radar radius. On foot it is fixed; in a vehicle it grows linearly
-- from the on-foot radius (at rest) to the max radius (at full speed).
function getRadarRadius()
	local onFoot = cfg.radarRadiusOnFoot;
	if (not Minimap.PlayerInVehicle) then
		return onFoot;
	end

	local vx, vy, vz = getElementVelocity(Minimap.PlayerInVehicle);
	local speed = math.sqrt(vx * vx + vy * vy + vz * vz);   -- velocity magnitude (units/tick)

	local maxR = cfg.radarRadiusMaxSpeed;
	if (speed >= 1) then
		return maxR;
	end

	return math.ceil(onFoot + speed * (maxR - onFoot));
end

function getPointFromDistanceRotation(x, y, dist, angle)
	local a = math.rad(90 - angle);
	local dx = math.cos(a) * dist;
	local dy = math.sin(a) * dist;

	return x + dx, y + dy;
end

function getRotation()
	local cameraX, cameraY, _, rotateX, rotateY = getCameraMatrix();
	local camRotation = getVectorRotation(cameraX, cameraY, rotateX, rotateY);

	return camRotation;
end

function getVectorRotation(X, Y, X2, Y2)
	local TWO_PI = 6.2831853071796;
	-- NOTE: '%' binds tighter than '-' in Lua; the parentheses below make the
	-- original (precedence-driven) grouping explicit rather than changing it.
	local rotation = TWO_PI - (math.atan2(X2 - X, Y2 - Y) % TWO_PI);

	return -rotation;
end

function getMinimapState()
	return Minimap.IsVisible;
end

function getBigmapState()
	return Bigmap.IsVisible;
end

local function getFreeroamResource()
	local resource = getResourceFromName("freeroam");
	if (resource and getResourceState(resource) == "running") then
		return resource;
	end

	return nil;
end

local function isMapDoubleClick(cursorX, cursorY)
	local now = getTickCount();
	local distance = getDistanceBetweenPoints2D(cursorX, cursorY, lastMapClickX, lastMapClickY);
	local isDoubleClick = (now - lastMapClickTick) <= MAP_DOUBLE_CLICK_MS and distance <= MAP_DOUBLE_CLICK_DISTANCE;

	lastMapClickTick, lastMapClickX, lastMapClickY = now, cursorX, cursorY;
	return isDoubleClick;
end

closeTeleportConfirm = function()
	if (teleportConfirmWindow and isElement(teleportConfirmWindow)) then
		destroyElement(teleportConfirmWindow);
	end

	teleportConfirmWindow = nil;
	teleportConfirmLabel = nil;
	teleportConfirmYes = nil;
	teleportConfirmNo = nil;
	pendingTeleportX = nil;
	pendingTeleportY = nil;
	pendingTeleportZ = nil;
end

local function confirmFreeroamTeleport()
	local x, y, z = pendingTeleportX, pendingTeleportY, pendingTeleportZ;
	closeTeleportConfirm();

	local freeroam = getFreeroamResource();
	if (not freeroam) then
		outputChatBox("Freeroam is not running; map teleport is unavailable.", 255, 80, 80);
		return;
	end

	local success = call(freeroam, "setPlayerPosition", x, y, z, false, true);
	if (success == false) then
		outputChatBox("Freeroam rejected the map teleport.", 255, 80, 80);
	end
end

local function showTeleportConfirm(x, y, z)
	if (not getFreeroamResource()) then
		return false;
	end

	closeTeleportConfirm();
	pendingTeleportX, pendingTeleportY, pendingTeleportZ = x, y, z;

	local width, height = 320, 128;
	local left = math.floor((Display.Width - width) / 2);
	local top = math.floor((Display.Height - height) / 2);

	teleportConfirmWindow = guiCreateWindow(left, top, width, height, "Confirm teleport", false);
	teleportConfirmLabel = guiCreateLabel(18, 28, width - 36, 42, ("Teleport to %.1f, %.1f?"):format(x, y), false, teleportConfirmWindow);
	teleportConfirmYes = guiCreateButton(54, 82, 92, 28, "Teleport", false, teleportConfirmWindow);
	teleportConfirmNo = guiCreateButton(width - 146, 82, 92, 28, "Cancel", false, teleportConfirmWindow);

	guiLabelSetHorizontalAlign(teleportConfirmLabel, "center", true);
	guiWindowSetSizable(teleportConfirmWindow, false);
	guiBringToFront(teleportConfirmWindow);
	showCursor(true);

	addEventHandler("onClientGUIClick", teleportConfirmYes, confirmFreeroamTeleport, false);
	addEventHandler("onClientGUIClick", teleportConfirmNo, closeTeleportConfirm, false);
	return true;
end

-- World -> screen (big map). See getWorldFromMapPosition for the inverse.
function getMapFromWorldPosition(worldX, worldY)
	local centerX, centerY = (Bigmap.PosX + (Bigmap.Width / 2)), (Bigmap.PosY + (Bigmap.Height / 2));
	local mapLeftFrame = centerX - ((playerX - worldX) / Bigmap.CurrentZoom * Minimap.MapUnit);
	local mapRightFrame = centerX + ((worldX - playerX) / Bigmap.CurrentZoom * Minimap.MapUnit);
	local mapTopFrame = centerY - ((worldY - playerY) / Bigmap.CurrentZoom * Minimap.MapUnit);
	local mapBottomFrame = centerY + ((playerY - worldY) / Bigmap.CurrentZoom * Minimap.MapUnit);

	centerX = math.max(mapLeftFrame, math.min(mapRightFrame, centerX));
	centerY = math.max(mapTopFrame, math.min(mapBottomFrame, centerY));

	return centerX, centerY;
end


function CreateBlip(button, state, cursorX, cursorY)
	if (not initialized) then return; end
	if (not Bigmap.IsVisible or Minimap.IsVisible) then return; end
	if (button ~= "left" or state ~= "down") then return; end
	if (isCursorInBlipInfoAction(cursorX, cursorY)) then
		triggerBlipInfoAction();
		return;
	end
	if (isCursorInBlipInfoWaypoint(cursorX, cursorY)) then
		triggerBlipInfoWaypoint();
		return;
	end
	if (isCursorInBlipInfoPanel(cursorX, cursorY)) then
		return;
	end

	local infoBlip = nil;
	if (cursorX >= Bigmap.PosX and cursorX <= Bigmap.PosX + Bigmap.Width and cursorY >= Bigmap.PosY and cursorY <= Bigmap.PosY + Bigmap.Height) then
		infoBlip = getDescribedBlipAtBigmapPosition(cursorX, cursorY);
	end

	if (infoBlip) then
		selectedBlipInfoBlip = infoBlip;
		activeBlipInfoBlip = infoBlip;
		playSoundFrontEnd(1);
		return;
	end

	if (selectedBlipInfoBlip) then
		clearBlipInfoSelection();
		playSoundFrontEnd(2);
		return;
	end

	if (cursorX < Bigmap.PosX or cursorX > Bigmap.PosX + Bigmap.Width or cursorY < Bigmap.PosY or cursorY > Bigmap.PosY + Bigmap.Height) then return; end

	local x, y = getWorldFromMapPosition(cursorX / Display.Width, cursorY / Display.Height);
	if (isMapDoubleClick(cursorX, cursorY) and showTeleportConfirm(x, y, 0)) then
		playSoundFrontEnd(1);
		return;
	end

	local targetPlayer = getPlayerAtBigmapPosition(cursorX, cursorY);

	if (targetBlip and isElement(targetBlip)) then
		destroyElement(targetBlip);
		targetBlip = nil;
		blipAAAA = nil;
		playSoundFrontEnd(2);
		return;
	end

	if (targetPlayer) then
		targetBlip = createBlipAttachedTo(targetPlayer, 41, 2);
		blipAAAA = targetBlip;
		setElementDimension(targetBlip, getElementDimension(targetPlayer));
		setElementInterior(targetBlip, getElementInterior(targetPlayer));
		playSoundFrontEnd(1);
		return;
	end

	targetBlip = createBlip(x, y, 0, 41, 2);
	blipAAAA = targetBlip;
	setElementDimension(targetBlip, getElementDimension(localPlayer));
	playSoundFrontEnd(1);
end
addEventHandler("onClientClick", root, CreateBlip)

-- Screen -> world (big map). FIX: this is now a true inverse of
-- getMapFromWorldPosition. The original formula bore no relation to the
-- forward transform (no center offset, no MapUnit), so clicked/cursor world
-- positions -- and therefore zone-name lookup and placed blips -- were wrong.
--   forward: screen = center + (world - player)/zoom * MapUnit
--   inverse: world  = player + (screen - center) * zoom / MapUnit
-- `cursorX`/`cursorY` are normalized (0..1) from getCursorPosition.
function getWorldFromMapPosition(cursorX, cursorY)
	local screenX = cursorX * Display.Width;
	local screenY = cursorY * Display.Height;

	local centerX = Bigmap.PosX + (Bigmap.Width / 2);
	local centerY = Bigmap.PosY + (Bigmap.Height / 2);

	local worldX = playerX + (screenX - centerX) * Bigmap.CurrentZoom / Minimap.MapUnit;
	local worldY = playerY - (screenY - centerY) * Bigmap.CurrentZoom / Minimap.MapUnit;

	return worldX, worldY;
end

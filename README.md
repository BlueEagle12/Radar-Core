# Radar_Core | MTA:SA

Radar_Core is a client-side custom radar resource for MTA:SA.

It replaces the default GTA:SA radar with a configurable DX-based radar system, including a minimap, big map, custom radar textures, custom blip icons, blip info panels, waypoint support, player labels, radar areas, and optional circular minimap masking.

Newer eagleLoader maps use Radar_Core as the shared radar backend so radar behavior can be updated in one place instead of being duplicated across every map resource.

## What This Does

Radar_Core handles the actual radar drawing and gameplay interaction.

The radar settings, map texture, colors, sizing, keybinds, zoom values, and image paths are loaded from a separate radar config resource. By default, Radar_Core looks for a resource named `Radar_Files`.

That means custom maps can provide their own radar files without modifying Radar_Core itself.

## Basic Setup

1. Download or clone this repository.
2. Place the `Radar_Core` folder into your MTA:SA server resources folder.
3. Make sure your radar files/config resource is also installed.
4. Start the radar files/config resource first.
5. Start `Radar_Core`.
6. Start any map or gameplay resource that uses it.

Example start order:

```xml
<resource src="Radar_Files" startup="1" protected="0" />
<resource src="Radar_Core" startup="1" protected="0" />
<resource src="your_map_resource" startup="1" protected="0" />
```

## Config Resource

Radar_Core does not hardcode a single radar map directly into the core resource.

Instead, it loads settings from another resource using:

```lua
exports.Radar_Files:getRadarSettings()
```

By default, the config resource is:

```lua
Radar_Files
```

You can change the active config resource at runtime with:

```lua
exports.Radar_Core:setRadarConfigResource("Your_Radar_Files")
```

The config resource should provide the radar texture, world size, minimap settings, big map settings, colors, keybinds, blip settings, and other radar configuration used by the core.

## Using a Custom Radar Config Resource

To switch Radar_Core to another radar config resource:

```lua
exports.Radar_Core:setRadarConfigResource("My_Custom_Radar_Files")
```

To reset it back to the default `Radar_Files` resource:

```lua
exports.Radar_Core:resetRadarConfigResource()
```

To check which config resource is currently active:

```lua
local currentRadarResource = exports.Radar_Core:getRadarConfigResource()
outputChatBox("Current radar config: " .. tostring(currentRadarResource))
```

## Blip Info

Radar_Core supports extra blip information for the big map.

You can attach a name and description to a blip:

```lua
local blip = createBlip(1000, 500, 20, 35)

exports.Radar_Core:setBlipInfo(
    blip,
    "Airport",
    "Main airport entrance"
)
```

When the player opens the big map and interacts with a supported blip, Radar_Core can show the blip name, description, and waypoint option.

To read the info back:

```lua
local name, description = exports.Radar_Core:getBlipInfo(blip)

outputChatBox(tostring(name))
outputChatBox(tostring(description))
```

## Circular Minimap Mask

Radar_Core supports an optional circular minimap mask.

Enable it:

```lua
exports.Radar_Core:setMinimapCircleMask(true)
```

Disable it:

```lua
exports.Radar_Core:setMinimapCircleMask(false)
```

Set mask feathering:

```lua
exports.Radar_Core:setMinimapCircleMask(true, 2)
```

Check if the circular mask is enabled:

```lua
local enabled = exports.Radar_Core:isMinimapCircleMaskEnabled()
```

## Resource Exports

### setRadarConfigResource

```lua
setRadarConfigResource(resourceName)
```

Changes the radar config provider resource.

Example:

```lua
exports.Radar_Core:setRadarConfigResource("My_Radar_Files")
```

Returns `true` if the config resource was accepted, otherwise `false`.

### resetRadarConfigResource

```lua
resetRadarConfigResource()
```

Resets Radar_Core back to the default config resource:

```lua
Radar_Files
```

Example:

```lua
exports.Radar_Core:resetRadarConfigResource()
```

### getRadarConfigResource

```lua
getRadarConfigResource()
```

Returns the currently active radar config resource name.

Example:

```lua
local resourceName = exports.Radar_Core:getRadarConfigResource()
```

### setMinimapCircleMask

```lua
setMinimapCircleMask(enabled, feather)
```

Enables or disables the circular minimap mask.

`feather` is optional and controls the softness of the mask edge.

Example:

```lua
exports.Radar_Core:setMinimapCircleMask(true, 2)
```

### isMinimapCircleMaskEnabled

```lua
isMinimapCircleMaskEnabled()
```

Returns whether the circular minimap mask is currently enabled.

Example:

```lua
if exports.Radar_Core:isMinimapCircleMaskEnabled() then
    outputChatBox("Circular minimap is enabled.")
end
```

### setBlipInfo

```lua
setBlipInfo(blip, name, description)
```

Adds custom display info to a blip.

Example:

```lua
local blip = createBlip(0, 0, 3, 41)

exports.Radar_Core:setBlipInfo(
    blip,
    "Waypoint",
    "Custom map marker"
)
```

### getBlipInfo

```lua
getBlipInfo(blip)
```

Returns the custom blip name and description.

Example:

```lua
local name, description = exports.Radar_Core:getBlipInfo(blip)
```

## Notes for Map Resources

Map resources should not copy Radar_Core logic into themselves.

Instead, they should either:

* Use the default `Radar_Files` resource
* Provide their own radar config/files resource
* Tell Radar_Core to use that resource with `setRadarConfigResource`

This keeps radar rendering, blip behavior, big map behavior, masking, and future gameplay improvements centralized.

## Notes for eagleLoader Maps

Newer eagleLoader maps should use Radar_Core for radar handling.

This makes map maintenance easier because radar fixes and improvements can be made in Radar_Core without updating every individual map resource separately.

## Related Projects

[Eagle Map Loader](https://github.com/BlueEagle12/MTA-SA---Eagle-Loader)

[Discord](https://discord.gg/q8ZTfGqRXj)

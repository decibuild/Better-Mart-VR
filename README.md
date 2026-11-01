# Better Mart VR

A [UEVR](https://github.com/praydog/UEVR) profile that makes Better Mart play well in VR with motion controllers: you aim with your right hand, and tools and boxes sit in your hand. Menus, the till, customer thought bubbles and the computer shop also get fixes.

It's a set of UEVR Lua scripts plus UEVR settings. It doesn't change any game files.

## What it does

### VR

- **Aim with your right controller.** A small dot shows where you're pointing. The game's fixed centre reticle is hidden, since it no longer matches where you aim.
- **Tools in your hand.** The scanner, the wrench and the mop follow your right controller. The mop cleans where its head touches the floor.
- **Carried boxes follow your hand.** Putting a box down still drops it at your feet, as in flat play.
- **Menus hold still.** The Start menu, the rewards menu and the main menu appear as a steady panel in front of you. The computer shows as a flat screen.
- **The forklift stays in VR.** Driving it shows the 3D world, not a flat screen.
- **The till.** Seated, your view sits a little further back from the counter, so you don't have to bend your wrist to reach the till. B stands you up wherever you're aiming. Button prompts show controller buttons, not keyboard keys.
- **Customer thought bubbles in the world.** They float above each customer, facing you, and are readable from across the store, not shrunk onto the HUD.
- **Performance settings** for VR in `user_script.txt` (see below).

### Gameplay fixes

These fix controller problems in the game itself, which also happen in flat play.

- **No accidental jumps while scanning.** X both scans a pallet and jumps, so jumping is turned off while the scanner is out.
- **Computer shop navigation.** On the Buy screen, pressing right from any category now goes to the products. Before, it only worked when a product sat level with that category.

## Requirements

- **Better Mart** (Steam, full version), with the default DirectX 12 launch option. Tested on game version **V0.8.4.B**. Game updates can rename the things the scripts look for, so a newer version may break some fixes.

  Testing so far covers the early game, so tools, machines or menus you unlock later may not work properly in VR yet. I'll fix them as I get further into the game. If you hit a problem, please [report it](../../issues).
- **UEVR nightly with joeyhodge's `UEVRBackend.dll`.** The profile doesn't work with a plain nightly.
  1. Download a UEVR nightly: https://github.com/praydog/UEVR-nightly/releases
  2. Download joeyhodge's build: https://github.com/joeyhodge/UEVR/releases
  3. Overwrite the nightly's `UEVRBackend.dll` with the one from joeyhodge's release. Keep every other file from the nightly.
- A PC VR headset with motion controllers, using an OpenXR runtime.
- **Optional, recommended: [uevr-stick-fix](https://github.com/decibuild/uevr-stick-fix).** Without it, turning can stop while you sit at the till. See [below](#optional-uevr-stick-fix).

## Install

1. Download `BetterMart-Win64-Shipping.zip` from the [Releases](../../releases) page.
2. Start Better Mart, then open UEVR's injector (`UEVRInjector.exe`) and select `BetterMart-Win64-Shipping.exe`.
3. Click **Import Config** and choose the zip.

To install by hand instead, unzip it into:

```
%APPDATA%\UnrealVRMod\BetterMart-Win64-Shipping\
```

so that you end up with `config.txt`, `user_script.txt` and a `scripts` folder in there. Back up anything already in that folder first, because `config.txt` will be replaced.

If you're using uevr-stick-fix, put `stick_fix.dll` in that folder's `plugins` folder (create it if it isn't there).

Then inject as usual.

## Optional: uevr-stick-fix

In UEVR's OpenXR mode, a thumbstick can stop working while the *other* controller is idle. In Better Mart this shows at the till: you sit with your left hand still, the left controller goes to sleep, and turning with the right stick stops until you move the left controller again.

[uevr-stick-fix](https://github.com/decibuild/uevr-stick-fix) is a small UEVR plugin that works around this. It's a separate download: put `stick_fix.dll` into `%APPDATA%\UnrealVRMod\BetterMart-Win64-Shipping\plugins\`. Without it, everything else here works, and moving the left controller brings turning back.

## Settings

### Performance (`user_script.txt`)

Many of these can't be set in the game's own graphics menu, and some of the menu's settings don't work properly. For example, the resolution slider always saves 63% whatever you pick. So set them here instead: UEVR runs these console commands when it injects, overriding the game's menu.

| Setting | Effect |
| --- | --- |
| `r.ScreenPercentage 85` | Renders at 85% resolution, upscaled by TSR. Raise it if you have headroom. |
| `r.DynamicRes.OperationMode 0` | No automatic resolution drops. |
| `r.ReflectionMethod 2` | Screen-space reflections. |
| `sg.GlobalIlluminationQuality 2` | Lumen GI at High instead of Epic. Set it to `1` to turn Lumen GI off for more performance. |
| `r.MotionBlurQuality 0`, `r.DepthOfFieldQuality 0`, `r.SceneColorFringeQuality 0`, `r.FilmGrain 0`, `r.LensFlareQuality 0`, `r.VolumetricFog 0`, `r.Tonemapper.Quality 1` | Turns off motion blur, depth of field, chromatic aberration, film grain, lens flares, volumetric fog and the vignette. |
| `r.MaxAnisotropy 16` | Sharper textures at an angle. |

Set anti-aliasing to TSR in the game's own settings. The game has no DLSS, FSR or XeSS, so TSR is its upscaler.

### Tuning the scripts

Each script has its settings at the top, with comments. A few you may want to change:

- `scripts/held_box.lua`: `HOLD_AHEAD`, how far ahead of your hand a carried box sits (cm).
- `scripts/till_seat.lua`: `SEAT_BACK`, how far back your seated view is moved at the till (cm).
- `scripts/customer_bubbles.lua`: `CM_PER_PIXEL` and `DISTANCE_GROWTH`, how big the thought bubbles are, up close and far away.
- `scripts/controller_pointer.lua`: the aim dot's size and colour.

### Don't use

- UEVR's alternating-eye rendering (AFR, `VR_RenderingMethod=2`).
- The game's Vulkan or DirectX 11 options. UEVR doesn't support Vulkan, and DirectX 11 loses Nanite and virtual shadow maps.

## Known issues

- Boxes you put down land at your feet. That's the game's design, the same as in flat play.
- The game sometimes crashes when you quit. The cause isn't known yet.
- Only tested on a Quest 3 through Virtual Desktop. Reports from other headsets and runtimes are welcome.

## Licence

MIT, see [LICENSE](LICENSE).

Better Mart is not made by or affiliated with this project. No game files are included.

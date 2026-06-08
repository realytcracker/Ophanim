# Galgal

Galgal is an essential part of [Ophanim](https://github.com/Ophanim/Ophanim). Galgal implements core functions of Ophanim, including display control, key mapping and bypassing.

## Display Control

<!-- iOS APPs running on macOS usually have fixed display settings, which may not be suitable for the user's needs. Galgal allows you to adjust the display settings of the game, so that you can enjoy the game in a more comfortable way. -->

Galgal allows you to control:

- Resolution: Supports 1080p, 4k, 1440p and custom resolution
- Aspect Ratio: Supports 16:9, 16:10, 4:3 and custom aspect ratio
- Scale Factor: Supports custom scale factor (e.g. 1.0, 1.5, 2.0)
- Display Orientation: Supports manually rotating the game window during game play.
- Application type (most useful case is changing to type `game` and the type reflects in screen time usage)
- Custom discord activity
- Device type

## Key Mapping

Galgal provides a key mapping tool to map game actions to the keyboard, mouse, trackpad or controller.

Supported input devices include:

- Keyboard
- Mouse
- Trackpad
- Controller

Input from these devices can be mapped to these in-game actions:

- Button
- Joystick (e.g. WASD)
- Camera Control (usually by mouse)
- Draggable Button (e.g. wheel menu selection)

More mapping options such as swiping will be added in the future.

## Bypassing

Games designed for iOS devices may not work properly on macOS. Galgal provides a solution to bypass these issues.

### Jailbreak Bypassing

Some games refuse to work on macOS because they detect the environment as a jailbroken device. Galgal hijacks the detection process of popular jailbreak detection tools, so that the game will think it is running on a non-jailbroken device.

Galgal also allows per-game configuration for more advanced jailbreak bypassing techniques.

### ChainGuard

ChainGuard is a tool that solves key chain issues by replacing the game's key chain with a custom one. Key chain issues usually prevent the game from logging in.

### Introspection Library

Some games only work under debug environment. By inserting the Introspection Library, Galgal tricks the game into thinking it is running under debug environment.

# How to Use

Galgal is shipped with Ophanim, and is installed together with the game. You do not need to install Galgal manually.

Galgal provides in-game menus mostly for key mapping setup. Other features are accessible through the Ophanim settings menu.

Localization is handled in [Weblate](https://hosted.weblate.org/projects/ophanim/).

# How it Works

Galgal runs alongside of the game. During IPA installation, Galgal is inserted into the game's executable. When the game is launched, Galgal will be launched together.

Galgal uses swizzle techniques to replace framework methods and system calls with the versions provided by Galgal. During game play, Galgal intercepts game input events and translates them to the corresponding touch events and feed them to the game.

# How to Build

Galgal is built using Xcode.

## Production Build
In release builds, the building script of Ophanim will automatically fetch the latest version of Galgal from the official repository and build it. Generally, you do not need to build Galgal manually.

To build Ophanim with a specific version of Galgal, mostly for testing purposes, change the [Cartfile](https://github.com/Ophanim/Ophanim/blob/develop/Cartfile) of Ophanim to point to the specific version of Galgal. You can specify which branch/tag of which repository to build from.

You can also edit the Cartfile to build from a local directory. To do this, edit the Cartfile to be:
```
git "file:///path/to/galgal" "branch or tag"
```
See [Cartfile format](https://github.com/Carthage/Carthage/blob/master/Documentation/Artifacts.md#example-cartfile)

In most cases, `Cartfile.resolved` would be automatically updated based on the Cartfile. In rare cases, you may need to manually edit the resolved file.

## Development Build
Galgal can also be built separately. This is useful when you want to modify the source code.

To do so, 

1. Clone the Galgal repository.

1. Open the Galgal project in Xcode.

1. Set the development team in the Xcode project settings. Both `Galgal` and `GalgalInterface` targets need to be set. You may need to create a development team first.

1. Build Galgal towards iOS platform. This will create a `Galgal.framework` in the build directory.

1. Find the build path. This can be done by right clicking on `Galgal.framework` in `Product`, and selecting `Show in Finder`. 

6. Deploy the build. Replace the `BUILD_PATH` in the following script with your build path and run:

```bash
#!/bin/sh
BUILD_PATH=~/Library/Developer/Xcode/DerivedData/Galgal-<YOUR-UUID>/Build/Products/Debug-iphoneos

echo "Converting to maccatalyst"
vtool \
	-set-build-version maccatalyst 11.0 14.0 \
	-replace -output \
	"$BUILD_PATH/Galgal.framework/Galgal" \
	"$BUILD_PATH/Galgal.framework/Galgal"

echo "Codesigning Galgal"
codesign -fs- "$BUILD_PATH/Galgal.framework/Galgal"

echo "Copying to Ophanim"
rm -r "/Applications/Ophanim.app/Contents/Frameworks/Galgal.framework"
cp -r "$BUILD_PATH/Galgal.framework" "/Applications/Ophanim.app/Contents/Frameworks/"

```
This script transforms the target platform to Mac Catalyst, codesigns Galgal and copies the binaries into the Ophanim App.

7. Relaunch Ophanim.

### Temporary Deploy

If you are debugging and testing your own code, relaunching Ophanim every time you make a change is a bit annoying. 

To avoid this, run this script instead:

```bash
#!/bin/sh
BUILD_PATH=~/Library/Developer/Xcode/DerivedData/Galgal-<YOUR-UUID>/Build/Products/Debug-iphoneos

echo "Converting to maccatalyst"
vtool \
	-set-build-version maccatalyst 11.0 14.0 \
	-replace -output \
	"$BUILD_PATH/Galgal.framework/Galgal" \
	"$BUILD_PATH/Galgal.framework/Galgal"

echo "Codesigning Galgal"
codesign -fs- "$BUILD_PATH/Galgal.framework/Galgal"

echo "Copying to frameworks"
cp "$BUILD_PATH/Galgal.framework/Galgal" "~/Library/Frameworks/Galgal.framework/"
```

This only copies `Galgal.framework/Galgal` to `~/Library/Frameworks/Galgal.framework/`, instead of the whole `Galgal.framework` directory into Ophanim. Changes take effect immediately, no Ophanim relaunch needed. Changes will be lost when you relaunch Ophanim.

However, If you modified `GalgalInterface` or added localization strings, the temporary deploy method may not work for you. You may copy the whole `Galgal.framework` as described above, or directly copy them into the game you're testing on:
```bash
#!/bin/sh
BUILD_PATH=~/Library/Developer/Xcode/DerivedData/Galgal-<YOUR-UUID>/Build/Products/Debug-iphoneos

cp "$BUILD_PATH/Galgal.framework/PlugIns/GalgalInterface.bundle" "~/Library/Containers/be.ophanim.Ophanim/Applications/<YOUR-GAME-NAME>.app/PlugIns"

cp "$BUILD_PATH/Galgal.framework/*.lproj" "~/Library/Containers/be.ophanim.Ophanim/Applications/<YOUR-GAME-NAME>.app/"
```
This will be overwritten when you launch the game through Ophanim. You can launch the game from Finder to avoid this.

# Products

## Galgal

The main part of Galgal. This ends up as a dynamic library. This part is built towards iOS platform because it uses iOS APIs that are not available on Mac Catalyst.

## GalgalInterface

A bridge that encapsulates native macOS APIs to expose an interface for Galgal. This includes manipulating mouse and keyboard events, controlling cursor and application state, and reading window information.

## Localizable Strings

Localizations for Galgal are tricky. As Galgal runs as a dynamic library inside the game, localizable strings must be copied into the game to take effect. This is done during IPA installation and every launch of the game through Ophanim.

To avoid conflicting with the game's own localizable strings, Galgal' localizable strings are renamed to `Galgal.strings`, instead of the default `Localizable.strings`.


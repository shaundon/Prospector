# Prospector

A little visionOS app for walking around inside large USDZ models (house scans, terrain, etc.) on Apple Vision Pro, with game controller support for movement.

I built this for myself (well, I vibe coded it so if any code is janky please don't yell at me), so it's rough around the edges and not the most straightforward to use, but it should be a fun starting point if you want to explore your own large models in an immersive space.

## Setup

1. Set your development team in the project's Signing & Capabilities settings.
2. Build and run on Apple Vision Pro (visionOS 2.5+).

Use the **Passthrough** control on the floating panel to let your real surroundings show through the model.

## Controls

### Without a controller

Pinch anywhere on the model and drag. Use your left hand to move the model, and your right to rotate it. With this, you can line up the model to match a real-life room.

### With a game controller

Pair a game controller (e.g. a DualSense or Xbox controller) with your Vision Pro. Movement is relative to the direction you're looking.

| Input | Action |
| --- | --- |
| Left thumbstick | Move |
| Right thumbstick | Look (yaw) |
| Left / right trigger | Move down / up |
| D-pad up | Reset height to the terrain surface |
| D-pad right | Toggle terrain follow (height snaps to the ground as you move) |
| D-pad left | Toggle speed mode (6× movement) |

You can also pinch your thumb and middle finger together for half a second (either hand) to switch full passthrough on or off.

## Credits

The environment skybox is the [Meadow 2](https://polyhaven.com/a/meadow_2) HDRI from Poly Haven (CC0).

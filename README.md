# Live Light

A KOReader plugin that makes the brightness and warmth edge swipes behave the way they do in Kobo's own software: the light changes **while your finger is moving**, not after you lift it.

- Slide up or down the **left edge** of the screen for brightness.
- Slide up or down the **right edge** for warmth.
- Prefer them the other way round? There’s a setting to swap the sides.
- A small box shows the level as you go.

| Brightness | Warmth |
|:---:|:---:|
| ![Sliding up the left edge of a home screen raises the brightness](images/brightness-home.gif) | ![Sliding along the right edge of a home screen changes the warmth](images/warmth-home.gif) |
| ![Sliding along the left edge of a book page changes the brightness](images/brightness-book.gif) | ![Sliding along the right edge of a book page changes the warmth](images/warmth-book.gif) |

Top row: a [Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin) home screen. Bottom row: while reading.


## Tested on

Developed and tested on a **Kobo Clara BW** running **KOReader 2026.07.02**. Users have reported good experiences running this plug-in on:

- **Kobo**: Clara BW; Clara Colour; Libra; Libra Colour
- **Kindle**: Paperwhite 11th, 7th, 5th gen; Colorsoft SE 2024; Scribe
- **PocketBook**: Verse; Era Color

People have reported some delay with the PocketBook Era Lite and Nook GlowLight 4 Plus.

Reports from other devices are welcome.

Devices without a warmth light get brightness on the left edge only. The right edge is left alone. (Or vice versa if you have "Swap Sides" turned on.)

## Install or update

1. Download `livelight.koplugin.zip` from the [Releases](../../releases) page and unzip it. You should have a folder named `livelight.koplugin`.
2. Connect your e-reader to a computer with USB.
3. Copy into or replace the `livelight.koplugin` folder in KOReader's `plugins` folder. On a Kobo that is `.adds/koreader/plugins/`. The `.adds` folder is hidden: on a Mac, press **Cmd+Shift+.** in Finder to show it.
4. Eject the device and restart KOReader.

If you already have edge-swipe settings set up, you do not need to change or disable them. Live Light takes priority over KOReader's built-in edge swipes while it is switched on, and hands the edges back when it is switched off.

To uninstall, delete the folder.

## Using it

Put a finger on the left or right edge of the screen (the outer eighth) and slide up or down. Start moving right away. If you rest your finger for about half a second, KOReader treats it as a long-press.

- About 70% of the screen height covers the full range.
- Sliding brightness all the way down turns the light off; sliding back up turns it on.
- Once a slide has started, your finger can wander off the edge strip and it keeps working until you lift.

> [!IMPORTANT]
> **NOTE:** After you leave a book, this plug-in does not work on Bookshelf's shelf screens until the book is actually no longer in memory, which happens soon but not immediately. **THIS IS NOT IDEAL BUT IS NOT A BUG.**
>
> When you leave a book, Bookshelf actually keeps it open in the background for a while. During this time, Bookshelf disables certain features until the device has gone untouched for 30 to 40 seconds, or you open a different book. There are good reasons for this, but it has the side effect of making this plug-in not work during this period. Bookshelf would need to be modified to allow these swipes through while a book is in memory.


### Settings

Top menu → gear icon → Taps and gestures → Live Light:

- **Enable Live Light**: the main on/off switch.
- **Show level while sliding**: show or hide the box with the number.
- **Swap sides**: brightness on the right edge and warmth on the left.

![Settings](images/settings.jpg)

## Where it works

Tested on the device:

- **While reading a book.**
- **[Bookshelf](https://github.com/AndyHazz/bookshelf.koplugin) home screens.**

It deliberately stays out of full-screen viewers such as the image viewer.

And it has the limitation mentioned above about not working in Bookshelf's main shelf screens while a book is still in memory.

## Credits

Written by David Friedman, working with [Claude](https://claude.com/claude-code), Anthropic's AI model.

## License

[AGPL-3.0](LICENSE), the same license as KOReader.

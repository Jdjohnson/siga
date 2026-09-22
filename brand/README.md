# Everyday quiet

Sigá makes room for your voice while your music keeps playing. The brand should feel warm, useful, and as small as the app itself.

## The idea

**Keep your music on.**

Explain the tool plainly: “A tiny Mac app that fades the volume down while you dictate, then gently brings it back when you’re done.”

Write like you’re explaining a useful little app to a friend. Use “volume” instead of “output” unless a technical distinction matters. Keep headings in sentence case. No eyebrow labels. Skip claims about being the lightest or fastest until there is comparison data.

Use **Sigá**, with the accent, in prose. Use **Siga** for the application filename and terminal commands.

## Color

| Color | Value | Use |
| --- | --- | --- |
| Teal | `#064B4E` | Wordmark, headings, buttons |
| Blue | `#8AB3DC` | The continuing wave |
| Apricot | `#F0B79D` | Small supporting accents |
| Sage | `#DDE5C9` | Quiet supporting panels |
| Paper | `#F7F3EA` | Main background |
| Icon blue | `#629FC8` | App-icon background |
| Body | `#426368` | Supporting readable copy |

Paper does most of the work. Use Teal for clear contrast. Blue, Sage, and Apricot support the composition; they are not body-text colors. [Machine-readable tokens](tokens.json).

## Lettering and mark

The production wordmark uses **Fraunces**, weight 700, optical size 144, softness 100, with wonk enabled. It gives the approved direction a reproducible, openly licensed foundation. The supplied SVG wordmarks contain outlines, so they need no installed font or webfont download.

The wordmark replaces the acute accent with one thick, rounded wave. The app icon uses that same single wave. Keep the original three waves in the menu bar: they become shorter from top to bottom, suggesting sound settling down. The menu-bar mark remains a native macOS template image so it adapts to light and dark appearances. Keep Sigá correctly accented in written text and accessibility labels.

Leave at least one stroke width around the mark. Don’t stretch it, add extra waves, or turn it into a microphone or pause symbol. Use the Teal or Paper version for clear contrast. Keep the icon simple, with a subtle blue gradient and fine paper texture.

Use the system sans-serif for website copy and native macOS type in the app. No new font or branding dependency is bundled with the app.

## Layout and imagery

Use generous space, clear type, and a small number of elements. The website photograph shows a person wearing headphones and speaking toward her Mac, with her hands away from the keyboard. Warm daylight, pale wood, and natural shadows carry the Everyday quiet mood. Keep it secondary to the words and the install action.

Wave accents stay continuous and become gentler. Avoid busy equalizers, glowing effects, heavy decoration, and staged interface illustrations. Disclosure panels open and close with a short, gentle ease. Respect reduced-motion preferences and keep native disclosure behavior when JavaScript is unavailable.

## Files

- [Teal wordmark](assets/wordmark-teal.svg) and [Paper wordmark](assets/wordmark-paper.svg)
- [Horizontal logo](assets/logo-horizontal.svg)
- [Teal wave mark](assets/mark-teal.svg) and [Paper wave mark](assets/mark-paper.svg)
- [App icon, 1024 px](assets/app-icon-1024.png), [favicon](assets/favicon.svg), and [touch icon](assets/apple-touch-icon.png)
- [README header](assets/readme-header.webp) and [editable SVG](assets/readme-header.svg)
- [Website photograph](assets/everyday-quiet.webp)

The app’s icon source, native ICNS, and small preview live in `../assets/`. The website and README images are not part of the app bundle.

See [credits and reuse](CREDITS.md). The image brief, `prompts.md`, is kept privately. It is not part of this repository or the public source archive.

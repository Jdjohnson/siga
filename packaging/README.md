# Drag-to-Applications disk image

The installer window contains `Siga.app` and a shortcut to `/Applications`. Opening the disk image does not install or launch the app.

`background.tiff` and `finder-layout.dsstore` preserve Sigá's existing branded installer layout. The layout sets a 720 × 480 window, icon view, and the app and Applications icon positions. The package script copies the layout to `.DS_Store` and uses the app's current icon as the volume icon. These assets came from the previous Sigá installer; no application from that image is reused.

`../package-dmg.sh` takes an already signed and stapled app, builds the disk image with Apple's command-line tools, signs and notarizes the image, staples its ticket, and verifies Gatekeeper acceptance. It needs no third-party packaging tool. The image keeps the volume name `Install Sigá` so the saved Finder background alias resolves correctly.

For a package-only rebuild:

```sh
SIGA_IDENTITY='Developer ID Application: Your name (TEAMID)' SIGA_NOTARY='your-notarytool-profile' ./package-dmg.sh /path/to/Siga.app /path/to/Siga.dmg
```

Use a new output path. After building, mount the image and check the Finder window, the Applications shortcut, and that the bundled app matches the input. Do not launch the app on the build machine as part of packaging verification.

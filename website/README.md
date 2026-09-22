# Sigá website

A small static website in the Everyday quiet style. Plain HTML and CSS with a small, optional accordion animation. The disclosures still work without JavaScript, and motion respects reduced-motion preferences. No framework, package install, API key, database, tracking, or remote font service is required. Serve this folder as static files.

The Mac download is deliberately unavailable until a Developer ID signed, notarized DMG has passed the release checks. Replace both disabled download buttons in index.html with the same actual Siga.dmg release URL at that point, and remove its preparation note. Keep the app download first and the source instructions secondary.

The source ZIP in downloads is a `git archive` of the reviewed release commit recorded in RELEASING.md, for people who want to build or customize Sigá. Regenerate it with the steps there when app source or release assets change. The ZIP is ignored by git and copied in when the site is deployed, so the archive never contains itself. LICENSE.txt in downloads must match the LICENSE in the release source.

Once the GitHub destination is chosen, add its exact URL to the source links. There is no build step, but launch from a fresh copy of this folder with the current source ZIP copied in, not from an earlier preview deployment, which can carry an older ZIP. Before the site is public, confirm that both app buttons download the verified DMG and that the served DMG and source ZIP hashes match the release record.

# Releasing Sigá

The Mac download is `Siga.dmg`. Open it and drag Sigá into Applications. Building from source stays available for people who want to customize it.

## Version 0.2 release

Prepared September 22, 2026, build 18, from the reviewed all-dictation source. Fade B is the sole shipping fade (400 ms down, 850 ms up); the unused alternatives and preference override are removed. The owner accepted the listening session. Sleep/wake and Flow Command Mode are explicitly excluded from this release's acceptance requirements; do not reintroduce them through the general checklists below.

The complete Mini integration evidence covers Willow, superwhisper, Wispr Flow dictation/Notetaker and the custom-add flow. Older macOS versions remain unverified and must not be advertised as tested.

On September 23, Jarad approved a 30 MiB settled physical-footprint limit. The installed build 18 measured 29.1 MiB in three idle readings after normal use, with RSS about 83 MiB recorded separately. This supersedes the earlier 25 MiB physical-footprint limit and the original 25 MiB RSS limit; it does not mean RSS met either limit. Jarad downloaded and installed the notarized DMG from the website, confirmed setup and normal lowering/restoration, and accepted that hands-on result. He explicitly waived the remaining clean Mac Mini first-launch and login checks for this release. Do not claim those waived checks passed. CPU and energy comparisons were not refreshed in this acceptance pass.

Version 0.2 and build 18 are the release identifiers. Build 18 keeps the cream button-label color when controls are disabled. The public repository is [`Jdjohnson/siga`](https://github.com/Jdjohnson/siga). The notarized build 18 DMG is available at [getsiga.app](https://getsiga.app/) and in the [GitHub release](https://github.com/Jdjohnson/siga/releases/tag/v0.2-build18).

The build checks the executable budget after signing as well as before it. The signer reserves 11 KB for the complete CMS signature, retaining the certificate chain, secure timestamp and hardened runtime; signing fails if a future signature no longer fits.

The private release packet records source/app hashes, signing/notarization receipts and the status of each outstanding gate. Do not include that packet in the source archive.

## Checklist for future releases

- Finish the hands-on checks in [CONTRIBUTING.md](CONTRIBUTING.md) using a build of the exact source being released.
- Obtain a **Developer ID Application** signing identity and a notarization keychain profile. An **Apple Development** identity is not a substitute for outside-the-store distribution.
- Choose the GitHub repository and confirm the version in `build.sh`.
- Check the archive contains no private review files, credentials, diagnostics, or local environment files. `brand/prompts.md` is not part of this repository: it is in no commit, `.gitignore` keeps it and files named like it, in any letter case, from being added, and `.gitattributes` excludes them from `git archive` output should one ever be force-added. The source ZIP under `website/downloads` is not tracked, so the archive never contains itself.
- Before the repository is first pushed, confirm the brief is in no commit. Run these in zsh or bash from the root of the checkout that holds `brand/prompts.md`. Each command prints nothing:

  ```sh
  grep -qE '.{40,}' brand/prompts.md || echo "brand/prompts.md is missing or has no line of 40 or more characters"
  git --no-replace-objects log --all --oneline -- ':(icase)brand/prompts*'
  git --no-replace-objects grep -lF -f <(grep -E '.{40,}' brand/prompts.md) $(git --no-replace-objects rev-list --all)
  git --no-replace-objects log --all --format=%B | grep -qF -f <(grep -E '.{40,}' brand/prompts.md) && echo "a commit message quotes the brief"
  git replace -l
  git stash list
  git for-each-ref --format='%(refname) %(objectname) %(refname) 0000000000000000000000000000000000000000' | python3 "$(git rev-parse --git-path hooks)/siga-private-guard.py" push
  ```

  The first confirms the brief is there to compare against. The second looks for its name in any letter case. The third and fourth look for any of its lines of 40 or more characters, unchanged, anywhere in a file or commit message, including inside a longer line, so they miss a copy that is re-encoded, compressed, or reworded. `--no-replace-objects` keeps a replacement object from hiding a commit. The last runs the brief guard’s push scan over every ref: it also reads UTF-16 and UTF-32 text and ZIP, tar, gzip, bzip2 and xz data up to three levels deep, catches near copies that share at least eight six-word phrases with the brief, and refuses a stash. The guard lives only in the maintainer’s `.git/hooks`, which git does not clone; without it, that line prints an error instead of nothing. None of these checks find a copy in base64, rot13, or another deliberate encoding. Also, `git cat-file -e "$(git hash-object brand/prompts.md)"` exits with status 1 because no such object exists.

## Build and notarize

`build.sh` already performs the release pipeline when its two release variables are set:

```sh
SIGA_IDENTITY='Developer ID Application: Your name (TEAMID)' SIGA_NOTARY='your-notarytool-profile' ./build.sh
```

It builds the Apple Silicon app, signs it with a timestamp and hardened runtime, notarizes and staples the app, then creates `Siga.dmg` with the branded drag-to-Applications window. The disk image is also signed, notarized, stapled, and checked by Gatekeeper. The intermediate app ZIP is not the website download. A successful local development build does not complete these steps. See [packaging](packaging/README.md) to package an already verified app without rebuilding it.

Use your actual signing identity and existing notarization profile. Keep credentials out of the repository.

## Source archive

The website’s source download is a `git archive` of one reviewed commit, so anyone can reproduce and check it.

1. Commit the finished source. Build the app from that commit and run the checks in [CONTRIBUTING.md](CONTRIBUTING.md) before archiving.
2. From the repository root, with `<commit>` being that commit:

   ```sh
   TZ=UTC git archive --format=zip --prefix=Siga-source/ --output=website/downloads/siga-source-preview.zip <commit>
   shasum -a 256 website/downloads/siga-source-preview.zip
   git archive --format=tar --prefix=Siga-source/ <commit> | shasum -a 256
   unzip -z website/downloads/siga-source-preview.zip   # prints the archived commit
   git --version
   ```

   `TZ=UTC` takes the time zone out of the ZIP’s hash. ZIP entries store file times in local time, so without it the hash depends on the time zone of whoever runs the command; the tar has no such dependence. Both hashes also assume git’s default settings (`core.autocrlf` changes line endings in both archives, and `tar.umask` changes the tar’s file modes), and another git version may compress the ZIP differently, so the record names the git version used. If only the ZIP hash differs, the comparison in step 3 shows whether its files are the same.

3. Check the ZIP against a tar of the same commit, confirm the brief and the ZIP itself are absent in any letter case, and build the app from the extracted source. Run the commands in zsh or bash from the root of the checkout that holds `brand/prompts.md`. They stop at the first failed check, and remove the extracted copies either way:

   ```sh
   check=$(mktemp -d)
   (
     set -e -o pipefail
     mkdir "$check/zip" "$check/tar"
     unzip -q website/downloads/siga-source-preview.zip -d "$check/zip"
     git archive --format=tar --prefix=Siga-source/ <commit> | tar -x -C "$check/tar"
     diff -r "$check/zip" "$check/tar"
     echo "same files"
     named=$(find "$check" -ipath '*/brand/prompts*' -o -ipath '*/website/downloads/*.zip')
     test -z "$named"
     grep -E '.{40,}' brand/prompts.md > "$check/brief-lines"
     found=0; grep -rlF -f "$check/brief-lines" "$check/zip" "$check/tar" || found=$?
     test "$found" = 1
     echo "no brief, no nested ZIP"
     cd "$check/zip/Siga-source"
     ./build.sh
     shasum -a 256 Siga.app/Contents/MacOS/Siga
   )
   checked=$?
   rm -rf "$check"
   test "$checked" = 0 && echo "archive checked"
   ```

   The content check fails closed: `grep` exits 1 only when it read the brief’s lines and found none of them in the archive, so a missing brief, a brief with no line of 40 or more characters, or an archived copy of one of those lines each stops the commands. Like the greps before the first push, it finds only an unchanged line of the brief, anywhere in a file, including inside a longer line. The guard’s push scan also reads the same commit’s files as UTF-16 and UTF-32 text and inside ZIP, tar, gzip, bzip2 and xz data, and catches near copies. Neither finds a copy in base64, rot13, or another deliberate encoding.

4. Record the commit, the git version, the ZIP and tar SHA-256 values, the app’s SHA-256 printed in step 3, and the build number under **Release record** in a follow-up commit that changes only this file. The archive is made from `<commit>`, which the follow-up commit does not change, so the recorded hashes stay valid. The ZIP itself is ignored by git and copied in when the website is deployed.

## Historical source-preview release record

Build 12, version 0.1, archived 2026-09-14 with git 2.50.1 (Apple Git-155) and git’s default settings.

- Commit `20a805c08726c52f5ac5fd8436f7c29e3939b1f4`.
- `website/downloads/siga-source-preview.zip`, made with `TZ=UTC` as in step 2: SHA-256 `6b721f206ab3cee024536d35c24ba2f0a6d0653c6b16f80c990671dd07b15a61`. `unzip -z` prints the commit.
- `git archive --format=tar --prefix=Siga-source/ 20a805c08726c52f5ac5fd8436f7c29e3939b1f4`: SHA-256 `59db00ab951b62e83ad78618b8e8fe51055a363da0ac12ff1085f5f84a99fbae`. The ZIP unpacks to the same files.
- `./build.sh` in the extracted archive produced `Siga.app/Contents/MacOS/Siga` with SHA-256 `04e5487db0eb3b92110bb2c0ffeb6ea30a8437e8d17a19522d4172578fae11c9` (CFBundleVersion 12, ad-hoc development signature), byte-identical to the build from the working tree.
- Signed and notarized `Siga.zip`: not produced yet. It needs the Developer ID Application identity and notarization profile described above.

## Check the artifact

Download the final DMG through the website. Open it in Finder and confirm the branded window contains Sigá and an Applications shortcut; the shortcut must point to `/Applications`. Check the bundled app's signature, stapled ticket, and executable hash against the verified input app. Both website download buttons must serve the same verified DMG.

For future builds, test installation and first launch from the exact disk image in a clean, authorized macOS test environment. Restore the clean environment for repeat first-run and Login Items checks. The isolated preview does not validate real macOS permission dialogs. Check actual speaker and headphone behavior separately on a physical Mac, including saved settings and restoration after interruption, Restore, Disable, Quit, and device changes. Check behavior after restarting with Sigá added to Login Items. For build 18, the owner accepted the direct installation and live-use result and waived the remaining clean Mini and login checks as recorded above.

Generate a checksum:

```sh
shasum -a 256 Siga.dmg
```

The build 18 DMG and checksum are already attached to the GitHub release. Keep the website and README links pointed at that verified artifact.

## Website

The website is plain HTML and CSS with one small optional script and local assets. It can be hosted as static files; it does not require a server framework, a package install, an API key, or a database. See [website/README.md](website/README.md).

## Release notes

Sigá keeps your music playing while you dictate. It gently lowers the volume and brings it back afterward. This release is for Apple Silicon Macs and macOS 14.2 or later. Choose Willow or superwhisper in setup, or add the app you use with Use another app…. The app makes no network requests and has no third-party runtime dependencies.

Keep compatibility claims limited to what has been implemented and tested. Document any remaining limitations before publishing.

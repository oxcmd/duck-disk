# Release checklist

Run through this list before publishing a build. Duck Disk moves people's files, so the steps that touch the Trash matter most. Use a test user account or a folder of copies, never your only copy of anything.

## 1. Prepare the build

- [ ] Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`.
- [ ] `swift build --product DuckDiskChecks && ./.build/debug/DuckDiskChecks` passes.
- [ ] `scripts/package-app.sh --dmg` finishes. For a public build, the log says "Signing with Developer ID Application" and "Notarizing", and `spctl -a -vv "dist/Duck Disk.app"` says "accepted".
- [ ] Mount the disk image, drag the app to Applications, and open it from there.

## 2. First launch

- [ ] The app opens without a Gatekeeper warning (notarized builds only).
- [ ] The sidebar shows the duck logo; clicking every room switches the content and highlights the row.
- [ ] Settings opens with ⌘, and each tab shows its controls.
- [ ] Switching Appearance between Light, Dark and Match System restyles the window.

## 3. Scanning

- [ ] Without Full Disk Access, scanning Macintosh HD shows the macOS permission prompts and continues after each answer.
- [ ] With Full Disk Access, a full scan finishes and the summary line shows files, time and free space.
- [ ] Stop (⌘.) during a scan returns to the start screen.
- [ ] Choosing another drive or folder while a scan is running, or while it says "Working out what can go", shows only the new target's results.
- [ ] A folder added under Settings → "Never scan these folders" is missing from Space after a rescan.

- [ ] Quit and reopen the app: Find searches the saved index before any scan and says when it was made.
- [ ] Space → Treemap: rectangles match the folder sizes, Size/Files/Age and Depth −/+ change the picture, double-click opens a folder, the breadcrumb goes back.
- [ ] Cleanup lists local AI models (if any) under "AI models", unselected.

## 4. Clearing to the Trash

- [ ] Overview: the centre total changes as categories are ticked and unticked.
- [ ] Overview: "Move … to Trash" shows the confirmation list; Cancel changes nothing.
- [ ] After confirming, the items are in the Trash and Finder's "Put Back" restores them.
- [ ] The banner says "Done. … is in the Trash", and the totals and Space sizes drop by the same amount.
- [ ] Cleanup: un-ticking single items changes the footer total; trashing from Cleanup updates Overview.
- [ ] Space and Find: "Move to Trash…" from the right-click menu and from the inspector works, and the item disappears from both rooms.
- [ ] Protected items are refused: try `~/Library`, `~/Pictures/Photos Library.photoslibrary`, `/Applications/Safari.app`. The menu item is disabled or the sheet says it will be skipped.
- [ ] Activity lists each cleanup with its size.

## 5. Duplicates

- [ ] Make two copies of a large file (Finder → Duplicate, which makes a clone, and `cp` in Terminal, which makes a real copy). After a scan, the clone is labelled "Clone" and only the real copy can be ticked.
- [ ] The row marked Keep has no "Move to Trash…" item, and the inspector's button is disabled for it.
- [ ] "Keep This" on another copy moves the Keep badge.
- [ ] Trash the kept copy from Finder, rescan: another copy becomes Keep, and one copy always stays.

## 6. Applications

- [ ] The list finishes measuring and is sorted by total size.
- [ ] A helper app whose bundle name repeats another app's name (for example Claude Code URL Handler next to Claude) does not list that app's data folders.
- [ ] Uninstall a small test app that is running: the app asks to quit it first, then the app and its data are in the Trash.
- [ ] Apple apps cannot be uninstalled.
- [ ] Clear Cache on a running app asks to quit it first, then moves only caches to the Trash; the app keeps its settings and stays signed in.
- [ ] Reset Web Data warns about signing out, then moves the app's cookies and website storage to the Trash.
- [ ] If an app refuses to quit (for example with unsaved work), nothing is moved and Duck Disk says so.

## 7. Monitor

- [ ] CPU, memory, processes and ports update every second; battery shows on laptops and "no battery" on desktops.
- [ ] Quitting a process from Top processes or Listening ports asks for confirmation first.

## 8. Compress

- [ ] A large JPEG and a large video compress; the footer shows the space saved.
- [ ] With "Replace originals" on, the original is in the Trash and the compressed file has the original's name.
- [ ] With it off, a "(compressed)" copy sits next to the original.
- [ ] RAW, PSD, GIF and TIFF files cannot be added.
- [ ] Leaving the room during a long video and coming back shows the job still running.

## 9. Publish

- [ ] Commit, tag `vX.Y.Z`, push the tag.
- [ ] `gh release create vX.Y.Z dist/DuckDisk-X.Y.Z.dmg` with notes on what changed. Mark it as a pre-release until the build is notarized.

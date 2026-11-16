# KoDrop documentation

This page describes how KoDrop behaves. See the [README](README.md) for installation.

## Overview

KoDrop is a KOReader plugin. It runs a small HTTP server inside KOReader and serves a file manager page. Any browser on the same Wi-Fi network can open `http://<kindle-ip>:<port>` to browse, upload, download, rename, move and delete files on the Kindle.

The server runs inside KOReader's main loop, so you can keep reading while it's on. It works without internet access. Only "Check for update" goes online.

## The KOReader menu

The menu is under Settings → Network → KoDrop. The KoDrop entry itself shows a checkmark while the server is running.

| Item | What it does |
|---|---|
| Run server | Starts or stops the server. Ticked while running. Asks to turn on Wi-Fi if it's off. |
| Address line | Shows `http://<ip>:<port>` while running. Tap it to show the IP/port popup again. |
| Show QR code | Shows the address as a QR code. |
| Port | Listening port, 1024 to 65535. Default 3636. |
| Root folder | The top folder the browser can see. Default `/mnt/us`. |
| PIN | Optional 4-digit PIN. Leave it empty to remove it. |
| Auto-stop | Stops the server after N idle minutes. Default 15. 0 disables it. |
| Check for update (version) | Looks for a newer release on GitHub and installs it. |

Changing the port, root folder or PIN restarts the server if it's running. Changing auto-stop takes effect immediately without a restart.

Settings are stored in `koreader/settings/kodrop.lua`.

## Starting and stopping

When the server starts, KoDrop:

1. Opens the port in the Kindle firewall (Kindle only):
   ```
   iptables -A INPUT  -p tcp --dport <port> -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
   iptables -A OUTPUT -p tcp --sport <port> -m conntrack --ctstate ESTABLISHED -j ACCEPT
   ```
   It deletes any copy of these rules first, so a crash never leaves duplicates.
2. Stops the device from sleeping. It pauses KOReader's auto-suspend and standby, and on Kindle runs `lipc-set-prop com.lab126.powerd preventScreenSaver 1`.
3. Pauses KOReader's "Auto-disable Wi-Fi" idle check, which would otherwise turn Wi-Fi off while no browser is talking to the Kindle.
4. Shows a popup with the IP, port and full address.

When the server stops, all of this is undone. The `preventScreenSaver` setting is left on if the KeepAlive plugin is active.

The server stops when:

- you untick Run server;
- nothing has happened for the auto-stop time and no connection is open (KOReader shows a message);
- the device suspends, because Wi-Fi goes down anyway;
- KOReader exits or restarts;
- you install an update.

Switching between the file browser and a book does not stop it.

## The web page

The page is a single HTML file with no external resources. It follows the browser's light or dark theme.

### Browsing

- The bar at the top shows the current path. Tap any part to jump there.
- The ← button goes back in history and ↑ goes to the parent folder. The browser's own back button works too, because the folder is kept in the URL (`#/documents`).
- Each row shows an icon, the name, the size (files only) and the modification date.
- Tap a folder name to open it. Tap a file name, or the ⋮ button on any row, to get the actions: Download (files), Open (folders), Rename, Move and Delete.

These are never listed:

- names starting with `.`, which includes in-progress `.part` uploads;
- folders ending in `.sdr` (KOReader's per-book metadata);
- the KOReader folder, unless it is inside the chosen root;
- symlinks that point outside the root;
- anything that isn't a regular file or folder.

### Uploading

- Drag files from the desktop anywhere on the page to upload them into the current folder.
- Drop files on a folder row or a path segment to upload into that folder instead.
- On phones, tap Upload and pick one or more files.

Files upload one at a time, each with its own progress bar at the bottom of the page. A finished upload disappears from the list. A failed one stays with the error message; tap it to dismiss it.

### Moving

- Drag a row onto a folder row or a path segment.
- Or use ⋮ → Move, which opens a folder picker. Browse to the target folder and tap "Move here".

If several rows are checked and you drag one of them, all checked items move.

### Selecting several items

Tick row checkboxes and "Move (n)" and "Delete (n)" buttons appear in the top bar.

### PIN

If a PIN is set, the page asks for it before showing anything. After the right PIN the browser gets a session cookie, valid until the server stops. All browsers share the same session. After 5 wrong PINs, login is blocked for 60 seconds.

## What happens to files

### Paths

Every path the browser sends is relative to the root folder: `/documents` means `<root>/documents`. A browser cannot reach outside the root:

- paths containing `..` are rejected;
- a path that resolves, through a symlink, to somewhere outside the root is rejected;
- the root folder itself cannot be renamed, moved or deleted;
- the KOReader folder (`/mnt/us/koreader` on Kindle) is off limits unless you choose it, or a folder inside it, as the root.

### Uploads

- The data is streamed to disk in 64 KB pieces, so file size isn't limited by memory.
- A file is written as `<name>.part` and renamed to `<name>` when it's complete. If the connection drops, the upload fails, or the server stops mid-upload, the `.part` file is deleted.
- An existing file is never overwritten. A second `book.epub` is saved as `book (1).epub`, then `book (2).epub`, and so on.
- Only the base name of the uploaded file is used. Any folder part is dropped and control characters are removed. Names that are empty, `.`, `..` or longer than 255 bytes are rejected.
- If the disk fills up, the upload fails with "Write failed (storage full?)" and the partial file is deleted.

### Renaming, moving and deleting

These update KOReader's own records the way its file manager does:

- Renaming or moving a book: its `.sdr` folder (reading position, highlights, notes) moves with it, and history and collections point to the new path.
- Deleting a book: its `.sdr` folder is deleted and it is removed from history and collections.
- Deleting a folder: it is deleted with everything inside, and history and collections are updated.

Other rules:

- A move or rename never replaces an existing item; it fails with "Already exists".
- A folder can't be moved into itself.
- Moving an item into the folder it's already in does nothing.
- For several items, the operation goes in order and stops at the first error. Items handled before the error stay moved or deleted.

### KOReader's file browser

If KOReader's file browser is showing a folder that changed, it refreshes about one second after the last change. A batch of uploads causes one refresh.

## HTTP API

Everything the page does goes through this API, so you can script it, for example with `curl`.

General rules:

- Responses are JSON, except `GET /` (the page) and downloads.
- Errors are `{"error": "message"}` with a matching status code.
- Every POST needs a header `X-KoDrop` (any value). Browsers can't add a custom header to a request from another website without permission from the Kindle, which KoDrop never gives, so other sites you visit can't send commands to it.
- If a PIN is set, every `/api/` request except `/api/login` needs the `kodrop` session cookie.
- Each response closes the connection (HTTP/1.0, `Connection: close`) and is sent with `Cache-Control: no-store`.

### Endpoints

`GET /api/ls?path=/documents`

Lists a folder. Folders come first, then files, sorted by name ignoring case. `mtime` is a Unix timestamp.

```json
{"path": "/documents", "entries": [{"name": "a.epub", "dir": false, "size": 1048576, "mtime": 1731700000}]}
```

`GET /api/dl?path=/documents/a.epub`

Downloads a file as `application/octet-stream`, with a `Content-Disposition` header that keeps non-ASCII names.

`POST /api/upload?path=/documents`

Body: `multipart/form-data` with one or more file fields. Fields without a file name are ignored. `Content-Length` is required. The response lists the names the files were saved as, after any renaming:

```json
{"ok": true, "saved": ["a.epub", "a (1).epub"]}
```

`POST /api/mkdir`, body `{"path": "/documents/new folder"}`

Creates one folder. The parent must exist.

`POST /api/rename`, body `{"path": "/documents/a.epub", "name": "b.epub"}`

Renames inside the same folder. `name` is a name, not a path.

`POST /api/move`, body `{"paths": ["/a.epub", "/comics"], "dest": "/documents"}`

Moves the items into `dest`.

`POST /api/delete`, body `{"paths": ["/a.epub", "/old"]}`

Deletes files and folders. Folders are deleted with their contents.

`POST /api/login`, body `{"pin": "1234"}`

Returns `{"ok": true}` and sets the cookie `kodrop=<token>; Path=/; HttpOnly; SameSite=Strict`. Without a PIN configured it always succeeds and sets no cookie.

### Status codes

| Code | When |
|---|---|
| 400 | Invalid path, JSON, name or multipart body; too many headers; upload ended early; moving a folder into itself |
| 401 | PIN required, or wrong PIN |
| 403 | Path outside the root or inside the KOReader folder; missing `X-KoDrop` header; trying to change the root folder; file can't be opened |
| 404 | Path doesn't exist, wrong type (file vs folder), or unknown endpoint |
| 409 | The target name already exists |
| 411 | Upload without `Content-Length` |
| 413 | JSON body over 64 KB |
| 429 | Too many wrong PINs; wait 60 seconds |
| 500 | The file system refused the operation |
| 507 | Write failed during an upload, usually a full disk |

### Limits

- Request line and header lines: 8 KB each, at most 64 headers.
- A connection with no data moving for 60 seconds is dropped.
- JSON bodies: 64 KB.
- Uploads: no size limit beyond free space.

### Examples

```
curl 'http://192.168.1.50:3636/api/ls?path=/documents'
curl -OJ 'http://192.168.1.50:3636/api/dl?path=/documents/a.epub'
curl -H 'X-KoDrop: 1' -F file=@book.epub 'http://192.168.1.50:3636/api/upload?path=/documents'
curl -H 'X-KoDrop: 1' -d '{"paths":["/documents/a.epub"]}' http://192.168.1.50:3636/api/delete
```

With a PIN:

```
curl -c jar -H 'X-KoDrop: 1' -d '{"pin":"1234"}' http://192.168.1.50:3636/api/login
curl -b jar 'http://192.168.1.50:3636/api/ls?path=/'
```

## Updates

Check for update asks the GitHub API for the latest release:

- If its tag equals the installed version, KoDrop says it's up to date. Builds installed from source report version `dev` and are always offered the update.
- Otherwise it asks before installing. Installing:
  1. stops the server;
  2. downloads `kodrop.koplugin.zip`;
  3. unpacks it next to the plugin as `kodrop.koplugin.new`;
  4. checks that `main.lua` is present;
  5. swaps the folders.

If any step fails, the installed plugin is left as it was. After a successful update, KOReader asks to restart.

Releases are built automatically on every push to the default branch, with versions `v1.0.1`, `v1.0.2`, and so on.

## Performance

The server never blocks KOReader. It checks the network every 20 ms while a connection is open and every 250 ms otherwise, and does at most 50 ms of work per check. Pages and menus stay usable during a transfer, though large uploads make the device slower to respond than usual.

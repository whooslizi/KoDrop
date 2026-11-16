# KoDrop

KOReader plugin that serves a small file manager over Wi-Fi. Start it on the Kindle and open `http://<kindle-ip>:3636` in a browser on the same network to upload, download, rename, move and delete files. No app needed on the other device.

Pure Lua, using only what KOReader ships (LuaSocket, lfs, ffi, json).

## Install

1. Download `kodrop.koplugin.zip` from the [latest release](../../releases/latest) and unzip it.
2. Over USB, copy the `kodrop.koplugin` folder to `/mnt/us/koreader/plugins/` (`koreader/plugins/` on the USB drive).
3. Eject the Kindle and restart KOReader.

To update later, use Settings → Network → KoDrop → Check for update. It downloads the latest release from GitHub, replaces the plugin folder and asks to restart KOReader.

## Usage

1. In KOReader, go to Settings → Network → KoDrop → Run server. KOReader asks to turn Wi-Fi on if it's off.
2. A popup shows the Kindle's IP, port and address. Type the address into a browser, or use Settings → Network → KoDrop → Show QR code.
3. In the browser:
   - Drag files onto the page to upload them, or tap Upload. Dropping files on a folder row uploads into that folder.
   - Drag a row onto a folder or a breadcrumb to move it.
   - The ⋮ button on each row has Download, Rename, Move and Delete.
   - Use the checkboxes to move or delete several items.
4. Untick Run server when you're done. The server also stops after 15 idle minutes, on suspend, and when KOReader exits.

While the server runs, the Kindle doesn't auto-suspend and KOReader doesn't turn Wi-Fi off.

### Settings

| Setting | Default | Notes |
|---|---|---|
| Port | 3636 | 1024 to 65535 |
| Root folder | `/mnt/us` | Nothing outside it is visible |
| PIN | none | 4 digits, asked once per server start |
| Auto-stop | 15 min | 0 disables it |

Stored in `koreader/settings/kodrop.lua`.

### Paths and files

- Paths are relative to the root folder. `..` and symlinks leading outside the root are rejected.
- `/mnt/us/koreader` is hidden unless you pick it (or a folder inside it) as the root.
- Uploads go to `name.part` and are renamed when complete, so an interrupted upload leaves nothing behind. Existing files are never overwritten; a duplicate becomes `name (1).epub`.
- Moving, renaming or deleting a book also updates KOReader's history, collections and `.sdr` reading progress.

## Troubleshooting

### The page doesn't load

- Both devices must be on the same network. Guest networks and routers with AP/client isolation block devices from reaching each other; turn isolation off or use the main network.
- With a phone hotspot, connect the Kindle to it and open the address on that phone.
- Use `http://`. If the browser forces https, allow http for this address.

### Firewall

The Kindle firewall drops incoming connections, so KoDrop adds these rules on start (the same ones KOReader's SSH plugin uses) and removes them with `-D` on stop:

```
iptables -A INPUT  -p tcp --dport 3636 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
iptables -A OUTPUT -p tcp --sport 3636 -m conntrack --ctstate ESTABLISHED -j ACCEPT
```

If KOReader crashes while running, the rules stay until reboot or the next start. Check with `iptables -L INPUT -n | grep 3636` over SSH.

### Wi-Fi drops or the server stops

Wi-Fi goes off when the Kindle sleeps, so KoDrop stops on suspend. Don't press the power button during a transfer. If it stops on its own, raise Auto-stop or set it to 0.

### "Write failed (storage full?)"

The Kindle is out of space.

### Wrong IP or no IP

Use the IPv4 address under Network → Network info in KOReader.

## HTTP API

Responses are JSON; errors are `{"error": "..."}` with a matching status code. POST requests need the header `X-KoDrop: 1`. Paths are relative to the root folder.

| Request | Body | Response |
|---|---|---|
| `GET /api/ls?path=/documents` | | `{path, entries:[{name, dir, size, mtime}]}` |
| `GET /api/dl?path=/documents/a.epub` | | the file |
| `POST /api/upload?path=/documents` | `multipart/form-data` | `{ok, saved:[names]}` |
| `POST /api/mkdir` | `{"path": "/documents/new"}` | `{ok}` |
| `POST /api/rename` | `{"path": "/documents/a.epub", "name": "b.epub"}` | `{ok}` |
| `POST /api/move` | `{"paths": ["/a.epub"], "dest": "/documents"}` | `{ok}` |
| `POST /api/delete` | `{"paths": ["/a.epub"]}` | `{ok}` |
| `POST /api/login` | `{"pin": "1234"}` | sets the session cookie |

```
curl -H 'X-KoDrop: 1' -F file=@book.epub 'http://192.168.1.50:3636/api/upload?path=/documents'
```

## Development

Run the tests with `luajit spec/kodrop_spec.lua`. Each push to the default branch runs them and publishes a release.

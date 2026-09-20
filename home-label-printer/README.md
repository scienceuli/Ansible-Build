# Homebox label printing (Bluetooth, home-side)

Homebox runs on `dirac` (remote server) but the Niimbot D110 label printer is
Bluetooth-only and lives at home. The bridge:

```
Homebox (dirac) --writes--> /opt/docker/homebox/labels/label.png
      |
      v
homebox-label-watcher (dirac, systemd) --publishes--> Mosquitto (dirac, TLS+auth, mqtt.sam-projekte.de:8883)
                                                              |
                                                              v
                                          subscriber.py (this directory, runs at home)
                                                              |
                                                              v
                                          NiimPrintX (Bluetooth, via `bleak`) --> D110 printer
```

Everything left of Mosquitto is already deployed by `playbooks/homebox/playbook.yml`
(see `roles/mosquitto`, `roles/label_watcher`). Everything in this directory
runs on your own machine (Mac, Raspberry Pi, or other Linux) - it is **not**
managed by Ansible.

## Connection details

- Broker: `mqtt.sam-projekte.de:8883` (TLS)
- Topic: `homebox/labels`
- User: `homebox`
- Password: `vault_mosquitto_password` in `inventories/dirac/host_vars/dirac/vault.yml`
  (`ansible-vault view inventories/dirac/host_vars/dirac/vault.yml` to read it)

## What's here

- `subscriber.py` - connects to MQTT, and on every received label image shells
  out to NiimPrintX to print it
- `.env.example` - copy to `.env` and fill in the password
- `systemd/` - example unit for running persistently on a Pi/Linux box
- `launchd/` - example plist for running persistently on a Mac

## Printer library: NiimPrintX

We use [labbots/NiimPrintX](https://github.com/labbots/NiimPrintX), a fork
with explicit D110 support and cross-platform Bluetooth via
[`bleak`](https://github.com/hbldh/bleak) (works on Linux/macOS/Windows
without RFCOMM pairing quirks). It isn't published on PyPI - install it from
source via Poetry, as below.

**If your printer is a D110_M** (2024 hardware revision - check the case,
ours says `D110_M`): the base NiimPrintX prints entirely blank labels on this
model (confirmed, see "Known issues" below). The setup steps pull in a
two-file patch from [Eamo5/NiimPrintX](https://github.com/Eamo5/NiimPrintX)
that fixes it - everything else (Poetry env, `bleak` pin) stays from the
base clone.

## Setup: Raspberry Pi / other Linux

```sh
sudo apt update
sudo apt install -y python3 python3-pip pipx imagemagick bluetooth bluez \
    libcairo2-dev libgirepository1.0-dev pkg-config git

pipx install poetry
pipx ensurepath   # log out/in (or `exec $SHELL`) so poetry is on PATH

git clone https://github.com/labbots/NiimPrintX.git ~/NiimPrintX
cd ~/NiimPrintX
poetry install
poetry add paho-mqtt

# NiimPrintX's own bluetooth.py uses BLEDevice.metadata, which bleak
# deprecated in 0.20.0 and fully removed in 1.0.0. NiimPrintX's pyproject.toml
# pins "bleak = ^1.0.0" anyway, so a fresh install breaks with:
#   'BLEDevice' object has no attribute 'metadata'
# Pin an older bleak that still has it:
poetry add "bleak<1.0.0"

# D110_M only: patch in the fix for blank prints (see "Known issues" below).
# Skip this if you have a plain (non-_M) D110.
curl -sL https://raw.githubusercontent.com/Eamo5/NiimPrintX/main/NiimPrintX/cli/command.py -o NiimPrintX/cli/command.py
curl -sL https://raw.githubusercontent.com/Eamo5/NiimPrintX/main/NiimPrintX/nimmy/printer.py -o NiimPrintX/nimmy/printer.py

# Pair the printer once (BlueZ needs this even though bleak talks BLE directly
# afterwards):
bluetoothctl
#   scan on
#   [wait for the D110 to appear, note its MAC]
#   pair <MAC>
#   trust <MAC>
#   exit

cp /path/to/this/repo/home-label-printer/subscriber.py ~/NiimPrintX/subscriber.py
cp /path/to/this/repo/home-label-printer/.env.example ~/NiimPrintX/.env
# edit ~/NiimPrintX/.env, fill in LABEL_MQTT_PASSWORD
# (set LABEL_PRINTER_MODEL=d110_m in .env if you patched for D110_M above)

# Sanity check the printer is reachable before wiring up the full pipeline
# (use -m d110_m if you patched above, otherwise -m d110):
poetry run python -m NiimPrintX.cli info -m d110_m
```

If that `info` command finds the printer, install the persistent service:

```sh
sudo cp systemd/homebox-label-subscriber.service.example \
    /etc/systemd/system/homebox-label-subscriber.service
# edit paths/User in the unit if your username/checkout path differ
sudo systemctl daemon-reload
sudo systemctl enable --now homebox-label-subscriber
```

## Setup: macOS

```sh
brew install python@3.12 imagemagick libffi glib gobject-introspection cairo pkg-config pipx git
pipx install poetry
pipx ensurepath

git clone https://github.com/labbots/NiimPrintX.git ~/NiimPrintX
cd ~/NiimPrintX

export PKG_CONFIG_PATH="/usr/local/opt/libffi/lib/pkgconfig"
export LDFLAGS="-L/usr/local/opt/libffi/lib"
export CFLAGS="-I/usr/local/opt/libffi/include"
poetry install
poetry add paho-mqtt

# See the note in the Linux section above - NiimPrintX needs an older bleak
# than the one its pyproject.toml pins, or `info`/`print` fail with:
#   'BLEDevice' object has no attribute 'metadata'
poetry add "bleak<1.0.0"

# D110_M only: patch in the fix for blank prints (see "Known issues" below).
# Skip this if you have a plain (non-_M) D110.
curl -sL https://raw.githubusercontent.com/Eamo5/NiimPrintX/main/NiimPrintX/cli/command.py -o NiimPrintX/cli/command.py
curl -sL https://raw.githubusercontent.com/Eamo5/NiimPrintX/main/NiimPrintX/nimmy/printer.py -o NiimPrintX/nimmy/printer.py

cp /path/to/this/repo/home-label-printer/subscriber.py ~/NiimPrintX/subscriber.py
cp /path/to/this/repo/home-label-printer/.env.example ~/NiimPrintX/.env
# edit ~/NiimPrintX/.env, fill in LABEL_MQTT_PASSWORD
# (set LABEL_PRINTER_MODEL=d110_m in .env if you patched for D110_M above)
```

Pair the D110 the normal macOS way first: **System Settings > Bluetooth**,
put the printer in pairing mode, pair it there. `bleak` talks to macOS via
CoreBluetooth once paired - no manual MAC-address config needed.

```sh
# use -m d110_m if you patched above, otherwise -m d110
poetry run python -m NiimPrintX.cli info -m d110_m
```

If that finds the printer, install the persistent agent:

```sh
mkdir -p ~/Library/Logs
cp launchd/com.homebox.label-subscriber.plist.example \
    ~/Library/LaunchAgents/com.homebox.label-subscriber.plist
# edit USERNAME placeholders and LABEL_MQTT_PASSWORD in the plist
launchctl load ~/Library/LaunchAgents/com.homebox.label-subscriber.plist
```

## Testing end-to-end

Trigger a print from the Homebox UI (or manually touch a file) and watch the
subscriber's output/logs. To test the MQTT leg alone without the printer:

```sh
mosquitto_pub -h mqtt.sam-projekte.de -p 8883 -u homebox -P '<password>' \
    -t homebox/labels -f /path/to/some.png
```

## Known issues

- **`bleak<1.0.0` pin required** - see the `poetry add` step in both setup
  sections above. Without it, `info`/`print` fail with
  `'BLEDevice' object has no attribute 'metadata'`, since NiimPrintX's own
  code uses a `bleak` attribute that was removed in `bleak` 1.0.0, despite
  NiimPrintX's `pyproject.toml` pinning `bleak = "^1.0.0"`.
- **D110_M prints entirely blank labels** with base NiimPrintX's `-m d110`
  path, even for a solid black test image - confirmed, and confirmed to be a
  known upstream issue, not anything printer/paper-related (a printer
  self-test print works fine). Root cause: the D110_M needs a different
  Bluetooth print protocol sequence than the plain D110
  ([confirmed by the author of a competing Niimbot library](https://github.com/labbots/NiimPrintX/issues/32)
  - it's protocol-compatible with the B1, not the D110). NiimPrintX has an
  unmerged fix for this for B1
  ([PR #6](https://github.com/labbots/NiimPrintX/pull/6)), and
  [Eamo5/NiimPrintX](https://github.com/Eamo5/NiimPrintX) extends that same
  fix to add a `d110_m` model choice. The `curl` steps above pull in just
  those two changed files (`cli/command.py`, `nimmy/printer.py`) on top of
  the base clone. **Fixed and confirmed working** with `-m d110_m`.
- **Image width limit**: NiimPrintX asserts the (post-rotation) image width
  is `<= 240px` for D110/D110_M. Homebox renders labels at 320x96 (landscape,
  per the `HBOX_LABEL_MAKER_WIDTH`/`HEIGHT` vars in
  `inventories/dirac/host_vars/dirac/vars.yml`), so it must be rotated 90°
  before printing (320x96 -> 96x320, well under the limit). `subscriber.py`
  does this automatically via `LABEL_PRINTER_ROTATE` (default `90`) - if you
  change Homebox's label dimensions, you may need to revisit this.
- Confirmed working end-to-end (MQTT -> subscriber -> NiimPrintX -> D110_M
  print), tested on macOS.

## Things to verify when moving to a Raspberry Pi

- BlueZ pairing/trust behaves a bit differently from macOS's CoreBluetooth
  path - if `info -m d110_m` doesn't find the printer after `bluetoothctl pair`
  + `trust`, try re-running the scan/pair cycle once more; BlueZ can be flaky
  on first pairing.
- Bluetooth range: the printer needs to be within BLE range of whichever
  machine runs `subscriber.py`. If that's a problem, an ESP32 Bluetooth proxy
  (as used in the original Home-Assistant-based guide this setup replaces)
  is one way to extend range - not set up here.

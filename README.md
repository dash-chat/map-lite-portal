# map-lite-portal

Captive portal webapp for a MikroTik mAP lite, plus the tooling to provision
one over wifi.

- `portal/` — the webapp: a small Svelte 5 + Vite package that builds to
  five static pages served directly by the router's hotspot from its flash
  storage. `login.html` is what people see when they join the wifi; its
  **Connect** button logs them in through RouterOS's passwordless *trial*
  method (no user accounts).
- `router/portal-setup.rsc.tpl` — idempotent RouterOS script that creates the
  hotspot (rendered and imported by `just provision`).
- `justfile` — all tooling: `just` lists the recipes, `just provision` points
  at a powered-on mAP lite and does everything.

## Requirements

- `nix develop` shell (provides `just`, `openssh`, `sshpass`, `node` and
  `pnpm`).
- NetworkManager (`nmcli`) on this machine, used to join the device's wifi.
  Not needed with `skip_wifi=1`.
- A mAP lite that is powered on with its wifi network in range, running
  RouterOS with the legacy `/interface wireless` stack (stock firmware on the
  mAP lite, both v6 and v7).

## Usage

`just` lists all recipes. The main ones, in the order you'll meet them:

Device already configured with these credentials — installs/updates the
portal only:

```sh
just provision dash-portal 'secret123' 'adminpass'
```

Factory-fresh device (open wifi named `MikroTik-XXXXXX`, empty admin
password) — the last three arguments are the credentials to reach it *now*;
the device ends up with the first three:

```sh
just provision dash-portal 'secret123' 'adminpass' MikroTik-ABCDEF '' ''
```

Iterating on the webapp — rebuilds and re-uploads it, nothing else:

```sh
just upload 'adminpass'
```

Other recipes: `just dev` (portal dev server), `just check` (svelte-check),
`just cli 'adminpass'` (RouterOS shell on the device). Options go in front as
variable overrides: `just skip_wifi=1 provision …` if this machine already
reaches the router (e.g. over ethernet), `just router_ip=10.5.50.1 upload …`
if the device doesn't use the default `192.168.88.1`.

## What `just provision` does

1. Joins the device's wifi with `nmcli` and finds the router (the wifi
   gateway, falling back to `192.168.88.1`).
2. Logs in as `admin` over ssh, trying the given password and the
   factory-default empty one.
3. Builds the webapp and uploads `portal/dist` to `flash/portal` (that's
   `just upload`; flash so the pages survive reboots — the mAP lite's root
   filesystem is a ramdisk).
4. Imports the rendered `portal-setup.rsc`, which creates a hotspot server on
   the LAN interface with `html-directory=flash/portal` and trial login
   (`trial-uptime-limit=0s` = unlimited sessions). The existing DHCP server
   and addressing from the default configuration are left untouched.
5. Sets the admin password and wifi SSID/WPA2 key to the given values if they
   differ (credentials go last, so a dropped wifi link can't interrupt the
   setup; the script then reconnects with the new credentials).
6. Verifies the hotspot is active.

The provisioning machine's MAC is added as a *bypassed* hotspot ip-binding
(comment `map-lite-portal:host-bypass`) so the hotspot can never cut off
management access mid-setup. This also means **this machine never sees the
portal** — test from a phone, or remove the binding from `just cli`:

```
/ip hotspot ip-binding remove [find where comment="map-lite-portal:host-bypass"]
```

## Customizing the portal

The webapp lives in `portal/`:

```
portal/
  login.html … error.html   HTML entry shells — RouterOS $(...) variables live here
  src/types.ts              typed contract between the shells and the app
  src/main.ts               reads the variables, mounts the app
  src/App.svelte            picks the page component
  src/pages/*.svelte        one component per hotspot page
  src/portal.css            shared styles
```

The app is TypeScript; `just check` runs `svelte-check` over it. Edit the
Svelte components and re-run `just upload`. For live preview, `just dev` and
open e.g. `http://localhost:5173/login.html` — sample values are substituted
for the hotspot variables in dev mode.

RouterOS only substitutes `$(...)` variables in the HTML it serves, never in
JS bundles, so the entry shells pass them to the app through a
`window.__HOTSPOT__` object (plus a hidden `#hotspot-error` element, which
keeps arbitrary error text out of a JS string). If a page needs another
variable, add it to the shell's `__HOTSPOT__` and read it from the component.
The variables used here:

| Variable | Meaning |
| --- | --- |
| `$(identity)` | Router identity (`/system identity`) |
| `$(error)` | Login error message, inside `$(if error) … $(endif)` |
| `$(link-login-only)` | Login endpoint; the Connect button posts the trial user `T-$(mac-esc)` to it |
| `$(link-orig-esc)` | Originally requested URL |
| `$(link-redirect)`, `$(link-logout)`, `$(link-login)` | Post-login redirect, logout and login URLs |
| `$(ip)`, `$(uptime)`, `$(bytes-in-nice)`, `$(bytes-out-nice)` | Session info on `status.html` |

The build (`portal/dist`) is five HTML shells plus `assets/main.js` and
`assets/style.css`, with stable file names so re-provisioning simply
overwrites them. Everything must fit the mAP lite's 16 MB flash, of which
only a few MB are free — keep an eye on bundle size when adding dependencies
(the current build is ~35 kB).

Captive-portal detection works because phones probe well-known plain-HTTP
URLs on join; the hotspot intercepts the probe and the OS pops up
`login.html`. HTTPS pages can't be redirected — that's inherent to captive
portals, not a bug in this setup.

## Troubleshooting

- **"wifi network not found"** — the mAP lite takes ~1 min to boot. For a
  factory reset, hold the reset button while powering on until the LED
  flashes, then release.
- **Login page shows "no more sessions are allowed"** — your RouterOS build
  may not treat `trial-uptime-limit=0s` as unlimited; set a large limit
  instead: `/ip hotspot profile set map-lite-portal trial-uptime-limit=30d`.
- **Portal doesn't appear on your laptop** — it's probably the provisioning
  host, which is bypassed (see above).
- **ssh host-key warnings** — the script pins nothing
  (`StrictHostKeyChecking=no`) because every device has a different key;
  it's meant for a trusted local link.

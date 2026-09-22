# Ukraine Air Alert — Noctalia bar widget

Port of the idea behind [Gnome-UkraineAlert-Plugin](https://github.com/coolerUA/Gnome-UkraineAlert-Plugin)
to Noctalia's v5+ Luau plugin system. Shows a green shield when your chosen
region is clear, a yellow outline triangle for a **yellow** (threat warning)
alert and a filled red badge for a **red** (air raid) alert, polling
api.ukrainealarm.com or the public AJAX status API.

**Watching more than one region?** Region selection is a *per-widget-instance*
setting, not a plugin-wide one — add the widget to the bar again
(Settings → Bar → add widget → Ukraine Air Alert) and pick a different region
in that instance's own settings. Each instance gets its own dropdown; no IDs
to look up.

## Install

The plugin lives at
[github.com/coolerUA/Noctalia-UkraineAlert-Plugin](https://github.com/coolerUA/Noctalia-UkraineAlert-Plugin)
and installs as a git plugin source — no manual copying needed.

**From the CLI:**

```bash
noctalia msg plugins source add ukrainealarm git https://github.com/coolerUA/Noctalia-UkraineAlert-Plugin
noctalia msg plugins enable coolerUA/ukrainealarm
```

**From the settings GUI:**

1. Open **Settings → Plugins → Add source**.
2. Add a git source pointing at
   `https://github.com/coolerUA/Noctalia-UkraineAlert-Plugin`.
3. Find **Ukraine Air Alert** in the discovered plugin list and toggle it on.
4. Add the widget to a bar section from **Settings → Bar**.

Enabling from a git source exports the plugin into Noctalia's own
materialized-plugins state dir, so nothing needs to be checked out by hand.
Updates are pulled with:

```bash
noctalia msg plugins update ukrainealarm
```

or via the source's **Update** action in Settings → Plugins (enable
`auto_update` there for a background pull on every startup).

### Local development instead

If you're hacking on the plugin itself rather than just using it, a path
source skips git entirely and points straight at your working copy:

```bash
noctalia msg plugins source add ukrainealarm-dev path ~/dev/Noctalia-UkraineAlert-Plugin
noctalia msg plugins enable coolerUA/ukrainealarm
```

or place the checkout under `~/.local/share/noctalia/plugins/ukrainealarm/`,
which Noctalia auto-discovers as a built-in local source.

## Configure

Two settings live in the plugin's own settings (gear icon on its row in
Settings → Plugins) and apply to **every** instance of the widget:

- **API token** — leave empty to use the free public AJAX status API. Fill
  it in (request via the form on [api.ukrainealarm.com](https://api.ukrainealarm.com))
  to use that API instead, which supports finer raion/community-level
  regions instead of just oblasts.
- **Refresh interval** — defaults to 30s; floored at 15s with no token
  (public API rate limit) or 10s with one.
- **Primary output** — optional. Only relevant on a multi-monitor setup
  where you place this widget on more than one bar (e.g. a mirrored bar
  layout). Set it to one output's connector name (`eDP-1`, `HDMI-A-1`,
  etc. — check with `hyprctl monitors` / `niri msg outputs` / your
  compositor's equivalent) and only the instance running on that output
  will actually poll the API; every other instance for the *same region*
  just mirrors its last result instead of polling independently. Leave
  empty (the default) for the old behavior where every instance fetches on
  its own.
  - If you'd rather a secondary monitor not show this widget **at all**
    instead of mirroring, that's a Noctalia bar setting, not this plugin —
    give that monitor a `[bar.<name>.monitor.<match>]` override with its
    own `start`/`center`/`end` list that omits this widget. See
    [Noctalia's bar docs](https://docs.noctalia.dev/noctalia/bar/#per-monitor-overrides).

Which region *this instance* watches is set per widget instance — right-click
the bar badge (or find it under the widget's own settings where you added it
in Settings → Bar):

- **No token set** → **Region (public API)**: a dropdown of all 28 supported
  oblasts/cities. Add the widget again and pick a different one to watch a
  second region.
- **Token set** → **Region ID (ukrainealarm.com)**: free text, since that API
  has no fixed enumerable list without a key. Get it via
  `GET https://api.ukrainealarm.com/api/v3/regions` with your token.
- **Alert scope (public API only)** — the public API's response for an
  oblast also lists alerts declared for districts/communities *inside* it.
  **Whole region only** (default) ignores those and lights up only for an
  alert covering the picked region itself. **Include districts** counts them
  too, so the badge reacts when any part of the region is under alert (for
  frontline oblasts that can mean it's red most of the time).

## Behavior

- Left click: force an immediate refresh (still subject to the public API's
  rate limit when no token is set — see below).
- Right click: open the plugin's settings.
- Two alert levels, as reported by both APIs:
  - **Red** — air raid alert (sirens), take shelter. Filled red triangle with
    a `!` badge.
  - **Yellow** — threat warning / pre-alert, be ready. Yellow outline
    triangle, no badge text.
  - Alerts the API reports without a level (artillery, urban fights, …) count
    as red; informational `INFO`/`CUSTOM` messages without a level count as
    yellow. When several alerts overlap, the worst level wins.
  - The tooltip lists the level, the alert count, the alert types and (with a
    token) the reason text the API attaches to the level.
- A notification fires on every transition between clear, yellow and red —
  including yellow → red escalations and red → yellow downgrades.
- Unconfigured (no region picked yet) shows a gear glyph instead of erroring.

## Notes / things you may want to change

- The public API's ~1 request/15s rate limit is enforced via
  `noctalia.state`, which is shared across every instance of this widget
  (each instance is its own isolated script, so a plain Lua variable
  wouldn't coordinate between them). Watching several public-API regions
  therefore means each instance's badge updates roughly once every
  `15s × number of public-API instances`, since they take turns through the
  shared limit rather than all polling every 15s.
- The public API's region *picker* only offers oblast granularity — 24
  oblasts plus Kyiv/Zaporizhzhia/Kharkiv city and Crimea — though its
  response does include district-level alerts inside the picked oblast (see
  **Alert scope** above). ukrainealarm.com lets you watch a raion or
  community directly if you need finer than that.
- `plugin_api = 12` is set conservatively; bump it in `plugin.toml` (and the
  matching row in the repo's `catalog.toml`) if you add features from a
  newer API level later.

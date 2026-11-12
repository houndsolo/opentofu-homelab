"""The desktop's "Sailor Mars" OLED palette for the generated Grafana dashboards.

Grafana (13.x) only ships its built-in dark theme, and custom themes or CSS are not
an option, so this themes what dashboard JSON controls: field colors (fixed,
thresholds, value mappings, overrides), legacy panel colors and graph styles.
custom.py and update.py run every dashboard through apply_theme() just before they
write it, so builders may keep Grafana's color names ("green", "orange", ...) and
the pass turns them into palette colors by meaning:

    green -> OK, yellow -> WARN, orange -> WARN_HIGH, red -> ERROR, blue -> INFO,
    purple -> ACCENT3, text -> TEXT; dark-/semi-dark-/light-/super-light- variants
    are derived from the same palette color; "transparent" stays.

Hex/rgb(a) colors of vendored dashboards map the same way: Grafana's named-color
hex values exactly, anything else by hue (cyan -> ACCENT2, magenta/pink -> ACCENT,
greys -> the muted text colors) and lightness (-> variant), keeping any alpha.
The accent pink never means error; ERROR is the palette's red.

Series: a time series/pie panel on palette-classic whose 2-10 queries each return
one series, with no color overrides yet, gets one palette series color per query
(byFrameRefID, in SERIES order); a single such query gets ACCENT2. Queries that
return many series (legends with {{label}}, `sum by`, Flux) keep palette-classic,
which Grafana can't recolor. Lines are thin (1-2 px) and filled areas fade out
(gradientMode "opacity", capped fill opacity).

The pass is idempotent: every color it produces maps to itself.
Source of the palette: mon-ha/theme/palette.json (Quickshell Theme.qml + pywal).
"""
import colorsys
import re

# --- palette --------------------------------------------------------------------

BACKGROUND = "#010304"
SURFACE = "#0c0f0f"
SURFACE_VARIANT = "#181b1a"
BORDER = "#1c2027"
TEXT = "#e5f3e2"
TEXT_MUTED = "#a0aa9e"
ACCENT = "#F70997"   # hot pink
ACCENT2 = "#21E2D7"  # cyan
ACCENT3 = "#9932cc"  # violet glow
OK = "#02E5A8"       # mint
WARN = "#ffd27a"
ERROR = "#ff6188"
INFO = "#6870ff"
SERIES = ["#F70997", "#21E2D7", "#02E5A8", "#9932cc", "#6870ff", "#ffd27a", "#C9499C", "#ff6188", "#8f95ff",
          "#D0D9C4"]
SELECTION = "#4a1640"
GRAFANA_BG = "#111217"  # Grafana's dark theme canvas (for previews only)


def _rgb(color):
    c = color.lstrip("#")
    if len(c) == 3:
        c = "".join(ch * 2 for ch in c)
    return tuple(int(c[i:i + 2], 16) for i in (0, 2, 4))


def _hex(rgb):
    return "#" + "".join(f"{max(0, min(255, round(v))):02x}" for v in rgb)


def mix(a, b, f):
    """a blended f (0..1) of the way towards b."""
    return _hex(x + (y - x) * f for x, y in zip(_rgb(a), _rgb(b)))


def _hls(h, l, s):
    return _hex(v * 255 for v in colorsys.hls_to_rgb(h / 360, l, s))


# Grafana's "orange" sits between warning and error: WARN turned towards red (hue 40 -> 28).
WARN_HIGH = _hls(28, 0.66, 1.0)
MUTED_DIM = mix(TEXT_MUTED, BACKGROUND, 0.4)  # disabled/unknown states (Grafana's greys)

# Variants: darker ones blend into the background, lighter ones into the text color.
SHADE = {"deep": 0.6, "dark-": 0.4, "semi-dark-": 0.2}
TINT = {"light-": 0.3, "super-light-": 0.55}
VARIANTS = ("super-light-", "light-", "", "semi-dark-", "dark-")
FAMILIES = {"green": OK, "yellow": WARN, "orange": WARN_HIGH, "red": ERROR, "blue": INFO, "purple": ACCENT3,
            "cyan": ACCENT2, "pink": ACCENT}
SPECIAL = {("blue", "light-"): SERIES[8]}  # the palette's own light indigo


def variant(family, prefix=""):
    base = FAMILIES[family]
    if (family, prefix) in SPECIAL:
        return SPECIAL[(family, prefix)]
    if prefix in SHADE:
        return mix(base, BACKGROUND, SHADE[prefix])
    if prefix in TINT:
        return mix(base, TEXT, TINT[prefix])
    return base


NAMED = {f"{p}{fam}": variant(fam, p) for fam in ("green", "yellow", "orange", "red", "blue", "purple")
         for p in VARIANTS}
NAMED["text"] = TEXT

# Grafana's named colors as hex (what vendored dashboards and old pickers store).
GRAFANA_HEX = {
    "red": ("#FFA6B0", "#FF7383", "#F2495C", "#E02F44", "#C4162A"),
    "orange": ("#FFCB7D", "#FFB357", "#FF9830", "#FF780A", "#FA6400"),
    "yellow": ("#FFF899", "#FFEE52", "#FADE2A", "#F2CC0C", "#E0B400"),
    "green": ("#C8F2C2", "#96D98D", "#73BF69", "#56A64B", "#37872D"),
    "blue": ("#C0D8FF", "#8AB8FF", "#5794F2", "#3274D9", "#1F60C4"),
    "purple": ("#DEB6F2", "#CA95E5", "#B877D9", "#A352CC", "#8F3BB8"),
}
HEX_NAMES = {h.lower(): f"{p}{fam}" for fam, hexes in GRAFANA_HEX.items() for p, h in zip(VARIANTS, hexes)}

# Every color the pass produces; these are left alone (idempotence, and colors builders set on purpose).
OUTPUTS = {c.lower() for c in [BACKGROUND, SURFACE, SURFACE_VARIANT, BORDER, TEXT, TEXT_MUTED, MUTED_DIM, ACCENT,
                               ACCENT2, ACCENT3, OK, WARN, WARN_HIGH, ERROR, INFO, SELECTION, *SERIES,
                               *(variant(f, p) for f in FAMILIES for p in (*VARIANTS, "deep"))]}
OUTPUT_RGB = {_rgb(c) for c in OUTPUTS}

_HEX_RE = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")
_RGB_RE = re.compile(r"^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([0-9.]+)\s*)?\)$")


def _by_hue(rgb):
    """Palette color for an arbitrary color: family by hue, variant by lightness."""
    h, l, s = colorsys.rgb_to_hls(*(v / 255 for v in rgb))
    h *= 360
    if s < 0.12 or (l < 0.12 or l > 0.95):
        return SURFACE_VARIANT if l < 0.2 else MUTED_DIM if l < 0.55 else TEXT_MUTED if l < 0.8 else TEXT
    # Grafana's and the old classic palette's reds sit at 350-10 degrees; redder pinks are series colors.
    family = ("red" if h < 15 or h >= 350 else "orange" if h < 40 else "yellow" if h < 70 else
              "green" if h < 165 else "cyan" if h < 200 else "blue" if h < 250 else "purple" if h < 290 else "pink")
    # Lightness picks the variant, so a dark or pale source color stays dark or pale.
    prefix = ("deep" if l < 0.18 else "dark-" if l < 0.28 else "semi-dark-" if l < 0.36 else "" if l < 0.7 else
              "light-" if l < 0.82 else "super-light-")
    return variant(family, prefix)


def color(value):
    """The palette color for a Grafana color value; anything else is returned unchanged."""
    if not isinstance(value, str):
        return value
    v = value.strip()
    low = v.lower()
    if low in OUTPUTS or low == "transparent":
        return value
    if low in NAMED:
        return NAMED[low]
    if _HEX_RE.match(v):
        return NAMED[HEX_NAMES[low]] if low in HEX_NAMES else _by_hue(_rgb(v))
    m = _RGB_RE.match(low)
    if m:
        rgb = tuple(int(x) for x in m.group(1, 2, 3))
        alpha = float(m.group(4)) if m.group(4) is not None else 1.0
        if rgb in OUTPUT_RGB:
            return value
        hx = _hex(rgb)
        new = NAMED[HEX_NAMES[hx]] if hx in HEX_NAMES else _by_hue(rgb)
        if alpha >= 1:
            return new
        r, g, b = _rgb(new)
        return f"rgba({r}, {g}, {b}, {alpha:g})"
    return value


# --- the pass ---------------------------------------------------------------------

COLOR_KEYS = {"color", "fixedColor", "iconColor", "fillColor", "lineColor", "cardColor"}
COLOR_DICTS = {"aliasColors", "colors"}  # {series/state: color}


def _recolor(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, str):
                # "fill" is a color only in the heatmap's color options ({mode, fill, scheme, ...}).
                if k in COLOR_KEYS or (k == "fill" and "scheme" in node):
                    node[k] = color(v)
            elif k == "colors" and isinstance(v, list):
                node[k] = [color(c) for c in v]
            elif k in COLOR_DICTS and isinstance(v, dict) and all(isinstance(c, str) for c in v.values()):
                node[k] = {name: color(c) for name, c in v.items()}
            else:
                _recolor(v)
    elif isinstance(node, list):
        for v in node:
            _recolor(v)


def _panels(dash):
    for p in dash.get("panels", []):
        yield p
        yield from p.get("panels", [])  # collapsed rows


AGGREGATION = re.compile(r"^\s*\(*\s*(sum|count|avg|max|min|vector|scalar)\s*\(")
GROUPING = re.compile(r"\b(by|without)\s*\(")


def single_series(target):
    """True when a query surely returns one series (a fixed legend, or a top-level aggregation
    without by/without). Flux and anything unclear count as many."""
    expr = target.get("expr")
    if not isinstance(expr, str):
        return False
    legend = target.get("legendFormat") or ""
    if legend and legend != "__auto":
        return "{{" not in legend
    return bool(AGGREGATION.match(expr)) and not GROUPING.search(expr) and "group_" not in expr


def _has_color_override(panel):
    return any(p.get("id") == "color" for o in panel.get("fieldConfig", {}).get("overrides", [])
               for p in o.get("properties", []))


def _series_colors(panel):
    if panel.get("type") not in ("timeseries", "piechart"):
        return
    fc = panel.setdefault("fieldConfig", {})
    defaults = fc.setdefault("defaults", {})
    mode = defaults.get("color", {}).get("mode", "palette-classic")
    targets = [t for t in panel.get("targets", []) if not t.get("hide")]
    if (mode != "palette-classic" or _has_color_override(panel) or not 1 <= len(targets) <= len(SERIES)
            or not all(single_series(t) and t.get("refId") for t in targets)):
        return
    if len(targets) == 1:
        if panel["type"] == "timeseries":
            defaults["color"] = {"mode": "fixed", "fixedColor": ACCENT2}
        return
    fc.setdefault("overrides", []).extend(
        {"matcher": {"id": "byFrameRefID", "options": t["refId"]},
         "properties": [{"id": "color", "value": {"mode": "fixed", "fixedColor": SERIES[i]}}]}
        for i, t in enumerate(targets))


def _single_stat(panel):
    # Fixed color without a color: Grafana would pick its own; use the cyan accent.
    if panel.get("type") in ("stat", "gauge", "bargauge", "timeseries"):
        c = panel.get("fieldConfig", {}).get("defaults", {}).get("color")
        if isinstance(c, dict) and c.get("mode") == "fixed" and not c.get("fixedColor"):
            c["fixedColor"] = ACCENT2


UNSTACKED_FILL, STACKED_FILL = 25, 50


def _graph_style(panel):
    if panel.get("type") != "timeseries":
        return
    custom = panel.get("fieldConfig", {}).get("defaults", {}).get("custom")
    if not isinstance(custom, dict) or custom.get("drawStyle", "line") != "line":
        return
    lw = custom.get("lineWidth")
    if isinstance(lw, (int, float)) and lw > 2:
        custom["lineWidth"] = 2
    fill = custom.get("fillOpacity")
    if isinstance(fill, (int, float)) and fill > 0:
        stacked = custom.get("stacking", {}).get("mode", "none") not in ("none", None)
        custom["fillOpacity"] = min(fill, STACKED_FILL if stacked else UNSTACKED_FILL)
        if custom.get("gradientMode", "none") == "none":
            custom["gradientMode"] = "opacity"


def apply_theme(dash):
    """Theme a dashboard dict in place (and return it)."""
    _recolor(dash)
    for panel in _panels(dash):
        _single_stat(panel)
        _series_colors(panel)
        _graph_style(panel)
    return dash


# --- Categories ----------------------------------------------------------------
# Every dashboard also gets a "lylat-<folder>" tag from its provisioning folder (the first
# component of its path, e.g. Storage/ceph-osd.json -> lylat-storage), so a dashboards link can
# list one folder. The overview shows one dropdown per category, in this order.
CATEGORIES = ("Proxmox", "Storage", "Hosts", "Network", "Edge", "Services", "Databases", "Probes", "Logs", "Monitoring")


def category_tag(folder):
    return f"lylat-{folder.lower()}"


def categorize(dash, rel):
    """Add the category tag of the dashboard's folder (in place; returns it)."""
    folder = rel.split("/")[0]
    dash["tags"] = sorted(set(dash.get("tags", [])) | {category_tag(folder)})
    return dash


def category_links():
    """One dashboards dropdown per category (the overview's header)."""
    return [{"type": "dashboards", "tags": [category_tag(c)], "asDropdown": True, "title": c,
             "includeVars": False, "keepTime": True, "icon": "external link", "targetBlank": False,
             "tooltip": "", "url": ""} for c in CATEGORIES]

"""dark-triage helpdesk dashboard, built by custom.py (imported there).

Ticket data comes straight from the app's Postgres database on the Patroni cluster through the
read-only datasource uid "triage" (role triage_grafana: tickets, comments and the non-secret user
columns; see roots/monitoring-config/postgres.tf postgres_app_grafana_grants). App health comes
from the blackbox HTTP probe of /api/health (host "dark-triage", Prometheus).

The app stores timestamps as ISO-8601 text, hence the ::timestamptz casts. It records no
"resolved at" time, so "resolved" uses the last update of a ticket that is Resolved now.
"""
from custom import (DS, Board, ERROR, OK, WARN_HIGH, bargauge, cell, dashboard, mapping, override,
                    piechart, q, stat, steps, table, text, timeseries)
from theme import ACCENT, ACCENT2, INFO, TEXT_MUTED, WARN

TRIAGE = {"type": "grafana-postgresql-datasource", "uid": "triage"}
APP = "http://dark-triage.lylat.space"
OPEN = "status <> 'Resolved'"
PRIO_ORDER = "CASE t.priority WHEN 'Critical' THEN 0 WHEN 'High' THEN 1 WHEN 'Medium' THEN 2 ELSE 3 END"
PRIO_COLORS = {"Critical": ERROR, "High": WARN_HIGH, "Medium": WARN, "Low": TEXT_MUTED}
STATUS_COLORS = {"Open": TEXT_MUTED, "In progress": ACCENT2, "Waiting": WARN, "Resolved": OK}
COUNT = steps((INFO, None))
ATTENTION = steps((OK, None), (WARN_HIGH, 1), (ERROR, 5))
AGE = steps((OK, None), (WARN, 7 * 86400), (ERROR, 30 * 86400))


def sql(raw, fmt="table"):
    return {"datasource": dict(TRIAGE), "rawSql": " ".join(raw.split()), "format": fmt,
            "rawQuery": True, "editorMode": "code"}


def one(raw):
    """A single-number stat query."""
    return sql(raw)


def counts(names, column, where=OPEN):
    """One row, one column per value: bar gauges and pies keep a fixed order and colours."""
    cols = ", ".join(f"count(*) FILTER (WHERE {column} = '{n}') AS \"{n}\"" for n in names)
    return sql(f"SELECT {cols} FROM tickets WHERE {where}")


def fixed_colors(colors):
    return [override(name, {"color": {"mode": "fixed", "fixedColor": c}}) for name, c in colors.items()]


def per_row(panel):
    """Bar gauge over table rows (dynamic names: services, people)."""
    panel["options"]["reduceOptions"] = {"values": True, "calcs": [], "fields": ""}
    return panel


def text_colors(colors):
    return mapping(**{name: (name, c) for name, c in colors.items()})


TICKET_COLS = f"""
  'DT-' || lpad(t.id::text, 3, '0') AS "Ticket", t.title AS "Subject", t.type AS "Type",
  t.priority AS "Priority", t.status AS "Status", t.service AS "Service",
  coalesce(r.display_name, t.requester) AS "Requested by",
  coalesce(a.display_name, 'Unassigned') AS "Assignee",
  extract(epoch FROM now() - t.created::timestamptz) AS "Age",
  t.updated::timestamptz AS "Updated"
FROM tickets t LEFT JOIN users r ON r.id = t.requester_id LEFT JOIN users a ON a.id = t.assignee_id"""

TICKET_TABLE_OVERRIDES = [
    override("Ticket", {"links": [{"title": "Open ${__value.raw} in dark-triage", "url": f"{APP}/#${{__value.raw}}",
                                   "targetBlank": True}], "custom.width": 90}),
    override("Subject", {"custom.width": 520}),
    override("Priority", {"mappings": text_colors(PRIO_COLORS)}), cell("Priority", "color-text"),
    override("Status", {"mappings": text_colors(STATUS_COLORS)}), cell("Status", "color-text"),
    override("Age", {"unit": "dtdurations", "decimals": 0}),
    override("Updated", {"unit": "dateTimeFromNow"}),
]


def triage():
    b = Board()
    b.row("Now")
    b.add(stat("Open", [one(f"SELECT count(*) FROM tickets WHERE {OPEN}")], thresholds=COUNT,
               desc="Tickets that aren't Resolved."), 3, 4)
    b.add(stat("In progress", [one("SELECT count(*) FROM tickets WHERE status = 'In progress'")],
               thresholds=steps((ACCENT2, None))), 3, 4)
    b.add(stat("Waiting", [one("SELECT count(*) FROM tickets WHERE status = 'Waiting'")],
               thresholds=steps((WARN, None))), 3, 4)
    b.add(stat("Needs attention", [one(f"SELECT count(*) FROM tickets WHERE {OPEN} AND priority IN ('High', 'Critical')")],
               thresholds=ATTENTION, desc="Open tickets with priority High or Critical."), 3, 4)
    b.add(stat("Unassigned", [one(f"SELECT count(*) FROM tickets WHERE {OPEN} AND assignee_id IS NULL")],
               thresholds=steps((OK, None), (WARN, 1)), desc="Open tickets nobody is assigned to."), 3, 4)
    b.add(stat("Resolved, 7 days", [one("SELECT count(*) FROM tickets WHERE status = 'Resolved' "
                                        "AND updated::timestamptz > now() - interval '7 days'")],
               thresholds=steps((OK, None)), desc="Resolved tickets last updated in the past 7 days."), 3, 4)
    b.add(stat("Oldest open", [one(f"SELECT extract(epoch FROM now() - min(created::timestamptz)) FROM tickets WHERE {OPEN}")],
               unit="dtdurations", decimals=0, thresholds=AGE, color_mode="value", no_value="none open"), 3, 4)
    b.add(stat("App", [q('probe_success{job="blackbox-http_2xx", host="dark-triage"}', instant=True)],
               mappings=mapping(**{"0": ("DOWN", ERROR), "1": ("UP", OK)}), thresholds=steps((ERROR, None), (OK, 1)),
               no_value="no probe", desc="Blackbox probe of /api/health: 200 only when the app reaches its "
                                         "database (Patroni VIP 10.13.11.104)."), 3, 4)

    b.row("Open queue")
    b.add(bargauge("By priority", [counts(PRIO_COLORS, "priority")], overrides=fixed_colors(PRIO_COLORS),
                   thresholds=COUNT, decimals=0, mode="gradient"), 6, 7)
    b.add(bargauge("By status", [counts(["Open", "In progress", "Waiting"], "status")],
                   overrides=fixed_colors({k: v for k, v in STATUS_COLORS.items() if k != "Resolved"}),
                   thresholds=COUNT, decimals=0, mode="gradient"), 6, 7)
    b.add(per_row(bargauge("By service", [sql(f"""SELECT service AS "Service", count(*) AS "Open"
        FROM tickets WHERE {OPEN} GROUP BY 1 ORDER BY 2 DESC, 1""")], thresholds=steps((ACCENT, None)),
        decimals=0, mode="gradient")), 6, 7)
    b.add(per_row(bargauge("By assignee", [sql(f"""SELECT coalesce(a.display_name, 'Unassigned') AS "Assignee",
        count(*) AS "Open" FROM tickets t LEFT JOIN users a ON a.id = t.assignee_id WHERE t.{OPEN}
        GROUP BY 1 ORDER BY 2 DESC, 1""")], thresholds=steps((ACCENT2, None)), decimals=0, mode="gradient")), 6, 7)

    b.add(table("Open tickets", [sql(f"SELECT {TICKET_COLS} WHERE t.{OPEN} ORDER BY {PRIO_ORDER}, t.created")],
                overrides=TICKET_TABLE_OVERRIDES,
                desc="Every open ticket, most urgent first, then oldest. Click a ticket number to open it in "
                     "dark-triage."), 24, 10)

    b.row("Flow")
    b.add(timeseries("Created and resolved per day", [
        sql("""SELECT $__timeGroupAlias(created::timestamptz, '1d', 0), count(*) AS "Created"
               FROM tickets WHERE $__timeFilter(created::timestamptz) GROUP BY 1 ORDER BY 1""", "time_series"),
        sql("""SELECT $__timeGroupAlias(updated::timestamptz, '1d', 0), count(*) AS "Resolved"
               FROM tickets WHERE status = 'Resolved' AND $__timeFilter(updated::timestamptz)
               GROUP BY 1 ORDER BY 1""", "time_series")],
        draw="bars", fill=70, decimals=0, calcs=("sum", "max"),
        overrides=fixed_colors({"Created": ACCENT, "Resolved": OK}),
        desc="Resolved = the last update of tickets that are Resolved now (the app keeps no resolve time)."), 12, 8)
    b.add(timeseries("Open backlog", [sql("""SELECT d AS time, (SELECT count(*) FROM tickets t
            WHERE t.created::timestamptz <= d + interval '1 day'
              AND NOT (t.status = 'Resolved' AND t.updated::timestamptz <= d + interval '1 day')) AS "Open"
          FROM generate_series(date_trunc('day', $__timeFrom()::timestamptz), $__timeTo()::timestamptz,
                               interval '1 day') AS d ORDER BY 1""", "time_series")],
        fill=20, line=2, decimals=0, calcs=("min", "max", "lastNotNull"), step=True,
        overrides=fixed_colors({"Open": ACCENT}),
        desc="Tickets open at the end of each day (same Resolved approximation)."), 12, 8)
    b.add(timeseries("Updates per day", [sql("""SELECT $__timeGroupAlias(c.created::timestamptz, '1d', 0),
            count(*) FILTER (WHERE c.kind = 'comment' AND coalesce(u.is_bot, 0) = 0) AS "People",
            count(*) FILTER (WHERE c.kind = 'comment' AND u.is_bot = 1) AS "Bots",
            count(*) FILTER (WHERE c.kind = 'system') AS "Activity"
          FROM comments c LEFT JOIN users u ON u.id = c.author_id
          WHERE $__timeFilter(c.created::timestamptz) GROUP BY 1 ORDER BY 1""", "time_series")],
        draw="bars", fill=70, stack=True, decimals=0, calcs=("sum",),
        overrides=fixed_colors({"People": ACCENT, "Bots": ACCENT2, "Activity": TEXT_MUTED}),
        desc="Comments by people and by bots (claude, qwen), and activity lines (assignment changes)."), 12, 8)
    b.add(piechart("Created by type", [sql("""SELECT count(*) FILTER (WHERE type = 'Issue') AS "Issue",
            count(*) FILTER (WHERE type = 'Request') AS "Request", count(*) FILTER (WHERE type = 'Change') AS "Change"
          FROM tickets WHERE $__timeFilter(created::timestamptz)""")],
        overrides=fixed_colors({"Issue": ACCENT, "Request": ACCENT2, "Change": INFO}),
        desc="Tickets created in the selected time range."), 6, 8)
    b.add(per_row(bargauge("Opened by", [sql("""SELECT coalesce(r.display_name, t.requester) AS "Requester",
            count(*) AS "Tickets" FROM tickets t LEFT JOIN users r ON r.id = t.requester_id
          WHERE $__timeFilter(t.created::timestamptz) GROUP BY 1 ORDER BY 2 DESC, 1""")],
        thresholds=steps((ACCENT, None)), decimals=0, mode="gradient",
        desc="Tickets created in the selected time range, per requester (bots included).")), 6, 8)

    b.row("Recently resolved")
    b.add(table("Resolved in the time range", [sql(f"""SELECT {TICKET_COLS}
            WHERE t.status = 'Resolved' AND $__timeFilter(t.updated::timestamptz) ORDER BY t.updated DESC""")],
                overrides=TICKET_TABLE_OVERRIDES + [override("Age", {"displayName": "Open for (until last update)"})],
                desc="Age here is creation to now; the app keeps no resolve time."), 24, 8)
    b.add(text("About", f"Data: dark-triage's Postgres database (read-only role `triage_grafana`). "
                        f"App: [{APP}]({APP}). Bots file tickets with `dt` (claude) and `lylat-triage` (qwen)."), 24, 2)

    return finish(dashboard("dark-triage", "dark-triage helpdesk",
                            "dark-triage tickets: open queue, priorities, assignment, flow and app health.",
                            b, tags=["dark-triage", "services"], time_from="now-30d"))


def finish(dash):
    """Panels whose targets are SQL use the dark-triage Postgres datasource."""
    def walk(panels):
        for p in panels:
            yield p
            yield from walk(p.get("panels", []))
    for p in walk(dash["panels"]):
        targets = p.get("targets", [])
        if targets and all("rawSql" in t for t in targets):
            p["datasource"] = dict(TRIAGE)
    return dash


DASHBOARDS = {"Services/dark-triage.json": triage}

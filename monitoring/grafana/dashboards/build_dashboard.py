#!/usr/bin/env python3
"""
Builds the Grafana dashboard JSON.

Kept as a generator rather than a hand-written JSON file for three reasons:
the file is over 1000 lines and hand-editing it is how dashboards end up with
a broken panel nobody notices; the panels share config (units, thresholds,
datasource) that would otherwise be copy-pasted sixteen times and drift apart;
and the result is deterministic, so regenerating produces no git diff unless
something genuinely changed.

Run from the repository root:
    python3 monitoring/grafana/dashboards/build_dashboard.py
"""

import json
import pathlib

DS = {"type": "prometheus", "uid": "prometheus"}

# Thresholds in one place so the same resource always warns (amber) and fails
# (red) at the same numbers on every panel. Fixed hex rather than named colours
# because Grafana's named palette changes between releases.
AMBER = "rgba(237, 129, 40, 1)"
RED = "rgba(245, 54, 54, 1)"
GREEN = "rgba(50, 172, 45, 1)"

REDUCER = {
    "datasource": DS,
    "reducer": "lastNotNull",
    "fields": "",
}


def target(expr, legend, ref="A", instant=False):
    """A Prometheus query target."""
    t = {
        "datasource": DS,
        "editorMode": "code",
        "expr": expr,
        "legendFormat": legend,
        "range": not instant,
        "refId": ref,
    }
    if instant:
        t["instant"] = True
        t["range"] = False
    return t


def thresholds(steps):
    return {
        "mode": "absolute",
        "steps": steps,
    }


def steps(*pairs):
    return [{"color": c, "value": v} for c, v in pairs]


def pct_thresholds(warn, crit):
    """Memory/disk style panels: the base state is green, then amber, then red."""
    return thresholds(steps((GREEN, None), (AMBER, warn), (RED, crit)))


def inverted_thresholds(warn, crit):
    """Free-space style panels: green above, then amber, then red as it falls."""
    return thresholds(steps((RED, None), (AMBER, warn), (GREEN, crit)))


def stat(pid, title, expr, legend, unit, th, x, y, w, h, decimals=1, text_mode="auto"):
    return {
        "id": pid,
        "type": "stat",
        "title": title,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [target(expr, legend, instant=True)],
        "options": {
            "reduceOptions": REDUCER,
            "orientation": "auto",
            "textMode": text_mode,
            "colorMode": "value",
            "graphMode": "area",
            "justifyMode": "auto",
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "decimals": decimals,
                "thresholds": th,
                "mappings": [],
                # Sparkline behind the number: one glance says whether the value
                # is trending the right way or just happens to be high right now.
                "custom": {},
            },
            "overrides": [],
        },
    }


def timeseries(pid, title, targets, unit, x, y, w, h, th=None, desc="", stack=False,
               legend_calcs=("mean", "max"), minv=None, maxv=None):
    panel = {
        "id": pid,
        "type": "timeseries",
        "title": title,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "description": desc,
        "targets": targets,
        "options": {
            "legend": {
                "displayMode": "table",
                "placement": "bottom",
                "calcs": list(legend_calcs),
                "showLegend": True,
            },
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "min": minv,
                "max": maxv,
                "thresholds": th or thresholds(steps((GREEN, None))),
                "mappings": [],
                "custom": {
                    # A visible line only: on a 1 GB box this dashboard is read
                    # on a laptop, and a fill per series turns four overlapping
                    # areas into an unreadable blob.
                    "drawStyle": "line",
                    "lineWidth": 2,
                    "fillOpacity": 0,
                    "gradientMode": "none",
                    "showPoints": "never",
                    "pointSize": 5,
                    "spanNulls": False,
                    "stacking": {"mode": "normal" if stack else "none", "group": "A"},
                    "axisBorderShow": False,
                    "axisCenteredZero": False,
                    "axisColorMode": "text",
                    "axisLabel": "",
                    "scaleDistribution": {"type": "linear"},
                    "thresholdsStyle": {"mode": "off"},
                },
            },
            "overrides": [],
        },
    }
    return panel


def gauge(pid, title, targets, unit, x, y, w, h, th, desc=""):
    return {
        "id": pid,
        "type": "gauge",
        "title": title,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "description": desc,
        "targets": targets,
        "options": {
            "reduceOptions": REDUCER,
            "orientation": "auto",
            "showThresholdLabels": False,
            "showThresholdMarkers": True,
            "minVizHeight": 75,
            "minVizWidth": 75,
        },
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "thresholds": th,
                "mappings": [],
            },
            "overrides": [],
        },
    }


def row(pid, title, y):
    return {"id": pid, "type": "row", "title": title, "collapsed": False,
            "gridPos": {"x": 0, "y": y, "w": 24, "h": 1}, "panels": []}


panels = []

# ---------------------------------------------------------------- host summary
panels += [
    stat(1, "Uptime",
         "node_time_seconds - node_boot_time_seconds", "uptime",
         "s", thresholds(steps((GREEN, None))), 0, 0, 4, 4, decimals=0),

    stat(2, "CPU busy",
         '100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)',
         "cpu", "percent",
         pct_thresholds(70, 90), 4, 0, 4, 4),

    stat(3, "Memory used",
         "100 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes * 100)",
         "mem", "percent",
         pct_thresholds(80, 92), 8, 0, 4, 4),

    stat(4, "Disk used",
         '100 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100)',
         "disk", "percent",
         pct_thresholds(80, 92), 12, 0, 4, 4),

    stat(5, "Load (15m)",
         "node_load15", "load", "short",
         pct_thresholds(1.5, 3.0), 16, 0, 4, 4),

    stat(6, "Targets up",
         'sum(up)', "up", "short",
         inverted_thresholds(2.5, 1.5), 20, 0, 4, 4, decimals=0),

    row(7, "Host", 4),

    timeseries(8, "CPU by mode",
               [target(
                   'avg by (mode) (rate(node_cpu_seconds_total{mode!="idle"}[5m])) * 100',
                   "{{mode}}")],
               "percent", 0, 5, 12, 7, stack=True,
               desc="User, system and iowait. On a shared-core e2-micro the steal "
                    "time is worth watching: it is time taken by the hypervisor."),

    timeseries(9, "Memory",
               [target("node_memory_MemTotal_bytes", "total", "A"),
                target("node_memory_MemAvailable_bytes", "available", "B"),
                target("node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "used", "C")],
               "bytes", 12, 5, 12, 7,
               desc="Available, not free: MemAvailable estimates what a new "
                    "process could claim without swapping, which is the number "
                    "that predicts trouble."),

    timeseries(10, "Load average",
               [target("node_load1", "1m", "A"),
                target("node_load5", "5m", "B"),
                target("node_load15", "15m", "C")],
               "short", 0, 12, 8, 7,
               desc="Compare against 2 vCPUs. Sustained above 2 means work is "
                    "queueing."),

    timeseries(11, "Filesystem free",
               [target(
                   'node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"} * 100',
                   "/")],
               "percent", 8, 12, 8, 7,
               th=inverted_thresholds(20, 10),
               desc="A 30 GB disk cannot be enlarged on the free tier, so space "
                    "has to be reclaimed rather than bought."),

    timeseries(12, "Inodes free",
               [target(
                   'node_filesystem_files_free{mountpoint="/"} / node_filesystem_files{mountpoint="/"} * 100',
                   "/")],
               "percent", 16, 12, 8, 7,
               th=inverted_thresholds(20, 10),
               desc="Disk can be " + '"full" with bytes to spare if inodes run '
                    "out, which is the failure mode that surprises people."),

    timeseries(13, "Network I/O",
               [target("rate(node_network_receive_bytes_total{device!=\"lo\"}[5m]) * 8", "received", "A"),
                target("rate(node_network_transmit_bytes_total{device!=\"lo\"}[5m]) * 8", "transmitted", "B")],
               "bps", 0, 19, 12, 7,
               desc="Per interface, in bits per second. The external interface is "
                    "the one named like ens4 or enp0s."),

    timeseries(14, "Disk I/O",
               [target('rate(node_disk_read_bytes_total{device!="loop"}[5m])', "read", "A"),
                target('rate(node_disk_written_bytes_total{device!="loop"}[5m])', "written", "B")],
               "Bps", 12, 19, 12, 7),

    row(15, "Containers (cAdvisor)", 26),

    gauge(16, "Memory vs limit, per container",
          [target(
              'container_memory_working_set_bytes{container!="",container!="POD"}'
              ' / on(instance, name) container_spec_memory_limit_bytes{container!="",container!="POD"} * 100',
              "{{name}}", instant=True)],
          "percent", 0, 27, 12, 8, pct_thresholds(70, 90),
          desc="Each container's working set against the mem_limit set in "
               "docker-compose.yml. This is the panel that answers which of the "
               "seven containers is squeezing the others."),

    timeseries(17, "CPU by container",
               [target(
                   'sum by (name) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m])) * 100',
                   "{{name}}")],
               "percent", 12, 27, 12, 8, stack=True,
               desc="One core is 100%. Values above 100% mean the container used "
                    "more than one core in parallel."),

    timeseries(18, "Container restart pressure",
               [target(
                   'changes(container_last_seen{container!="",container!="POD"}[30m])',
                   "{{name}}")],
               "short", 0, 35, 12, 7,
               desc="Changes in container_last_seen: a non-zero line is a "
                    "container disappearing and coming back, i.e. a restart or "
                    "an OOM kill."),

    timeseries(19, "Host memory vs container total",
               [target("node_memory_MemAvailable_bytes", "host available", "A"),
                target('sum(container_memory_working_set_bytes{container!="",container!="POD"})', "containers total", "B")],
               "bytes", 12, 35, 12, 7,
               desc="The gap between these two lines is what the OS itself plus "
                    "Docker is using. It is normally small; if it is not, the "
                    "problem is outside the containers."),

    row(20, "Observability stack", 42),

    timeseries(21, "Prometheus series",
               [target("prometheus_tsdb_head_series", "head series", "A"),
                target("prometheus_tsdb_head_chunks", "head chunks", "B")],
               "short", 0, 43, 8, 7,
               th=thresholds(steps((GREEN, None), (AMBER, 5000), (RED, 10000))),
               desc="Series in memory. Cardinality is the usual cause of a "
                    "Prometheus OOM on a small instance."),

    timeseries(22, "Scrape health",
               [target("up", "{{job}}", "A")],
               "short", 8, 43, 8, 7,
               legend_calcs=("min",),
               minv=0, maxv=1,
               desc="0 or 1 per target. A target stuck at 0 is why alerts about "
                    "it stopped firing too."),

    timeseries(23, "Rule evaluation",
               [target('prometheus_rule_evaluation_failures_total', "failures", "A")],
               "short", 16, 43, 8, 7,
               legend_calcs=("max",),
               desc="Non-zero means a rule in alerts.yml is broken and silently "
                    "not being evaluated."),
]

dashboard = {
    "__inputs": [],
    "__requires": [
        {"type": "grafana", "id": "grafana", "name": "Grafana", "version": "11.0.0"},
        {"type": "prometheus", "id": "prometheus", "name": "Prometheus", "version": "1.0.0"},
    ],
    "annotations": {
        "list": [
            {
                "builtIn": 1,
                "datasource": {"type": "grafana", "uid": "-- Grafana --"},
                "enable": True,
                "hide": True,
                "iconColor": "rgba(0, 211, 255, 1)",
                "name": "Annotations & Alerts",
                "type": "dashboard",
            },
            {
                # Deploy markers come from Prometheus, so an alert can be lined up
                # against the change that caused it instead of guessed at.
                "datasource": DS,
                "enable": True,
                "expr": 'ALERTS{alertstate="firing"}',
                "iconColor": "red",
                "name": "Firing alerts",
                "step": "1m",
                "tagKeys": "alertname,severity",
                "titleFormat": "{{severity}}: {{alertname}}",
                "type": "tags",
            },
        ],
    },
    "description": (
        "Single view of the e2-micro instance: host, containers and the "
        "observability stack itself. Every panel is backed by a metric that a "
        "corresponding alert in alerts.yml also uses, so what is seen here is "
        "what pages."
    ),
    "editable": True,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 1,
    "id": None,
    "links": [
        {
            "asDropdown": False,
            "icon": "external link",
            "includeVars": False,
            "keepTime": True,
            "tags": [],
            "targetBlank": True,
            "title": "Runbook: alerting",
            "tooltip": "What to do when one of these panels turns amber",
            "type": "link",
            "url": "https://github.com/odominguezm/GCP-infrastructure-automation/blob/main/docs/runbooks/alerting.md",
        }
    ],
    "panels": panels,
    "preload": False,
    "refresh": "1m",
    "schemaVersion": 39,
    "tags": ["devops", "gcp", "e2-micro", "sre"],
    "templating": {"list": []},
    "time": {"from": "now-6h", "to": "now"},
    "timepicker": {
        "refresh_intervals": ["30s", "1m", "5m", "15m", "30m", "1h"],
        "time_options": ["15m", "1h", "6h", "12h", "24h", "7d"],
    },
    "timezone": "browser",
    "title": "Node overview",
    "uid": "node-overview",
    "version": 1,
    "weekStart": "",
}

out = pathlib.Path(__file__).parent / "node-overview.json"
out.write_text(json.dumps(dashboard, indent=2, ensure_ascii=False) + "\n")
print(f"escrito {out} ({len(panels)} paneles)")
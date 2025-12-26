#!/usr/bin/env python3
"""
Proton VPN Management API
Provides HTTP endpoints for managing wireproxy-proton service and switching regions.
"""

import os
import subprocess
import json
from pathlib import Path
from flask import Flask, request, jsonify

app = Flask(__name__)

# Configuration
CONFIG_DIR = os.environ.get("PROTON_CONFIG_DIR", "/etc/wireproxy")
PROTON_CONFIG = os.path.join(CONFIG_DIR, "proton.conf")
REGIONS_DIR = os.path.join(CONFIG_DIR, "regions")
SERVICE_NAME = "wireproxy-proton"
DEFAULT_SOCKS_BIND = "127.0.0.1:25345"


def get_available_regions():
    """Get list of available WireGuard config files in regions directory."""
    regions = {}
    if os.path.exists(REGIONS_DIR):
        for f in os.listdir(REGIONS_DIR):
            if f.endswith(".conf"):
                name = f.replace(".conf", "")
                # Extract region from filename (e.g., proton-jp.conf -> jp)
                if "-" in name:
                    region_code = name.split("-")[-1]
                else:
                    region_code = name
                regions[region_code] = {
                    "file": os.path.join(REGIONS_DIR, f),
                    "name": region_code.upper()
                }
    return regions


def get_current_region():
    """Get currently configured region from proton.conf."""
    if not os.path.exists(PROTON_CONFIG):
        return None
    
    with open(PROTON_CONFIG, "r") as f:
        content = f.read()
    
    for line in content.split("\n"):
        if line.startswith("WGConfig"):
            path = line.split("=")[1].strip()
            filename = os.path.basename(path)
            name = filename.replace(".conf", "")
            if "-" in name:
                return name.split("-")[-1]
            return name
    return None


def get_service_status():
    """Check if wireproxy-proton service is running."""
    try:
        result = subprocess.run(
            ["systemctl", "is-active", SERVICE_NAME],
            capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip() == "active"
    except Exception:
        return False


def update_config(wg_config_path, socks_bind=DEFAULT_SOCKS_BIND):
    """Update proton.conf with new WireGuard config path."""
    content = f"""# Proton VPN Configuration
# Managed by proton-ctl API

WGConfig = {wg_config_path}

[Socks5]
BindAddress = {socks_bind}
"""
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(PROTON_CONFIG, "w") as f:
        f.write(content)
    os.chmod(PROTON_CONFIG, 0o600)


def run_systemctl(action):
    """Run systemctl command on wireproxy-proton service."""
    try:
        subprocess.run(
            ["systemctl", action, SERVICE_NAME],
            check=True, timeout=30
        )
        return True, None
    except subprocess.CalledProcessError as e:
        return False, str(e)
    except Exception as e:
        return False, str(e)


@app.route("/api/proton/status")
def status():
    """Get service status and current region."""
    return jsonify({
        "running": get_service_status(),
        "region": get_current_region(),
        "config_file": PROTON_CONFIG
    })


@app.route("/api/proton/regions")
def regions():
    """Get list of available regions."""
    return jsonify({
        "regions": get_available_regions(),
        "current": get_current_region()
    })


@app.route("/api/proton/switch", methods=["POST"])
def switch_region():
    """Switch to a different region."""
    data = request.get_json() or {}
    region = data.get("region")
    
    if not region:
        return jsonify({"error": "Region required"}), 400
    
    available = get_available_regions()
    if region not in available:
        return jsonify({
            "error": f"Unknown region: {region}",
            "available": list(available.keys())
        }), 400
    
    # Update configuration
    update_config(available[region]["file"])
    
    # Restart service if running
    was_running = get_service_status()
    if was_running:
        success, error = run_systemctl("restart")
        if not success:
            return jsonify({"error": f"Failed to restart: {error}"}), 500
    
    return jsonify({
        "success": True,
        "region": region,
        "restarted": was_running
    })


@app.route("/api/proton/start", methods=["POST"])
def start():
    """Start wireproxy-proton service."""
    if not os.path.exists(PROTON_CONFIG):
        return jsonify({"error": "No configuration found. Switch to a region first."}), 400
    
    success, error = run_systemctl("start")
    if success:
        return jsonify({"success": True, "running": True})
    return jsonify({"error": error}), 500


@app.route("/api/proton/stop", methods=["POST"])
def stop():
    """Stop wireproxy-proton service."""
    success, error = run_systemctl("stop")
    if success:
        return jsonify({"success": True, "running": False})
    return jsonify({"error": error}), 500


@app.route("/api/proton/health")
def health():
    """Health check endpoint."""
    return jsonify({"status": "ok"})


if __name__ == "__main__":
    # Only listen on localhost for security
    app.run(host="127.0.0.1", port=8081, debug=False)

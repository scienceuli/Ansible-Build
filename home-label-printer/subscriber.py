#!/usr/bin/env python3
"""Subscribe to Homebox label images over MQTT and print them via NiimPrintX.

Expects to be run with `poetry run` from inside the NiimPrintX checkout (see
../README.md), so that both paho-mqtt and NiimPrintX are on the same
interpreter's path.
"""
import os
import subprocess
import sys
import tempfile

import paho.mqtt.client as mqtt

MQTT_HOST = os.environ.get("LABEL_MQTT_HOST", "mqtt.sam-projekte.de")
MQTT_PORT = int(os.environ.get("LABEL_MQTT_PORT", "8883"))
MQTT_USER = os.environ["LABEL_MQTT_USER"]
MQTT_PASSWORD = os.environ["LABEL_MQTT_PASSWORD"]
MQTT_TOPIC = os.environ.get("LABEL_MQTT_TOPIC", "homebox/labels")
PRINTER_MODEL = os.environ.get("LABEL_PRINTER_MODEL", "d110_m")
# Homebox renders labels landscape (wider than tall); NiimPrintX caps image
# width post-rotation at 240px for D110/D110_M, so this must stay "90" (or
# "270") unless Homebox's label dimensions change - see README "Known issues".
PRINTER_ROTATE = os.environ.get("LABEL_PRINTER_ROTATE", "90")


def on_connect(client, userdata, flags, reason_code, properties=None):
    print(f"Connected (rc={reason_code}), subscribing to {MQTT_TOPIC}")
    client.subscribe(MQTT_TOPIC)


def on_message(client, userdata, msg):
    print(f"Received {len(msg.payload)} bytes on {msg.topic}")
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
        f.write(msg.payload)
        image_path = f.name

    try:
        subprocess.run(
            [
                "poetry", "run", "python", "-m", "NiimPrintX.cli", "print",
                "-m", PRINTER_MODEL,
                "-r", PRINTER_ROTATE,
                "-i", image_path,
            ],
            check=True,
        )
        print("Print job sent")
    except subprocess.CalledProcessError as exc:
        print(f"Print failed: {exc}", file=sys.stderr)
    finally:
        os.unlink(image_path)


def main():
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
    client.username_pw_set(MQTT_USER, MQTT_PASSWORD)
    client.tls_set()
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(MQTT_HOST, MQTT_PORT)
    client.loop_forever()


if __name__ == "__main__":
    main()

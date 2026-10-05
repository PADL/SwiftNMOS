#!/usr/bin/env python3
"""A walkthrough of a node's IS-12 control protocol: the device model's tree, getting
and setting common properties, a property-changed notification, and invoking AES70
methods the bridge presents. Every request and response is printed, shortened.

    scripts/nmos/is12demo.py [--url http://127.0.0.1:8116] [--width 140]

It speaks only standard IS-12 messages: Get (1m1) and Set (1m2), GetMemberDescriptors
(2m1), the class manager's GetControlClass (3m1), Subscription, and Command with the
mapped IDs of the methods it finds in the class descriptors. Anything it sets is set
back afterwards. The node defaults to $NMOS_URL, then http://127.0.0.1:8080.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from nmosctl import ROOT_OID, STATUS, Node, WebSocket, class_id_text  # noqa: E402


def compact(value, width):
    text = json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    return text if len(text) <= width else text[:width - 1] + "…"


def element(level, index):
    return {"level": level, "index": index}


class Session:
    """One control session, printing what it sends and what it is answered."""

    def __init__(self, url, width):
        self.socket = WebSocket(url)
        self.width = width
        self.handle = 0
        self.notifications = []

    def _show(self, arrow, message):
        print(f"  {arrow} {compact(message, self.width)}")

    def _next(self, kind):
        while True:
            message = json.loads(self.socket.receive())
            if message.get("messageType") == kind:
                return message
            if message.get("messageType") == 2:
                self._show("⇠", message)
                self.notifications.extend(message.get("notifications", []))

    def command(self, oid, method, arguments=None, quiet=False):
        self.handle += 1
        command = {"handle": self.handle, "oid": oid, "methodId": method}
        if arguments is not None:
            command["arguments"] = arguments
        request = {"messageType": 0, "commands": [command]}
        if not quiet:
            self._show("→", request)
        self.socket.send(json.dumps(request))
        while True:
            for response in self._next(1).get("responses", []):
                if response.get("handle") == self.handle:
                    result = response["result"]
                    if not quiet:
                        status = result.get("status")
                        self._show("←", result)
                        if status != 200:
                            print(f"    ({status} {STATUS.get(status, '')})")
                    return result

    def get(self, oid, prop, quiet=False):
        return self.command(oid, element(1, 1), {"id": prop}, quiet).get("value")

    def set(self, oid, prop, value, quiet=False):
        return self.command(oid, element(1, 2), {"id": prop, "value": value}, quiet)

    def subscribe(self, oids):
        request = {"messageType": 3, "subscriptions": oids}
        self._show("→", request)
        self.socket.send(json.dumps(request))
        self._show("←", self._next(4))

    def await_notification(self):
        if not self.notifications:
            message = self._next(2)
            self._show("⇠", message)
            self.notifications.extend(message.get("notifications", []))
        return self.notifications.pop(0)


def step(number, title, *lines):
    print(f"\n== {number}. {title}")
    for line in lines:
        print(f"   {line}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("NMOS_URL", "http://127.0.0.1:8080"))
    parser.add_argument("--width", type=int, default=140, help="longest JSON line to print")
    args = parser.parse_args()

    step(1, "Find the control endpoint",
         "IS-04: the device's controls list urn:x-nmos:control:ncp/v1.0.")
    url = Node(args.url).ncp_url
    print(f"   {url}")
    session = Session(url, args.width)

    step(2, "Walk the root block",
         "NcBlock GetMemberDescriptors (2m1), recursively, on the root block (oid 1).")
    members = session.command(ROOT_OID, element(2, 1), {"recurse": True})["value"]
    paths = {ROOT_OID: "root"}
    for member in members:
        paths[member["oid"]] = f"{paths.get(member['owner'], '?')}/{member['role']}"
    shown = members[:14]
    for member in shown:
        print(f"   {member['oid']:>10}  {class_id_text(member['classId']):<34} {paths[member['oid']]}")
    print(f"   … {len(members) - len(shown)} more")

    def find(role_path):
        return next(m for m in members if paths[m["oid"]] == role_path)

    manager = find("root/ClassManager")["oid"]
    describing = {}

    def descriptor(member):
        class_id = tuple(member["classId"])
        if class_id not in describing:
            describing[class_id] = session.command(
                manager, element(3, 1), {"classId": member["classId"], "includeInherited": True}, quiet=True
            )["value"]
        return describing[class_id]

    def property_id(member, name):
        return next(p["id"] for p in descriptor(member)["properties"] if p["name"] == name)

    def method_id(member, name):
        return next(m["id"] for m in descriptor(member)["methods"] if m["name"] == name)

    channel = find("root/Mixer@1/HP@1/Input@1")
    gain = find("root/Mixer@1/HP@1/Input@1/Gain")
    mute = find("root/Mixer@1/HP@1/Input@1/Mute")
    device_manager = find("root/DeviceManager")

    step(3, "A block's user label",
         f"NcObject userLabel (1p6) on {paths[channel['oid']]}: Get, Set, Get, and back.")
    label = element(1, 6)
    before = session.get(channel["oid"], label)
    session.set(channel["oid"], label, "Talkback")
    session.get(channel["oid"], label)
    session.set(channel["oid"], label, before, quiet=True)

    gain_value = property_id(gain, "gain")
    mute_state = property_id(mute, "state")
    step(4, "A channel's gain and mute",
         "OcaGain's gain and OcaMute's state are AES70 level 4, so under NcWorker (level 2)",
         f"they are level 5: gain is {gain_value['level']}p{gain_value['index']}, "
         f"mute is {mute_state['level']}p{mute_state['index']} (1 muted, 2 unmuted). The gain's range is a",
         "runtime constraint (1p8).")
    session.get(gain["oid"], gain_value)
    session.get(gain["oid"], element(1, 8))
    session.get(mute["oid"], mute_state)
    session.set(mute["oid"], mute_state, 1)
    session.get(mute["oid"], mute_state)
    session.set(mute["oid"], mute_state, 2, quiet=True)

    step(5, "A notification",
         "Subscribe to the gain, set it, and the device notifies the change (⇠).")
    session.subscribe([gain["oid"]])
    old_gain = session.get(gain["oid"], gain_value, quiet=True)
    session.set(gain["oid"], gain_value, old_gain - 6.0 if old_gain > -120 else old_gain + 6.0)
    notification = session.await_notification()
    data = notification["eventData"]
    print(f"   oid {notification['oid']}: {data['propertyId']['level']}p{data['propertyId']['index']} "
          f"is now {data['value']}")
    session.subscribe([])
    session.set(gain["oid"], gain_value, old_gain, quiet=True)

    device_name = element(3, 6)
    step(6, "The device's name",
         "NcDeviceManager deviceName (3p6), served by the AES70 device manager's DeviceName.")
    name = session.get(device_manager["oid"], device_name)
    session.set(device_manager["oid"], device_name, "Demo")
    session.get(device_manager["oid"], device_name)
    session.set(device_manager["oid"], device_name, name, quiet=True)

    get_path = method_id(gain, "GetPath")
    get_port_name = method_id(gain, "GetPortName")
    step(7, "An AES70 method with no parameters",
         f"OcaWorker GetPath (AES70 2.13) is {get_path['level']}m{get_path['index']} on the gain. "
         "Its two results are fields of the result.")
    session.command(gain["oid"], get_path)

    port = session.get(gain["oid"], property_id(gain, "ports"), quiet=True)[0]
    step(8, "An AES70 method with a parameter",
         f"OcaWorker GetPortName (AES70 2.6) is {get_port_name['level']}m{get_port_name['index']}; "
         "its PortID is one of the gain's ports (3p2).")
    session.command(gain["oid"], get_port_name, {"PortID": port["Id"]})

    step(9, "Errors",
         "A port the gain does not have: the device's ParameterOutOfRange is ParameterError.",
         "A method the class does not have is MethodNotImplemented.")
    session.command(gain["oid"], get_port_name, {"PortID": {"Mode": 1, "Index": 99}})
    session.command(gain["oid"], element(get_path["level"], 99))

    # not described unless the node is built with the DescribeVendorMethods trait
    flags = element(6, 22)
    step(10, "A vendor method",
         "PADL's device manager GetFeatureFlags is 6m22, below NcDeviceManager and AES70's "
         "OcaDeviceManager. It is called by its ID, as it is not described.")
    session.command(device_manager["oid"], flags)


if __name__ == "__main__":
    try:
        main()
    except (BrokenPipeError, KeyboardInterrupt):
        pass

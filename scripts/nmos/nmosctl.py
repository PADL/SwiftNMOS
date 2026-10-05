#!/usr/bin/env python3
"""A small NMOS client for poking at a node: IS-04 (Node API), IS-05 (Connection API)
and IS-12 (control protocol). Standard library only, plain HTTP and WebSocket.

    nmosctl.py --url http://10.0.0.5:80 node
    nmosctl.py list senders
    nmosctl.py show receiver 3b8be755-08ff-452b-b217-c9151eb21193
    nmosctl.py sdp SENDER_ID
    nmosctl.py connection receiver RECEIVER_ID active
    nmosctl.py connect RECEIVER_ID SENDER_ID [--sender-url http://other-node]
    nmosctl.py disconnect RECEIVER_ID
    nmosctl.py patch receiver RECEIVER_ID '{"master_enable": false, ...}'
    nmosctl.py ncp tree
    nmosctl.py ncp describe 1
    nmosctl.py ncp get 1 1p6
    nmosctl.py ncp set 1 1p6 '"Studio A"'
    nmosctl.py ncp invoke 1 2m3 '{"role": "DeviceManager", "caseSensitive": true, ...}'
    nmosctl.py ncp classes
    nmosctl.py ncp watch [OID ...]

The node defaults to $NMOS_URL, then http://127.0.0.1:8080.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import socket
import struct
import sys
import urllib.error
import urllib.parse
import urllib.request

KINDS = {"device": "devices", "source": "sources", "flow": "flows",
         "sender": "senders", "receiver": "receivers"}


def fail(message):
    sys.exit(f"nmosctl: {message}")


def show(value):
    print(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False))


# ---------------------------------------------------------------- HTTP

def request(method, url, body=None, content_type="application/json", accept="application/json"):
    """Returns (status, content type, body bytes); an NMOS error body is not an exception."""
    data = None
    headers = {"Accept": accept}
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, response.headers.get("Content-Type", ""), response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.headers.get("Content-Type", ""), error.read()
    except (urllib.error.URLError, OSError) as error:
        fail(f"{method} {url}: {error}")


def get_json(url):
    status, _, body = request("GET", url)
    if status != 200:
        fail(f"GET {url}: HTTP {status} {body.decode(errors='replace')}")
    return json.loads(body)


def latest(versions):
    """The highest of a list such as ["v1.1/", "v1.2/"], without its slash."""
    names = [v.strip("/") for v in versions]
    return max(names, key=lambda v: [int(n) for n in v.lstrip("v").split(".")])


class Node:
    def __init__(self, url):
        self.url = url.rstrip("/")
        self._node_api = None

    @property
    def node_api(self):
        if self._node_api is None:
            version = latest(get_json(f"{self.url}/x-nmos/node/"))
            self._node_api = f"{self.url}/x-nmos/node/{version}"
        return self._node_api

    def resources(self, kind):
        return get_json(f"{self.node_api}/{KINDS[kind]}")

    def resource(self, kind, identifier):
        return get_json(f"{self.node_api}/{KINDS[kind]}/{identifier}")

    def control(self, urn):
        """The href of the newest control of this type that any device lists, or None."""
        found = []
        for device in self.resources("device"):
            for control in device.get("controls", []):
                if control["type"].startswith(urn):
                    found.append((control["type"], control["href"]))
        if not found:
            return None
        return max(found, key=lambda c: [int(n) for n in re.findall(r"\d+", c[0].rsplit("/", 1)[-1])])[1]

    @property
    def connection_api(self):
        href = self.control("urn:x-nmos:control:sr-ctrl/")
        if href:
            return href.rstrip("/")
        version = latest(get_json(f"{self.url}/x-nmos/connection/"))
        return f"{self.url}/x-nmos/connection/{version}"

    @property
    def ncp_url(self):
        href = self.control("urn:x-nmos:control:ncp/")
        if href:
            return href
        parts = urllib.parse.urlsplit(self.url)
        return f"ws://{parts.netloc}/x-nmos/ncp/v1.0"


# ---------------------------------------------------------------- IS-04

def cmd_node(node, args):
    show(get_json(f"{node.node_api}/self"))


def cmd_list(node, args):
    kind = args.kind.rstrip("s")
    for resource in node.resources(kind):
        detail = resource.get("transport") or resource.get("media_type") or resource.get("format") \
            or resource.get("type") or ""
        active = resource.get("subscription", {}).get("active")
        state = "" if active is None else ("active" if active else "inactive")
        print(f"{resource['id']}  {detail:<34} {state:<9} {resource.get('label', '')}")


def cmd_show(node, args):
    show(node.resource(args.kind, args.id))


def transport_file(node, sender_id):
    """A sender's transport file as (text, content type), from its manifest_href."""
    href = node.resource("sender", sender_id).get("manifest_href")
    if not href:
        fail(f"sender {sender_id} has no manifest_href")
    # whatever the sender has: a node may offer an SDP file as JSON to one who asks for that
    status, content_type, body = request("GET", href, accept="*/*")
    if status != 200:
        fail(f"GET {href}: HTTP {status}")
    return body.decode(), content_type.split(";")[0].strip() or "application/sdp"


def cmd_sdp(node, args):
    sys.stdout.write(transport_file(node, args.id)[0])


# ---------------------------------------------------------------- IS-05

def cmd_connection(node, args):
    url = f"{node.connection_api}/single/{KINDS[args.kind]}/{args.id}/{args.what}"
    status, content_type, body = request("GET", url)
    if status != 200:
        fail(f"GET {url}: HTTP {status} {body.decode(errors='replace')}")
    if "json" in content_type:
        show(json.loads(body))
    else:
        sys.stdout.write(body.decode())


def patch(node, kind, identifier, body):
    url = f"{node.connection_api}/single/{KINDS[kind]}/{identifier}/staged"
    status, _, response = request("PATCH", url, body)
    print(f"HTTP {status}")
    try:
        show(json.loads(response))
    except ValueError:
        sys.stdout.write(response.decode(errors="replace"))
    if status not in (200, 202):
        sys.exit(1)


def cmd_connect(node, args):
    sender_node = Node(args.sender_url) if args.sender_url else node
    body = {"sender_id": args.sender, "master_enable": True, "activation": {"mode": "activate_immediate"}}
    # a transport with no transport file (Dante, Milan) is patched by the sender's parameters
    if sender_node.resource("sender", args.sender).get("manifest_href"):
        data, content_type = transport_file(sender_node, args.sender)
        body["transport_file"] = {"data": data, "type": content_type}
    else:
        url = f"{sender_node.connection_api}/single/senders/{args.sender}/active"
        body["transport_params"] = get_json(url)["transport_params"]
    patch(node, "receiver", args.receiver, body)


def cmd_disconnect(node, args):
    patch(node, "receiver", args.receiver, {
        "sender_id": None,
        "master_enable": False,
        "activation": {"mode": "activate_immediate"},
    })


def cmd_patch(node, args):
    text = open(args.json[1:]).read() if args.json.startswith("@") else args.json
    patch(node, args.kind, args.id, json.loads(text))


# ---------------------------------------------------------------- WebSocket (RFC 6455 client)

class WebSocket:
    def __init__(self, url):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != "ws":
            fail(f"{url}: only ws:// is supported")
        try:
            self.sock = socket.create_connection((parts.hostname, parts.port or 80), timeout=10)
        except OSError as error:
            fail(f"{url}: {error}")
        key = base64.b64encode(os.urandom(16)).decode()
        path = parts.path or "/"
        self.sock.sendall((
            f"GET {path} HTTP/1.1\r\nHost: {parts.netloc}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        ).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                fail(f"{url}: connection closed during the WebSocket handshake")
            head += chunk
        status = head.split(b"\r\n", 1)[0].decode()
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        if " 101 " not in status or accept.encode() not in head:
            fail(f"{url}: not a WebSocket endpoint ({status})")
        self.sock.settimeout(None)

    def _read(self, count):
        data = b""
        while len(data) < count:
            chunk = self.sock.recv(count - len(data))
            if not chunk:
                raise EOFError
            data += chunk
        return data

    def _frame(self, opcode, payload):
        mask = os.urandom(4)
        length = len(payload)
        if length < 126:
            header = struct.pack("!BB", 0x80 | opcode, 0x80 | length)
        elif length < 65536:
            header = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, length)
        else:
            header = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, length)
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send(self, text):
        self._frame(0x1, text.encode())

    def receive(self):
        """The next text message; raises EOFError when the server closes."""
        message = b""
        while True:
            first, second = self._read(2)
            opcode, length = first & 0x0F, second & 0x7F
            if length == 126:
                length = struct.unpack("!H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._read(8))[0]
            payload = self._read(length)
            if opcode == 0x8:
                raise EOFError
            if opcode == 0x9:
                self._frame(0xA, payload)
                continue
            if opcode == 0xA:
                continue
            message += payload
            if first & 0x80:
                return message.decode()


# ---------------------------------------------------------------- IS-12

ROOT_OID = 1
STATUS = {200: "Ok", 298: "PropertyDeprecated", 299: "MethodDeprecated", 400: "BadCommandFormat",
          401: "Unauthorized", 404: "BadOid", 405: "Readonly", 406: "InvalidRequest",
          409: "Conflict", 413: "BufferOverflow", 414: "IndexOutOfBounds", 417: "ParameterError",
          423: "Locked", 500: "DeviceError", 501: "MethodNotImplemented",
          502: "PropertyNotImplemented", 503: "NotReady", 504: "Timeout"}


def element(text):
    """An element ID from "1p6", "2m1", "1e1" or "3.4"."""
    match = re.fullmatch(r"(\d+)[pme.](\d+)", text)
    if not match:
        fail(f"{text}: expected an element ID such as 1p6 or 2m1")
    return {"level": int(match.group(1)), "index": int(match.group(2))}


class Ncp:
    def __init__(self, url):
        self.socket = WebSocket(url)
        self.handle = 0
        self.notifications = []

    def message(self, wanted):
        """The next message of the wanted type; notifications met on the way are kept."""
        while True:
            message = json.loads(self.socket.receive())
            kind = message.get("messageType")
            if kind == wanted:
                return message
            if kind == 2:
                self.notifications.extend(message.get("notifications", []))
            elif kind == 5:
                fail(f"protocol error {message.get('status')}: {message.get('errorMessage')}")

    def invoke(self, oid, method, arguments=None, check=True):
        self.handle = self.handle % 65535 + 1
        command = {"handle": self.handle, "oid": oid, "methodId": method}
        if arguments is not None:
            command["arguments"] = arguments
        self.socket.send(json.dumps({"messageType": 0, "commands": [command]}))
        while True:
            for response in self.message(1).get("responses", []):
                if response.get("handle") == self.handle:
                    result = response["result"]
                    if check and result.get("status") not in (200, 298, 299):
                        status = result.get("status")
                        fail(f"oid {oid}: {status} {STATUS.get(status, '')} {result.get('errorMessage', '')}")
                    return result

    def get(self, oid, prop):
        return self.invoke(oid, {"level": 1, "index": 1}, {"id": prop}).get("value")

    def members(self, oid):
        return self.get(oid, {"level": 2, "index": 2}) or []

    def is_block(self, member):
        return member["classId"][:2] == [1, 1]

    def walk(self, oid=ROOT_OID, path=("root",)):
        """Every member below a block as (role path, descriptor)."""
        for member in self.members(oid):
            here = path + (member["role"],)
            yield here, member
            if self.is_block(member):
                yield from self.walk(member["oid"], here)

    def class_manager(self):
        for member in self.members(ROOT_OID):
            if member["role"] == "ClassManager":
                return member["oid"]
        fail("the root block has no ClassManager")

    def subscribe(self, oids):
        self.socket.send(json.dumps({"messageType": 3, "subscriptions": oids}))
        return self.message(4).get("subscriptions", [])


def oid(text):
    """An oid in decimal, or in hex with 0x, as object numbers are often written."""
    try:
        return int(text, 0)
    except ValueError:
        raise argparse.ArgumentTypeError(f"not an oid: {text}")


def class_id_text(class_id):
    """A class ID as dotted fields, an authority key shown as the organisation's ID in hex."""
    return ".".join(str(n) if n >= 0 else f"<{-n:06X}>" for n in class_id)


def class_names(ncp):
    """The name of every class the device describes, by class ID."""
    descriptors = ncp.get(ncp.class_manager(), element("3p1")) or []
    return {tuple(d["classId"]): d["name"] for d in descriptors}


def cmd_ncp_tree(ncp, args):
    names = {} if args.ids else class_names(ncp)

    def kind(class_id):
        return names.get(tuple(class_id)) or class_id_text(class_id)

    if args.flat:
        rows = [(ROOT_OID, kind(ncp.get(ROOT_OID, element("1p1"))), "root", None)]
        rows += [(m["oid"], kind(m["classId"]), "/".join(path), m.get("userLabel")) for path, m in ncp.walk()]
        width = max(len(row[1]) for row in rows)
        print(f"{'oid':>10}  {'class':<{width}}  path")
        for oid, name, path, label in rows:
            print(f"{oid:>10}  {name:<{width}}  {path}" + (f"  ({label})" if label else ""))
        return

    # each object indented under its block, with its class and oid
    def line(prefix, role, class_id, oid, label):
        text = f"{prefix}+-o {role}  <class {kind(class_id)}, oid {oid}"
        print(text + (f", \"{label}\">" if label else ">"))

    def draw(oid, prefix):
        members = ncp.members(oid)
        for index, member in enumerate(members):
            last = index == len(members) - 1
            line(prefix, member["role"], member["classId"], member["oid"], member.get("userLabel"))
            if ncp.is_block(member):
                draw(member["oid"], prefix + ("  " if last else "| "))

    line("", "root", ncp.get(ROOT_OID, element("1p1")), ROOT_OID, None)
    draw(ROOT_OID, "  ")


def cmd_ncp_get(ncp, args):
    show(ncp.get(args.oid, element(args.property)))


def cmd_ncp_set(ncp, args):
    show(ncp.invoke(args.oid, {"level": 1, "index": 2},
                    {"id": element(args.property), "value": json.loads(args.value)}))


def cmd_ncp_invoke(ncp, args):
    arguments = json.loads(args.arguments) if args.arguments else None
    show(ncp.invoke(args.oid, element(args.method), arguments, check=False))


def cmd_ncp_describe(ncp, args):
    class_id = ncp.get(args.oid, element("1p1"))
    descriptor = ncp.invoke(ncp.class_manager(), element("3m1"),
                            {"classId": class_id, "includeInherited": True})["value"]
    print(f"oid {args.oid}: {descriptor['name']}, class {class_id_text(class_id)}")
    for prop in descriptor["properties"]:
        identifier = f"{prop['id']['level']}p{prop['id']['index']}"
        result = ncp.invoke(args.oid, {"level": 1, "index": 1}, {"id": prop["id"]}, check=False)
        if result.get("status") == 200:
            value = json.dumps(result.get("value"), ensure_ascii=False)
        else:
            value = f"<{STATUS.get(result.get('status'), result.get('status'))}>"
        if len(value) > 100 and not args.full:
            value = value[:97] + "..."
        kind = (prop.get("typeName") or "any") + ("[]" if prop.get("isSequence") else "")
        access = "ro" if prop.get("isReadOnly") else "rw"
        print(f"  {identifier:<6} {access} {prop['name']:<28} {kind:<30} {value}")
    for method in descriptor["methods"]:
        identifier = f"{method['id']['level']}m{method['id']['index']}"
        parameters = ", ".join(f"{p['name']}: {p.get('typeName') or 'any'}" for p in method["parameters"])
        print(f"  {identifier:<6}    {method['name']}({parameters}) -> {method['resultDatatype']}")


def cmd_ncp_classes(ncp, args):
    manager = ncp.class_manager()
    if args.datatypes:
        for datatype in ncp.get(manager, element("3p2")):
            print(f"{datatype['name']}")
        return
    descriptors = sorted(ncp.get(manager, element("3p1")), key=lambda d: d["classId"])
    width = max(len(d["name"]) for d in descriptors)
    for descriptor in descriptors:
        print(f"{descriptor['name']:<{width}}  {class_id_text(descriptor['classId'])}")


def cmd_ncp_watch(ncp, args):
    oids = args.oids or [ROOT_OID] + [member["oid"] for _, member in ncp.walk()]
    accepted = ncp.subscribe(oids)
    print(f"subscribed to {len(accepted)} of {len(oids)} objects; Ctrl-C to stop", file=sys.stderr)
    try:
        while True:
            pending, ncp.notifications = ncp.notifications, []
            for notification in pending or ncp.message(2).get("notifications", []):
                data = notification.get("eventData", {})
                prop = data.get("propertyId", {})
                print(f"oid {notification['oid']} {prop.get('level')}p{prop.get('index')} "
                      f"change {data.get('changeType')}: {json.dumps(data.get('value'), ensure_ascii=False)}",
                      flush=True)
    except (KeyboardInterrupt, EOFError):
        pass


def cmd_ncp_raw(ncp, args):
    ncp.socket.send(args.json)
    print(ncp.socket.receive())


# ---------------------------------------------------------------- command line

def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default=os.environ.get("NMOS_URL", "http://127.0.0.1:8080"),
                        help="base URL of the node (default: $NMOS_URL or http://127.0.0.1:8080)")
    commands = parser.add_subparsers(dest="command", required=True)

    commands.add_parser("node", help="IS-04: the node resource").set_defaults(run=cmd_node)
    sub = commands.add_parser("list", help="IS-04: list resources of a kind")
    sub.add_argument("kind", choices=sorted(KINDS.values()))
    sub.set_defaults(run=cmd_list)
    sub = commands.add_parser("show", help="IS-04: one resource")
    sub.add_argument("kind", choices=sorted(KINDS))
    sub.add_argument("id")
    sub.set_defaults(run=cmd_show)
    sub = commands.add_parser("sdp", help="IS-04: a sender's transport file")
    sub.add_argument("id")
    sub.set_defaults(run=cmd_sdp)

    sub = commands.add_parser("connection", help="IS-05: read a sender's or receiver's connection")
    sub.add_argument("kind", choices=["sender", "receiver"])
    sub.add_argument("id")
    sub.add_argument("what", nargs="?", default="active",
                     choices=["active", "staged", "constraints", "transporttype", "transportfile"])
    sub.set_defaults(run=cmd_connection)
    sub = commands.add_parser("connect", help="IS-05: connect a receiver to a sender, now")
    sub.add_argument("receiver")
    sub.add_argument("sender")
    sub.add_argument("--sender-url", help="base URL of the sender's node, if not this one")
    sub.set_defaults(run=cmd_connect)
    sub = commands.add_parser("disconnect", help="IS-05: disconnect a receiver, now")
    sub.add_argument("receiver")
    sub.set_defaults(run=cmd_disconnect)
    sub = commands.add_parser("patch", help="IS-05: PATCH a staged resource with JSON or @file")
    sub.add_argument("kind", choices=["sender", "receiver"])
    sub.add_argument("id")
    sub.add_argument("json")
    sub.set_defaults(run=cmd_patch)

    ncp = commands.add_parser("ncp", help="IS-12: the control protocol").add_subparsers(dest="ncp", required=True)
    sub = ncp.add_parser("tree", help="every object, drawn under its block")
    sub.add_argument("--ids", action="store_true", help="show class IDs instead of class names")
    sub.add_argument("--flat", action="store_true", help="one row per object, by role path")
    sub.set_defaults(ncp_run=cmd_ncp_tree)
    sub = ncp.add_parser("describe", help="an object's properties with their values, and its methods")
    sub.add_argument("oid", type=oid)
    sub.add_argument("--full", action="store_true", help="do not shorten long values")
    sub.set_defaults(ncp_run=cmd_ncp_describe)
    sub = ncp.add_parser("get", help="a property value, e.g. get 1 1p6")
    sub.add_argument("oid", type=oid)
    sub.add_argument("property")
    sub.set_defaults(ncp_run=cmd_ncp_get)
    sub = ncp.add_parser("set", help="set a property to a JSON value, e.g. set 1 1p6 '\"Label\"'")
    sub.add_argument("oid", type=oid)
    sub.add_argument("property")
    sub.add_argument("value")
    sub.set_defaults(ncp_run=cmd_ncp_set)
    sub = ncp.add_parser("invoke", help="call a method with JSON arguments, e.g. invoke 1 2m1 '{\"recurse\": true}'")
    sub.add_argument("oid", type=oid)
    sub.add_argument("method")
    sub.add_argument("arguments", nargs="?")
    sub.set_defaults(ncp_run=cmd_ncp_invoke)
    sub = ncp.add_parser("classes", help="the control classes the device describes")
    sub.add_argument("--datatypes", action="store_true", help="list datatypes instead")
    sub.set_defaults(ncp_run=cmd_ncp_classes)
    sub = ncp.add_parser("watch", help="print property changes (every object if none is given)")
    sub.add_argument("oids", nargs="*", type=oid)
    sub.set_defaults(ncp_run=cmd_ncp_watch)
    sub = ncp.add_parser("raw", help="send one JSON message and print the reply")
    sub.add_argument("json")
    sub.set_defaults(ncp_run=cmd_ncp_raw)

    args = parser.parse_args()
    node = Node(args.url)
    if args.command == "ncp":
        args.ncp_run(Ncp(node.ncp_url), args)
    else:
        args.run(node, args)


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        pass

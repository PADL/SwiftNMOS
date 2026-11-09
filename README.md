# SwiftNMOS

An [AMWA NMOS](https://specs.amwa.tv/nmos/) node in Swift, and a bridge that presents a
[SwiftOCA](https://github.com/PADL/SwiftOCA) device through it.

- **`NMOS`** knows nothing of OCA. It has the resource models and their store, an HTTP
  router, the IS-04 Node API with registration, heartbeats and peer-to-peer
  advertisement, the IS-05 Connection API, and the IS-12 control protocol with the
  MS-05-02 model, its standard descriptors generated from the AMWA model files. The
  host supplies the HTTP server (FlyingFox), DNS-SD and a connection provider.
- **`NMOSClient`** is a controller's side of NMOS: the IS-04 Query API, read and followed by
  subscription, the Node API, and IS-05 connection. `NMOSRegistryMirror` keeps a copy of a
  registry, and `NMOSRegistryLocator` finds one by DNS-SD. Where there is none, `NMOSPeerMirror`
  delivers the same from the nodes advertising themselves, reading each when its `ver_` TXT
  records change.
- **`NMOSDiscovery`** is DNS-SD for NMOS services, for those not wanting the bridge.
- **`NMOSOCABridge`** maps a SwiftOCADevice device onto `NMOS`. One `NMOSOcaBridge`
  describes the device as IS-04 resources from its media transport applications, and
  from that description serves IS-05 through one adaptation per transport (RTP by SDP,
  Dante by channel subscription, Milan by stream binding) and IS-12 by presenting every
  AES70 object as an MS-05-02 object, with native NMOS classes where one applies. See
  [`Sources/NMOSOCABridge/IS12/README.md`](Sources/NMOSOCABridge/IS12/README.md).

### Resource IDs

The bridge derives every ID as a UUIDv5, so the same device gives the same IDs after every
restart. The node and device are named from the host's seed (a MAC address or serial
number). A sender, receiver, flow or source is named from its transport's own name for
the endpoint, in the fixed namespace `2a72491d-cc4b-42a3-8690-bd91e5a856d5`, so any node
presenting the same native endpoint gives it the same ID:

| Transport | Native name |
|---|---|
| IEEE 1722 (Milan) | `ieee1722/<entity ID, 16 hex digits>/<descriptor type>/<index>`: STREAM_OUTPUT `0006` for a sender, STREAM_INPUT `0005` for a receiver |
| Dante | `dante/<device name>/<channel name>` |
| RTP (AES67) | none: named from the node, the application and the endpoint |

AES70-23 exposes no Dante device ID that survives a rename, so renaming a Dante device or
channel makes its senders, receivers, flows and sources new resources: the old ones are
removed and new ones registered, and a controller connects them again. A Milan entity ID
is fixed for the entity's life (IEEE 1722.1-2021 ADP `entity_id`). An RTP endpoint has no
name that outlives its session, so it stays node-seeded. IS-04 lets one node register a
resource, so only the node that owns an endpoint should present it to a registry.

The specifications followed are IS-04 v1.3, IS-05 v1.1 and v1.2, IS-12 v1.0 and
MS-05-02 v1.0.

## Example

`Examples/NMOSDevice` is an AES70 device with a mixer (a block of channel blocks, each
with a gain and a mute), an identify actuator that logs when a controller asks the device
to identify itself (an NcIdentBeacon over IS-12), and mock AES67 and Dante transports, served as an NMOS node. The transports move no audio, but behave as a device's would when patched,
so IS-04, IS-05 (`urn:x-nmos:transport:rtp` and `urn:x-nmos:transport:dante`) and IS-12
can all be exercised. OCP.1 and OCP.2 share its HTTP port, as WebSocket subprotocols,
and OCP.1 is also served over TCP on `--oca-port` (65000), for `ocacli -h localhost`.

    swift run NMOSDevice --peer-to-peer
    scripts/nmos/nmosctl.py --url http://localhost:8080 list receivers
    scripts/nmos/nmosctl.py --url http://localhost:8080 connect RECEIVER_ID SENDER_ID
    scripts/nmos/nmosctl.py --url http://localhost:8080 ncp tree

Without `--peer-to-peer` it looks for a registry by DNS-SD, or uses the one `--registry`
names. `--port`, `--receivers` and `--senders` set the port and the number of each.

## Tools

`scripts/nmos/` has `nmosctl.py`, a standard-library client for IS-04, IS-05 and IS-12
(`nmosctl.py --url http://node:port ncp tree` draws a node's IS-12 object tree);
`is12demo.py`, a walk through a node's IS-12 endpoint; `fetch-specs.sh`, which clones the
AMWA specifications into `.build/nmos-specs`; and `generate-ms0502.py`, which regenerates
the MS-05-02 descriptors from them.

## Licence

Apache 2.0; see [LICENSE.md](LICENSE.md).

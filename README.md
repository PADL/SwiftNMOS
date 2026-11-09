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
  Dante by channel subscription, IEEE 1722 by stream binding) and IS-12 by presenting every
  AES70 object as an MS-05-02 object, with native NMOS classes where one applies. See
  [`Sources/NMOSOCABridge/IS12/README.md`](Sources/NMOSOCABridge/IS12/README.md).

### Resource IDs

The bridge derives every ID as a UUIDv5, so the same device gives the same IDs after every
restart. The node and device are named from the host's seed (a MAC address or serial
number). A sender, receiver, flow or source is named `<kind>/<native name>`, from its
transport's own name for the endpoint; the kind (`sender`, `receiver`, `flow` or
`source`, none containing `/`) keeps apart a talker and a listener of the same entity ID
and index, and a sender from its flow and source. The native names are canonical:

| Transport | Native name | Namespace |
|---|---|---|
| IEEE 1722 (Milan) | `ieee1722:<entity ID>:<unique ID>`: the entity ID as 16 lowercase hex digits without `0x`, and the stream's ACMP talker or listener unique ID, its STREAM_OUTPUT or STREAM_INPUT index | fixed, `2a72491d-cc4b-42a3-8690-bd91e5a856d5` |
| Dante | `dante:<channel>@<device>`, Dante's own notation for a channel on a device | the device's ID |
| RTP (AES67) | none: named from the application and the endpoint | the device's ID |

IS-04 IDs share one space in a registry: a UUID is universally unique (RFC 4122), and
the Registration API refuses an `id` "already used by another resource type held in the
registry" (IS-04 v1.3 Behaviour: Registration). An IEEE 1722 entity ID is an EUI-64
(IEEE 1722.1-2021 Clause 6.2.1.8), unique everywhere, so its streams are named in the
fixed namespace and any node presenting the bridge's entity gives them the same IDs. A
Dante device name is unique only within its Dante network, and two bridges on two
networks may both keep the default name, so a Dante name is qualified by the device.
IS-04 also says a sender, receiver or source is owned by its device and SHOULD change
if the device ID does (Data Model: Identifier Mapping), which the device namespace keeps.

The transport prefix is not needed for uniqueness today: every Dante name contains `@`,
which neither name may (the IS-05 patterns), and no IEEE 1722 name does. It is kept
because IS-04 says a sender or receiver ID SHOULD change if its transport type URN
changes, and naming the transport makes that hold by construction for any transport
added later whose names could overlap.

AES70-23 exposes no Dante device ID that survives a rename, so renaming a Dante device or
channel makes its senders, receivers, flows and sources new resources: the old ones are
removed and new ones registered, and a controller connects them again. A Milan entity ID
is fixed for the entity's life. An RTP endpoint has no name that outlives its session,
so it stays seeded. IS-04 lets one node register a resource, so only the node that owns
an endpoint presents it to a registry.

The specifications followed are IS-04 v1.3, IS-05 v1.1 and v1.2, IS-12 v1.0 and
MS-05-02 v1.0.

### Enabling and disabling senders

A sender's stream is set up outside NMOS, so its transport parameters are fixed by its
constraints. IS-05 `master_enable` starts and stops its transmission with the AES70
method `ApplyEndpointCommand` (Start or Stop), and `/active` and IS-04 read it from the
endpoint's state in `EndpointStatuses`:

- An IEEE 1722 or Dante sender is disabled while Connected, where AES70's Stop leaves an
  endpoint.
- An RTP sender is disabled while Ready, or while it has no active description. Connected
  counts as enabled, as a started sender may wait there for its media.

A device that reports the change after the method returns is given two seconds to show
it, so the activation's response says what it did. A refusal is answered as its status
says: `Locked` with 423, a parameter error with 400, and `NotImplemented` (an application
that cannot start or stop its senders) or any other with 500. The request meets the
schema and the constraints (`master_enable` has none), so IS-05 answers it with 500 when
it cannot be carried out. The bridge observes sender states, not receiver states, so a
stop made by another controller reaches IS-04.

## Transports

Dante and IEEE 1722 are not in AMWA's register of transports, and `urn:x-nmos:` is AMWA's
namespace, so they are named in PADL's. IS-05 serves them from v1.2. Neither has a
transport file: a receiver is patched by staging its `transport_params`.

| Transport | URN | Parameters | Schemas |
|-----------|-----|------------|---------|
| RTP (AES67, and Dante carried as AES67) | `urn:x-nmos:transport:rtp` | IS-05's | IS-05's |
| Dante | `urn:x-padl:transport:dante` | `device_name`, `channel_name` | [sender](schemas/sender_transport_params_dante.json), [receiver](schemas/receiver_transport_params_dante.json) |
| IEEE 1722 | `urn:x-padl:transport:ieee1722` | `entity_id`, `stream_index` | [sender](schemas/sender_transport_params_ieee1722.json), [receiver](schemas/receiver_transport_params_ieee1722.json) |

The schemas in [`schemas/`](schemas) follow IS-05's per-transport ones. An IEEE 1722
`entity_id` is written as IEEE 1722.1 writes an EUI-64, 16 hexadecimal digits with an
optional `0x`, not in IS-04's hyphenated form. The bridge presents a Milan entity's
streams (AES70-22) as IEEE 1722, Milan being the profile of it the entity implements.

## Example

`Examples/NMOSDevice` is an AES70 device with a mixer (a block of channel blocks, each
with a gain and a mute), an identify actuator that logs when a controller asks the device
to identify itself (an NcIdentBeacon over IS-12), and mock AES67 and Dante transports, served as an NMOS node. The transports move no audio, but behave as a device's would when patched,
so IS-04, IS-05 (`urn:x-nmos:transport:rtp` and `urn:x-padl:transport:dante`) and IS-12
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

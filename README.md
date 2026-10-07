# SwiftNMOS

An [AMWA NMOS](https://specs.amwa.tv/nmos/) node in Swift, and a bridge that presents a
[SwiftOCA](https://github.com/PADL/SwiftOCA) device through it.

- **`NMOS`** knows nothing of OCA. It has the resource models and their store, an HTTP
  router, the IS-04 Node API with registration, heartbeats and peer-to-peer
  advertisement, the IS-05 Connection API, and the IS-12 control protocol with the
  MS-05-02 model, its standard descriptors generated from the AMWA model files. The
  host supplies the HTTP server (FlyingFox), DNS-SD and a connection provider.
- **`NMOSOCABridge`** maps a SwiftOCADevice device onto `NMOS`: IS-04 resources from the
  device's media transport applications, IS-05 through one adaptation per transport (RTP
  by SDP, Dante by channel subscription, Milan by stream binding), and IS-12 by
  presenting every AES70 object as an MS-05-02 object, with native NMOS classes where
  one applies. See [`Sources/NMOSOCABridge/IS12/README.md`](Sources/NMOSOCABridge/IS12/README.md).

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

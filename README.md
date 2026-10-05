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

## Traits

- `DescribeVendorMethods`: describe a vendor's methods over IS-12. They may be called by
  their IDs either way.

## Tools

`scripts/nmos/` has `nmosctl.py`, a standard-library client for IS-04, IS-05 and IS-12
(`nmosctl.py --url http://node:port ncp tree` draws a node's IS-12 object tree);
`is12demo.py`, a walk through a node's IS-12 endpoint; `fetch-specs.sh`, which clones the
AMWA specifications into `.build/nmos-specs`; and `generate-ms0502.py`, which regenerates
the MS-05-02 descriptors from them.

## Licence

Apache 2.0; see [LICENSE.md](LICENSE.md).

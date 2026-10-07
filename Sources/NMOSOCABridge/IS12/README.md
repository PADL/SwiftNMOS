# IS-12: AES70 classes as MS-05-02 classes

How the bridge presents an AES70 object is derived from the object's own declarations at
run time; `NMOSOcaControlMapping` holds only what cannot be derived (which AES70 classes
stand for which standard classes, and which of their properties serve the standard ones).
This note records the rules the derivation follows, and the decisions behind them.

## Classes and levels

An object is presented under the deepest *anchor* in its AES70 lineage: an AES70 class with
a standard counterpart (OcaRoot/NcObject, OcaWorker/NcWorker, OcaBlock/NcBlock,
OcaIdentificationActuator/NcIdentBeacon, OcaManager/NcManager,
OcaDeviceManager/NcDeviceManager).
Every AES70 class below OcaRoot becomes a non-standard class whose ID is the anchor's,
then an authority key, then the AES70 class ID's fields after the leading 1 (an AES70
proprietary marker and its authority collapse into that authority's key).

An AES70 element defined at AES70 level **L** is presented at level **N + L − 1**, where
**N** is the anchor's level, with its AES70 index unchanged. This is the same thing as
MS-05-02's own rule, the level of the defining class counted without authority keys,
applied to the class IDs above. It holds for properties and methods alike.

## The class manager

AES70 has no class manager, so the bridge adds SwiftOCADevice's `OcaClassManager` to the
device (PADL's class `1.3.<PADL>.1`, object number 4095, the last AES70 reserves). It is
registered with the device like any manager, so it is listed in the device manager's
`Managers`, which the root block's members include. To an OCA controller it describes
the classes of the device's objects in OCA's terms (`GetControlClass`,
`GetControlClasses`), with descriptors that correspond to MS-05-02's.

Its methods are NcClassManager's own in OCA's terms, so IS-12 presents it as
`NcClassManager` exactly: its anchor hides it and the OCA classes above it
(`hideSubclasses`), and `NcObjectModel` answers NcClassManager's methods and properties
for it, as for any object the source presents with that class. Nothing in the object
model is special to its oid.

## The one exception: OcaRoot

OcaRoot's elements are not presented (`presented`, on a lineage). NcObject owns
level 1: OcaRoot's properties are NcObject's (class ID and role; the lock state has no
counterpart), and OcaRoot's seven methods, 1.1 to 1.7, would take the IDs of NcObject's
`Get`, `Set` and the sequence methods under an NcObject anchor, or of the anchor's own
methods under a deeper one (NcBlock's `GetMemberDescriptors` to `FindMembersByClassId`),
since level 1 maps to the anchor's level. The lock methods stay hidden: IS-12 has no lock,
and a session must not be able to lock objects against AES70 controllers.

## Standard methods take precedence by structure

`NcObjectModel` answers every standard method itself before asking the source, through a
class for each standard class (`NcObject`, `NcBlock`, `NcClassManager`) that handles its
own methods and passes the rest to the class it derives from, as SwiftOCA's classes do:
NcObject's `1m1`–`1m7` for every object, NcBlock's `2m1`–`2m4` for a block,
NcClassManager's for the class manager. With OcaRoot excluded, every presented AES70 class has L ≥ 2 and so every AES70
method lands at level N + 1 or below, under every standard class in the lineage; no
renumbering is needed, and no method is excluded by name or by class. Checked over every
method table in SwiftOCADevice and in one vendor device: the only collisions are OcaRoot's, and
they fall inside the exception; a non-block class that
defines `{2, 4}` or `{3, 1}` shares numerals with NcBlock or NcClassManager in an unrelated
class, which MS-05-02 allows (NcReceiverMonitor and NcSenderMonitor both define `4m1`).

## The tree

The tree is the device's, looked up when a request needs it and never copied: an oid is
the object of that number in `OcaDevice.objects`, and it is in the tree if its owner is,
up to the root block. A manager's owner is the root block, as MS-05-02 has it; any other
object's is the block that owns it (`OcaOwnable.owner`). A block's members are the
objects it owns, after the managers for the root block. So what a dataset or a controller
changes is seen at once, and the bridge neither walks the tree nor watches it.

## Methods

Each presented AES70 class lists the methods SwiftOCADevice declares for it with
`@OcaDeviceMethod` (`OcaDeviceClassDescriptor.methods`), at the level and index the rule
above gives (`NMOSOcaControlClasses.presentMethods`). Where a class declares a method ID
more than once the most derived declaration is the one presented. A method is described by
its model name; its parameters by their OCP.2 names and schemas, as properties are; and its
result by a struct derived from `NcMethodResult`, named for the class and the method
(`OcaWorkerGetPortNameResult`), whose one field is `value` for a method with one result, or
a field per result under its OCP.2 name for several. A method with no results returns
`NcMethodResult` itself. `isDeprecated` is false, as SwiftOCA has nothing to say otherwise.
A class that adds only methods to its anchor is presented as a class derived from it, as
one that adds a property is (`NMOSOcaControlClasses.isPresentedAsDerivedClass`). A debug
assertion checks that no presented method takes the ID of a standard method of the anchor's lineage.

A method is left out when:

- its ID is the getter or setter of one of the class's properties (`Get`/`Set` serve it);
- it does not describe its parameters (`isDescribed` is false, as for `SetResetKey`);
- a parameter or result has a type MS-05-02 cannot describe, as for a property.

A method the device refuses to a controller is still presented: the device's
`PermissionDenied` is the session's `Unauthorized` when it is called, as over OCP.1 and
OCP.2.

`NMOSOcaObjectSource.handleCommand` serves a presented method from the class's `methods`, keyed by
the mapped `NcElementID`. Each IS-12 argument is looked up by its OCP.2 name (a missing one
is `ParameterError`) and converted by its schema, and the command goes to the device as the
session's own OCP.2 controller, so the device's method table decodes it and makes the lock
and access checks; the bridge decodes nothing itself. The OCA status maps to an
`NcMethodStatus` (`NotImplemented` to `MethodNotImplemented`, `PermissionDenied` to
`Unauthorized`, `Locked` to `Locked`), and the results are converted back by their schemas.

A vendor's classes may declare their own methods with `@OcaDeviceMethod` too, so they may
be invoked by the same rules, under the vendor's authority key, as they may over OCP.1
and OCP.2, and are described as the standard classes' are. Which of a class's methods are candidates is
decided in one place, `NMOSOcaControlClasses.candidates`.

Decisions:

- Property accessors are not methods: a table method whose ID is the getter or setter of
  an `@OcaDeviceProperty` is served by the property (`Get`/`Set`). A getter the device
  declares only as a method, such as OcaLevelSensor's `GetReading`, is a method.
- A property with a getter is described whether or not the device lets the session read
  it. Whether to answer a `Get` is the device's to decide, on each request: its
  `PermissionDenied` is the session's `Unauthorized`.
- A property is read only exactly when it has no setter. One with a setter is described
  as writable, and the device may still refuse a `Set`: its `PermissionDenied` is the
  session's `Unauthorized`, and `NotImplemented` its `Readonly`.
- `OcaONo`-typed parameters and results are presented as the raw AES70 object numbers,
  as `OcaONo` properties already are; an oid differs only for the root block and the
  device manager.
- A method whose parameters the device cannot describe (OcaDeviceManager's raw
  `SetResetKey`) cannot be presented honestly, and is left out, as its descriptor says.

## Notifications

Every presented property is notified when it changes, metering and counters included: a
generic sensor's `reading`, PADL's `clip`, and the counter sets of a network application,
a network interface, a media transport application's `endpointCounterSets` and a counter
set agent. They may also be read, or polled: `GetReading` and `GetEndpointCounter` are
methods like any other.

OcaLevelSensor's reading is not a property at all: SwiftOCA keeps it privately and sends
its own change events for 4.1, which no presented property has, so a client reads it with
`GetReading`. Events other than property changes are never forwarded, so a counter
notifier's are not.

A session subscribed to an object has its controller subscribed to each of the object's
presented properties (`AddPropertyChangeSubscription2`, in effect) rather than to all of
its property changes. The device then does not encode, or send the bridge, a change to
anything not presented. With no session
subscribed to an object, the bridge hears nothing from it, unless it is a block or the
device manager, whose changes to the tree the bridge observes for itself. Counter agents
and counter notifiers are presented like any agent: what they hold may be read, which
leaves nothing of them hollow.

What a session's controller takes from a notification is only which object and property
changed: the event, and the property ID read from its event data without decoding the
value (`OcaEventDataCoding.propertyID(from:)`). The value is read afresh, as the session's
own `Get` would read it, and sent as `NcPropertyChangedEventData`.

## User labels

MS-05-02 has every object's `userLabel` writable. Where the object has an OCA `label` a
controller can set, the label is that property, written as the session's controller: a
lock, the device's refusal, or any other failure is the session's error. An object
without one (a manager, the class manager) has its label kept in an `NMOSOcaLabelStore`
instead, by object number. MS-05-02 also requires that a label persist across a restart: the default store,
`NMOSOcaMemoryLabelStore`, keeps labels only while the process runs, and a host that
can persist them passes a store of its own to `NMOSOcaDeviceModel`.

## Demo

`scripts/nmos/is12demo.py` walks through a node's IS-12 endpoint with standard messages
only: the tree, a block's user label, a channel's gain and mute, a notification, the device
name, and AES70 methods presented by the bridge (`GetPath`, `GetPortName`, the errors
they map to, and a vendor method called by ID, as it is not described). Against a node
serving IS-12 on port 8116:

    scripts/nmos/is12demo.py --url http://127.0.0.1:8116

`scripts/nmos/nmosctl.py --url http://127.0.0.1:8116 ncp tree` draws the object tree, each
object indented under its block with its class and oid, and `ncp describe OID` lists an
object's properties with their values, and its methods. An oid may be given in decimal or
in hex (`0x64`).

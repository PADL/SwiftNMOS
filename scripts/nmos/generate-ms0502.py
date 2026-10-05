#!/usr/bin/env python3
"""Generates Sources/NMOS/MS0502/NcStandardModel+Generated.swift from the AMWA models.

The class and datatype descriptors a device's class manager must publish for the
standard classes are data AMWA maintains as JSON: MS-05-02 for the framework, and
the control feature sets register for identification and monitoring. This writes
them out as Swift literals, so the target needs no resource bundle at run time.

Usage: scripts/nmos/fetch-specs.sh && scripts/nmos/generate-ms0502.py [specs-directory]
"""

import glob
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
SPECS = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, ".build", "nmos-specs")
OUTPUT = os.path.join(ROOT, "Sources", "NMOS", "MS0502", "NcStandardModel+Generated.swift")

# (repository, directory holding models/, what the generated file calls it)
SOURCES = [
    ("ms-05-02", "", "framework"),
    ("nmos-control-feature-sets", "identification", "identification"),
    ("nmos-control-feature-sets", "monitoring", "monitoring"),
]

# MS-05-02 defines the primitives in prose only (Framework.md, "Primitives")
PRIMITIVES = [
    "NcBoolean", "NcInt16", "NcInt32", "NcInt64", "NcUint16", "NcUint32", "NcUint64",
    "NcFloat32", "NcFloat64", "NcString",
]


def string(value):
    return "nil" if value is None else json.dumps(value, ensure_ascii=False)


def literal(value):
    """A JSON value as an NMOSJSONValue literal."""
    if value is None:
        return ".null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float, str)):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "[" + ", ".join(literal(item) for item in value) + "]"
    if not value:
        return "[:]"
    return "[" + ", ".join(f"{json.dumps(k)}: {literal(v)}" for k, v in value.items()) + "]"


def constraints(value):
    return "" if value is None else f", constraints: {literal(value)}"


def flag(name, value, default=False):
    return "" if value == default else f", {name}: {'true' if value else 'false'}"


def element(value):
    return f".init(level: {value['level']}, index: {value['index']})"


def parameter(p):
    return (f".init(description: {string(p['description'])}, name: {string(p['name'])}, "
            f"typeName: {string(p['typeName'])}{flag('isNullable', p['isNullable'])}"
            f"{flag('isSequence', p['isSequence'])}{constraints(p['constraints'])})")


def control_class(c):
    lines = [f"    .init(", f"      description: {string(c['description'])},",
             f"      classID: {c['classId']}, name: {string(c['name'])}, fixedRole: {string(c['fixedRole'])},"]
    lines.append("      properties: [")
    for p in c["properties"]:
        lines.append(
            f"        .init(description: {string(p['description'])}, id: {element(p['id'])}, "
            f"name: {string(p['name'])}, typeName: {string(p['typeName'])}, "
            f"isReadOnly: {'true' if p['isReadOnly'] else 'false'}{flag('isNullable', p['isNullable'])}"
            f"{flag('isSequence', p['isSequence'])}{flag('isDeprecated', p['isDeprecated'])}"
            f"{constraints(p['constraints'])}),")
    lines.append("      ],")
    lines.append("      methods: [")
    for m in c["methods"]:
        lines.append(
            f"        .init(description: {string(m['description'])}, id: {element(m['id'])}, "
            f"name: {string(m['name'])}, resultDatatype: {string(m['resultDatatype'])}, parameters: [")
        for p in m["parameters"]:
            lines.append(f"          {parameter(p)},")
        lines.append(f"        ]{flag('isDeprecated', m['isDeprecated'])}),")
    lines.append("      ],")
    lines.append("      events: [")
    for e in c["events"]:
        lines.append(
            f"        .init(description: {string(e['description'])}, id: {element(e['id'])}, "
            f"name: {string(e['name'])}, eventDatatype: {string(e['eventDatatype'])}"
            f"{flag('isDeprecated', e['isDeprecated'])}),")
    lines.append("      ]")
    lines.append("    ),")
    return lines


def datatype(d):
    head = f"    .init(description: {string(d['description'])}, name: {string(d['name'])}, kind: "
    tail = f"{constraints(d['constraints'])}),"
    kind = d["type"]
    if kind == 0:
        return [head + ".primitive" + tail]
    if kind == 1:
        sequence = "true" if d["isSequence"] else "false"
        return [head + f".typedef(parentType: {string(d['parentType'])}, isSequence: {sequence})" + tail]
    if kind == 2:
        lines = [head + ".struct(fields: ["]
        lines += [f"      {parameter(f)}," for f in d["fields"]]
        lines.append(f"    ], parentType: {string(d['parentType'])})" + tail)
        return lines
    if kind == 3:
        lines = [head + ".enum(items: ["]
        lines += [f"      .init(description: {string(i['description'])}, name: {string(i['name'])}, "
                  f"value: {i['value']})," for i in d["items"]]
        lines.append("    ])" + tail)
        return lines
    raise ValueError(f"unknown datatype type {kind} for {d['name']}")


def load(directory):
    return [json.load(open(path)) for path in sorted(glob.glob(os.path.join(directory, "*.json")))]


def revision(repository):
    return subprocess.check_output(
        ["git", "-C", os.path.join(SPECS, repository), "log", "-1", "--format=%h %cs"], text=True
    ).strip()


def main():
    out = ["// Generated by scripts/nmos/generate-ms0502.py from the AMWA models. Do not edit.", "//"]
    for repository in sorted({source[0] for source in SOURCES}):
        out.append(f"//   AMWA-TV/{repository} at {revision(repository)}")
    out += ["//", "// The models are Copyright AMWA and licensed under the Apache License, Version 2.0.",
            "", "// swiftformat:disable all", "", "extension NcStandardModel {"]

    for repository, directory, name in SOURCES:
        models = os.path.join(SPECS, repository, directory, "models")
        classes = sorted(load(os.path.join(models, "classes")), key=lambda c: c["classId"])
        datatypes = load(os.path.join(models, "datatypes"))
        if name == "framework":
            datatypes = [{"description": None, "name": p, "type": 0, "constraints": None}
                         for p in PRIMITIVES] + datatypes

        out.append(f"  static let {name}Classes: [NcClassDescriptor] = [")
        for c in classes:
            out += control_class(c)
        out += ["  ]", ""]
        out.append(f"  static let {name}Datatypes: [NcDatatypeDescriptor] = [")
        for d in datatypes:
            out += datatype(d)
        out += ["  ]", ""]

    out[-1] = "}"
    with open(OUTPUT, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {os.path.relpath(OUTPUT, ROOT)}")


if __name__ == "__main__":
    main()

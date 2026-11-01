//
// Copyright (c) 2026 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation
import NMOS
import NMOSClient
import NMOSDiscovery

// Follows a registry, named or found by DNS-SD, printing what it holds as that changes.
func queryAPI() async -> URL? {
  if CommandLine.arguments.count > 1 { return URL(string: CommandLine.arguments[1]) }
  let locator = NMOSRegistryLocator(discovery: NMOSOcaServiceDiscovery())
  for await urls in locator.queryAPIs() {
    if let url = urls.first { return url }
  }
  return nil
}

setvbuf(stdout, nil, _IOLBF, 0)
guard let url = await queryAPI() else { exit(1) }
print("following \(url)")
let mirror = NMOSRegistryMirror(client: NMOSQueryClient(baseURL: url))
for await snapshot in mirror.snapshots() {
  print(
    "nodes \(snapshot.nodes.count)",
    "devices \(snapshot.devices.count)",
    "senders \(snapshot.senders.count)",
    "receivers \(snapshot.receivers.count)"
  )
}

# FaNG patches to AMSMB2

This is AMSMB2 4.0.3 (upstream commit `1726aaaf7adf63d7d1d2a0c5d1b0e635028215c0`), vendored so FaNG can
add the few operations it needs that the public API doesn't expose. AMSMB2 and libsmb2 are LGPL 2.1; these
changes are under the same license. libsmb2 has one patch (below).

All changes are in one extension at the end of `AMSMB2/AMSMB2.swift`, marked "FaNG additions":

- `moveItem(atPath:replacingItemAtPath:)`: rename with `ReplaceIfExists`, in one request. libsmb2's
  `smb2_rename_async` hard-codes `replace_if_exist = 0`, which forced a delete-then-rename for content
  replacement.
- `uploadItem(at:toPath:offset:progress:)`: upload starting at an offset in both files, to resume an
  interrupted upload without loading the file into memory.
- `downloadRange(atPath:range:to:chunkSize:progress:)`: read a byte range of a remote file into a local file at
  the same offsets, so one file can be downloaded in parallel pieces over several connections.
- `writeRanges(from:ranges:toPath:size:progress:)`: write chosen byte ranges of a local file into an existing
  remote file, set its length and flush it: delta uploads into a server-side clone of the old contents.

One limit in `AMSMB2/FileHandle.swift` (`capped`, marked "FaNG patch"):

- **2 MiB requests on iOS.** `optimizedReadSize` and `optimizedWriteSize` used the server's maximum (8 MiB on
  Samba). Each request's buffer exists twice, so two transfers at once pushed the File Provider extension past
  iOS's ~20 MB limit and the system ended it in a loop ("Download Error" on most files). macOS keeps the full size.

One fix outside that extension, in `AMSMB2/Context.swift` (`wait_for_reply`, marked "FaNG patch"):

- **Timeouts close the connection.** When a request times out, AMSMB2 stops waiting but leaves the request
  queued in libsmb2, with its callback data, result structs and read buffers pointing at the waiting call's
  stack. A late reply, or tearing down the connection, then wrote through those dangling pointers (seen as a
  crash in `close_cb` from `smb2_destroy_context` after the server was paused mid-download). The patch calls
  `smb2_close_context` on timeout: the socket is gone, so no late reply arrives; `generic_handler` already
  ignores callbacks when `fd` is invalid; and `connectShare` builds a fresh client for the next call.

Two speedups in libsmb2's encryption and signing on Apple platforms (marked "FaNG patch"; same output, byte for
byte, checked against the generic code for sizes from 0 to 8 MiB and, for CMAC, the RFC 4493 vector):

- **AES-128-CCM** (`lib/aes128ccm.c`): the payload goes through one CommonCrypto CTR pass and one CBC pass (the
  CBC-MAC), fed in 64 KiB pieces. The generic code ran one AES block at a time, and on Apple each block created
  and released a CommonCrypto context: 68 MB/s per core, now 2,290 MB/s. It capped every encrypted connection.
- **AES-128-CMAC signing** (`lib/smb2-signing.c`): the CBC chain in one CommonCrypto context: 130 MB/s, now
  1,736 MB/s.

One fix in libsmb2, `Dependencies/libsmb2/lib/socket.c` (`smb2_connect_async`, marked "FaNG patch"):

- **Address literals stay as they are.** libsmb2 resolved the server with `getaddrinfo(host, port, NULL, …)`.
  With no hints, Apple's `getaddrinfo` turns an IPv4 literal into a NAT64 IPv6 address on IPv6-only networks,
  which most cellular networks are. That address goes out to the carrier instead of into a VPN that routes
  the IPv4 address (a subnet route), so connections over 5G timed out while the same VPN worked on
  any Wi-Fi. A numeric IPv4 or IPv6 address is now resolved with `AI_NUMERICHOST` and its own family; host
  names resolve as before.

To update AMSMB2: copy the new release over this folder (without `.git`), re-apply the extension, the two patches and
this file, and run the FaNGKit tests. Both additions are candidates to offer upstream, which would end the need
for the vendored copy.

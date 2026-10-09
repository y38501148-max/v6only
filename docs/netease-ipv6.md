# NetEase audio over IPv6 on macOS

The macOS 3.1.12 client can use IPv6, but its API, artwork and audio use different hosts. On the tested campus network, API/artwork already used IPv6 while audio on `m701.music.126.net` used IPv4. The standard recursive answers either lacked AAAA or selected unreachable Telecom nodes.

`v6core --netease-ipv6` optionally resolves the verified official Aliyun CDN aliases for exactly `m701.music.126.net` and `m801.music.126.net`. Fixed public Mobile/Unicom /24 prefixes are EDNS CDN location hints; the user's address is not sent in ECS. Queries race TCP/UDP and the configured supplemental resolvers, have a 1.5-second budget, collect both carrier answers for up to 250 ms after the first valid answer, and cache dynamic AAAA results for at most 30 seconds. The resolver rejects private/non-global addresses and falls back to ordinary DNS if discovery fails. Once an IPv6 answer exists, the normal no-IPv4-fallback connection policy applies.

The macOS runtime enables the option. Other platforms and direct CLI invocations retain the previous behavior unless explicitly enabled. The allowlist excludes API, artwork, unrelated domains and lookalike suffixes. The original music URL, HTTP Host and TLS SNI remain unchanged; no HTTPS decryption, certificate override, account setting, subscription bypass or media modification is involved.

On 2026-10-09, the same authorized signed audio URL returned HTTP 206 through IPv4 and multiple Mobile/Unicom IPv6 nodes. Every 65,536-byte sample had SHA-256 `3acb273a8eda2a57bc9a763c03dcce2d151b315365291383234ea3d076992a5d`; the complete resource size reported by each was 48,230,767 bytes. Both original hostnames passed certificate validation. These are endpoint/content checks, not proof that every song or every network uses the same CDN configuration. Addresses are resolved at runtime rather than pinned from this sample.

Regression tests cover the opt-in and exact domain boundary, DNS response name/TTL/ID, one resolver returning NODATA before another returns AAAA, private IPv6 filtering, lookup timeouts, normal DNS preservation, actual IPv6 dial selection and rejection of IPv4 fallback after IPv6 connection failure.

## Release 2.1.6 verification

The locally installed candidate `2.1.5-netease.1` was tested on macOS on 2026-10-09. Three HTTPS range downloads used real IPv6 connections and returned identical 65,536-byte bodies to the IPv4 response. After deployment, the unmodified NetEase macOS client played a new track and transferred 30,224,670 bytes on `m701.music.126.net` over IPv6. The forwarding health check passed. Go race tests, `go vet`, and all 24 macOS controller regression tests passed.

The release includes this policy in the normal macOS runtime, so installing the released macOS package preserves the feature. It is limited to the two verified audio hosts: unrelated or IPv4-only NetEase APIs retain the standard routing policy. CDN availability can differ by network and time.

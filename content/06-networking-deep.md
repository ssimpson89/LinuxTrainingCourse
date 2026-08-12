---
title: Networking Deep
type: module
track: linux-internals
tags: [linux-internals, networking, netfilter, nftables, namespaces, xdp, ebpf, tc, conntrack, sockets]
requires: [Rocky 9.x VM with root, "kernel>=5.15 (all labs)", "kernel>=5.16 (nft netdev egress hook, Lab 3)", "clang + libbpf-devel (Lab 4 XDP build)", "BTF/CO-RE for eBPF portability", "veth native XDP support (Lab 4)"]
module_number: 6
status: reviewed
created: 2026-07-08
---

# 06 - Networking Deep

Backlink: [[00 - Track Overview]]

> Scope: the kernel network datapath end to end (RX and TX), netfilter hooks and
> nftables (with the iptables mental-model mapping), routing and policy routing,
> network namespaces + veth + bridges, tc/qdisc traffic control, socket internals,
> connection tracking, and an intro to XDP/eBPF on the datapath. The through-line is
> **container networking from first principles**: by the end you should be able to
> reconstruct, with `ip`, `nft`, and `tc`, everything Docker/Podman/CNI does for you,
> and know which counter is lying when it silently drops your packets.

---

## Concept deep-dive

The kernel network stack is not one thing. It is a pipeline of subsystems that hand
a packet buffer (`struct sk_buff`, universally "skb") from the NIC's DMA ring up
through softirq context, protocol handlers, netfilter hooks, routing, and finally a
socket receive queue, then back down on transmit. Every one of those handoffs is a
place where a packet can be dropped, and each drop increments a *different* counter.
Staff-level networking debugging is largely the discipline of knowing which counter
corresponds to which handoff.

### 0. The map: where a packet lives in the kernel

```
                RX (ingress)                          TX (egress)
                ============                          ===========
   NIC RX ring (DMA) ----------.              socket send() / sendmsg()
        | hardirq              |                     |
   napi_schedule()             |              tcp_sendmsg -> tcp_write_xmit
        | NET_RX_SOFTIRQ        |                     | (build skb, TSO/GSO)
   net_rx_action()             |              ip_queue_xmit / ip_output
        | driver ->poll()      |                     | nf INET_LOCAL_OUT
   napi_gro_receive()  <-- GRO |              nf INET_POST_ROUTING (SNAT)
        | XDP hook (native)    |                     |
   __netif_receive_skb_core    |              dev_queue_xmit()
        | tc ingress (clsact)  |                     | tc egress (clsact)
        | nf INGRESS (netdev)  |                     | qdisc enqueue/dequeue
   ip_rcv -> nf PRE_ROUTING    |              nf netdev EGRESS (>=5.16)
        | conntrack, DNAT      |                     |
   fib_lookup (routing)        |              ndo_start_xmit -> NIC TX ring
        |                      |                     |
   local? --------------------'              (DMA out, TX completion IRQ)
     |  yes                  no -> forward
   nf INPUT                        nf FORWARD -> nf POST_ROUTING
     |                                    (SNAT/masquerade)
   L4 (tcp_v4_rcv / udp_rcv)
     | demux by 4-tuple
   sk->sk_receive_queue -> wake up -> recv()
```

Keep this map open while reading. Everything below is a zoom into one of these boxes.

### 1. The receive path in detail

**Ring buffer and DMA.** The NIC and driver pre-allocate a *ring* of RX descriptors,
each pointing at a DMA-mapped buffer in RAM. When a frame arrives, the NIC DMA-copies
it into the next buffer and advances the ring. The CPU never touches the wire; it
touches memory the NIC wrote. Ring size is visible and tunable with `ethtool -g eth0`
(`RX/TX` current vs max). A too-small ring under bursty load overflows before softirq
drains it: that shows up as `rx_no_buffer` / `rx_missed_errors` / `rx_fifo_errors` in
`ethtool -S eth0`, **not** in any `ip -s link` counter. This is the first "lying
dashboard" trap: your `ifconfig` drops are zero, the NIC is dropping in silicon.

**Hard IRQ, then NAPI.** Interrupt-per-packet melts a CPU at high pps, so Linux uses
NAPI (New API). The driver's hardirq handler does almost nothing: it calls
`napi_schedule()`, which sets `NAPI_STATE_SCHED`, masks further RX interrupts on that
queue, and raises `NET_RX_SOFTIRQ`. Real work happens in softirq context in
`net_rx_action()` (`net/core/dev.c`). This is *interrupt mitigation*: while packets
keep arriving, the NIC stays in polled mode and interrupts stay masked. Source of
truth: `struct napi_struct`, `napi_poll()`, and the driver's `->poll` callback.

**net_rx_action and the budget.** `net_rx_action()` walks the per-CPU `poll_list` of
scheduled NAPI instances and calls each driver's `->poll(napi, budget)`. Two limits
stop softirq from monopolizing the CPU: a per-poll `budget` (default 64, global
`net.core.netdev_budget` default 300 across all NAPIs) and a time limit
(`net.core.netdev_budget_usecs`, default 2000). When either is exhausted, softirq
reschedules itself; if softirqs keep saturating, the work is pushed to the per-CPU
`ksoftirqd/N` kernel thread, which is why you see `ksoftirqd` burning a core under
heavy RX. The counter for "budget exhausted, had to defer" is column 3 (time_squeeze)
in `/proc/net/softnet_stat` (one line per CPU, hex). Column 2 is packets *dropped*
because the per-CPU backlog queue (`netdev_max_backlog`) was full. Learn to read
softnet_stat; it is the single most under-used RX diagnostic.

**skb construction and GRO.** The driver `->poll` builds an `sk_buff` around each
received frame (`napi_build_skb` / `build_skb`) and calls `napi_gro_receive()`. GRO
(Generic Receive Offload) coalesces consecutive segments of the same flow into one
large skb *before* it climbs the stack, amortizing per-packet overhead across the TCP/IP
code. GRO is why `tcpdump` on a busy 10G link shows you 64KB "packets" that never
existed on the wire. Toggle with `ethtool -K eth0 gro off` when you need to see reality.

**RSS, RPS, RFS: spreading the load.** A single RX queue pins all softirq work to one
CPU, capping you at whatever one core can do (often the real limit long before line
rate). Three mechanisms spread it:
- **RSS** (Receive Side Scaling): hardware hashes the 4-tuple and steers flows to
  multiple hardware RX queues, each with its own IRQ. Check `ls
  /sys/class/net/eth0/queues/` and `ethtool -l eth0`. IRQ-to-CPU affinity lives in
  `/proc/irq/*/smp_affinity`.
- **RPS** (Receive Packet Steering): software equivalent when the NIC has one queue;
  hashes and enqueues to a remote CPU's backlog. `/sys/class/net/eth0/queues/rx-*/rps_cpus`.
- **RFS** (Receive Flow Steering): steers a flow to the CPU where the consuming
  application runs, improving cache locality. `net.core.rps_sock_flow_entries`.

At scale, mis-tuned IRQ affinity (all queues' IRQs pinned to CPU0) is a classic
throughput cliff that no application-level metric reveals.

**Up the stack.** `__netif_receive_skb_core()` runs the tc ingress (clsact) hook, the
netfilter netdev-ingress hook, then dispatches by `skb->protocol` to the registered
`packet_type` handler (`ip_rcv` for IPv4). From there: netfilter PREROUTING,
conntrack, routing decision (`ip_rcv_finish` -> `fib_lookup`), then either the local
delivery path (`ip_local_deliver` -> netfilter INPUT -> `tcp_v4_rcv`) or forwarding
(netfilter FORWARD -> POSTROUTING -> `dev_queue_xmit`).

**L4 demux and the socket queue.** `tcp_v4_rcv()` looks up the owning socket by the
4-tuple in a hash table (`ehash` for established, `lhash` for listeners). For an
established connection the data is appended to `sk->sk_receive_queue` and the socket's
`sk_data_ready` callback wakes any thread blocked in `recv()`/`epoll_wait()`. For a
SYN to a listener, the two-queue handshake machinery kicks in (see §7).

### 2. The transmit path in detail

`send()` copies user data into skbs in the socket send buffer (`sk_wmem`), TCP decides
what to send (`tcp_write_xmit`, honoring cwnd/rwnd), GSO defers segmentation so a big
skb travels most of the stack as one unit (segmented late, ideally offloaded to the
NIC as TSO). `ip_queue_xmit` adds the IP header, netfilter LOCAL_OUT and POSTROUTING
run, and `dev_queue_xmit()` hands the skb to the interface's **qdisc** (§6). The qdisc
enqueues, then dequeues into the driver's `ndo_start_xmit`, which places it on the TX
ring for DMA. A TX-completion interrupt later frees the skb. Backpressure: if the qdisc
is full, `dev_queue_xmit` returns `NET_XMIT_DROP` and TCP treats it as congestion. BQL
(Byte Queue Limits, `/sys/class/net/eth0/queues/tx-*/byte_queue_limits/`) bounds how
many bytes sit in the ring to fight bufferbloat at the driver layer.

### 3. sk_buff: the packet's home

`struct sk_buff` (`include/linux/skbuff.h`) is one of the most important structures in
the kernel. Mental model:

```
 sk_buff (metadata)                     linear data buffer (skb->head .. skb->end)
 +-----------------+                    +----+--------+---------+---------+--------+
 | head, data,     |----- head ------->|head| room   | headers | payload | tail   |
 | tail, end       |                    |room|(push)  |  L2/L3  |  L4     | room   |
 | len, data_len   |                    +----+--------+---------+---------+--------+
 | mac/network/    |                             ^data      ^tail   ^end
 |   transport hdr |                    skb_reserve/push/pull/put move these pointers
 | dev, sk         |                    Non-linear payload lives in skb_shared_info
 | cb[48] (per-    |                    (page frags + frag_list) at skb->end
 |   layer scratch)|
 +-----------------+
```

Key mechanisms a senior knows:
- **Header pointers, not copies.** `skb_pull`/`skb_push` just move `skb->data`. Layers
  don't copy the packet as it climbs; they slide a pointer. This is why zero-copy
  matters and why an out-of-bounds header parse is a real risk (the verifier enforces
  bounds checks in eBPF for exactly this reason, §9).
- **Non-linear skbs.** Large/GRO'd packets keep payload in page fragments referenced
  by `skb_shared_info`, not the linear buffer. `skb_headlen()` vs `skb->data_len`.
  `skb_linearize()` collapses them (expensive) when a consumer needs contiguous bytes.
- **Cloning vs copying.** `skb_clone()` shares the data buffer (bumps a refcount) and
  copies only metadata; tcpdump/AF_PACKET taps clone. `pskb_copy`/`skb_copy` deep-copy.
  Writing to a cloned skb triggers copy-on-write (`skb_cow`).
- **`skb->cb[48]`** is per-layer scratch (TCP stores control block state here).
- **Truesize** (`skb->truesize`) is the real memory footprint and is what socket
  memory accounting charges against `sk_rmem`/`sk_wmem`, not `skb->len`. A flood of
  tiny packets can exhaust socket memory while `len`-based accounting looks fine.

### 4. Netfilter hooks and nftables

Netfilter is five hook points in the IPv4/IPv6 path plus the newer netdev hooks. Every
firewall, NAT, and conntrack decision happens at one of these:

```
                         PREROUTING          FORWARD          POSTROUTING
   NIC --[netdev        [conntrack,         (filter)         [SNAT/       --> NIC
        ingress]---------> DNAT] --- routing decision --------> masquerade]
                              |                                    ^
                          local dest                               |
                              v                                    |
                           INPUT ---> local socket ---> OUTPUT ----'
```

**Hook priorities (this is the exam question).** Multiple chains can attach to the same
hook; they run in ascending integer priority. The canonical values (from
`uapi/linux/netfilter_ipv4.h`, exposed as nft names) explain *why* things happen in the
order they do:

| Priority | Name | What lives here |
|---|---|---|
| -400 | CONNTRACK_DEFRAG | IP defragmentation |
| -300 | RAW | `raw` table (e.g. `NOTRACK`), runs before conntrack |
| -225 | SELINUX_FIRST | SELinux |
| -200 | CONNTRACK | connection tracking creates/looks up the tuple |
| -150 | MANGLE | packet mangling |
| -100 | NAT_DST (DSTNAT) | DNAT (prerouting) |
| 0 | FILTER | the default `filter` table / accept-drop decisions |
| 50 | SECURITY | SELinux secmark table |
| 100 | NAT_SRC (SRCNAT) | SNAT/masquerade (postrouting) |
| 300 | CONNTRACK_HELPER | ALG helpers (ftp, sip) |

Consequences you must internalize: conntrack runs at **-200** in prerouting, so DNAT at
-100 happens *after* the tuple is created but conntrack records the pre-DNAT tuple and
rewrites reply packets accordingly. NAT only actually rewrites on the *first* packet of
a flow; subsequent packets are handled by conntrack's stored NAT transformation, which
is why a `nat`-type chain must not be flushed mid-flow. Also why you can't put a filter
chain at priority < -200 and expect conntrack state (`ct state established`) to be
populated: it hasn't run yet.

**Netdev hooks.** `ingress` (since 4.2) sees the frame right after the driver, before
`prerouting`, in the same place as tc ingress and before conntrack: ideal for early
drop/DDoS filtering without conntrack cost. `egress` (nft support since Linux 5.16)
mirrors it on the way out, positioned right before tc egress, so a mark set here is
visible to tc.

**The nftables VM.** nft is not "iptables with new syntax." Under the hood it is a tiny
bytecode VM (`nf_tables` core) that evaluates *expressions* against the packet and
executes *statements*. A rule is a list of expressions; matching loads a packet field
(payload, meta, ct) into a register and compares. The power comes from first-class data
structures the kernel evaluates in one shot:
- **sets** (`ip saddr @blocklist`) backed by a hashtable or, for ranges, an interval
  tree (rbtree) — O(1)/O(log n) instead of a linear chain of rules;
- **maps and verdict maps** (`ip daddr map { ... }`, `vmap`) — data-driven dispatch;
- **concatenations** — match tuples like `. ip saddr . tcp dport .` in one set.

This is why nftables scales where iptables' linear rule traversal collapses: a 100k-entry
iptables ipset-less ruleset is 100k comparisons per packet; the nft set is one lookup.

**iptables mental-model mapping.** iptables *tables* were an artifact of separate kernel
modules; nft has no fixed tables, you create chains at whatever hook+priority you want.
The mapping:

| iptables table | nft base-chain hook + priority |
|---|---|
| raw | prerouting/output @ raw (-300) |
| mangle | any hook @ mangle (-150) |
| nat | prerouting @ dstnat (-100) / postrouting @ srcnat (100) |
| filter | input/forward/output @ filter (0) |

On RHEL/Rocky 8+ the `iptables` command is by default `iptables-nft` — a translation
shim that programs nft under the hood. `nft list ruleset` shows you the reality; the
legacy `iptables -L` output is a compatibility fiction. Mixing native nft rules and
iptables-nft rules on overlapping hooks is a real production footgun (ordering surprises).

### 5. Routing, FIB, and policy routing

The routing decision is a longest-prefix-match lookup in the FIB (Forwarding
Information Base), implemented as an LPC-trie (`fib_trie`, `net/ipv4/fib_trie.c`). But
before the main table is consulted, the kernel walks the **routing policy database**
(`ip rule`), a priority-ordered list of rules (`fib_rules`). Each rule has a selector
(source, `fwmark`, `iif`, `tos`, uid range) and an action, normally "look up table N."
First match wins. Default rules:

```
0:      from all lookup local     # kernel-owned; local/broadcast addresses
32766:  from all lookup main      # your normal routes
32767:  from all lookup default
```

Policy routing = insert rules before 32766 that send matched traffic to a custom table.
The canonical use is multi-homing and mark-based routing: mark packets with nft/iptables
(`meta mark set` / `-j MARK`), then `ip rule add fwmark 0x1 table 100`. Named tables
live in `/etc/iproute2/rt_tables`. This is exactly the mechanism VPNs, WireGuard's
`Table=`, Kubernetes egress gateways, and multi-ISP failover use. `ip route get <dst>`
tells you the actual decision including which table and rule fired — always use it
instead of eyeballing `ip route show`.

Scale/failure notes: the FIB trie is fast but route churn (BGP full tables, ~1M routes)
stresses memory and update latency; `ip -s route` and `/proc/net/fib_trie` expose it.
Reverse-path filtering (`net.ipv4.conf.*.rp_filter`) silently drops asymmetrically-routed
packets — the single most common "policy routing works one way only" bug.

### 6. tc: qdiscs, classes, filters

Every TX interface has a **qdisc** (queueing discipline) that decides the order and
timing of dequeue. The default on modern kernels is `fq_codel` (fair-queue + CoDel AQM)
on single-queue devices, or `mq` (a root that delegates to one child qdisc per hardware
TX queue) on multiqueue NICs — an important detail: on a multiqueue NIC, replacing "the"
qdisc means replacing each per-queue child, and a naive `tc qdisc replace dev eth0 root`
may not do what you think.

Taxonomy:
- **Classless** qdiscs shape/schedule a single stream: `pfifo_fast` (legacy 3-band
  priority FIFO), `fq_codel`/`cake` (modern AQM that fights bufferbloat by dropping/ECN-marking
  when standing queue latency exceeds a target), `netem` (deliberately inject
  latency/loss/reorder — indispensable for testing), `tbf` (token bucket rate limit).
- **Classful** qdiscs build a tree: `htb` (Hierarchical Token Bucket) is the workhorse
  for guaranteed/ceiling bandwidth per class; `hfsc` for latency+rate decoupling. Leaf
  classes get their own child qdisc (usually fq_codel).

A packet's path through a classful qdisc: **filters** (tc filters: u32, flower, or a
bpf classifier) classify the skb into a **class**; the class's qdisc enqueues it; the
root's dequeue algorithm decides who transmits next.

```
        root htb 1:
        /     |     \
     1:10   1:20   1:30      <- classes with rate/ceil
      |       |      |
   fq_codel fq_codel netem   <- leaf qdiscs
      ^ filters (flower/u32/bpf) sort skbs into classes
```

**clsact** is the modern ingress+egress hook qdisc for attaching eBPF (`tc filter ...
bpf da`) — this is where Cilium does most of its dataplane work. Direct-action (`da`)
lets the eBPF program return the verdict itself.

CAKE deserves a callout: it rolls shaping, per-flow and per-host fairness, and DiffServ
handling into one qdisc and is the current best answer for last-mile bufferbloat.

Failure mode at scale: a single deep FIFO qdisc (or a driver with a huge TX ring and no
BQL) creates bufferbloat — RTT balloons under load even though throughput looks fine.
The tell is high `ping` latency *only when the link is saturated*, invisible to
bandwidth graphs. `tc -s qdisc show dev eth0` (backlog, drops, overlimits) plus
`fq_codel`'s per-flow stats diagnose it.

### 7. Socket internals and the two-queue accept model

`struct sock` (`include/net/sock.h`) is the protocol-agnostic socket; `tcp_sock`
embeds it. Key fields: `sk_receive_queue`, `sk_write_queue`, `sk_rmem_alloc`/`sk_wmem_alloc`
(memory accounting vs `sk_rcvbuf`/`sk_sndbuf` limits), `sk_backlog` (packets that
arrive while the socket is locked by a syscall), and the callbacks `sk_data_ready`,
`sk_write_space`, `sk_state_change`.

**The listen handshake uses two queues**, and confusing them is the top TCP-scaling bug:
- **SYN queue** (a.k.a. request-sock queue): connections in `SYN_RECV` — SYN received,
  SYN-ACK sent, final ACK not yet arrived. Bounded by `net.ipv4.tcp_max_syn_backlog`.
- **Accept queue** (completed queue): fully-established connections waiting for the app
  to call `accept()`. Bounded by `min(backlog, net.core.somaxconn)` where `backlog` is
  the second arg to `listen(2)`. `somaxconn` default rose to 4096 in recent kernels
  (was 128 for decades — a famous silent bottleneck).

```
 SYN --> [ SYN queue ]  --final ACK-->  [ accept queue ] --accept()--> fd
         (SYN_RECV)                     (ESTABLISHED)
   overflow: SYN drop or               overflow: drop ACK, resend SYN-ACK,
   syncookies                          or reset if tcp_abort_on_overflow=1
```

- **Accept-queue overflow** happens when the application is too slow to `accept()`. The
  kernel drops the client's final ACK (default) and the connection silently retries;
  the counter is `ListenOverflows` and `ListenDrops` in `nstat -a` / `netstat -s`. This
  is the "our service intermittently hangs on connect under load" bug — the app, not the
  network.
- **SYN-queue overflow / SYN flood.** `net.ipv4.tcp_syncookies=1` lets the server encode
  the connection state into the SYN-ACK sequence number (a cryptographic cookie) and
  discard SYN-queue state entirely, so it can complete handshakes without holding
  per-embryo memory. Cost: TCP options (window scaling, SACK, timestamps) are
  reconstructed with reduced fidelity, so syncookies are a survival mechanism, not a
  free lunch.

**SO_REUSEPORT** lets N sockets bind the same ip:port; the kernel hashes each incoming
connection to one of the group's listeners (`sk_reuseport_cb`, an array that starts at
128 sockets and doubles). This gives per-thread accept queues and kills the accept-lock
contention and thundering-herd of one shared listener. A `BPF_PROG_TYPE_SK_REUSEPORT`
program can override the hash for custom steering. Pre-5.14 there was a real defect:
closing a listener dropped in-flight handshakes and queued children even though a
sibling could have taken them — relevant for zero-downtime restarts.

**epoll scalability.** `EPOLLEXCLUSIVE` (4.5+) wakes one waiter per event instead of the
whole herd; level- vs edge-triggered semantics and the classic "epoll is broken for
accept load balancing" articles are required reading (see resources). `SO_INCOMING_CPU`
and RFS align the wakeup CPU with the softirq CPU for cache locality.

### 8. Connection tracking (conntrack)

Conntrack (`nf_conntrack`) is the stateful core under NAT and `ct state` matching. On
the first packet of a flow it creates a `struct nf_conn` recording both directions'
tuples (`IP_CT_DIR_ORIGINAL` / `IP_CT_DIR_REPLY`) in a hashtable, and every subsequent
packet is matched to it. NAT is layered on top: the translation is stored in the conn
and applied automatically to the whole flow, which is why you NAT the first packet and
conntrack handles the rest.

State machine (for TCP): `NEW -> ESTABLISHED -> ...`, with `RELATED` for helper-spawned
flows (FTP data channel) and `INVALID` for packets that don't fit. `ct state` in nft
matches these.

**The failure mode that pages you:** `nf_conntrack: table full, dropping packet`. This
is *not* CPU or memory exhaustion; it's slot exhaustion. Two knobs:
- `net.netfilter.nf_conntrack_max` — max tracked flows (default often 65536, way too low
  for a busy LB/NAT box or a Kubernetes node).
- `net.netfilter.nf_conntrack_buckets` (via `nf_conntrack_hashsize`) — hashtable buckets.
  Rule of thumb: `max ~= 4 * buckets`. If buckets is too small, each bucket becomes a
  long linked list and *lookups* degrade (per-packet cost), a subtler killer than
  outright drops.

Diagnostics: `conntrack -L` (live table), `conntrack -S` (per-CPU stats: `insert_failed`,
`drop`, `early_drop`), `cat /proc/sys/net/netfilter/nf_conntrack_count`. Mitigations
beyond raising limits: shorten timeouts for short-lived flows
(`nf_conntrack_tcp_timeout_time_wait`), or exempt high-volume/stateless traffic with a
`notrack` rule in the raw/-300 chain so it never consumes a slot. On Kubernetes nodes,
conntrack exhaustion from kube-proxy iptables/ipvs NAT is a canonical incident; it's why
Cilium's eBPF datapath can bypass conntrack for some paths entirely.

Conntrack is also a *correctness* landmine: it defrags (at -400) and holds flow state, so
asymmetric routing (reply takes a different box) breaks NAT, and flushing conntrack
mid-flow breaks established connections. The `flowtable` fast path (`docs.kernel.org/networking/nf_flowtable.html`)
offloads established flows past the full netfilter traversal (and even to hardware),
another modern scaling lever.

### 9. XDP and eBPF on the datapath

**XDP (eXpress Data Path)** runs an eBPF program at the *earliest possible* point — in
the driver's RX poll, on the raw DMA buffer, **before any skb is allocated**. That "no
skb" property is the whole point: skb allocation is expensive, so dropping/redirecting
before it is what enables tens of millions of pps on one box (DDoS scrubbing, L4 load
balancing like Meta's Katran, Cloudflare's L4Drop).

Return codes (the verdict): `XDP_DROP` (free the buffer, ~free DDoS mitigation),
`XDP_PASS` (continue up the normal stack, allocating the skb), `XDP_TX` (bounce back out
the same NIC — needs driver support), `XDP_REDIRECT` (send to another NIC or into an
AF_XDP socket), `XDP_ABORTED` (drop + tracepoint, signals a bug).

Three attach modes, and knowing the difference is a senior tell:
- **Native/driver** — the driver implements the XDP hook; full performance. Requires
  driver support (ixgbe, i40e, mlx5, virtio-net, veth, etc.).
- **Offloaded** — the program runs on the NIC (SmartNIC, e.g. Netronome). Rare.
- **Generic/SKB** — kernel fallback for any device, runs *after* skb allocation in
  `__netif_receive_skb`. Works everywhere, but loses XDP's performance premise. If your
  XDP program "works but isn't fast," you're silently in generic mode.

**tc/BPF (clsact)** is the other datapath hook: it runs later (skb exists, so you have
full metadata and can see egress), and is where policy/observability that needs skb
context lives. XDP is for speed on ingress; tc-bpf is for richer skb-aware processing
both directions. Cilium uses both.

**The eBPF machine model** (why the constraints exist): a restricted 64-bit RISC VM,
JIT-compiled to native. The **verifier** is the gatekeeper — it does static analysis to
prove the program terminates and is memory-safe *before* load: no unbounded loops
(bounded loops allowed since 5.3), every pointer dereference must be provably in-bounds
(hence the endless `if (data + sizeof(hdr) > data_end) return XDP_DROP;` in packet
parsers), and a complexity ceiling (~1M instructions analyzed). Programs communicate with
userspace and hold state via **maps** (hash, array, LRU, per-CPU, LPM-trie for
longest-prefix, ringbuf for events). **CO-RE + BTF** (Compile Once, Run Everywhere) is
the modern portability mechanism: the program carries relocations resolved against the
running kernel's BTF type info, so one binary runs across kernel versions without
recompiling against each kernel's headers. This is what made bpftrace/bcc tooling
practical to ship.

### 10. Network namespaces, veth, bridges: container networking from first principles

**Namespaces** virtualize kernel resources per-process; the **network namespace**
(`CLONE_NEWNET`) gives a process its own interfaces, routing tables, netfilter rules,
conntrack table, `/proc/net`, and port space. A namespace is created by
`clone(CLONE_NEWNET)`/`unshare(CLONE_NEWNET)`/`setns()`; `ip netns add` does it and bind-mounts
the nsfs handle under `/var/run/netns/` so it persists without a process. Every process
has an entry in `/proc/PID/ns/net` — two processes in the same namespace share the
inode number there. This *is* what a container's network isolation is, at the syscall
level; Docker just automates it.

**veth** is a virtual Ethernet cable: a pair of interfaces where a frame written to one
end pops out the other. It is the wire that connects a namespace to the outside. You put
one end in the container namespace and the other in the host (or a bridge).

**bridge** is a software L2 switch (`brctl`/`ip link add type bridge`): it learns MACs
and forwards frames between enslaved ports. Docker's `docker0` is exactly this. The full
container-networking recipe, which you'll build by hand in Lab 2:

```
 host netns                                    container netns (ns1)
 +------------------------------+              +-----------------------+
 |            br0 (bridge)      |              |                       |
 |         10.10.0.1/24         |              |   veth1 (eth0)        |
 |        /        \            |              |   10.10.0.2/24        |
 |   veth0-h     [uplink NAT    |    "cable"   |   default via         |
 |     |          via nft       |<====veth====>|      10.10.0.1        |
 |     '-- enslaved to br0]     |              |                       |
 +------------------------------+              +-----------------------+
   + ip_forward=1
   + nft masquerade oifname eth0   (SNAT container subnet to host IP)
```

That is the entire Docker bridge-network model: namespace + veth + bridge +
`net.ipv4.ip_forward` + a masquerade rule + (for published ports) a DNAT rule. CNI
plugins (bridge, ipvlan, macvlan) and Kubernetes are elaborations on these primitives.

**Mount-namespace-adjacent detail that bites containers:** veth and bridge live in the
network namespace, but the *rules* (nft, conntrack, sysctls like `ip_forward`,
`rp_filter`) are also per-netns. A container has its own empty conntrack table and its
own `net.ipv4.*` — a sysctl you set on the host does not apply inside. This per-namespace
independence is why "it works on the host but not in the container" is so common.

`macvlan`/`ipvlan` are alternatives to the veth+bridge pair: they hang virtual
interfaces directly off a physical NIC with distinct MACs (macvlan) or shared MAC and
distinct IPs (ipvlan L3), avoiding the bridge and its forwarding overhead — used when you
want containers to appear as first-class hosts on the physical LAN.

---

## Hands-on labs

> All labs assume a throwaway Linux VM (any distro with a >=5.15 kernel; examples tested
> on Rocky 9 / Debian 12 / Ubuntu 22.04+). Run as root or via `sudo`. Nothing here
> touches persistent config outside the lab unless stated; namespaces and veths vanish on
> reboot. Install once, distro-agnostic:
>
> ```bash
> # Debian/Ubuntu
> apt-get install -y iproute2 nftables tcpdump conntrack bpftrace ethtool netcat-openbsd
> # RHEL/Rocky/Fedora
> dnf install -y iproute nftables tcpdump conntrack-tools bpftrace ethtool nmap-ncat
> ```

### Lab 1 — Make the RX path visible: softnet, backlog, and the queues that lie

**Objective.** See, with real counters, that "no drops" at the interface level can hide
drops at the NIC ring, the per-CPU backlog, and the socket accept queue. Build the reflex
of reading `/proc/net/softnet_stat` and `nstat`.

**Setup.**
```bash
# a loopback-only lab needs no NIC; we'll use a veth pair to have a real driver path
ip link add veth-a type veth peer name veth-b
ip addr add 10.0.0.1/24 dev veth-a
ip addr add 10.0.0.2/24 dev veth-b
ip link set veth-a up
ip link set veth-b up
```

**Steps.**
1. Snapshot the softnet stats and understand the columns. Column 1 = packets processed,
   column 2 = dropped (backlog full), column 3 = time_squeeze (budget exhausted), one row
   per CPU, all hex:
   ```bash
   cat /proc/net/softnet_stat
   ```
2. Watch per-CPU softirq work live while you generate load. In one terminal:
   ```bash
   # flood small UDP packets across the veth
   timeout 20 bash -c 'yes | tr "\n" "x" | head -c 100000000 | \
     while read -r _; do :; done' &  # cpu noise
   ping -f -s 1400 10.0.0.2 &        # flood ping over the veth
   watch -n1 'grep . /proc/net/softnet_stat; echo; \
     grep -E "RX|TX" /proc/net/dev | head'
   ```
3. Shrink the backlog to *force* a column-2 drop and prove you can create the failure:
   ```bash
   sysctl -w net.core.netdev_max_backlog=1     # absurdly small, lab only
   # hammer it
   ping -f -s 1400 -c 100000 10.0.0.2 >/dev/null
   ```
4. Now the accept-queue lie. Start a listener with a tiny backlog and never accept:
   ```bash
   # backlog of 1, then stall; use python for explicit listen() backlog control
   python3 - <<'EOF' &
   import socket,time
   s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
   s.bind(("10.0.0.1",9999)); s.listen(1)   # backlog=1
   time.sleep(60)                            # never accept()
   EOF
   sleep 1
   # fire many connections that complete the handshake but never get accepted
   for i in $(seq 1 50); do (exec 3<>/dev/tcp/10.0.0.1/9999) 2>/dev/null & done
   ```
5. Read the overflow counter:
   ```bash
   nstat -az | grep -Ei 'ListenOverflow|ListenDrop|SyncookiesSent'
   ss -ltn 'sport = :9999'      # Recv-Q = current accept queue depth, Send-Q = max
   ```

**Prove it.** The accept-queue overflow is visible and non-zero even though `ip -s link`
shows zero interface drops:
```bash
nstat -az TcpExtListenOverflows TcpExtListenDrops
# TcpExtListenOverflows  <nonzero>  0.0
```
If `ListenOverflows` is non-zero while `ip -s link show veth-a` reports zero RX/TX drops,
you have proven the core lesson: the interface counter and the socket counter measure
different handoffs. Reset when done: `sysctl -w net.core.netdev_max_backlog=1000`.

**Teardown.** `ip link del veth-a` (deletes the pair); `kill %1 %2 2>/dev/null`.

---

### Lab 2 — Build container networking from scratch (netns + veth + bridge + NAT)

**Objective.** Reconstruct, by hand, exactly what Docker's default bridge network does:
isolated namespaces, a veth to each, a bridge tying them together, `ip_forward`, and an
nftables masquerade so containers reach the internet. Then publish a port with DNAT.

**Setup.** A VM with one uplink interface that has internet access. Find it:
```bash
UPLINK=$(ip route show default | awk '{print $5; exit}')
echo "uplink is $UPLINK"
```

**Steps.**
1. Create two "container" namespaces:
   ```bash
   ip netns add c1
   ip netns add c2
   # prove isolation: c1 has only loopback, down
   ip netns exec c1 ip link
   ```
2. Build the bridge in the host namespace and give it the gateway IP:
   ```bash
   ip link add br0 type bridge
   ip addr add 10.10.0.1/24 dev br0
   ip link set br0 up
   ```
3. Wire each namespace to the bridge with a veth pair:
   ```bash
   for c in c1 c2; do
     ip link add "veth-$c" type veth peer name "in-$c"
     ip link set "veth-$c" master br0        # host end -> bridge port
     ip link set "veth-$c" up
     ip link set "in-$c" netns "$c"          # other end -> container ns
   done
   # inside each namespace, configure the container end
   ip netns exec c1 ip addr add 10.10.0.11/24 dev in-c1
   ip netns exec c1 ip link set in-c1 up
   ip netns exec c1 ip link set lo up
   ip netns exec c1 ip route add default via 10.10.0.1
   ip netns exec c2 ip addr add 10.10.0.12/24 dev in-c2
   ip netns exec c2 ip link set in-c2 up
   ip netns exec c2 ip link set lo up
   ip netns exec c2 ip route add default via 10.10.0.1
   ```
4. Container-to-container should already work over the bridge (pure L2). Confirm:
   ```bash
   ip netns exec c1 ping -c2 10.10.0.12
   ```
5. Now reach the outside. Enable forwarding and add the masquerade rule with nft:
   ```bash
   sysctl -w net.ipv4.ip_forward=1
   nft add table ip nat
   nft add chain ip nat postrouting '{ type nat hook postrouting priority srcnat; }'
   nft add rule ip nat postrouting ip saddr 10.10.0.0/24 oifname "$UPLINK" masquerade
   ip netns exec c1 ping -c2 1.1.1.1
   ```
6. Publish a port: run a listener in c1 and DNAT host port 8080 to it.
   ```bash
   ip netns exec c1 python3 -m http.server 80 --bind 10.10.0.11 &
   nft add chain ip nat prerouting '{ type nat hook prerouting priority dstnat; }'
   nft add rule ip nat prerouting tcp dport 8080 dnat to 10.10.0.11:80
   # from the host:
   curl -s http://127.0.0.1:8080/ >/dev/null && echo "DNAT works"  # may need hairpin; test from another host if not
   ```

**Prove it.** Watch conntrack record the NAT translation for the container's flow — this
is the proof that stateful NAT is doing the work, and it shows both tuples:
```bash
ip netns exec c1 ping -c1 1.1.1.1 &
conntrack -L 2>/dev/null | grep '10.10.0.11'
# icmp ... src=10.10.0.11 dst=1.1.1.1 ... src=1.1.1.1 dst=<HOST_UPLINK_IP> ...
```
Seeing the reply tuple's `dst=` rewritten to the host's uplink IP proves masquerade +
conntrack are translating the flow. Bonus understanding: `ip netns exec c1 conntrack -L`
shows an *empty* table — conntrack is per-namespace, the translation lives in the host ns.

**Teardown.**
```bash
ip netns del c1; ip netns del c2
ip link del br0
nft delete table ip nat
sysctl -w net.ipv4.ip_forward=0
```

---

### Lab 3 — Netfilter hook ordering and conntrack exhaustion, observed

**Objective.** Prove the hook-priority ordering with `nft monitor trace`, watch a packet
traverse prerouting -> conntrack -> filter, and then deliberately exhaust the conntrack
table to reproduce the `table full` incident and see which counter fires.

**Setup.** Reuse the c1 namespace + bridge from Lab 2, or a fresh veth pair. We'll trace
traffic to a local listener.
```bash
nft add table inet t
nft add chain inet t input '{ type filter hook input priority filter; policy accept; }'
```

**Steps.**
1. Turn on tracing for ICMP to see the hook journey. Add a trace-marking rule at
   prerouting and start the monitor:
   ```bash
   nft add chain inet t pre '{ type filter hook prerouting priority raw; }'
   nft add rule inet t pre icmp type echo-request meta nftrace set 1
   nft monitor trace &
   ping -c1 10.10.0.11    # or your veth peer
   sleep 1; kill %1
   ```
   Read the trace output: each line shows the chain, hook, and the `ct state` at that
   point. Note that `ct state` is `new` by the time you reach `filter` (priority 0) but
   the conntrack lookup itself happened at priority -200, *after* your raw-priority
   prerouting chain at -300. That ordering is the whole lesson.
2. Inspect current conntrack sizing:
   ```bash
   sysctl net.netfilter.nf_conntrack_max
   cat /proc/sys/net/netfilter/nf_conntrack_count
   conntrack -S | head   # per-cpu: found, insert, insert_failed, drop, early_drop
   ```
3. Shrink the table to make exhaustion trivial to hit (lab only), then flood new flows:
   ```bash
   sysctl -w net.netfilter.nf_conntrack_max=128
   # generate many distinct short-lived flows (each unique src port = new conntrack entry)
   for p in $(seq 1 2000); do
     timeout 0.05 bash -c "exec 3<>/dev/udp/10.10.0.11/$((20000+p))" 2>/dev/null &
   done; wait 2>/dev/null
   ```
4. Watch for the drop:
   ```bash
   dmesg | tail -5                       # look for "nf_conntrack: table full"
   conntrack -S | awk '{for(i=1;i<=NF;i++) if($i ~ /drop|insert_failed/) print $i}'
   ```

**Prove it.** A non-zero `insert_failed` or `drop` in `conntrack -S`, and/or the kernel
log line, with `nf_conntrack_count` pinned at the max you set:
```bash
conntrack -S | grep -o 'insert_failed=[1-9][0-9]*' | head -1
# insert_failed=<nonzero>
```
Now fix it the right way and re-run to show the drop stops:
```bash
sysctl -w net.netfilter.nf_conntrack_max=262144
```
Understand: raising `nf_conntrack_max` alone without raising `nf_conntrack_buckets`
(`echo 65536 > /sys/module/nf_conntrack/parameters/hashsize`) leaves long hash chains and
degrades per-packet lookup. Keep `max ~= 4 * buckets`.

**Teardown.**
```bash
nft delete table inet t
sysctl -w net.netfilter.nf_conntrack_max=262144   # or your original value
```

---

### Lab 4 — XDP_DROP + tc netem: the datapath at the edges

**Objective.** Attach a minimal XDP program that drops a chosen packet type at the driver
hook (before an skb exists), confirm it via bpftrace on the XDP tracepoint, and then use
tc/netem to inject latency and see bufferbloat vs fq_codel behavior. This makes the two
ends of the datapath (earliest ingress hook, egress qdisc) tangible.

**Setup.** veth supports native XDP, so no special NIC needed.
```bash
ip link add xa type veth peer name xb
ip addr add 192.168.9.1/24 dev xa
ip addr add 192.168.9.2/24 dev xb
ip link set xa up; ip link set xb up
```

**Steps (XDP drop).**
1. Write a tiny XDP program that drops ICMP echo requests. Save as `xdp_drop.c`:
   ```c
   #include <linux/bpf.h>
   #include <linux/if_ether.h>
   #include <linux/ip.h>
   #include <bpf/bpf_helpers.h>

   SEC("xdp")
   int drop_icmp(struct xdp_md *ctx) {
       void *data = (void *)(long)ctx->data;
       void *data_end = (void *)(long)ctx->data_end;
       struct ethhdr *eth = data;
       if ((void *)(eth + 1) > data_end) return XDP_PASS;   // bounds check (verifier)
       if (eth->h_proto != __builtin_bswap16(ETH_P_IP)) return XDP_PASS;
       struct iphdr *ip = (void *)(eth + 1);
       if ((void *)(ip + 1) > data_end) return XDP_PASS;    // bounds check
       if (ip->protocol == IPPROTO_ICMP) return XDP_DROP;   // drop pings, pre-skb
       return XDP_PASS;
   }
   char _license[] SEC("license") = "GPL";
   ```
   Build and load (needs clang + libbpf-devel/ libbpf-dev):
   ```bash
   clang -O2 -g -target bpf -c xdp_drop.c -o xdp_drop.o
   ip link set dev xb xdp obj xdp_drop.o sec xdp   # native XDP on the xb end
   ```
2. Confirm the mode. `xdp` (not `xdpgeneric`) in the link output means you're in native
   driver mode, the whole point:
   ```bash
   ip -details link show xb | grep -i xdp
   ```
3. Prove the drop happens and that it's counted at XDP, not in the IP stack:
   ```bash
   # this should now fail/time out because pings to xb are dropped at the driver hook
   ping -c3 -W1 192.168.9.2
   # watch XDP action counts (RHEL/modern iproute exposes them; else use bpftool)
   bpftool prog show                     # find the loaded prog id
   ```
   Trace the action live with bpftrace on the xdp tracepoint:
   ```bash
   bpftrace -e 'tracepoint:xdp:xdp_exception { @[args->act] = count(); }' &
   ping -c3 -W1 192.168.9.2; sleep 1; kill %1
   ```

**Steps (netem bufferbloat vs fq_codel).**
4. Remove XDP, then add 100ms latency + a huge dumb FIFO on egress and measure RTT under
   load:
   ```bash
   ip link set dev xb xdp off
   tc qdisc replace dev xa root netem delay 100ms limit 100000
   ping -c3 192.168.9.2        # ~100ms baseline
   # saturate the link while pinging: watch RTT balloon (bufferbloat)
   (timeout 10 dd if=/dev/zero bs=64k | nc -q0 192.168.9.2 9  2>/dev/null) &
   ping -c10 192.168.9.2
   ```
5. Swap the dumb queue for fq_codel and repeat — RTT under load should stay controlled:
   ```bash
   tc qdisc replace dev xa root fq_codel
   tc -s qdisc show dev xa      # watch 'maxpacket', 'drop_overlimit', 'new_flows_len'
   ```

**Prove it.** For XDP: `ping` to `xb` times out while the interface is *up and healthy*,
and the `xdp` keyword (not `xdpgeneric`) appears in `ip -details link show xb` — proving
a native-mode drop before skb allocation. For tc: `tc -s qdisc show dev xa` under
fq_codel shows non-zero drops/ECN marks keeping queue latency bounded, versus netem's
FIFO where ping RTT under load climbs far above the 100ms base.

**Teardown.**
```bash
ip link set dev xb xdp off 2>/dev/null
ip link del xa
```

---

## Curated resources

Primary kernel docs and man pages first (when a blog and a man page disagree, the man
page wins), then the landmark explainers, then the hands-on repos.

**Primary references (ABI / kernel source of truth)**
- **Netfilter hooks — nftables wiki**, https://wiki.nftables.org/wiki-nftables/index.php/Netfilter_hooks — the authoritative map of the five IP hooks plus netdev ingress/egress, and the exact priority constants. This is the mental model behind *where* every firewall/NAT/conntrack decision happens; memorize the priority table.
- **nftables wiki — main + "Configuring chains" + "Quick reference in 10 minutes"**, https://wiki.nftables.org/wiki-nftables/index.php/Main_Page — the definitive nft docs: the expression/statement VM, sets/maps/verdict-maps/concatenations (the data structures that make nft scale past iptables), and base-chain hook+priority syntax. RHEL/Rocky 8+ default, so current production knowledge.
- **man7: namespaces(7), network_namespaces(7), veth(4), clone(2), unshare(2), setns(2)**, https://man7.org/linux/man-pages/man7/network_namespaces.7.html — Kerrisk's overview pages are dense conceptual essays, not lookups. `network_namespaces(7)` is the definitive statement of what a netns owns; `veth(4)` explains the pair semantics.
- **man7: tcp(7), socket(7), ip(7), unix(7)**, https://man7.org/linux/man-pages/man7/tcp.7.html — the authoritative behavior of the socket layer, including the accept/SYN backlog knobs, `SO_REUSEPORT`, and every `net.ipv4.tcp_*` sysctl's precise meaning.
- **Netfilter's flowtable infrastructure — kernel.org**, https://docs.kernel.org/networking/nf_flowtable.html — the established-flow fast path that bypasses the full netfilter traversal (and can offload to hardware). The modern scaling lever for NAT/forwarding boxes.
- **BPF and XDP Reference Guide — Cilium**, https://docs.cilium.io/en/stable/bpf/ — the best single reference on the eBPF machine model: instruction set, the verifier (why unbounded loops and unchecked pointer arithmetic are rejected, the complexity limit), map types and their tradeoffs, tail calls, and tc vs XDP hook placement. Read this to understand *why* the verifier constrains you.
- **ip-rule(8) / ip-route(8) man pages**, https://man7.org/linux/man-pages/man8/ip-rule.8.html — the policy routing database semantics: rule priority order, selectors (from/fwmark/iif/uidrange), and why `ip route get` is the only honest way to see a routing decision.
- **tc(8) + tc-fq_codel(8) + tc-cake(8) + tc-htb(8) + tc-netem(8)**, https://man7.org/linux/man-pages/man8/tc.8.html — the qdisc/class/filter model and each qdisc's knobs. Pair `tc-cake(8)` and `tc-fq_codel(8)` for the modern AQM story.
- **rockyman.org**, https://rockyman.org/ — authoritative Rocky Linux man-page index, versioned 8/9/10; verify exact flags/config keys here. When a lab command (`nft`, `tc`, `conntrack`, `ip`, `ss`, `nstat`, `ethtool`) needs confirming against the distro the customer actually runs, this is the source of truth for Rocky.

**Landmark explainers**
- **LWN "Namespaces in operation" (Kerrisk, 7-part series)**, https://lwn.net/Articles/531114/ — the definitive from-scratch build-up of every namespace type: how `clone(CLONE_NEW*)`/`unshare`/`setns` manipulate the per-process nsproxy, why user namespaces enabled unprivileged containers, PID/mount/net semantics. The conceptual backbone under Docker/Podman/nspawn.
- **Illustrated Guide to Monitoring and Tuning the Linux Networking Stack: Receiving Data (Packagecloud)**, https://blog.packagecloud.io/illustrated-guide-monitoring-tuning-linux-networking-stack-receiving-data/ — the single best line-by-line walk of the RX path: NIC ring -> hardirq -> NAPI -> `net_rx_action` -> softnet -> protocol stack, mapping each stage to its `/proc`/`ethtool`/sysctl counter and tunable. Its TX companion post is equally good.
- **Thermalcircle: "nftables — packet flow and Netfilter hooks in detail"**, https://thermalcircle.de/doku.php?id=blog:linux:nftables_packet_flow_netfilter_hooks_detail — meticulous diagrams of exactly where each hook sits relative to routing, conntrack, and tc, on both ingress and egress. The clearest treatment of the netdev egress-vs-tc ordering.
- **"How Container Networking Works: Building a Bridge Network From Scratch" (iximiuz Labs)**, https://labs.iximiuz.com/tutorials/container-networking-from-scratch — an interactive, correct rebuild of the netns+veth+bridge+NAT stack; the perfect companion to Lab 2, and iximiuz's XDP tutorial pairs with Lab 4.
- **"Epoll is fundamentally broken" (idea.popcount.org, 2 parts)**, https://idea.popcount.org/2017-02-20-epoll-is-fundamentally-broken-12/ — the definitive treatment of epoll's accept-load-balancing and thundering-herd pathologies, `EPOLLEXCLUSIVE`, and why `SO_REUSEPORT` is usually the better answer. Required reading before you tune a high-connection server.
- **"The SYN and Accept queues" / Cloudflare's "SYN packet handling in the wild"**, https://blog.cloudflare.com/syn-packet-handling-in-the-wild/ — the canonical deep dive on the two-queue handshake, `somaxconn` vs `tcp_max_syn_backlog`, syncookies, and the exact counters (`ListenOverflows`, `ListenDrops`) that reveal accept-queue overflow.

**Hands-on repos and books**
- **xdp-project/xdp-tutorial**, https://github.com/xdp-project/xdp-tutorial — the canonical progressive path into XDP maintained by the XDP maintainers: XDP_PASS, libbpf loaders, header parsing against the verifier, maps, XDP_REDIRECT, AF_XDP zero-copy. Where you learn native vs generic/SKB mode and the XDP_TX driver-support caveat first-hand. Do every lab.
- **bpftrace one-liner tutorial + reference**, https://github.com/bpftrace/bpftrace/blob/master/man/adoc/bpftrace.adoc — escalating one-liners covering kprobe/kretprobe, tracepoints, uprobes, histograms, and stack aggregation. The fastest route from "I know perf top" to answering arbitrary questions about live kernel network behavior with no restart (used in Lab 4).
- **BPF Performance Tools — Brendan Gregg (book + repo)**, https://www.brendangregg.com/bpf-performance-tools-book.html — the networking chapter's ready-to-run tools (tcplife, tcpretrans, tcpconnect, so-timeouts) plus the methodology for *when* to reach for each. The observability endgame for the network stack.
- **Systems Performance, 2nd ed — Brendan Gregg**, https://www.brendangregg.com/systems-performance-2nd-edition-book.html — the networking chapter connects NIC ring buffers -> softirq -> TCP with the USE method, and is the reference for turning "the network feels slow" into a systematic drill-down.
- **The Linux Programming Interface (TLPI) — Kerrisk**, https://man7.org/tlpi/ — the sockets chapters (56-61) are the definitive treatment of the sockets API and its kernel-boundary semantics: the listen backlog, `SO_REUSEADDR`/`SO_REUSEPORT`, UNIX vs INET sockets, and out-of-band data. Written by the man-pages maintainer.
- **Linux Advanced Routing & Traffic Control HOWTO (LARTC)**, https://lartc.org/howto/ — dated in spots but still the best conceptual explanation of policy routing (multiple tables + `ip rule`) and the classful tc hierarchy (HTB enqueue/dequeue, shaping, bufferbloat). Pair the qdisc material with the modern fq_codel/CAKE man pages.
- **Cilium docs — "Life of a Packet" / eBPF datapath**, https://docs.cilium.io/en/stable/network/ebpf/ — how a production eBPF dataplane stitches tc-bpf, XDP, and maps into a full container/K8s network, including conntrack bypass. The best "here's what all these primitives become in anger" resource.

---

## Senior signal

- **Knows which counter measures which handoff, and distrusts the friendly one.** A mid-level reads `ip -s link` sees zero drops and declares the network healthy. A senior checks `ethtool -S` (NIC ring / silicon drops), `/proc/net/softnet_stat` column 2 & 3 (backlog drops, budget squeeze), and `nstat`/`netstat -s` for `ListenOverflows`, `PruneCalled`, `TCPBacklogDrop` — because the drop is almost never at the interface layer everyone looks at first.
- **Diagnoses accept-queue overflow as an application problem, not a network problem.** Recognizes that intermittent connect hangs under load with rising `ListenOverflows` and a pinned `ss -ltn` Recv-Q means the app isn't calling `accept()` fast enough, and knows `somaxconn` + `SO_REUSEPORT` + per-thread accept queues is the fix, not more bandwidth.
- **Reasons about netfilter by hook priority, not by table name.** Can explain why DNAT (-100) sees a conntrack tuple already created at -200, why a `ct state established` match is impossible before conntrack runs, and why iptables-nft and native nft rules on the same hook produce ordering surprises. Reaches for `nft monitor trace` to see the actual traversal instead of guessing.
- **Treats conntrack table exhaustion as slot exhaustion, sizes buckets with max, and knows the `notrack` escape hatch.** Understands that `nf_conntrack: table full` is neither CPU nor memory pressure, that raising `nf_conntrack_max` without `nf_conntrack_buckets` just trades drops for slow lookups, and that stateless high-volume traffic should skip conntrack entirely via a raw/-300 `notrack` rule.
- **Can rebuild container networking from `ip`, `nft`, and `tc` primitives and therefore debug any CNI.** Sees "Docker networking" as netns + veth + bridge + `ip_forward` + masquerade + DNAT, knows conntrack and sysctls are per-namespace (so host-side fixes don't apply inside), and can pick macvlan/ipvlan vs veth+bridge based on the L2/L3 requirement.
- **Distinguishes XDP native vs generic mode on sight and knows the skb boundary.** Understands that XDP's value is dropping/redirecting *before* skb allocation, that "XDP but slow" means you silently fell back to generic/SKB mode, and that tc-bpf (clsact) is the right hook when you need skb context or egress. Knows why the verifier forces the `data + hdr > data_end` bounds check on every parse.
- **Owns bufferbloat as a latency problem invisible to throughput graphs.** Recognizes RTT that balloons *only under saturation* as a queueing problem, reaches for `tc -s qdisc` and fq_codel/CAKE + BQL rather than "the network is congested," and can reason about where the standing queue lives (driver ring vs qdisc vs downstream device).
- **Uses policy routing and `fwmark` fluently, and checks `rp_filter` first.** Reaches for `ip rule` + mark-based tables for multi-homing/VPN/egress-gateway routing, always confirms with `ip route get`, and knows that asymmetric routing silently dies to reverse-path filtering — the first thing to check when "traffic works one direction only."
- **Reads the stack as coupled subsystems.** Can trace a single symptom (a stalled flow) across NIC ring -> softirq/RPS CPU steering -> conntrack state -> qdisc backpressure -> socket buffer limits, rather than treating each as a black box, and picks the one tool (`bpftrace`, `ss`, `conntrack -S`, `tc -s`, `nstat`) that proves or falsifies a specific hypothesis about which boundary is failing.

---

## See also

- [[10 - Namespaces and cgroups v2]] — the network namespace built by hand in Lab 2 is one member of the namespace family covered there; that module generalizes `CLONE_NEWNET`/`unshare`/`setns` to the mount, pid, user, and other namespaces and adds the cgroups v2 resource-control side that pairs with per-netns isolation.
- [[11 - Observability and Tracing with eBPF]] — the XDP/tc-bpf datapath and the verifier/maps/CO-RE machine model from §9 are the networking slice of the broader eBPF tracing toolkit; that module goes deep on bpftrace, kprobes/tracepoints, and the observability workflow used in Lab 1 and Lab 4.
- [[05 - Kubernetes Networking and Workloads]] — CNI plugins, kube-proxy, and Service/pod networking are elaborations of the netns + veth + bridge + conntrack + NAT primitives you build by hand in Lab 2.
- [[04 - VPC Networking Deep]] — cloud VPC routing, security groups, and NAT gateways map onto the FIB/policy-routing, netfilter, and masquerade mechanisms here, just enforced in the provider's fabric.
- [[08 - High-Performance Networking (InfiniBand and RDMA)]] — RDMA/InfiniBand deliberately bypasses this kernel datapath (kernel-bypass, no skb, no conntrack); understanding the stack here is what makes the bypass motivation concrete.
- [[06 - Kubernetes Security (CKS-level)]] — NetworkPolicy enforcement is nftables/eBPF at the pod boundary, built on the hooks and conntrack state covered in §4 and §8.

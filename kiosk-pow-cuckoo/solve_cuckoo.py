#!/usr/bin/env python3
"""
Clean-room Cuckatoo-Cycle proof-of-work solver.
CPU-only, pure Python + numpy (no GPU, no CUDA, no C/C++ toolchain required).
Runs in an assistant sandbox (Mac mini / DigitalOcean VDS / AWS EC2).

Dependencies: numpy  (pip install numpy)

Algorithm: Cuckatoo variant of Cuckoo Cycle by John Tromp.
Clean-room implementation from the public algorithm spec — no GPL/FAIR-MINING
source code copied or adapted.

SipHash-2-4 non-standard init (Cuckatoo variant):
    v0=k0, v1=k1, v2=k2, v3=k3^nonce
    SIPROUND×2; v0^=nonce; v2^=0xff; SIPROUND×4
    return (v0^v1)^(v2^v3)

Keys: blake2b-256(header) → 4 LE-u64 words.
Header: salt_bytes ‖ struct.pack("<I", header_nonce)

Edge endpoints (N = 1<<edgebits, mask = N-1):
    U(i) = siphash(2*i)   & mask
    V(i) = siphash(2*i+1) & mask

A valid proof is 42 strictly-ascending edge indices forming a single 42-cycle
on node-pairs (node>>1), accepted by Kiosk::Pow::Cuckoo.verify.

Key implementation note:
    Cuckatoo trimming operates on NODE-PAIRS (node >> 1), NOT raw node values.
    Each of the N=2^edgebits edges has U[e]∈[0,N-1]; U-pair = U[e]>>1 ∈ [0,N/2-1].
    Mean pair degree = N / (N/2) = 2, which keeps ~20% of edges after trimming.
    Using raw-node trimming instead (mean degree 1) incorrectly destroys all cycles.

Usage:
    python3 solve_cuckoo.py '<challenge json>'
    python3 solve_cuckoo.py  # reads from stdin

Challenge JSON:
    {"salt": "<base64>", "params": {"edgebits": <int>, "proofsize": 42, "target": null}}

Output (one JSON line):
    {"header_nonce": <int>, "cycle": [42 ints ascending]}

Honest performance note:
    edgebits=18  → ~1–10 s on a modern CPU  (demo-safe)
    edgebits=20  → ~10–60 s
    edgebits=29  → infeasible in pure numpy (requires a C miner)
"""

import base64
import hashlib
import json
import os
import struct
import sys
from collections import defaultdict

# Keep numpy single-threaded — this solver is elementwise uint64, not BLAS, and
# uncapped threads were part of the runaway that pinned all cores. Set BEFORE numpy.
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
           "VECLIB_MAXIMUM_THREADS", "NUMEXPR_NUM_THREADS"):
    os.environ.setdefault(_v, "1")

import numpy as np

# ---------------------------------------------------------------------------
# HARD memory guard (safety-critical).
#
# The vectorized siphash keeps ~10-12 live uint64 arrays of N = 2^edgebits
# elements (8 bytes each), so peak ≈ ~96 * 2^edgebits bytes; the cycle-finder
# adds Python-object overhead on top. An uncapped high-edgebits run once ate
# ~524 GB of swap and killed the machine. macOS ignores `ulimit -v`, so we
# self-limit: predict the peak from edgebits and REFUSE before allocating.
#
# Cap is configurable via KIOSK_POW_MAX_BYTES (default 1.5 GiB). This makes the
# solver safe to invoke at ANY edgebits regardless of how it's called.
# ---------------------------------------------------------------------------
_BYTES_PER_EDGE_PEAK = 96          # generous upper bound for the numpy peak
_DEFAULT_MAX_BYTES = 1536 * 1024 * 1024   # 1.5 GiB


def _max_bytes() -> int:
    raw = os.environ.get("KIOSK_POW_MAX_BYTES")
    return int(raw) if raw else _DEFAULT_MAX_BYTES


def _predicted_peak_bytes(edgebits: int) -> int:
    return _BYTES_PER_EDGE_PEAK * (1 << edgebits)


def _enforce_memory_budget(edgebits: int) -> None:
    predicted = _predicted_peak_bytes(edgebits)
    cap = _max_bytes()
    if predicted > cap:
        msg = (
            f"refusing edgebits={edgebits}: predicted peak "
            f"~{predicted / 1024 / 1024:.0f} MiB exceeds cap "
            f"{cap / 1024 / 1024:.0f} MiB (set KIOSK_POW_MAX_BYTES to override). "
            f"This pure-numpy reference solver is for small/demo edgebits only; "
            f"production sizes (29+) need a native solver."
        )
        print(json.dumps({"error": "edgebits_too_large", "message": msg}))
        sys.exit(2)
    # Best-effort OS guard on top (often a no-op on macOS, real on Linux).
    try:
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_AS)
        want = cap + 256 * 1024 * 1024  # cap + headroom
        new_hard = want if hard == resource.RLIM_INFINITY else min(hard, want)
        resource.setrlimit(resource.RLIMIT_AS, (want, new_hard))
    except (ImportError, ValueError, OSError):
        pass

# ---------------------------------------------------------------------------
# Constants (numpy uint64)
# ---------------------------------------------------------------------------
ROT13 = np.uint64(13)
ROT16 = np.uint64(16)
ROT17 = np.uint64(17)
ROT21 = np.uint64(21)
ROT32 = np.uint64(32)
XFF   = np.uint64(0xFF)
ONE   = np.uint64(1)

# ---------------------------------------------------------------------------
# Vectorized SipHash-2-4 (Cuckatoo non-standard init) via numpy.
# Speed-critical: computes all N edge endpoints in parallel.
# ---------------------------------------------------------------------------

def _rotl64_vec(x, n):
    return (x << n) | (x >> (np.uint64(64) - n))


def _sipround_vec(v0, v1, v2, v3):
    v0 = v0 + v1
    v1 = _rotl64_vec(v1, ROT13) ^ v0
    v0 = _rotl64_vec(v0, ROT32)
    v2 = v2 + v3
    v3 = _rotl64_vec(v3, ROT16) ^ v2
    v0 = v0 + v3
    v3 = _rotl64_vec(v3, ROT21) ^ v0
    v2 = v2 + v1
    v1 = _rotl64_vec(v1, ROT17) ^ v2
    v2 = _rotl64_vec(v2, ROT32)
    return v0, v1, v2, v3


def siphash_vec(k0: int, k1: int, k2: int, k3: int, nonces: np.ndarray) -> np.ndarray:
    """
    Vectorized Cuckatoo SipHash-2-4.
    nonces: 1-D numpy array of dtype uint64.
    Returns: uint64 array of same length.
    """
    K0 = np.uint64(k0)
    K1 = np.uint64(k1)
    K2 = np.uint64(k2)
    K3 = np.uint64(k3)

    v0 = np.full(len(nonces), K0, dtype=np.uint64)
    v1 = np.full(len(nonces), K1, dtype=np.uint64)
    v2 = np.full(len(nonces), K2, dtype=np.uint64)
    v3 = np.full(len(nonces), K3, dtype=np.uint64) ^ nonces

    v0, v1, v2, v3 = _sipround_vec(v0, v1, v2, v3)
    v0, v1, v2, v3 = _sipround_vec(v0, v1, v2, v3)

    v0 ^= nonces
    v2 ^= XFF

    for _ in range(4):
        v0, v1, v2, v3 = _sipround_vec(v0, v1, v2, v3)

    return (v0 ^ v1) ^ (v2 ^ v3)


# ---------------------------------------------------------------------------
# Scalar SipHash (same algorithm) — reference / testing.
# ---------------------------------------------------------------------------

def _rotl64(x: int, n: int) -> int:
    return ((x << n) | (x >> (64 - n))) & 0xFFFFFFFFFFFFFFFF


def _sipround(v0, v1, v2, v3):
    v0 = (v0 + v1) & 0xFFFFFFFFFFFFFFFF
    v1 = _rotl64(v1, 13) ^ v0
    v0 = _rotl64(v0, 32)
    v2 = (v2 + v3) & 0xFFFFFFFFFFFFFFFF
    v3 = _rotl64(v3, 16) ^ v2
    v0 = (v0 + v3) & 0xFFFFFFFFFFFFFFFF
    v3 = _rotl64(v3, 21) ^ v0
    v2 = (v2 + v1) & 0xFFFFFFFFFFFFFFFF
    v1 = _rotl64(v1, 17) ^ v2
    v2 = _rotl64(v2, 32)
    return v0, v1, v2, v3


def siphash_scalar(k0: int, k1: int, k2: int, k3: int, nonce: int) -> int:
    """Cuckatoo non-standard SipHash-2-4 (scalar, for testing)."""
    v0, v1, v2, v3 = k0, k1, k2, k3 ^ nonce
    v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
    v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
    v0 ^= nonce
    v2 ^= 0xFF
    for _ in range(4):
        v0, v1, v2, v3 = _sipround(v0, v1, v2, v3)
    return ((v0 ^ v1) ^ (v2 ^ v3)) & 0xFFFFFFFFFFFFFFFF


# ---------------------------------------------------------------------------
# Key derivation
# ---------------------------------------------------------------------------

def derive_keys(header: bytes):
    digest = hashlib.blake2b(header, digest_size=32).digest()
    k0, k1, k2, k3 = struct.unpack_from("<QQQQ", digest)
    return k0, k1, k2, k3


# ---------------------------------------------------------------------------
# Build all edge endpoints (vectorized, the speed-critical step).
# Returns U[N] and V[N] as uint64 arrays (values masked to edgebits).
# ---------------------------------------------------------------------------

def build_endpoints(k0, k1, k2, k3, edgebits: int):
    N    = 1 << edgebits
    mask = np.uint64(N - 1)
    i    = np.arange(N, dtype=np.uint64)
    U    = siphash_vec(k0, k1, k2, k3, np.uint64(2) * i)                 & mask
    V    = siphash_vec(k0, k1, k2, k3, np.uint64(2) * i + np.uint64(1))  & mask
    return U, V


# ---------------------------------------------------------------------------
# Edge trimming via numpy bincount — Cuckatoo-correct version.
#
# CRITICAL: degree is counted on NODE-PAIRS (node >> 1), not raw node values.
#
# Why: a valid Cuckatoo 42-cycle has 42 UNIQUE U-endpoints (raw degree 1 each)
# but 21 UNIQUE U-PAIRS (pair degree 2 each).  Raw-degree trimming destroys
# all valid cycles at the first round; pair-degree trimming preserves them.
# Mean pair degree = N / (N/2) = 2, so ~20% of edges survive after trimming.
# ---------------------------------------------------------------------------

def trim_edges(U: np.ndarray, V: np.ndarray, edgebits: int, rounds: int = 20) -> np.ndarray:
    N      = 1 << edgebits
    NPAIRS = N >> 1           # number of node-pair values per side
    alive  = np.ones(len(U), dtype=bool)

    # Pre-compute pair arrays (they don't change, only alive changes).
    UP = (U >> ONE).astype(np.intp)   # U-pair indices
    VP = (V >> ONE).astype(np.intp)   # V-pair indices

    for _ in range(rounds):
        prev_count = alive.sum()

        deg_up  = np.bincount(UP[alive], minlength=NPAIRS)
        alive  &= deg_up[UP] >= 2

        deg_vp  = np.bincount(VP[alive], minlength=NPAIRS)
        alive  &= deg_vp[VP] >= 2

        if alive.sum() == prev_count:
            break

    return alive


# ---------------------------------------------------------------------------
# Cuckatoo cycle verifier — Python mirror of the Ruby verifier (cuckoo.rb).
#
# Agreement here ↔ Ruby verify() returns true.
# Takes sorted cycle_edges (list of edge indices, length proofsize).
# ---------------------------------------------------------------------------

def verify_cuckatoo_cycle(U_arr, V_arr, cycle_edges, _mask=0) -> bool:
    """Returns True iff cycle_edges is a valid Cuckatoo proofsize-cycle.

    Works for any proofsize (not just 42).  The cycle-walk algorithm is
    identical regardless of length; only `ps` changes.
    """
    ps = len(cycle_edges)
    if ps < 2:
        return False   # degenerate: need at least 2 edges for a cycle

    uvs = []
    for ei in cycle_edges:
        uvs.append(int(U_arr[ei]))
        uvs.append(int(V_arr[ei]))

    uvs_size = 2 * ps
    i = 0
    n = 0

    while True:
        j = i
        k = i
        branch = False

        while True:
            k = (k + 2) % uvs_size
            if k == i:
                break
            if (uvs[k] >> 1) == (uvs[i] >> 1):
                if j != i:
                    branch = True
                    break
                j = k

        if branch:
            return False
        if j == i:
            return False
        if uvs[j] == uvs[i]:
            return False

        i = j ^ 1
        n += 1
        if i == 0:
            break
        if n > ps:
            return False

    return n == ps


# ---------------------------------------------------------------------------
# Cycle finder using recursive DFS on the quotient (node-pair) graph.
#
# After pair-degree trimming, surviving nodes have pair-degree ≥ 2.
# We run a recursive DFS that correctly backtracks (path_depth is cleaned up
# on every unwind), so back-edge depths are exact.  When a back-edge closes
# a cycle of EXACTLY proofsize edges we validate it with verify_cuckatoo_cycle
# and return immediately.
#
# Depth is bounded at proofsize so recursion never exceeds proofsize frames
# (≤ 42 for production, ≤ 12 for the toy demo) — safe against Python's
# recursion limit.  We restart DFS from each node so every component is
# searched even when part of it was visited on a non-cycle path earlier.
#
# Correctness vs. the old iterative version:
#   The old version never removed nodes from depth_map on backtrack, so
#   stale depths corrupted cycle-length calculations and valid cycles were
#   rejected or never extracted.  This version removes each node from
#   path_depth exactly on unwind, giving exact depths at every step.
# ---------------------------------------------------------------------------

def find_cycle(U: np.ndarray, V: np.ndarray, alive_mask: np.ndarray, proofsize: int = 42):
    edge_idx = np.where(alive_mask)[0]
    if len(edge_idx) < proofsize:
        return None

    # Build adjacency on node-pairs.
    # Node key: (side, pair_value), side ∈ {0=U, 1=V}.
    adj: dict = defaultdict(list)
    for ei in edge_idx:
        up = (0, int(U[ei]) >> 1)
        vp = (1, int(V[ei]) >> 1)
        adj[up].append((vp, int(ei)))
        adj[vp].append((up, int(ei)))

    for start_node in list(adj.keys()):
        # Fresh path state per start (ensures clean backtracking across starts).
        path_depth: dict = {}   # node -> depth on the CURRENT path only
        path_edges: list = []   # edges on the current path (len == current depth)

        # Recursive DFS.  parent_ei is the edge index we arrived on (−1 at root)
        # so we don't immediately traverse back on the same edge.
        #
        # Invariant entering dfs(node, depth, parent_ei):
        #   path_edges has exactly `depth` elements.
        #   path_depth holds exactly the nodes on the path from start to
        #   the CALLER of this function (not including `node` yet).
        def dfs(node, depth, parent_ei):
            # --- Back-edge check (done before the depth limit so we always
            #     detect cycles even at the maximum allowed depth) ---
            if node in path_depth:
                anc_depth = path_depth[node]
                cycle_len = depth - anc_depth  # #edges = depth - anc_depth
                # path_edges[anc_depth:] is the back-edge included (it was
                # appended by our caller before this call).
                if cycle_len == proofsize:
                    cycle = path_edges[anc_depth:]   # already has proofsize elements
                    sc = sorted(cycle)
                    if verify_cuckatoo_cycle(U, V, sc):
                        return sc
                return None

            # --- Depth limit: don't add nodes beyond proofsize levels ---
            if depth >= proofsize:
                return None

            # --- Enter this node ---
            path_depth[node] = depth

            for nbr, ei in adj[node]:
                if ei == parent_ei:
                    continue           # skip the edge we arrived on
                path_edges.append(ei)  # include edge before recursing
                result = dfs(nbr, depth + 1, ei)
                path_edges.pop()       # restore on unwind
                if result is not None:
                    del path_depth[node]
                    return result

            # --- Leave this node (backtrack) ---
            del path_depth[node]
            return None

        result = dfs(start_node, 0, -1)
        if result is not None:
            return result

    return None


# ---------------------------------------------------------------------------
# Main solve loop
# ---------------------------------------------------------------------------

def solve(challenge: dict) -> dict:
    salt      = base64.b64decode(challenge["salt"])
    params    = challenge["params"]
    edgebits  = int(params["edgebits"])
    proofsize = int(params.get("proofsize", 42))
    target    = params.get("target")

    _enforce_memory_budget(edgebits)   # refuse oversized edgebits before allocating

    header_nonce = 0
    while True:
        header          = salt + struct.pack("<I", header_nonce)
        k0, k1, k2, k3 = derive_keys(header)

        U, V   = build_endpoints(k0, k1, k2, k3, edgebits)
        alive  = trim_edges(U, V, edgebits)
        cycle  = find_cycle(U, V, alive, proofsize)

        if cycle is not None:
            if target is not None:
                cycle_packed = struct.pack(f"<{len(cycle)}Q", *sorted(cycle))
                cycle_hash   = hashlib.blake2b(cycle_packed, digest_size=32).digest()
                hash_int     = int.from_bytes(cycle_hash, "big")
                target_int   = int(target) if isinstance(target, int) else int.from_bytes(target, "big")
                if hash_int >= target_int:
                    header_nonce += 1
                    continue
            return {"header_nonce": header_nonce, "cycle": cycle}

        header_nonce += 1


def main():
    if len(sys.argv) > 1:
        challenge = json.loads(sys.argv[1])
    else:
        challenge = json.load(sys.stdin)

    result = solve(challenge)
    print(json.dumps(result))


if __name__ == "__main__":
    main()

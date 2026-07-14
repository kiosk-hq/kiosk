# Kiosk PoW Skill Fragment

> Paste this fragment into a Kiosk provider's `KIOSK.skill.md` so the assistant knows how to handle proof-of-work challenges.

---

## Handling `pow_required`

Any `query` or `run` response may be HTTP 402 with this shape (the gate always
emits a `challenges` array — one entry for N=1, more under N×PoW):

```json
{
  "ok": false,
  "error": {
    "code": "pow_required",
    "message": "proof-of-work required",
    "challenges": [
      {
        "id":     "<opaque id>",
        "alg":    "argon2id",
        "params": { "m": 65536, "t": 1, "p": 1, "d": 6 },
        "salt":   "<base64-encoded raw salt>",
        "exp":    1750000600,
        "sig":    "<HMAC-SHA256 hex>"
      }
    ]
  }
}
```

Solve every challenge in the array; submit one proof per challenge (see step 3).

**Do this — in order:**

1. Install the solver dependency (once per sandbox):
   ```
   pip install argon2-cffi
   ```

2. Run the shipped solver with the full challenge object as a JSON argument:
   ```
   python3 kiosk-pow/solve.py '<the challenge JSON>'
   ```
   The solver reads `challenge["salt"]` and `challenge["params"]` (keys `m`, `t`,
   `p`, `d`) and iterates nonces until `d` leading zero bits are found. It prints
   one line to stdout:
   ```json
   {"nonce": "73821"}
   ```
   This may take a few seconds to a few minutes depending on `d`. Read the
   `nonce` string from that output.

3. Re-POST the **exact same** original request body — the verb args stay at the
   top level (the wire posts them flat) — with a sibling `pow` field added. For a
   single challenge, `pow` is `{ "challenge": ..., "nonce": ... }`; for N×PoW,
   `pow` is `{ "proofs": [ { "challenge": ..., "nonce": ... }, ... ] }`:
   ```json
   {
     "name":       "menu_by_restaurant",
     "restaurant": "Mamma Pizza",
     "pow": {
       "challenge": { "id": "...", "alg": "argon2id", "params": { "m": 65536, "t": 1, "p": 1, "d": 6 }, "salt": "...", "exp": 1750000600, "sig": "..." },
       "nonce":     "73821"
     }
   }
   ```
   The `challenge` value inside `pow` must be the **verbatim** challenge object
   from the 402 response — every field, unchanged. `nonce` is the decimal string
   returned by `solve.py`. When the 402 returned multiple challenges, submit one
   `{challenge, nonce}` per challenge inside `pow.proofs`.

4. The server verifies and serves the original response. If it returns HTTP 403
   (`invalid proof of work`), do not retry silently — tell the user:
   **"The provider rejected the proof — my client may be outdated; please contact support."**

**Never:**
- Try to negotiate the algorithm or parameters down. The provider mandates `alg`
  and `params`. If you cannot solve the demanded `alg`, tell the user:
  _"This provider requires a proof-of-work algorithm my client cannot handle.
  Please update me."_
- Solve with a different algorithm (e.g. SHA256 instead of `argon2id`).
- Skip the proof and retry without `pow`.
- Send raw SQL — use named `query` calls with a top-level `name` + parameters.

The provider may demand PoW again on subsequent requests at its discretion.
If you receive another 402, solve and retry again.

`solve.py` is in `kiosk-pow/solve.py` (shipped with the kiosk-pow gem). It
accepts the challenge JSON as `sys.argv[1]` or on stdin.

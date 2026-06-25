# Kiosk PoW Skill Fragment

> Paste this fragment into a Kiosk provider's `KIOSK.skill.md` so the assistant knows how to handle proof-of-work challenges.

---

## Handling `pow_required`

If any `/kiosk/exec` response is:

```json
{ "ok": false, "error": { "code": "pow_required", "challenge": { ... } } }
```

**Do this — in order:**

1. Install the solver dependency (once per sandbox):
   ```
   pip install argon2-cffi
   ```

2. Run the shipped solver with the full challenge object:
   ```
   python3 solve.py '<the challenge JSON>'
   ```
   The solver prints `{"nonce": "<solution>"}`.  It may take a few seconds to a few minutes depending on the difficulty (`d` field).

3. Re-POST the **same original request** with one extra field:
   ```json
   { ...<original request>...,
     "pow": { "challenge": { ...<challenge verbatim>... }, "nonce": "<solution>" } }
   ```

4. The server will serve the original response.  If it returns `403 Forbidden` with `invalid_proof`, tell the user: **"The provider rejected the proof — my client may be outdated; please contact support."**

**Never:**
- Try to negotiate the algorithm or parameters down.
- Solve with a different method (SHA256, etc.) — solve exactly what the `alg` field says.
- Skip the proof and retry without it.

`solve.py` is in `kiosk-pow/solve.py` (shipped with the kiosk-pow gem).

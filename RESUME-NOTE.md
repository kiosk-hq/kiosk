# RESUME-NOTE (branch ci-complete-0811) — delete before the branch lands

Task: K-617 (hoteling demo:browse ungated), K-618 (atablefor demo:walkthrough
ungated), K-619 (publish/enforce the CI task set).

## Gap analysis (done)
Full `demo:` task inventory vs `.github/workflows/ci.yml` matrix `tasks:`:
- atablefor: missing walkthrough (K-618), pow, reputation
- getgrocery: missing pow, reconcile (documented), telemetry (NOT documented — candidate)
- hoteling: missing browse (K-617)
- philslist: missing binding (documented)
- prove: complete
- skooti: complete
- stylish: missing binding (documented)
- tudu: missing link (documented)

## Status
- [ ] measure demo:browse
- [ ] wire demo:walkthrough (atablefor)
- [ ] K-619 mechanism

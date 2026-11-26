# The Grassroots App's app

The app of App, the Grassroots App, the home of the Grassroots Super-App: the contract that composes knowing people, meeting them nearby, friendship, programs, stores, invitation links and directories (`programs/social/graph/App.txt` and `App.glp`, adopted from the Calculus; its cascade run `cascade/App`), compiled down the abstraction cascade as the other apps of `programs/apps` are.

## The files

| File | What it holds |
|---|---|
| `platform.vglp` | the canonical CVA platform of App, as `programs/vglp/cva/compiler` prints it; `bash programs/apps/compile.sh --check` re-prints it and compares (`COMPILE_APPS=app` for this app alone) |
| `miniapp.glp` | `miniapp/3`, the apps' wrapper (`../gsg/miniapp.glp`), with one difference: App's agent also takes the presences of the persons near the phone and writes its trust level (the Encounters part of App), which the host here serves, every person whose conversation is open being in reach once the trust is open |
| `self.glp` | the platform's types written again, and the export |

It has no scripted person and no plays.

## Running it

From `glp_runtime/`, the directory loads:

```bash
printf '../programs/apps/app\n:quit\n' | bin/glpc
```

`servers/uiagents` runs it for the UI layer's web demo (`?real=1` on its Home): four persons, each the miniapp agent of App, establish, become friends, trust a developer, publish, offer and install programs, and open their place to those nearby, as the contract allows.

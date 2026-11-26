# Real agents for the UI layer's web demo

The screens of the Grassroots UI layer's web demo (programs/gce/ui), drawn by its general renderer from a contract's UI structure and UI style, run here on the contract's real app: each of the demo's persons, Alice, Bob, Carol and Dave, is the miniapp agent of the app (`programs/apps/gsg`, Friendship; `programs/apps/gsn`, Groups), every two of them joined by a conversation, all in one engine.  The server carries each tap to the person's agent, as the device's bridge does (`glp_multiagent/lib/ui_runtime/bridge.dart`), and the agent's screens back.  It decides nothing: the agents are the app's own, unchanged.

It is a test bench, not part of a grassroots platform: on a device the person's agent runs on the device.

## Endpoints

- `POST /new?app=gsg`: a new world; answers its `id` and each person's state.
- `GET /state?id=W`: each person's state: her agent's latest view (the facts she holds, the persons she knows, the requests she waits on, the tabs), the notices written after it, and the questions to her (the approval constructs open on her channel).
- `POST /propose?id=W&p=alice`, the body a request as a JSON term: the person proposes it, on the app's menu construct.
- `POST /answer?id=W&p=bob&q=N&yes=1`: the person answers the question of construct `N`, at the place its view names.

A JSON term is `{"a": name}`, `{"n": number}`, `{"f": functor, "args": [...]}` or `{"l": [...]}`.  A world unused longest goes when there are twenty.

## Run

With plain Dart (no Flutter), from this directory:

    dart pub get
    dart run bin/server.dart 4501

`GLP_PROGRAMS` names the programs directory (by default this repository's).  The demo runs on it with `?real=1`.

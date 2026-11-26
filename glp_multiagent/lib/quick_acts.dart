/// Shortcuts on the Grassroots App's home: each one a request the person could
/// make on home's own request form, filled in for them.
///
/// - Get the apps: trust the key the bundled mini-apps are certified under,
///   install Friendship (`gsg.glpw`) and Groups (`gsn.glpw`), and activate
///   both, so each has its screen at once (EShapiro2/GLP#181).
/// - For each friend home has told the person of (`connected(K)`): invite them
///   to Groups or to Friendship, and accept their invitations to both in
///   advance (the agent's `accept_invite(App, From)`).
///
/// Every shortcut is granted on home's request question, as the person's own
/// submission of the form is; nothing here reaches the agent another way.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'ui_runtime/app_screens.dart';
import 'ui_runtime/bridge.dart';
import 'ui_runtime/described.dart';
import 'ui_runtime/runtime.dart';
import 'ui_runtime/term.dart';

/// The bundled mini-apps: the name each is installed under, and its artefact.
const List<(String, String)> bundledApps = [('Friendship', 'gsg.glpw'), ('Groups', 'gsn.glpw')];

/// What the bundle says of the mini-apps: the key each is certified under,
/// and the UI structure and style of each, by the name it is installed under.
class BundledApps {
  /// The key each artefact is certified under, by its file name.
  final Map<String, String> keys;
  final Map<String, UiDescription> descriptions;
  const BundledApps(this.keys, this.descriptions);

  /// Whether every bundled mini-app has its key.
  bool get ready => bundledApps.every((a) => keys.containsKey(a.$2));

  /// Read from the programs directory [programs] (programs/social/graph/core/compiler_keys.txt,
  /// programs/gce/ui/apps.json); what is missing is left out.
  static BundledApps read(String programs) {
    final keys = <String, String>{};
    try {
      for (final line in File('$programs/social/graph/core/compiler_keys.txt').readAsLinesSync()) {
        final m = RegExp(r'^(\S+\.glpw) ([0-9a-f]{64})$').firstMatch(line.trim());
        if (m != null) keys[m.group(1)!] = m.group(2)!;
      }
    } catch (_) {}
    final ds = <String, UiDescription>{};
    try {
      final index = jsonDecode(File('$programs/gce/ui/apps.json').readAsStringSync()) as Map<String, dynamic>;
      for (final e in index.entries) {
        try {
          ds[e.key] = UiDescription.parse(File('$programs/gce/ui/${e.value}').readAsStringSync());
        } catch (_) {}
      }
    } catch (_) {}
    return BundledApps(keys, ds);
  }
}

/// The friends home has told the person of, in order: each `connected(K)` in
/// the thread of construct 0, less those `unfriended` since.
List<String> friendsOf(UiRuntime home) {
  final c0 = home.bridge.construct(0);
  if (c0 == null) return const [];
  final (_, args) = ctorArgs(c0.view);
  final v = args.isEmpty ? c0.view : args.last;
  final out = <String>[];
  if (v is! GList) return out;
  for (final m in v.items) {
    final (f, ms) = ctorArgs(m);
    if (f != 'msg' || ms.length != 3) continue;
    final (g, bs) = ctorArgs(ms[2]);
    final k = bs.isEmpty ? null : _text(bs[0]);
    if (k == null) continue;
    if (g == 'connected' && !out.contains(k)) out.add(k);
    if (g == 'unfriended') out.remove(k);
  }
  return out;
}

String? _text(GTerm t) => switch (t) {
      GAtom(:final name) => name,
      GString(:final value) => value,
      _ => null,
    };

/// The shortcuts, drawn above home's own screen.
class QuickActs extends StatefulWidget {
  final UiRuntime home;
  final AppScreens apps;
  final BundledApps bundled;
  const QuickActs({super.key, required this.home, required this.apps, required this.bundled});

  @override
  State<QuickActs> createState() => _QuickActsState();
}

class _QuickActsState extends State<QuickActs> {
  bool _asked = false;
  final Set<String> _accepted = {};

  /// Home's request question: the construct whose widget is the input box of its menu of requests.
  OpenConstruct? get _form {
    for (final c in widget.home.bridge.constructs) {
      if (formatTerm(c.widget).startsWith('input_box(menu([form(trust')) return c;
    }
    return null;
  }

  bool _request(GTerm r) {
    final f = _form;
    if (f == null) return false;
    widget.home.bridge.grant(f.id, const GList([]), r);
    return true;
  }

  void _getApps() {
    if (!widget.bundled.ready) return;
    for (final (_, file) in bundledApps) {
      _request(GStruct('trust', [GAtom(widget.bundled.keys[file]!)]));
    }
    for (final (name, file) in bundledApps) {
      _request(GStruct('install', [GAtom(name), GAtom(file)]));
    }
    for (final (name, _) in bundledApps) {
      _request(GStruct('activate', [GAtom(name)]));
    }
    setState(() => _asked = true);
  }

  static String _short(String k) => k.length > 10 ? '${k.substring(0, 6)}…${k.substring(k.length - 4)}' : k;

  @override
  Widget build(BuildContext context) {
    final installed = widget.apps.apps.toSet();
    final missing = !bundledApps.every((a) => installed.contains(a.$1));
    final friends = friendsOf(widget.home);
    final rows = <Widget>[
      if (missing && !_asked && widget.bundled.ready && _form != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: FilledButton.icon(
            key: const ValueKey('quick:get-apps'),
            onPressed: _getApps,
            icon: const Icon(Icons.download),
            label: const Text('Get Friendship and Groups'),
          ),
        ),
      for (final k in friends)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(_short(k), style: const TextStyle(fontWeight: FontWeight.w600)),
            for (final (name, _) in bundledApps)
              if (installed.contains(name))
                OutlinedButton(
                  key: ValueKey('quick:invite:$name:$k'),
                  onPressed: () => _request(GStruct('invite', [GAtom(name), GAtom(k)])),
                  child: Text('Invite to $name'),
                ),
            if (!_accepted.contains(k))
              TextButton(
                key: ValueKey('quick:accept:$k'),
                onPressed: () {
                  for (final (name, _) in bundledApps) {
                    _request(GStruct('accept', [GAtom(name), GAtom(k)]));
                  }
                  setState(() => _accepted.add(k));
                },
                child: const Text('Accept their invitations'),
              ),
          ]),
        ),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }
}

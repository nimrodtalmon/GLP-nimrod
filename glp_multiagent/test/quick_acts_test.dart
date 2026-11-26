/// The app's shortcut "Get Friendship and Groups" (lib/quick_acts.dart) on
/// `superapp_ui/4`: it trusts the key each bundled artefact is certified
/// under, installs Friendship (gsg) and Groups (gsn) and activates both, each
/// a request on home's own form; each mini-app then has its own screen
/// (EShapiro2/GLP#181), and the page of each is drawn from its UI structure
/// and style (programs/gce/ui).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glp_multiagent/isolate_protocol.dart' show runtimeTermOf, screenTermOf;
import 'package:glp_multiagent/manifests/superapp_ui.dart';
import 'package:glp_multiagent/quick_acts.dart';
import 'package:glp_multiagent/ui_runtime/agent_surface.dart';
import 'package:glp_multiagent/ui_runtime/app_screens.dart';
import 'package:glp_multiagent/ui_runtime/described.dart';
import 'package:glp_multiagent/ui_runtime/runtime.dart';
import 'package:glp_multiagent/ui_runtime/term.dart';
import 'package:glp_runtime/engine/glp_engine.dart';

Future<String?> _artefact(String repo, String prog, String core) async {
  final out = await Process.run('bash', ['-c', "printf ':artefact $repo/$prog $core\n:quit\n' | bin/glpc"],
      workingDirectory: Directory('$repo/../glp_runtime').absolute.path);
  return RegExp(r'certified under ([0-9a-f]{64})').firstMatch('${out.stdout}${out.stderr}')?.group(1);
}

void main() {
  testWidgets('Get Friendship and Groups: both installed and activated, each on its own screen', (tester) async {
    final repo = Directory('../programs').absolute.path;
    final core = '$repo/social/graph/core';
    final gsg = await tester.runAsync(() => _artefact(repo, 'apps/gsg', core));
    final gsn = await tester.runAsync(() => _artefact(repo, 'apps/gsn', core));
    expect(gsg, isNotNull);
    expect(gsn, isNotNull);
    final bundled = BundledApps({'gsg.glpw': gsg!, 'gsn.glpw': gsn!}, BundledApps.read(repo).descriptions);
    expect(bundled.descriptions.keys, containsAll(['Friendship', 'Groups']));

    final notifies = <GTerm>[];
    final engine = GlpEngine(rootSelfGlpPath: '$repo/self.glp');
    engine.runtime.outputTermCallback = (t) => notifies.add(screenTermOf(t));
    expect(engine.loadProgram(core), isTrue);
    final play = engine.postGoal('superapp_ui(alice, [bob], Grants?, [])', inputs: ['Grants']);
    final grants = play.inputs['Grants']!;
    final sends = <GTerm>[];
    final home = UiRuntime(manifest: superappManifest, onSend: sends.add);
    final apps = AppScreens(send: sends.add);
    var fed = 0;
    void settle() {
      do {
        while (sends.isNotEmpty) {
          grants.inject(runtimeTermOf(sends.removeAt(0))).forEach(engine.runtime.gq.enqueue);
        }
        play.scheduler.drainToQuiescence(maxCycles: 20000000);
        for (; fed < notifies.length; fed++) {
          if (!apps.handle(notifies[fed])) home.handle(notifies[fed]);
        }
      } while (sends.isNotEmpty);
    }

    settle();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          QuickActs(home: home, apps: apps, bundled: bundled),
          Expanded(child: AgentSurface(agentId: 'alice', runtime: home)),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('quick:get-apps')));
    settle();
    await tester.pumpAndSettle();
    expect(apps.apps, unorderedEquals(['Friendship', 'Groups']));
    for (final a in apps.apps) {
      expect(apps.screen(a)!.bridge.constructs, isNotEmpty, reason: a);
    }

    // Groups' page, drawn from its UI structure and style.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: DescribedUi(
          ui: bundled.descriptions['Groups']!,
          child: AgentSurface(agentId: 'Groups', runtime: apps.screen('Groups')!),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(DescribedScreen), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

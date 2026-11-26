/// The app's start screen (lib/start_screen.dart) on `superapp_ui/4`: Get
/// Friendship and Groups installs and activates both, whose tiles then open;
/// home's questions are drawn under "Waiting for you"; More leads to home's
/// own screen.  With START_SHOTS set, it writes a picture of the screen
/// there, in DejaVu Sans where the host has it.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glp_multiagent/isolate_protocol.dart' show runtimeTermOf, screenTermOf;
import 'package:glp_multiagent/manifests/superapp_ui.dart';
import 'package:glp_multiagent/quick_acts.dart';
import 'package:glp_multiagent/start_screen.dart';
import 'package:glp_multiagent/ui_runtime/app_screens.dart';
import 'package:glp_multiagent/ui_runtime/look.dart';
import 'package:glp_multiagent/ui_runtime/runtime.dart';
import 'package:glp_multiagent/ui_runtime/term.dart';
import 'package:glp_runtime/engine/glp_engine.dart';

Future<String?> _artefact(String repo, String prog, String core) async {
  final out = await Process.run('bash', ['-c', "printf ':artefact $repo/$prog $core\n:quit\n' | bin/glpc"],
      workingDirectory: Directory('$repo/../glp_runtime').absolute.path);
  return RegExp(r'certified under ([0-9a-f]{64})').firstMatch('${out.stdout}${out.stderr}')?.group(1);
}

Future<void> _fonts() async {
  for (final (family, path) in [
    ('Roboto', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'),
    ('MaterialIcons', '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/MaterialIcons-Regular.otf'),
  ]) {
    final f = File(path);
    if (!f.existsSync()) continue;
    final l = FontLoader(family)..addFont(Future.value(ByteData.view(f.readAsBytesSync().buffer)));
    await l.load();
  }
}

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['START_SHOTS'];
  if (dir == null) return;
  final ro = tester.firstRenderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('shot')));
  await tester.runAsync(() async {
    final img = await ro.toImage(pixelRatio: 2);
    final png = await img.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('the start screen: get the apps, open their tiles', (tester) async {
    await tester.runAsync(_fonts);
    final repo = Directory('../programs').absolute.path;
    final core = '$repo/social/graph/core';
    final gsg = await tester.runAsync(() => _artefact(repo, 'apps/gsg', core));
    final gsn = await tester.runAsync(() => _artefact(repo, 'apps/gsn', core));
    final bundled = BundledApps({'gsg.glpw': gsg!, 'gsn.glpw': gsn!}, BundledApps.read(repo).descriptions);

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
    final opened = <String>[];
    var more = 0;
    final theme = Looks.readSync('$repo/self.glp').of(superappContract).theme();
    Widget app() => MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme.copyWith(textTheme: theme.textTheme.apply(fontFamily: 'Roboto')),
          home: Scaffold(
            body: RepaintBoundary(
              key: const ValueKey('shot'),
              child: StartScreen(
                home: home,
                apps: apps,
                bundled: bundled,
                me: 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2',
                openApp: opened.add,
                openMore: () => more++,
              ),
            ),
          ),
        );
    tester.view.physicalSize = const Size(1080, 2200);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    await _shot(tester, 'start-1-new');
    await tester.tap(find.byKey(const ValueKey('start:get-apps')));
    settle();
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(apps.apps, unorderedEquals(['Friendship', 'Groups']));
    await _shot(tester, 'start-2-apps');
    await tester.tap(find.byKey(const ValueKey('start:app:Groups')));
    expect(opened, ['Groups']);
    await tester.tap(find.text('More'));
    expect(more, 1);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

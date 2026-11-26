/// The bot (lib/bot/bot_person.dart): the Grassroots App's own agent with a
/// scripted person, met by a phone whose person acts on her screen.  Both over
/// a network in this process (helpers/air.dart).  The bot opens its place,
/// installs and activates Friendship and Groups, says yes when alice
/// befriends it, accepts her invitations in advance, and joins Groups when
/// she invites it; each side then has Groups' screen open with the other in
/// it (EShapiro2/GLP#181).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glp_multiagent/bot/bot_person.dart';
import 'package:glp_multiagent/isolate_protocol.dart' show runtimeTermOf, screenTermOf;
import 'package:glp_multiagent/manifests/superapp_ui.dart';
import 'package:glp_multiagent/superapp_host.dart';
import 'package:glp_multiagent/ui_runtime/bridge.dart';
import 'package:glp_multiagent/ui_runtime/term.dart';
import 'package:glp_runtime/multiagent/simulation_network.dart' show generateKeyPair;

import 'helpers/air.dart';
import 'programs_dir.dart';

Future<String?> _artefact(String repo, String prog, String core) async {
  final out = await Process.run('bash', ['-c', "printf ':artefact $repo/$prog $core\n:quit\n' | bin/glpc"],
      workingDirectory: Directory('$repo/../glp_runtime').absolute.path);
  return RegExp(r'certified under ([0-9a-f]{64})').firstMatch('${out.stdout}${out.stderr}')?.group(1);
}

/// Waits, by polling the event loop, until [test] holds.
Future<void> until(bool Function() test, {String what = ''}) async {
  for (var i = 0; i < 600; i++) {
    if (test()) return;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('timed out waiting: $what');
}

List<String> notices(SuperAppHost h) {
  final v = h.ui.bridge.construct(0)?.view;
  return [if (v is GList) for (final m in v.items) formatTerm(ctorArgs(m).$2[2])];
}

OpenConstruct? form(SuperAppHost h) {
  for (final c in h.ui.bridge.constructs) {
    if (c.id != 0 && formatTerm(c.widget).startsWith('input_box(menu(')) return c;
  }
  return null;
}

void request(SuperAppHost h, GTerm r) {
  final f = form(h)!;
  h.ui.bridge.grant(f.id, questionAt(f.view)!, r);
}

GList? questionIn(GTerm v) {
  final p = questionAt(v);
  if (p != null) return p;
  final items = v is GStruct ? v.args : v is GList ? v.items : const <GTerm>[];
  for (final a in items) {
    final q = questionIn(a);
    if (q != null) return q;
  }
  return null;
}

void main() {
  test('the bot: befriended, it accepts the invitation to Groups and joins', () async {
    final repo = programsDir();
    final core = '$repo/social/graph/core';
    final gsg = await _artefact(repo, 'apps/gsg', core);
    final gsn = await _artefact(repo, 'apps/gsn', core);
    expect(gsg, isNotNull);
    expect(gsn, isNotNull);

    final air = Air();
    SuperAppHost host(String name) => SuperAppHost(
          agentId: name,
          program: core,
          rootSelfGlpPath: '$repo/self.glp',
          network: AirNetwork(generateKeyPair(), air),
          manifest: superappManifest,
        );
    final alice = host('alice');
    final botHost = host('bot');
    final errors = <String>[];
    final transcript = <String>[];
    for (final h in [alice, botHost]) {
      h.onOutput = (l) {
        transcript.add('${h.agentId}: $l');
        if (l.startsWith('[ERROR]')) errors.add('${h.agentId}: $l');
      };
    }
    final log = <String>[];
    final bot = BotPerson(
      send: (g) => botHost.act(runtimeTermOf(g)),
      apps: [(name: 'Friendship', file: 'gsg.glpw', key: gsg!), (name: 'Groups', file: 'gsn.glpw', key: gsn!)],
      inviteByLink: false,
      me: botHost.key,
      onLog: log.add,
    );
    botHost.onUserOutput = (t) => bot.handle(screenTermOf(t));
    await alice.start();
    await botHost.start();
    await until(() => form(alice) != null, what: 'alice home');
    await until(() => bot.openApps.length == 2, what: 'the bot activates both apps');

    // alice opens her place, and befriends the bot in Nearby; the bot says yes.
    request(alice, const GAtom('open_place'));
    final botKey = botHost.key;
    OpenConstruct? card() => alice.ui.bridge.constructs
        .where((c) => formatTerm(c.widget).startsWith('form(nearby,') && formatTerm(c.view).contains(botKey))
        .firstOrNull;
    await until(() => card() != null, what: 'the bot nearby');
    final c = card()!;
    alice.ui.bridge.grant(c.id, questionIn(c.view)!, const GAtom('befriend'));
    await until(() => notices(alice).any((n) => n.contains('connected') && n.contains(botKey)), what: 'connected');
    await until(() => bot.friends.contains(alice.key), what: 'bot knows alice');

    // alice installs and activates Groups, and invites the bot to it.
    request(alice, GStruct('trust', [GAtom(gsn)]));
    request(alice, const GStruct('install', [GAtom('Groups'), GAtom('gsn.glpw')]));
    request(alice, const GStruct('activate', [GAtom('Groups')]));
    await until(() => alice.apps.apps.contains('Groups'), what: 'alice Groups');
    await alice.idle;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    request(alice, GStruct('invite', [const GAtom('Groups'), GAtom(botKey)]));

    // In Groups alice establishes an identity and asks to acquaint the bot,
    // a joint act: the bot says yes, and alice's Groups knows the bot.
    void propose(GTerm p) {
      final ui = alice.apps.screen('Groups')!;
      final c = ui.bridge.constructs.firstWhere((c) => formatTerm(c.widget).startsWith('named(social_menu('));
      ui.bridge.grant(c.id, questionIn(c.view)!, GStruct('propose', [p]));
    }
    bool knows(SuperAppHost h, String app, String key) {
      final v = h.apps.screen(app)?.bridge.construct(0)?.view;
      if (v == null) return false;
      final s = formatTerm(v);
      return s.contains("knows($key)") || s.contains("knows('$key')");
    }
    await alice.idle;
    await Future<void>.delayed(const Duration(seconds: 1));
    propose(GStruct('establish', [GAtom(alice.key)]));
    await until(() => (alice.apps.screen('Groups')?.bridge.construct(0)?.view.toString().length ?? 0) > 0);
    await Future<void>.delayed(const Duration(seconds: 1));
    propose(GStruct('acquaint', [GAtom(alice.key), GAtom(botKey)]));
    try {
      await until(() => knows(alice, 'Groups', botKey), what: "alice's Groups knows the bot");
      await until(() => knows(botHost, 'Groups', alice.key), what: "the bot's Groups knows alice");
    } finally {
      print('BOT LOG:\n${log.join('\n')}');
      print('ALICE NOTICES: ${notices(alice)}');
      print('BOT NOTICES: ${notices(botHost)}');
      print('ERRORS: $errors');
      for (final l in transcript.skip(transcript.length > 80 ? transcript.length - 80 : 0)) {
        print('T: ${l.length > 250 ? l.substring(0, 250) : l}');
      }
      for (final t in alice.apps.screen('Groups')?.raw ?? const []) {
        final s = formatTerm(t);
        print('A-GROUPS: ${s.length > 300 ? s.substring(0, 300) : s}');
      }
    }
    expect(errors, isEmpty);
    for (final h in [alice, botHost]) {
      h.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}

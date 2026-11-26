/// A bot on the Grassroots network: the Grassroots App's own agent
/// (`programs/social/graph/core`, superapp/5) over the headless layer, its
/// person the script of lib/bot/bot_person.dart.  To everyone else it is a
/// person like any other, by its key; it says yes to whoever befriends it,
/// accepts their invitations to Friendship and Groups, joins, and consents
/// there.  Its link, made by Invite by link through the rendezvous server
/// (GRV:2), is printed as `LINK <link>` and written to --link-file, for a
/// phone to open.
///
///   dart run bin/bot.dart --programs ../programs --data bot-data \
///       [--keys compiler_keys.txt] [--link-file link.txt]
///
/// --programs: the programs tree, holding gsg.glpw and gsn.glpw in
/// social/graph/core (tool/sync_glp_assets.sh builds them into the bundle;
/// glpc's :artefact writes them anywhere).  --keys: the key each artefact is
/// certified under, `<name>.glpw <key>` a line, as the bundle's
/// compiler_keys.txt has them.  The services are the bundle's,
/// social/graph/core/services.json.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:glp_multiagent/bot/bot_person.dart';
import 'package:glp_multiagent/isolate_protocol.dart' show runtimeTermOf, screenTermOf;
import 'package:glp_runtime/multiagent/agent_runtime.dart';
import 'package:glp_runtime/multiagent/agent_state_store.dart';
import 'package:glp_runtime/runtime/terms.dart' as rt;
import 'package:grassroots_networking_core/grassroots_networking_core.dart';
import 'package:grassroots_networking_core/src/headless/identity_file.dart';
import 'package:grassroots_networking_glue/headless_glp_network.dart';

Future<void> main(List<String> argv) async {
  String? opt(String name) {
    final i = argv.indexOf('--$name');
    return i >= 0 && i + 1 < argv.length ? argv[i + 1] : null;
  }
  if (argv.contains('--help') || opt('programs') == null) {
    stdout.writeln('dart run bin/bot.dart --programs <programs> [--data bot-data] [--keys compiler_keys.txt] [--link-file link.txt]');
    return;
  }
  final programs = Directory(opt('programs')!).absolute.path;
  final data = Directory(opt('data') ?? 'bot-data')..createSync(recursive: true);
  final core = '$programs/social/graph/core';

  final keys = <String, String>{};
  final keysPath = opt('keys') ?? '$core/compiler_keys.txt';
  if (File(keysPath).existsSync()) {
    for (final l in File(keysPath).readAsLinesSync()) {
      final m = RegExp(r'^(\S+\.glpw) ([0-9a-f]{64})$').firstMatch(l.trim());
      if (m != null) keys[m.group(1)!] = m.group(2)!;
    }
  }
  final apps = <BotApp>[
    for (final (name, file) in [('Friendship', 'gsg.glpw'), ('Groups', 'gsn.glpw')])
      if (keys[file] != null && File('$core/$file').existsSync()) (name: name, file: file, key: keys[file]!),
  ];

  final services = jsonDecode(File('$core/services.json').readAsStringSync()) as Map<String, dynamic>;
  rt.Term list(List<rt.Term> xs) => xs.reversed.fold<rt.Term>(rt.ConstTerm(rt.nil), (t, x) => rt.StructTerm('.', [x, t]));
  final serviceTerms = <rt.Term>[
    for (final r in (services['rendezvous'] as List? ?? const []))
      rt.StructTerm('rendezvous', [rt.ConstTerm(r['key'] as String), rt.ConstTerm(r['address'] as String)]),
    if (services['directory'] is Map)
      rt.StructTerm('directory', [
        rt.ConstTerm((services['directory'] as Map)['key'] as String),
        rt.ConstTerm((services['directory'] as Map)['address'] as String),
      ]),
  ];

  final sodium = await initHeadlessSodium();
  final identity = await loadOrCreateIdentity('${data.path}/identity.json');
  final layer = HeadlessGrassrootsNetwork(
    identity: identity,
    sodium: sodium,
    outboundQueueStore: FileOutboundQueueStore('${data.path}/queue.json'),
  );
  final network = HeadlessGlpNetwork(layer);
  final agent = AgentRuntime(
    agentId: 'bot',
    program: core,
    rootSelfGlpPath: '$programs/self.glp',
    network: network,
    stateStore: FileAgentStateStore('${data.path}/state.bin'),
  );
  final key = network.getIdentity().hex;

  var acts = Future<void>.value();
  final person = BotPerson(
    me: key,
    apps: apps,
    send: (g) => acts = acts.then((_) => agent.injectUserInput(runtimeTermOf(g))),
    onLog: (l) => stdout.writeln('BOT $l'),
    onLink: (l) {
      stdout.writeln('LINK $l');
      final f = opt('link-file');
      if (f != null) File(f).writeAsStringSync('$l\n');
    },
  );
  agent.onUserOutput = (t) => person.handle(screenTermOf(t));
  agent.onOutput = (line) {
    if (line.startsWith('[ERROR]')) stderr.writeln(line);
  };
  agent.onPeerConnected = (pk, underlay, _) => stdout.writeln('CONNECTED ${pk.hex} ${underlay.name}');

  await agent.initialize();
  if (!await layer.start()) {
    stderr.writeln('could not bind the UDP port');
    exit(1);
  }
  stdout.writeln('READY ${layer.boundPort} $key apps=${apps.map((a) => a.name).join(',')}');
  if (agent.firstStart) {
    acts = acts.then((_) => agent.injectUserInput(
        rt.StructTerm('superapp', [rt.ConstTerm(key), rt.ConstTerm(rt.nil), list(serviceTerms)])));
  }

  final done = Completer<void>();
  void shutDown(ProcessSignal _) {
    if (!done.isCompleted) done.complete();
  }

  final subs = [ProcessSignal.sigint.watch().listen(shutDown), if (!Platform.isWindows) ProcessSignal.sigterm.watch().listen(shutDown)];
  await done.future;
  for (final s in subs) {
    await s.cancel();
  }
  await agent.save();
  agent.dispose();
  await layer.dispose();
  exit(0);
}

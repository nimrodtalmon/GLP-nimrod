/// Real GLP agents for the Grassroots UI layer's web demo.
///
/// A world is the demo's persons, each the miniapp agent of a real app (programs/apps/<app>), every two of
/// them joined by a conversation, all run by one engine.  The demo's general renderer draws each person's
/// screens from that person's state, and proposes and answers through these endpoints:
///
///   POST /new?app=gsg                     a new world; answers {"id": ...}
///   GET  /state?id=W                      each person's state: the facts she holds (without herself), the
///                                         requests she waits on, the questions to her, the notices
///   POST /propose?id=W&p=alice            body: a request, as a JSON term; the person proposes it
///   POST /answer?id=W&p=bob&q=N&yes=1     the person answers the question of construct N
///
/// A JSON term is {"a": name} (a string constant), {"n": number}, {"f": functor, "args": [...]} or
/// {"l": [...]}; {"v": 0} is a place not yet known.
///
/// The agents are the app's own, unchanged; the server only carries the person's taps to her agent, as the
/// device's bridge does (glp_multiagent/lib/ui_runtime/bridge.dart).
library;

import 'dart:convert';
import 'dart:io';

import 'package:glp_runtime/engine/glp_engine.dart';
import 'package:glp_runtime/runtime/heap_fcp.dart' show HeapCell;
import 'package:glp_runtime/runtime/external_io.dart' show InputInjector;
import 'package:glp_runtime/runtime/terms.dart' as rt;

import '../../../glp_multiagent/lib/isolate_protocol.dart' show runtimeTermOf, screenTermOf;
import '../../../glp_multiagent/lib/ui_runtime/manifest.dart';
import '../../../glp_multiagent/lib/ui_runtime/runtime.dart';
import '../../../glp_multiagent/lib/ui_runtime/term.dart';

const persons = ['alice', 'bob', 'carol', 'dave'];
const apps = {'gsg', 'gsn', 'app'};

late final String programs;

/// One person of a world: her agent's grants and draws, and the device side, the constructs it drew.
class Person {
  final String name;
  final InputInjector grants;
  final HeapCell draws;
  final List<GTerm> unsent = [];
  int fed = 0;
  late final UiRuntime ui = UiRuntime(
      manifest: const Manifest(title: 'app', panels: [Panel(id: 'app', name: 'App', constructs: true)], activity: []),
      onSend: unsent.add);
  Person(this.name, this.grants, this.draws);
}

class World {
  final String id, app;
  final GlpEngine engine;
  final dynamic play;
  final Map<String, Person> people;
  DateTime used = DateTime.now();
  World(this.id, this.app, this.engine, this.play, this.people);

  static World make(String id, String app) {
    final t0 = DateTime.now();
    // One engine per app runs many worlds, each its own goal, since loading the app is most of the cost; an
    // engine serves thirty worlds, its heap then left with the worlds it ran.
    var (engine, n) = engines[app] ?? (null, 0);
    if (engine == null || n >= 30) {
      engine = GlpEngine(rootSelfGlpPath: '$programs/self.glp');
      if (!engine.loadProgram('$programs/apps/$app')) throw StateError('cannot load $app');
      n = 0;
      stdout.writeln('loaded $app in ${DateTime.now().difference(t0).inMilliseconds} ms');
    }
    engines[app] = (engine, n + 1);
    String ch(String a, String b) => 'C_${a}_$b';
    final goal = [
      for (final (i, p) in persons.indexed)
        'miniapp($p, ch(G$i?, D$i), ch([${[
          for (final q in persons)
            if (q != p) 'conversation($q, ch(${ch(q, p)}?, ${ch(p, q)}))'
        ].join(', ')}], U$i))'
    ].join(', ');
    final play = engine.postGoal(goal, inputs: [for (var i = 0; i < persons.length; i++) 'G$i']);
    final people = {
      for (final (i, p) in persons.indexed) p: Person(p, play.inputs['G$i']!, play.variables['D$i']!)
    };
    final w = World(id, app, engine, play, people)..settle();
    stdout.writeln('world $id of $app in ${DateTime.now().difference(t0).inMilliseconds} ms');
    return w;
  }

  rt.Term _deep(rt.Term t) {
    final d = engine.runtime.heap.dereference(t);
    return d is rt.StructTerm ? rt.StructTerm(d.functor, [for (final a in d.args) _deep(a)]) : d;
  }

  /// Run every agent to quiescence, carrying each person's grants in and each new screen out.
  void settle() {
    for (var round = 0; round < 1000; round++) {
      var more = false;
      for (final p in people.values) {
        while (p.unsent.isNotEmpty) {
          more = true;
          p.grants.inject(runtimeTermOf(p.unsent.removeAt(0))).forEach(engine.runtime.gq.enqueue);
        }
      }
      play.scheduler.drainToQuiescence(maxCycles: 20000000);
      for (final p in people.values) {
        var cell = engine.runtime.heap.dereference(rt.VarRef(p.draws));
        var i = 0;
        while (cell is rt.StructTerm && cell.functor == '.' && cell.args.length == 2) {
          if (i++ >= p.fed) {
            p.ui.handle(screenTermOf(_deep(cell.args[0])));
            p.fed++;
            more = true;
          }
          cell = engine.runtime.heap.dereference(cell.args[1]);
        }
      }
      if (!more) return;
    }
  }

  /// The construct the person's acts are granted on: the app's menu, drawn again with a new id after each.
  int? menu(Person p) {
    for (final c in p.ui.bridge.constructs) {
      if (formatTerm(c.widget).startsWith('named(social_menu')) return c.id;
    }
    return null;
  }

  Map<String, Object?> state() => {
        for (final p in people.values)
          p.name: {
            ...lastView(p.ui.bridge.construct(0)?.view),
            'questions': [
              for (final c in p.ui.bridge.constructs)
                if (c.id != 0 && ctorArgs(c.view).$1 == 'approval') {'id': c.id, 'view': json(c.view)}
            ],
          }
      };

  void propose(String person, GTerm request) {
    final p = people[person]!, m = menu(p);
    if (m == null) throw StateError('no menu for $person');
    p.ui.bridge.grant(m, const GList([]), GStruct('propose', [request]));
    settle();
  }

  void answer(String person, int q, bool yes) {
    final p = people[person]!, c = p.ui.bridge.construct(q);
    if (c == null) throw StateError('no question $q');
    // The approval's answer place: input(Path) in its view.
    final (_, xs) = ctorArgs(c.view);
    final at = xs.isEmpty ? null : xs.last;
    final path = at is GStruct && at.functor == 'input' ? at.args.first : const GList([GInt(3)]);
    p.ui.bridge.grant(q, path, GAtom(yes ? 'yes' : 'no'));
    settle();
  }
}

/// The agent's latest view, and the notices written after it: construct 0 keeps each view the agent wrote, and
/// a notice shows until the next view (as the app reads it, named_widgets.dart, `SocialState.read`).
Map<String, Object?> lastView(GTerm? out) {
  if (out is! GList) return {'view': null, 'notices': []};
  GTerm? view;
  var notices = <GTerm>[];
  for (final e in out.items) {
    if (ctorArgs(e).$1 == 'view') {
      view = e;
      notices = [];
    } else {
      notices.add(e);
    }
  }
  return {'view': view == null ? null : json(view), 'notices': [for (final n in notices) json(n)]};
}

Object? json(GTerm? t) => switch (t) {
      null => {'v': 0},
      GAtom(:final name) => {'a': name},
      GString(:final value) => {'a': value},
      GInt(:final value) => {'n': value},
      GReal(:final value) => {'n': value},
      GList(:final items) => {'l': [for (final x in items) json(x)]},
      GStruct(:final functor, :final args) => {'f': functor, 'args': [for (final x in args) json(x)]},
    };

GTerm term(Object? j) {
  final m = j as Map<String, dynamic>;
  if (m.containsKey('a')) return GAtom(m['a'] as String);
  if (m.containsKey('n')) {
    final n = m['n'] as num;
    return n is int ? GInt(n) : GReal(n.toDouble());
  }
  if (m.containsKey('l')) return GList([for (final x in m['l'] as List) term(x)]);
  return GStruct(m['f'] as String, [for (final x in m['args'] as List) term(x)]);
}

final worlds = <String, World>{};
final engines = <String, (GlpEngine, int)>{};
var made = 0;

Future<void> main(List<String> argv) async {
  final port = int.parse(Platform.environment['PORT'] ?? (argv.isNotEmpty ? argv[0] : '4501'));
  programs = Platform.environment['GLP_PROGRAMS'] ?? Directory('${File.fromUri(Platform.script).parent.parent.parent.parent.path}/programs').absolute.path;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  stdout.writeln('uiagents on 127.0.0.1:$port, programs $programs');
  // Each app loaded at the start, so that the first world asked for comes at once.
  for (final app in apps) {
    World.make('warm-$app', app);
  }
  await for (final req in server) {
    final res = req.response;
    res.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type')
      ..contentType = ContentType.json;
    try {
      if (req.method == 'OPTIONS') {
        await res.close();
        continue;
      }
      final q = req.uri.queryParameters, path = req.uri.path.replaceFirst(RegExp(r'^/uiagents'), '');
      Object? out;
      if (path == '/' || path == '') {
        out = {'worlds': worlds.length, 'apps': apps.toList(), 'persons': persons};
      } else if (path == '/new') {
        final app = q['app'] ?? 'gsg';
        if (!apps.contains(app)) throw ArgumentError('no app $app');
        // At most twenty worlds: the least recently used goes.
        if (worlds.length >= 20) {
          final old = worlds.values.reduce((a, b) => a.used.isBefore(b.used) ? a : b);
          worlds.remove(old.id);
        }
        final id = '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${(made++).toRadixString(36)}';
        worlds[id] = World.make(id, app);
        out = {'id': id, 'app': app, 'persons': persons, 'state': worlds[id]!.state()};
      } else {
        final w = worlds[q['id']];
        if (w == null) {
          res.statusCode = 404;
          out = {'error': 'no world'};
        } else {
          w.used = DateTime.now();
          if (path == '/propose') {
            w.propose(q['p']!, term(jsonDecode(await utf8.decoder.bind(req).join())));
          } else if (path == '/answer') {
            w.answer(q['p']!, int.parse(q['q']!), q['yes'] == '1');
          } else if (path != '/state') {
            res.statusCode = 404;
          }
          out = {'state': w.state()};
        }
      }
      res.write(jsonEncode(out));
    } catch (e) {
      res.statusCode = 400;
      res.write(jsonEncode({'error': '$e'}));
    }
    await res.close();
  }
}

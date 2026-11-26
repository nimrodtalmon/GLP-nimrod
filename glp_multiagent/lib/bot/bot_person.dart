/// A scripted person for an agent with no one at the screen: a bot that looks
/// like any other person to everyone else, its key its own, its agent the
/// Grassroots App's own (`programs/social/graph/core`, superapp/5), and its
/// person a script in place of a human at the screen.
///
/// The script reads what the agent sends its person --- home's draws, and each
/// installed mini-app's, tagged `app(App, D)` (EShapiro2/GLP#181) --- and
/// answers as a person would, by grants on the constructs drawn:
///
/// 1. At its start, on home's request form: open the place, so that a device
///    nearby meets it (GPE:1); trust the key each bundled mini-app is
///    certified under, install Friendship and Groups, and activate both; and
///    invite by link (GRV:2), whose link it reports ([onLink]).
/// 2. On home's cards: yes to each request to connect and each
///    introduction; it befriends no one of its own accord.
/// 3. For each friend home reports (`connected(K)`): accept their invitations
///    to both mini-apps in advance.
/// 4. On each mini-app's screen: establish an identity once, and yes to
///    every approval question.
///
/// Nothing here reaches the agent but the grants a person's screen would
/// make.  The script is the blueprint of other persons with no human at the
/// screen: one that chooses at random, or an AI, decides in [decide].
library;

import '../ui_runtime/bridge.dart';
import '../ui_runtime/term.dart';

/// A bundled mini-app the bot installs: the name it installs it under, its
/// artefact, and the key the artefact is certified under.
typedef BotApp = ({String name, String file, String key});

class BotPerson {
  /// Sends one act of the person to the agent: a grant on home's screen,
  /// `input(Id, P, R)`, or on a mini-app's, tagged `app(App, G)`.
  final void Function(GTerm act) send;

  /// The mini-apps the bot installs and activates.
  final List<BotApp> apps;

  /// Told each link the bot's home makes by Invite by link.
  void Function(String link)? onLink;

  /// Told each line of what the bot does, for its log.
  void Function(String line)? onLog;

  /// Whether it invites by link at its start (GRV:2), which needs a rendezvous server.
  final bool inviteByLink;

  /// The bot's own key, which its acts in a mini-app name as their proposer;
  /// null, and it proposes nothing there.
  final String? me;

  BotPerson({required this.send, this.apps = const [], this.onLink, this.onLog, this.inviteByLink = true, this.me});

  final Set<String> _established = {};

  final Bridge _home = Bridge(onGrant: (_) {});
  final Map<String, Bridge> _apps = {};
  final Set<String> _answered = {};
  final Set<String> _friends = {};
  final Set<String> _links = {};
  bool _started = false;

  /// The bot's friends, as home reported them.
  Set<String> get friends => Set.unmodifiable(_friends);

  /// The mini-apps whose screens are open.
  Iterable<String> get openApps => _apps.keys;

  /// Take one term the agent sent its person.
  void handle(GTerm term) {
    final (ctor, args) = ctorArgs(term);
    if (ctor == 'app' && args.length == 2) {
      final name = _text(args[0]);
      if (name == null) return;
      final b = _apps.putIfAbsent(name, () => Bridge(onGrant: (_) {}));
      b.read(args[1]);
      void grant(GTerm g) => send(GStruct('app', [GAtom(name), g]));
      _establish(name, b, grant);
      _answerAll(b, grant, name);
      return;
    }
    if (!_home.read(term)) return;
    _readNotices();
    _start();
    _answerAll(_home, send, '');
  }

  /// Home's request form: the construct whose widget is the input box of its menu of requests.
  OpenConstruct? get _form {
    for (final c in _home.constructs) {
      if (formatTerm(c.widget).startsWith('input_box(menu([form(trust')) return c;
    }
    return null;
  }

  void _request(GTerm r) {
    final f = _form;
    if (f == null) return;
    _log('request ${formatTerm(r)}');
    send(GStruct('input', [GInt(f.id), const GList([]), r]));
  }

  void _start() {
    if (_started || _form == null) return;
    _started = true;
    _request(const GAtom('open_place'));
    for (final a in apps) {
      _request(GStruct('trust', [GAtom(a.key)]));
    }
    for (final a in apps) {
      _request(GStruct('install', [GAtom(a.name), GAtom(a.file)]));
    }
    for (final a in apps) {
      _request(GStruct('activate', [GAtom(a.name)]));
    }
    if (inviteByLink) _request(const GAtom('invite_link'));
  }

  /// What home told the bot, the thread of construct 0: each new friend's
  /// invitations accepted in advance; each new link reported.
  void _readNotices() {
    final c0 = _home.construct(0);
    if (c0 == null || c0.view is! GList) return;
    for (final m in (c0.view as GList).items) {
      final (f, ms) = ctorArgs(m);
      if (f != 'msg' || ms.length != 3) continue;
      final (n, ns) = ctorArgs(ms[2]);
      final arg = ns.isEmpty ? null : _text(ns[0]);
      if (n == 'connected' && arg != null && _friends.add(arg)) {
        _log('friend $arg');
        if (_started) {
          for (final a in apps) {
            _request(GStruct('accept', [GAtom(a.name), GAtom(arg)]));
          }
        }
      }
      if (n == 'invitation' && arg != null && _links.add(arg)) {
        _log('link $arg');
        onLink?.call(arg);
      }
    }
  }

  /// In each mini-app, once its request question is open: establish an
  /// identity, as a person starting the app does, so that others can take
  /// acts with it.
  void _establish(String app, Bridge b, void Function(GTerm grant) grant) {
    final me = this.me;
    if (me == null || _established.contains(app)) return;
    for (final c in b.constructs) {
      if (!formatTerm(c.widget).startsWith('named(social_menu(')) continue;
      final p = _openQuestion(c.view);
      if (p == null || !formatTerm(c.widget).contains('Establish')) return;
      _established.add(app);
      _log('$app: establish');
      grant(GStruct('input', [GInt(c.id), p, GStruct('propose', [GStruct('establish', [GAtom(me)])])]));
      return;
    }
  }

  /// Answer every open question of [b] not yet answered.
  void _answerAll(Bridge b, void Function(GTerm grant) grant, String where) {
    for (final c in b.constructs.toList()) {
      if (c.id == 0) continue;
      final w = formatTerm(c.widget);
      if (w.startsWith('input_box(') || w.startsWith('named(social_menu(')) continue;
      final p = _openQuestion(c.view);
      if (p == null) continue;
      final key = '$where/${c.id}/${formatTerm(p)}/${formatTerm(c.view)}';
      if (!_answered.add(key)) continue;
      final raw = decide(c.widget, p, c.view);
      if (raw == null) continue;
      _log('${where.isEmpty ? 'home' : where}: ${formatTerm(raw)} on ${formatTerm(c.view)}');
      grant(GStruct('input', [GInt(c.id), p, raw]));
    }
  }

  /// The person's answer to the question at [path] of a construct drawn by
  /// [widget] with [view]; null, and it is left open.  Yes to every
  /// approval and request; no lone button pressed.
  GTerm? decide(GTerm widget, GList path, GTerm view) {
    final w = _at(widget, path);
    final (f, ws) = ctorArgs(w ?? const GAtom(''));
    if (f == 'buttons' && ws.length == 1 && ws[0] is GList) {
      final opts = (ws[0] as GList).items;
      return opts.any((o) => _text(o) == 'yes') ? const GAtom('yes') : (opts.isEmpty ? null : opts.first);
    }
    // A lone button (befriend on a card of a person nearby, introduce) is
    // the person's initiative, which this script leaves to the others.
    if (f == 'button') return null;
    final (nf, ns) = ctorArgs(widget);
    if (nf == 'named' && ns.isNotEmpty && _text(ns[0]) == 'approval_sentence') return const GAtom('yes');
    final (vf, _) = ctorArgs(view);
    if (vf == 'approval') return const GAtom('yes');
    return null;
  }

  /// The widget at [path] of [w]: through a form's fields, by position.
  static GTerm? _at(GTerm w, GList path) {
    var cur = w;
    for (final i in path.items) {
      final (f, ws) = ctorArgs(cur);
      final n = (i as GInt).value;
      if (f == 'named' && ws.length == 2) {
        cur = ws[1];
        final (f2, ws2) = ctorArgs(cur);
        if (f2 != 'form' || ws2.length != 2 || ws2[1] is! GList) return null;
        final fields = (ws2[1] as GList).items;
        if (n < 1 || n > fields.length) return null;
        cur = _fieldWidget(fields[n - 1]) ?? cur;
        continue;
      }
      if (f != 'form' || ws.length != 2 || ws[1] is! GList) return null;
      final fields = (ws[1] as GList).items;
      if (n < 1 || n > fields.length) return null;
      final fw = _fieldWidget(fields[n - 1]);
      if (fw == null) return null;
      cur = fw;
    }
    return cur;
  }

  static GTerm? _fieldWidget(GTerm field) {
    final (f, ws) = ctorArgs(field);
    return f == 'field' && ws.length == 2 ? ws[1] : null;
  }

  /// The position of the first open question in [view]: an `input(P)` anywhere in it.
  static GList? _openQuestion(GTerm view) {
    final q = questionAt(view);
    if (q != null) return q;
    final (_, args) = ctorArgs(view);
    for (final a in args) {
      final p = _openQuestion(a);
      if (p != null) return p;
    }
    if (view is GList) {
      for (final a in view.items) {
        final p = _openQuestion(a);
        if (p != null) return p;
      }
    }
    return null;
  }

  static String? _text(GTerm t) => switch (t) {
        GAtom(:final name) => name,
        GString(:final value) => value,
        _ => null,
      };

  void _log(String line) => onLog?.call(line);
}

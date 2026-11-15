/// A chat-first face of the Grassroots App, for trying it out with people
/// (talmonlab's ADT build): onboarding with a name, Chats and Nearby, and a
/// chat screen.  It drives the same super-app as the generic surface does,
/// only through the bridge: it reads construct 0's notices (connected,
/// received, ...) and the open constructs (nearby cards, friend requests),
/// and grants on them --- befriend, yes/no, and the request send(Friend,
/// Text) on the request stream.
///
/// What the program does not carry, the shell keeps on the phone: the
/// person's name, the names of friends (exchanged as a first, hidden
/// message), and the chat history.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import 'ui_runtime/bridge.dart';
import 'ui_runtime/runtime.dart';
import 'ui_runtime/term.dart';

/// The mark of a hidden message carrying the sender's name.
const String _nameMark = '⁣name:';

class ChatMsg {
  final bool mine;
  final String text;
  final int at;
  ChatMsg(this.mine, this.text, this.at);
  Map<String, dynamic> toJson() => {'m': mine, 't': text, 'a': at};
  static ChatMsg fromJson(Map<String, dynamic> j) =>
      ChatMsg(j['m'] as bool, j['t'] as String, j['a'] as int);
}

/// What the shell keeps on the phone, in one JSON file.
class ChatStore {
  final File file;
  String? myName;
  final Map<String, String> names = {};
  final List<String> friends = [];
  final Map<String, List<ChatMsg>> chats = {};
  final Map<String, int> unread = {};

  /// How far into construct 0's notices the shell has read, and the first
  /// notice then, so that a thread started afresh is read from its start.
  int cursor = 0;
  String? first;

  /// Whether the person's place is open (home's open_place), so that the
  /// phone looks for people nearby and is seen by them.
  bool placeOpen = false;

  ChatStore(this.file);

  static Future<ChatStore> open(String path) async {
    final s = ChatStore(File(path));
    try {
      if (await s.file.exists()) {
        final j = jsonDecode(await s.file.readAsString()) as Map<String, dynamic>;
        s.myName = j['myName'] as String?;
        (j['names'] as Map<String, dynamic>? ?? {})
            .forEach((k, v) => s.names[k] = v as String);
        s.friends.addAll(((j['friends'] as List?) ?? []).cast<String>());
        (j['chats'] as Map<String, dynamic>? ?? {}).forEach((k, v) => s.chats[k] =
            [for (final m in v as List) ChatMsg.fromJson(m as Map<String, dynamic>)]);
        (j['unread'] as Map<String, dynamic>? ?? {})
            .forEach((k, v) => s.unread[k] = v as int);
        s.cursor = j['cursor'] as int? ?? 0;
        s.first = j['first'] as String?;
        s.placeOpen = j['placeOpen'] as bool? ?? false;
      }
    } catch (_) {
      // A file that does not read starts the shell afresh.
    }
    return s;
  }

  Future<void> save() async {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'myName': myName,
        'names': names,
        'friends': friends,
        'chats': {
          for (final e in chats.entries)
            e.key: [for (final m in e.value) m.toJson()]
        },
        'unread': unread,
        'cursor': cursor,
        'first': first,
        'placeOpen': placeOpen,
      }));
    } catch (_) {}
  }

  Future<void> wipe() async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}

/// A person nearby whom the person may befriend, or who asks to connect.
class Pending {
  final int id;
  final GList path;
  final String key;
  Pending(this.id, this.path, this.key);
}

/// The shell's logic: reads the runtime, keeps the store, grants.
class ChatController extends ChangeNotifier {
  final UiRuntime runtime;
  final ChatStore store;
  final String selfKey;
  ChatController(this.runtime, this.store, this.selfKey);

  /// The chat open on screen, whose messages are not unread.
  String? openChat;

  /// The friends this launch has told the person's name.
  final Set<String> _toldName = {};

  /// Sends waiting for the request construct to be open.
  final List<GTerm> _queued = [];

  /// A short line for the screen's snackbar, taken once.
  final StreamController<String> notices = StreamController.broadcast();

  List<Pending> nearby = [];
  List<Pending> requests = [];

  String nameOf(String key) => store.names[key] ?? 'Friend ${code(key)}';
  bool hasName(String key) => store.names.containsKey(key);

  static String code(String key) =>
      key.length >= 4 ? key.substring(0, 4).toUpperCase() : key.toUpperCase();

  int get unreadTotal => store.unread.values.fold(0, (a, b) => a + b);

  /// Friends, the latest chat first.
  List<String> get chatList {
    final l = [...store.friends];
    int last(String k) => store.chats[k]?.lastOrNull?.at ?? 0;
    l.sort((a, b) => last(b).compareTo(last(a)));
    return l;
  }

  void refresh() {
    _readNotices();
    _readConstructs();
    Timer.run(_flush);
    notifyListeners();
  }

  void _readConstructs() {
    final nb = <Pending>[], rq = <Pending>[];
    for (final c in runtime.bridge.constructs) {
      if (c.id == 0) continue;
      final v = c.view;
      if (v is! GStruct) continue;
      if (v.functor == 'nearby' && v.args.length == 2) {
        final p = questionAt(v.args[1]);
        if (p != null) nb.add(Pending(c.id, p, displayText(v.args[0])));
      } else if (v.functor == 'from' && v.args.length == 2) {
        final p = questionAt(v.args[1]);
        if (p != null) rq.add(Pending(c.id, p, displayText(v.args[0])));
      } else if (v.functor == 'approval' && v.args.length == 3) {
        // An introduction asked of the person: the other, accepted or not.
        final p = questionAt(v.args[2]);
        final (_, ia) = ctorArgs(v.args[0]);
        if (p != null && ia.length == 2) {
          rq.add(Pending(c.id, p, displayText(ia[1])));
        }
      }
    }
    nearby = nb;
    requests = rq;
  }

  /// The request construct: the stream of the person's requests.
  OpenConstruct? get _requestConstruct {
    for (final c in runtime.bridge.constructs) {
      if (c.id == 0) continue;
      final p = questionAt(c.view);
      if (p != null && p.items.isEmpty) return c;
    }
    return null;
  }

  void _flush() {
    final c = _requestConstruct;
    if (c == null) return;
    // The place opens once the person has a name: from then on the phone
    // looks for people nearby, and they see it.
    if (!store.placeOpen && (store.myName ?? '').isNotEmpty) {
      store.placeOpen = true;
      store.save();
      runtime.bridge.grant(c.id, const GList([]), const GAtom('open_place'));
    }
    while (_queued.isNotEmpty) {
      runtime.bridge.grant(c.id, const GList([]), _queued.removeAt(0));
    }
  }

  void _grantSend(String key, String text) {
    _queued.add(GStruct('send', [GString(key), GString(text)]));
    // Never grant from inside the runtime's own change callback: the grant
    // goes out on the next turn of the event loop.
    Timer.run(_flush);
  }

  void _tellName(String key) {
    final n = store.myName;
    if (n == null || n.isEmpty) return;
    _toldName.add(key);
    _grantSend(key, '$_nameMark$n');
  }

  void _readNotices() {
    final c0 = runtime.bridge.construct(0);
    final v = c0?.view;
    if (v is! GList) return;
    final items = v.items;
    final firstNow = items.isEmpty ? null : formatTerm(items.first);
    if (store.first != firstNow || items.length < store.cursor) {
      store.cursor = 0;
      store.first = firstNow;
    }
    var changed = false;
    for (; store.cursor < items.length; store.cursor++) {
      final (_, margs) = ctorArgs(items[store.cursor]);
      if (margs.length != 3) continue;
      _notice(margs[2]);
      changed = true;
    }
    if (changed) store.save();
  }

  void _notice(GTerm content) {
    final (k, a) = ctorArgs(content);
    switch (k) {
      case 'connected' when a.length == 1:
        final key = displayText(a[0]);
        if (!store.friends.contains(key)) store.friends.add(key);
        store.chats.putIfAbsent(key, () => []);
        _tellName(key);
      case 'unfriended' when a.length == 1:
        store.friends.remove(displayText(a[0]));
      case 'received' when a.length == 2:
        final key = displayText(a[0]);
        final text = displayText(a[1]);
        if (text.startsWith(_nameMark)) {
          store.names[key] = text.substring(_nameMark.length);
          if (!_toldName.contains(key)) _tellName(key);
          return;
        }
        if (!store.friends.contains(key)) store.friends.add(key);
        store.chats.putIfAbsent(key, () => []).add(
            ChatMsg(false, text, DateTime.now().millisecondsSinceEpoch));
        if (openChat != key) store.unread[key] = (store.unread[key] ?? 0) + 1;
      case 'not_a_friend' when a.length == 1:
        notices.add('Not delivered: you are not connected with '
            '${nameOf(displayText(a[0]))}');
      case 'rejected':
        notices.add('Your request was declined');
    }
  }

  // --- the person's acts ---------------------------------------------------

  /// The nearby cards the person asked to connect from.
  final Set<int> requested = {};

  void connect(Pending p) {
    requested.add(p.id);
    runtime.bridge.grant(p.id, p.path, const GAtom('befriend'));
    notifyListeners();
  }

  void answer(Pending p, bool yes) =>
      runtime.bridge.grant(p.id, p.path, GAtom(yes ? 'yes' : 'no'));

  void send(String key, String text) {
    final t = text.trim();
    if (t.isEmpty) return;
    store.chats.putIfAbsent(key, () => []).add(
        ChatMsg(true, t, DateTime.now().millisecondsSinceEpoch));
    _grantSend(key, t);
    store.save();
    notifyListeners();
  }

  void open(String? key) {
    openChat = key;
    if (key != null && (store.unread[key] ?? 0) > 0) {
      store.unread[key] = 0;
      store.save();
    }
    notifyListeners();
  }

  void setName(String name) {
    store.myName = name.trim();
    store.save();
    _flush();
    for (final f in store.friends) {
      _tellName(f);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    notices.close();
    super.dispose();
  }
}

// === Look ====================================================================

const Color _green = Color(0xFF1E8C5A);

ThemeData chatTheme({String? fontFamily}) => ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      colorScheme: ColorScheme.fromSeed(seedColor: _green, primary: _green),
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: AppBarTheme(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.white,
          elevation: 0,
          titleTextStyle: TextStyle(
              fontFamily: fontFamily,
              color: _green,
              fontSize: 22,
              fontWeight: FontWeight.w700)),
    );

Color _hue(String key) {
  var h = 0;
  for (final c in key.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.45, 0.55).toColor();
}

class Avatar extends StatelessWidget {
  final String keyText;
  final String? name;
  final double size;
  const Avatar(this.keyText, this.name, {super.key, this.size = 44});
  @override
  Widget build(BuildContext context) {
    final n = name?.trim() ?? '';
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: _hue(keyText),
      child: n.isEmpty
          ? Icon(Icons.person, color: Colors.white, size: size * 0.55)
          : Text(n.characters.first.toUpperCase(),
              style: TextStyle(
                  color: Colors.white,
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w600)),
    );
  }
}

String _time(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  String two(int x) => x.toString().padLeft(2, '0');
  if (d.year == now.year && d.month == now.month && d.day == now.day) {
    return '${two(d.hour)}:${two(d.minute)}';
  }
  return '${d.day}/${d.month}';
}

// === Screens =================================================================

/// The shell: the name first, then Chats and Nearby.
class ChatShell extends StatefulWidget {
  final ChatController c;
  final String? warning;
  final Future<void> Function() onStartOver;
  const ChatShell(
      {super.key, required this.c, required this.onStartOver, this.warning});
  @override
  State<ChatShell> createState() => _ChatShellState();
}

class _ChatShellState extends State<ChatShell> {
  int _tab = 0;
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = widget.c.notices.stream.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(m),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2)));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.c,
      builder: (context, _) {
        final c = widget.c;
        if ((c.store.myName ?? '').isEmpty) return NameScreen(c: c);
        final reqs = c.requests.length;
        return Scaffold(
          appBar: AppBar(
            title: const Text('Grassroots'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _profile(context),
                  child: Avatar(c.selfKey, c.store.myName, size: 36),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              if (widget.warning != null)
                Container(
                  width: double.infinity,
                  color: const Color(0xFFFFF4E0),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(widget.warning!,
                      style: const TextStyle(fontSize: 13)),
                ),
              Expanded(
                child: _tab == 0
                    ? ChatsTab(c: c, onNearby: () => setState(() => _tab = 1))
                    : NearbyTab(c: c),
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                icon: Badge(
                    isLabelVisible: c.unreadTotal > 0,
                    label: Text('${c.unreadTotal}'),
                    child: const Icon(Icons.chat_bubble_outline)),
                selectedIcon: const Icon(Icons.chat_bubble),
                label: 'Chats',
              ),
              NavigationDestination(
                icon: Badge(
                    isLabelVisible: reqs > 0,
                    label: Text('$reqs'),
                    child: const Icon(Icons.people_outline)),
                selectedIcon: const Icon(Icons.people),
                label: 'Nearby',
              ),
            ],
          ),
        );
      },
    );
  }

  void _profile(BuildContext context) {
    final c = widget.c;
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Avatar(c.selfKey, c.store.myName, size: 72),
            const SizedBox(height: 12),
            Text(c.store.myName ?? '',
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Your code: ${ChatController.code(c.selfKey)}',
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Change name'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(context);
              },
            ),
            ListTile(
              leading: const Icon(Icons.key_outlined),
              title: const Text('Copy my key'),
              onTap: () {
                Clipboard.setData(ClipboardData(text: c.selfKey));
                Navigator.pop(ctx);
              },
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt, color: Colors.red),
              title: const Text('Start over as a new person',
                  style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.pop(ctx);
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Start over?'),
                    content: const Text(
                        'Your friends and chats on this phone will be gone.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(d, false),
                          child: const Text('Cancel')),
                      TextButton(
                          onPressed: () => Navigator.pop(d, true),
                          child: const Text('Start over')),
                    ],
                  ),
                );
                if (ok == true) await widget.onStartOver();
              },
            ),
          ],
        ),
      ),
    );
  }

  void _rename(BuildContext context) {
    final t = TextEditingController(text: widget.c.store.myName);
    showDialog(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Your name'),
        content: TextField(controller: t, autofocus: true),
        actions: [
          TextButton(
              onPressed: () {
                if (t.text.trim().isNotEmpty) widget.c.setName(t.text);
                Navigator.pop(d);
              },
              child: const Text('Save')),
        ],
      ),
    );
  }
}

class NameScreen extends StatefulWidget {
  final ChatController c;
  const NameScreen({super.key, required this.c});
  @override
  State<NameScreen> createState() => _NameScreenState();
}

class _NameScreenState extends State<NameScreen> {
  final _t = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final ok = _t.text.trim().isNotEmpty;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 64, 28, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.forum_rounded, size: 56, color: _green),
              const SizedBox(height: 20),
              const Text('Grassroots',
                  style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text(
                  'Chat with the people you meet.\nNo company in the middle.',
                  style: TextStyle(fontSize: 17, color: Colors.black54)),
              const SizedBox(height: 40),
              TextField(
                controller: _t,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                    labelText: 'Your name', border: OutlineInputBorder()),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => ok ? widget.c.setName(_t.text) : null,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: ok ? () => widget.c.setName(_t.text) : null,
                  child: const Text('Continue', style: TextStyle(fontSize: 17)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ChatsTab extends StatelessWidget {
  final ChatController c;
  final VoidCallback onNearby;
  const ChatsTab({super.key, required this.c, required this.onNearby});
  @override
  Widget build(BuildContext context) {
    final list = c.chatList;
    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.chat_bubble_outline, size: 56, color: Colors.grey[400]),
            const SizedBox(height: 16),
            const Text('No chats yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text('Meet someone who has the app.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 20),
            FilledButton.icon(
                onPressed: onNearby,
                icon: const Icon(Icons.people),
                label: const Text('See who is nearby')),
          ]),
        ),
      );
    }
    return ListView.builder(
      itemCount: list.length,
      itemBuilder: (context, i) {
        final k = list[i];
        final msgs = c.store.chats[k] ?? const [];
        final last = msgs.lastOrNull;
        final un = c.store.unread[k] ?? 0;
        return ListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          leading: Avatar(k, c.store.names[k]),
          title: Text(c.nameOf(k),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(
              last == null
                  ? 'Say hi 👋'
                  : '${last.mine ? 'You: ' : ''}${last.text}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (last != null)
                Text(_time(last.at),
                    style: TextStyle(
                        fontSize: 12,
                        color: un > 0 ? _green : Colors.black45)),
              const SizedBox(height: 4),
              if (un > 0)
                CircleAvatar(
                    radius: 10,
                    backgroundColor: _green,
                    child: Text('$un',
                        style: const TextStyle(
                            fontSize: 11, color: Colors.white))),
            ],
          ),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => ChatPage(c: c, peer: k))),
        );
      },
    );
  }
}

class NearbyTab extends StatelessWidget {
  final ChatController c;
  const NearbyTab({super.key, required this.c});
  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (c.requests.isNotEmpty) ...[
          const _Header('Want to connect with you'),
          for (final p in c.requests)
            ListTile(
              leading: Avatar(p.key, c.store.names[p.key]),
              title: Text(c.hasName(p.key)
                  ? c.nameOf(p.key)
                  : 'Someone nearby · ${ChatController.code(p.key)}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(
                    tooltip: 'Decline',
                    onPressed: () => c.answer(p, false),
                    icon: const Icon(Icons.close)),
                FilledButton(
                    onPressed: () => c.answer(p, true),
                    child: const Text('Accept')),
              ]),
            ),
        ],
        const _Header('People nearby'),
        if (c.nearby.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(children: [
              SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 14),
              Expanded(
                  child: Text(
                      'Looking… Keep Bluetooth on and stand near someone '
                      'who has the app open.',
                      style: TextStyle(color: Colors.black54))),
            ]),
          )
        else
          for (final p in c.nearby)
            ListTile(
              leading: Avatar(p.key, c.store.names[p.key]),
              title: Text(c.hasName(p.key)
                  ? c.nameOf(p.key)
                  : 'Someone nearby · ${ChatController.code(p.key)}'),
              subtitle: const Text('Has the app'),
              trailing: c.requested.contains(p.id)
                  ? const Text('Requested',
                      style: TextStyle(color: Colors.black45))
                  : OutlinedButton(
                      onPressed: () => c.connect(p),
                      child: const Text('Connect')),
            ),
        if (c.store.friends.isNotEmpty) ...[
          const _Header('Your friends'),
          for (final k in c.store.friends)
            ListTile(
              leading: Avatar(k, c.store.names[k]),
              title: Text(c.nameOf(k)),
              trailing: const Icon(Icons.chat_bubble_outline, color: _green),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatPage(c: c, peer: k))),
            ),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 6),
        child: Text(text.toUpperCase(),
            style: const TextStyle(
                fontSize: 12,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w600,
                color: Colors.black45)),
      );
}

class ChatPage extends StatefulWidget {
  final ChatController c;
  final String peer;
  const ChatPage({super.key, required this.c, required this.peer});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _t = TextEditingController();
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => widget.c.open(widget.peer));
  }

  @override
  void dispose() {
    widget.c.openChat = null;
    _t.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _send() {
    widget.c.send(widget.peer, _t.text);
    _t.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final msgs = c.store.chats[widget.peer] ?? const [];
        return Scaffold(
          backgroundColor: const Color(0xFFF2EFE9),
          appBar: AppBar(
            titleSpacing: 0,
            title: Row(children: [
              Avatar(widget.peer, c.store.names[widget.peer], size: 36),
              const SizedBox(width: 10),
              Text(c.nameOf(widget.peer),
                  style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.w600)),
            ]),
          ),
          body: Column(children: [
            Expanded(
              child: msgs.isEmpty
                  ? const Center(
                      child: Text('Say hi 👋',
                          style:
                              TextStyle(fontSize: 18, color: Colors.black45)))
                  : ListView.builder(
                      controller: _scroll,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 12),
                      itemCount: msgs.length,
                      itemBuilder: (context, i) =>
                          _Bubble(msgs[msgs.length - 1 - i]),
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: Row(children: [
                  Expanded(
                    child: TextField(
                      controller: _t,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: 'Message',
                        filled: true,
                        fillColor: Colors.white,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 18, vertical: 10),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(24),
                            borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton.filled(
                    onPressed: _t.text.trim().isEmpty ? null : _send,
                    icon: const Icon(Icons.send),
                  ),
                ]),
              ),
            ),
          ]),
        );
      },
    );
  }
}

class _Bubble extends StatelessWidget {
  final ChatMsg m;
  const _Bubble(this.m);
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: m.mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(12, 8, 10, 6),
        decoration: BoxDecoration(
          color: m.mine ? const Color(0xFFD7F5DD) : Colors.white,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
                alignment: Alignment.centerLeft,
                widthFactor: 1,
                child: Text(m.text, style: const TextStyle(fontSize: 16))),
            const SizedBox(height: 2),
            Text(_time(m.at),
                style: const TextStyle(fontSize: 11, color: Colors.black45)),
          ],
        ),
      ),
    );
  }
}

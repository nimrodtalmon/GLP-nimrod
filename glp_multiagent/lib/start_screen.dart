/// The Grassroots App's start screen: the person's apps, friends and the few
/// acts that bring a friend in, drawn plainly, with home's own screen one tap
/// away under More.
///
/// Every act here is a request on home's own form, as the person would make
/// it there (quick_acts.dart); every question home asks the person (a request
/// to connect, a person nearby) is drawn here as home draws it
/// ([ConstructView]).  The names of friends are the person's own, kept on the
/// device and told to no one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'quick_acts.dart';
import 'ui_runtime/app_screens.dart';
import 'ui_runtime/bridge.dart';
import 'ui_runtime/construct_family.dart';
import 'ui_runtime/runtime.dart';
import 'ui_runtime/term.dart';

/// Where the bot's current invitation link is published (servers: the bot on
/// the studio desktop, glp_multiagent/bin/bot.dart).
const String botLinkUrl = 'https://talmonlab.bgu.ac.il/grassroots/app/bot-link.txt';

/// Icons of the bundled mini-apps, by the name each is installed under.
const Map<String, IconData> appIcons = {'Friendship': Icons.people_alt_outlined, 'Groups': Icons.forum_outlined};

class StartScreen extends StatefulWidget {
  final UiRuntime home;
  final AppScreens apps;
  final BundledApps bundled;
  final String me;
  final void Function(String app) openApp;
  final VoidCallback openMore;

  const StartScreen({
    super.key,
    required this.home,
    required this.apps,
    required this.bundled,
    required this.me,
    required this.openApp,
    required this.openMore,
  });

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen> {
  Map<String, String> _names = {};
  File? _namesFile;
  bool _asked = false;
  bool _acceptInvites = true;
  final Set<String> _accepted = {};
  bool _waitingLink = false;
  Set<String> _linksBefore = {};

  @override
  void initState() {
    super.initState();
    _loadNames();
  }

  Future<void> _loadNames() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File('${dir.path}/friend_names.json');
      _namesFile = f;
      if (f.existsSync()) {
        final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
        setState(() => _names = m.map((k, v) => MapEntry(k, '$v')));
      }
    } catch (_) {}
  }

  void _saveNames() {
    try {
      _namesFile?.writeAsStringSync(jsonEncode(_names));
    } catch (_) {}
  }

  // ---------------------------------------------------------------- home's form

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

  // ---------------------------------------------------------------- what home told the person

  List<(String, List<GTerm>)> get _notices {
    final v = widget.home.bridge.construct(0)?.view;
    if (v is! GList) return const [];
    return [
      for (final m in v.items)
        if (ctorArgs(m) case ('msg', [_, _, final body])) ctorArgs(body),
    ];
  }

  Set<String> get _links => {
        for (final (f, args) in _notices)
          if (f == 'invitation' && args.isNotEmpty && _text(args[0]) != null) _text(args[0])!,
      };

  static String? _text(GTerm t) => switch (t) {
        GAtom(:final name) => name,
        GString(:final value) => value,
        _ => null,
      };

  String _short(String k) => k.length > 10 ? '${k.substring(0, 6)}…${k.substring(k.length - 4)}' : k;
  String _nameOf(String k) => _names[k] ?? 'Friend ${_short(k)}';

  /// Home's questions to the person: every open construct but its thread and its request form.
  List<OpenConstruct> get _questions => [
        for (final c in widget.home.bridge.constructs)
          if (c.id != 0 && !formatTerm(c.widget).startsWith('input_box(')) c,
      ];

  // ---------------------------------------------------------------- acts

  Future<void> _pasteLink() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (!mounted) return;
    final ctl = TextEditingController(text: clip.contains('peoplesweb.org/i#') ? clip : '');
    final link = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Open a friend\'s link'),
        content: TextField(controller: ctl, maxLines: 4, decoration: const InputDecoration(hintText: 'https://peoplesweb.org/i#…')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Open')),
        ],
      ),
    );
    if (link != null && link.isNotEmpty) _openLink(link);
  }

  void _openLink(String link) {
    _request(GStruct('open_link', [GString(link)]));
    _snack('Asking to connect…');
  }

  Future<void> _befriendBot() async {
    try {
      final client = HttpClient();
      final req = await client.getUrl(Uri.parse(botLinkUrl));
      final res = await req.close();
      final body = (await res.transform(utf8.decoder).join()).trim();
      client.close();
      if (!body.startsWith('https://')) throw 'no link';
      _openLink(body);
    } catch (e) {
      _snack('Could not fetch the bot\'s link');
    }
  }

  void _shareMyLink() {
    _linksBefore = _links;
    setState(() => _waitingLink = true);
    _request(const GAtom('invite_link'));
  }

  void _snack(String s) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  }

  Future<void> _rename(String k) async {
    final ctl = TextEditingController(text: _names[k] ?? '');
    final n = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Name'),
        content: TextField(controller: ctl, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: const Text('Save')),
        ],
      ),
    );
    if (n == null) return;
    setState(() => n.isEmpty ? _names.remove(k) : _names[k] = n);
    _saveNames();
  }

  // ---------------------------------------------------------------- the screen

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final installed = widget.apps.apps.toSet();
    final friends = friendsOf(widget.home);
    final links = _links;

    // A new friend's invitations to the apps are accepted, while the switch is on.
    if (_acceptInvites && _form != null) {
      for (final k in friends) {
        if (_accepted.add(k)) {
          for (final (name, _) in bundledApps) {
            _request(GStruct('accept', [GAtom(name), GAtom(k)]));
          }
        }
      }
    }
    // The link made by Share my link.
    if (_waitingLink) {
      final fresh = links.difference(_linksBefore);
      if (fresh.isNotEmpty) {
        _waitingLink = false;
        final l = fresh.first;
        WidgetsBinding.instance.addPostFrameCallback((_) => _showLink(l));
      }
    }

    Widget section(String title, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
          child: Row(children: [
            Expanded(child: Text(title, style: t.textTheme.titleSmall?.copyWith(color: t.colorScheme.primary))),
            if (trailing != null) trailing,
          ]),
        );

    final questions = _questions;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
          child: Row(children: [
            Expanded(child: Text('Grassroots', style: t.textTheme.headlineSmall)),
            TextButton.icon(onPressed: widget.openMore, icon: const Icon(Icons.tune, size: 18), label: const Text('More')),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text('You: ${_short(widget.me)}', style: t.textTheme.bodySmall?.copyWith(color: t.hintColor)),
        ),

        if (questions.isNotEmpty) ...[
          section('Waiting for you'),
          for (final c in questions)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: ConstructView(
                key: constructKey(c.id),
                construct: c,
                grant: (path, raw) => widget.home.bridge.grant(c.id, path, raw),
              ),
            ),
        ],

        section('Apps'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            for (final (name, _) in bundledApps)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: _AppTile(
                    name: name,
                    icon: appIcons[name] ?? Icons.apps,
                    ready: installed.contains(name),
                    waiting: widget.apps.waiting(name),
                    onTap: installed.contains(name) ? () => widget.openApp(name) : null,
                  ),
                ),
              ),
          ]),
        ),
        if (!bundledApps.every((a) => installed.contains(a.$1)))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _asked
                ? Text('Getting the apps…', style: TextStyle(color: t.hintColor))
                : FilledButton.icon(
                    key: const ValueKey('start:get-apps'),
                    onPressed: widget.bundled.ready && _form != null ? _getApps : null,
                    icon: const Icon(Icons.download),
                    label: const Text('Get Friendship and Groups'),
                  ),
          ),

        section('Friends',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Text('Let them invite me', style: t.textTheme.bodySmall),
              Switch(value: _acceptInvites, onChanged: (v) => setState(() => _acceptInvites = v)),
            ])),
        if (friends.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text('No friends yet. Add one below.', style: TextStyle(color: t.hintColor)),
          ),
        for (final k in friends)
          ListTile(
            leading: CircleAvatar(child: Text(_nameOf(k).characters.first.toUpperCase())),
            title: Text(_nameOf(k)),
            subtitle: Text(_short(k)),
            onTap: () => _rename(k),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'rename') {
                  _rename(k);
                } else {
                  _request(GStruct('invite', [GAtom(v), GAtom(k)]));
                  _snack('Invited ${_nameOf(k)} to $v');
                }
              },
              itemBuilder: (_) => [
                for (final (name, _) in bundledApps)
                  if (installed.contains(name)) PopupMenuItem(value: name, child: Text('Invite to $name')),
                const PopupMenuItem(value: 'rename', child: Text('Rename')),
              ],
            ),
          ),

        section('Add a friend'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            OutlinedButton.icon(onPressed: _form == null ? null : _shareMyLink, icon: const Icon(Icons.ios_share), label: Text(_waitingLink ? 'Making a link…' : 'Share my link')),
            OutlinedButton.icon(onPressed: _form == null ? null : _pasteLink, icon: const Icon(Icons.link), label: const Text('Open a link')),
            OutlinedButton.icon(onPressed: _form == null ? null : () => _request(const GAtom('open_place')), icon: const Icon(Icons.wifi_tethering), label: const Text('Nearby')),
            OutlinedButton.icon(onPressed: _form == null ? null : _befriendBot, icon: const Icon(Icons.smart_toy_outlined), label: const Text('Befriend the bot')),
          ]),
        ),
      ],
    );
  }

  Future<void> _showLink(String link) async {
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Your link'),
        content: SelectableText(link, style: const TextStyle(fontSize: 12)),
        actions: [
          TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link));
                Navigator.pop(c);
                _snack('Copied');
              },
              child: const Text('Copy')),
        ],
      ),
    );
  }
}

class _AppTile extends StatelessWidget {
  final String name;
  final IconData icon;
  final bool ready;
  final int waiting;
  final VoidCallback? onTap;
  const _AppTile({required this.name, required this.icon, required this.ready, required this.waiting, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      elevation: 0,
      color: ready ? t.colorScheme.primaryContainer : t.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        key: ValueKey('start:app:$name'),
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 22),
          child: Column(children: [
            Badge(isLabelVisible: waiting > 0, label: Text('$waiting'), child: Icon(icon, size: 34)),
            const SizedBox(height: 8),
            Text(name, style: t.textTheme.titleMedium),
            if (!ready) Text('not installed', style: t.textTheme.bodySmall?.copyWith(color: t.hintColor)),
          ]),
        ),
      ),
    );
  }
}

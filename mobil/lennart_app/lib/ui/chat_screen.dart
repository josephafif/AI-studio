import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/catalog.dart';
import '../core/chats.dart';
import '../core/engine.dart';
import '../core/tokenizer.dart';
import 'aurora.dart';
import 'orb.dart';
import 'sheets.dart';
import 'theme.dart';

class ChatScreen extends StatefulWidget {
  final Catalog catalog;
  final ChatStore store;
  const ChatScreen({super.key, required this.catalog, required this.store});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _engine = LennartEngine();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  late ModelInfo _model = widget.catalog.models.last; // nyaste först
  late GenSettings _settings = _defaults(_model);
  late Conversation _chat = Conversation.empty(_model.id);
  bool _loading = false, _busy = false;
  StreamSubscription<GenEvent>? _sub;

  static const _suggestions = [
    'Hej! Vem är du?',
    'Vad är nätfiske?',
    'Hur skapar jag ett starkt lösenord?',
    'Någon har hackat mitt konto, vad gör jag?',
    'Ge mig tips för att sova bättre',
    'Vad är en brandvägg?',
  ];

  GenSettings _defaults(ModelInfo m) => GenSettings(temperature: m.temperature, maxTokens: m.maxTokens, topK: m.topK);
  Color get _color => Palette.model(_model.index);

  @override
  void initState() {
    super.initState();
    _loadModel(_model);
  }

  Future<void> _loadModel(ModelInfo m) async {
    setState(() {
      _model = m;
      _settings = _defaults(m);
      _loading = true;
    });
    try {
      await _engine.load(m.id, widget.catalog.modelPath(m), widget.catalog.tokenizerPath(m));
    } catch (e) {
      _toast('Kunde inte läsa in ${m.name}: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy || _loading) return;
    HapticFeedback.lightImpact();
    _input.clear();
    final reply = Message(false, '');
    setState(() {
      _chat.modelId = _model.id;
      _chat.messages
        ..add(Message(true, text))
        ..add(reply);
      _busy = true;
    });
    _scrollDown();
    final turns = [
      for (final m in _chat.messages.sublist(0, _chat.messages.length - 1))
        if (!m.error && m.text.isNotEmpty) ChatTurn(m.fromUser, m.text)
    ];
    _sub = _engine.generate(turns, _settings).listen((e) {
      switch (e) {
        case GenToken(:final text):
          setState(() => reply.text += text);
          _scrollDown();
        case GenDone():
          setState(() {
            if (reply.text.trim().isEmpty) reply.text = '…';
            reply.meta = '${_model.name} · ${e.tokens} tokens · ${e.tokensPerSecond.toStringAsFixed(1)} tok/s';
            _busy = false;
          });
          widget.store.save(_chat);
        case GenError(:final message):
          setState(() {
            reply
              ..text = message
              ..error = true;
            _busy = false;
          });
      }
    });
  }

  void _stop() {
    _engine.stop();
    HapticFeedback.selectionClick();
  }

  void _newChat() {
    if (_busy) return;
    setState(() => _chat = Conversation.empty(_model.id));
  }

  Future<void> _openChat(Conversation c) async {
    Navigator.pop(context);
    if (_busy) return;
    setState(() => _chat = c);
    final m = widget.catalog.models.where((x) => x.id == c.modelId).firstOrNull;
    if (m != null && m.id != _model.id) await _loadModel(m);
    _scrollDown();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
      drawer: _HistoryDrawer(store: widget.store, catalog: widget.catalog, onOpen: _openChat, onNew: () {
        Navigator.pop(context);
        _newChat();
      }),
      body: Stack(children: [
        Positioned.fill(child: Aurora(accent: _color)),
        SafeArea(
          child: Column(children: [
            _topBar(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: _chat.messages.isEmpty ? _empty() : _messages(),
              ),
            ),
            _composer(),
          ]),
        ),
      ]),
    );
  }

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
      child: Row(children: [
        Builder(
            builder: (ctx) => IconButton(
                icon: const Icon(Icons.notes_rounded, color: Palette.text), onPressed: () => Scaffold.of(ctx).openDrawer())),
        Expanded(
          child: Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: _busy
                  ? null
                  : () async {
                      final m = await pickModel(context, widget.catalog.models, _model.id);
                      if (m != null && m.id != _model.id) _loadModel(m);
                    },
              child: Glass(
                radius: 30,
                padding: const EdgeInsets.fromLTRB(6, 4, 12, 4),
                border: _color.withValues(alpha: 0.35),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Orb(size: 30, color: _color, thinking: _busy || _loading),
                  const SizedBox(width: 6),
                  Text(_model.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(width: 4),
                  Text(_model.paramsLabel, style: TextStyle(color: _color, fontSize: 12, fontWeight: FontWeight.w600)),
                  const Icon(Icons.expand_more_rounded, size: 18, color: Palette.muted),
                ]),
              ),
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.tune_rounded, color: Palette.text),
          onPressed: () async {
            final s = await editSettings(context, _settings, _model);
            if (s != null) setState(() => _settings = s);
          },
        ),
        IconButton(icon: const Icon(Icons.edit_square, color: Palette.text, size: 21), onPressed: _newChat),
      ]),
    );
  }

  Widget _empty() {
    return ListView(
      key: const ValueKey('empty'),
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      children: [
        Center(child: Orb(size: 170, color: _color, thinking: _loading)),
        const SizedBox(height: 6),
        Center(
          child: ShaderMask(
            shaderCallback: (r) => LinearGradient(colors: [_color, Palette.cyan]).createShader(r),
            child: Text(_loading ? 'Väcker ${_model.name} …' : 'Hej! Jag är ${_model.name}.',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: -0.5)),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text('Svensk AI som körs helt på din telefon – inget lämnar den.',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 13)),
        ),
        const SizedBox(height: 26),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _suggestions)
              ActionChip(
                label: Text(s),
                onPressed: () => _send(s),
                backgroundColor: Palette.glass,
                side: const BorderSide(color: Palette.stroke),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                labelStyle: const TextStyle(color: Palette.text, fontSize: 13),
              ),
          ],
        ),
      ],
    );
  }

  Widget _messages() {
    return ListView.builder(
      key: const ValueKey('list'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      itemCount: _chat.messages.length,
      itemBuilder: (_, i) {
        final m = _chat.messages[i];
        final last = i == _chat.messages.length - 1;
        return _Bubble(
          message: m,
          color: Palette.model((widget.catalog.models.where((x) => x.id == _chat.modelId).firstOrNull ?? _model).index),
          thinking: last && _busy && m.text.isEmpty,
          streaming: last && _busy,
        );
      },
    );
  }

  Widget _composer() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Glass(
        radius: 28,
        padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
        border: _focus.hasFocus ? _color.withValues(alpha: 0.5) : null,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(color: Palette.text, fontSize: 16),
              cursorColor: _color,
              decoration: InputDecoration(
                hintText: _loading ? 'Läser in ${_model.name} …' : 'Fråga ${_model.name} något …',
                hintStyle: const TextStyle(color: Palette.muted),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _busy
                ? _RoundButton(icon: Icons.stop_rounded, colors: const [Palette.danger, Color(0xFFFF9A6B)], onTap: _stop)
                : _RoundButton(icon: Icons.arrow_upward_rounded, colors: [_color, Palette.cyan], onTap: _loading ? null : () => _send()),
          ),
        ]),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  final IconData icon;
  final List<Color> colors;
  final VoidCallback? onTap;
  const _RoundButton({required this.icon, required this.colors, this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(colors: onTap == null ? [Palette.stroke, Palette.stroke] : colors),
          boxShadow: onTap == null ? null : [BoxShadow(color: colors.first.withValues(alpha: 0.45), blurRadius: 18)],
        ),
        child: Icon(icon, color: const Color(0xFF03140C), size: 24),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message message;
  final Color color;
  final bool thinking, streaming;
  const _Bubble({required this.message, required this.color, required this.thinking, required this.streaming});

  @override
  Widget build(BuildContext context) {
    final user = message.fromUser;
    final body = thinking
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            const _Dots(),
            const SizedBox(width: 8),
            Text('tänker', style: TextStyle(color: color.withValues(alpha: 0.9), fontSize: 13)),
          ])
        : Text.rich(TextSpan(children: [
            TextSpan(
                text: message.text,
                style: TextStyle(
                    color: user ? const Color(0xFF03140C) : (message.error ? Palette.danger : Palette.text),
                    fontWeight: user ? FontWeight.w500 : FontWeight.w400)),
            if (streaming && !user) WidgetSpan(child: _Caret(color: color)),
          ]));
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        gradient: user ? LinearGradient(colors: [color, Palette.cyan], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
        color: user ? null : Palette.glass,
        border: user ? null : Border.all(color: color.withValues(alpha: 0.22)),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: Radius.circular(user ? 20 : 6),
          bottomRight: Radius.circular(user ? 6 : 20),
        ),
      ),
      child: body,
    );
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (_, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 12 * (1 - v)), child: child)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: user ? CrossAxisAlignment.end : CrossAxisAlignment.start, children: [
          Row(
            mainAxisAlignment: user ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!user) ...[Orb(size: 30, color: color, thinking: streaming), const SizedBox(width: 6)],
              Flexible(
                child: GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: message.text));
                    HapticFeedback.mediumImpact();
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kopierat')));
                  },
                  child: bubble,
                ),
              ),
            ],
          ),
          if (message.meta != null)
            Padding(
              padding: const EdgeInsets.only(left: 42, top: 4),
              child: Text(message.meta!, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
            ),
        ]),
      ),
    );
  }
}

class _Dots extends StatefulWidget {
  const _Dots();
  @override
  State<_Dots> createState() => _DotsState();
}

class _DotsState extends State<_Dots> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Palette.text.withValues(alpha: 0.25 + 0.75 * (((_c.value * 3 - i) % 3) < 1 ? 1 : 0.0)),
            ),
          ),
      ]),
    );
  }
}

class _Caret extends StatefulWidget {
  final Color color;
  const _Caret({required this.color});
  @override
  State<_Caret> createState() => _CaretState();
}

class _CaretState extends State<_Caret> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
        opacity: _c,
        child: Container(
          margin: const EdgeInsets.only(left: 2),
          width: 8,
          height: 16,
          decoration: BoxDecoration(
              color: widget.color,
              borderRadius: BorderRadius.circular(2),
              boxShadow: [BoxShadow(color: widget.color, blurRadius: 8)]),
        ),
      );
}

class _HistoryDrawer extends StatefulWidget {
  final ChatStore store;
  final Catalog catalog;
  final void Function(Conversation) onOpen;
  final VoidCallback onNew;
  const _HistoryDrawer({required this.store, required this.catalog, required this.onOpen, required this.onNew});
  @override
  State<_HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<_HistoryDrawer> {
  @override
  Widget build(BuildContext context) {
    final items = widget.store.items;
    return Drawer(
      backgroundColor: Palette.surface,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Row(children: [
              const Orb(size: 36, color: Palette.green),
              const SizedBox(width: 8),
              Text('Lennart', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 20)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: Palette.green, foregroundColor: const Color(0xFF03140C), padding: const EdgeInsets.all(14)),
                onPressed: widget.onNew,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Nytt samtal', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
            child: Text('TIDIGARE SAMTAL', style: Theme.of(context).textTheme.bodySmall?.copyWith(letterSpacing: 1.2)),
          ),
          Expanded(
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text('Dina samtal sparas här.', style: Theme.of(context).textTheme.bodySmall))
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final c = items[i];
                      final m = widget.catalog.models.where((x) => x.id == c.modelId).firstOrNull;
                      return Dismissible(
                        key: ValueKey(c.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            color: Palette.danger.withValues(alpha: 0.2),
                            child: const Icon(Icons.delete_outline_rounded, color: Palette.danger)),
                        onDismissed: (_) => setState(() => widget.store.delete(c)),
                        child: ListTile(
                          leading: Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: Palette.model(m?.index ?? 0)),
                          ),
                          title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Palette.text)),
                          subtitle: Text(m?.name ?? c.modelId, style: Theme.of(context).textTheme.bodySmall),
                          onTap: () => widget.onOpen(c),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(18),
            child: Text('Allt körs lokalt på telefonen.\nModeller från AI Control Center.',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        ]),
      ),
    );
  }
}

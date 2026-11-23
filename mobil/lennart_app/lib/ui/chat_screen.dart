import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/catalog.dart';
import '../core/chats.dart';
import '../core/engine.dart';
import '../core/tokenizer.dart';
import 'ascii.dart';
import 'glass.dart';
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
  late ModelInfo _model = widget.catalog.latest;
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
  Color get _color => _model.color;
  String _label(ModelInfo m) => ModelIcon.labelFor(m.name);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
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
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
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
            reply.meta = '${_model.name} · ${e.tokens} tok · ${e.tokensPerSecond.toStringAsFixed(1)} tok/s';
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

  Future<void> _importModel() async {
    String? path;
    try {
      path = await Catalog.pickFile();
    } on MissingPluginException {
      _toast('Filväljaren finns bara på telefonen');
      return;
    }
    if (path == null || !mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Glass(
          padding: const EdgeInsets.all(26),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AsciiSphere(size: 120, color: Palette.violet, thinking: true),
            const SizedBox(height: 10),
            Material(color: Colors.transparent, child: BrailleSpinner(color: ctx.c.accent, text: 'installerar modellen')),
          ]),
        ),
      ),
    );
    try {
      final m = await widget.catalog.importPackage(path);
      if (!mounted) return;
      Navigator.pop(context);
      _toast('${m.name} är installerad');
      await _loadModel(m);
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      _toast('Kunde inte installera: $e');
    } finally {
      try {
        await File(path).delete();
      } catch (_) {}
    }
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
    final c = context.c;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: c.bg,
      statusBarIconBrightness: c.dark ? Brightness.light : Brightness.dark,
      systemNavigationBarIconBrightness: c.dark ? Brightness.light : Brightness.dark,
    ));
    return Scaffold(
      resizeToAvoidBottomInset: true,
      drawer: _HistoryDrawer(store: widget.store, catalog: widget.catalog, onOpen: _openChat, onNew: () {
        Navigator.pop(context);
        _newChat();
      }),
      body: Stack(children: [
        Positioned.fill(child: AsciiRain(color: _color)),
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
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
      child: Row(children: [
        Builder(builder: (ctx) => IconButton(icon: Icon(Icons.notes_rounded, color: c.text), onPressed: () => Scaffold.of(ctx).openDrawer())),
        Expanded(
          child: Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(30),
              onTap: _busy
                  ? null
                  : () async {
                      final m = await pickModel(context, widget.catalog.models, _model.id);
                      if (m == 'importera') {
                        await _importModel();
                      } else if (m is ModelInfo && m.id != _model.id) {
                        _loadModel(m);
                      }
                    },
              child: Glass(
                radius: 30,
                padding: const EdgeInsets.fromLTRB(5, 5, 12, 5),
                border: _color.withValues(alpha: 0.4),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  ModelIcon(size: 30, color: _color, label: _label(_model), thinking: _busy || _loading),
                  const SizedBox(width: 8),
                  Text(_model.name, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: c.text)),
                  const SizedBox(width: 6),
                  Text(_model.paramsLabel, style: mono.copyWith(color: c.dark ? _color : c.muted, fontSize: 11, fontWeight: FontWeight.w700)),
                  Icon(Icons.expand_more_rounded, size: 18, color: c.muted),
                ]),
              ),
            ),
          ),
        ),
        IconButton(
          icon: Icon(Icons.tune_rounded, color: c.text),
          onPressed: () async {
            final s = await editSettings(context, _settings, _model);
            if (s != null) setState(() => _settings = s);
          },
        ),
        IconButton(icon: Icon(Icons.edit_square, color: c.text, size: 21), onPressed: _newChat),
      ]),
    );
  }

  Widget _empty() {
    final c = context.c;
    return ListView(
      key: ValueKey('empty-${_model.id}'),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      children: [
        Center(child: AsciiSphere(size: 230, color: _color, thinking: _loading)),
        Center(
          child: ShaderMask(
            shaderCallback: (r) => LinearGradient(colors: [_color, Palette.cyan]).createShader(r),
            child: ScrambleText(_loading ? 'Väcker ${_model.name} …' : 'Hej! Jag är ${_model.name}.',
                style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: -0.5)),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text('> svensk AI · körs helt på telefonen · inget lämnar den_',
              textAlign: TextAlign.center, style: mono.copyWith(color: c.muted, fontSize: 11.5)),
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in _suggestions)
              ActionChip(
                label: Text(s),
                onPressed: () => _send(s),
                backgroundColor: c.glass,
                side: BorderSide(color: c.stroke),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                labelStyle: TextStyle(color: c.text, fontSize: 13),
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
        final model = widget.catalog.models.where((x) => x.id == _chat.modelId).firstOrNull ?? _model;
        return _Bubble(
          message: m,
          color: model.color,
          label: _label(model),
          thinking: last && _busy && m.text.isEmpty,
          streaming: last && _busy,
        );
      },
    );
  }

  Widget _composer() {
    final c = context.c;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: Glass(
        radius: 26,
        padding: const EdgeInsets.fromLTRB(16, 4, 6, 4),
        border: _focus.hasFocus ? _color.withValues(alpha: 0.6) : null,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 14, right: 6),
            child: Text('>', style: mono.copyWith(color: _color, fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(color: c.text, fontSize: 16),
              cursorColor: _color,
              cursorWidth: 8,
              decoration: InputDecoration(
                hintText: _loading ? 'läser in ${_model.name} …' : 'fråga ${_model.name} något …',
                hintStyle: mono.copyWith(color: c.muted, fontSize: 14),
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
    final c = context.c;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(colors: onTap == null ? [c.stroke, c.stroke] : colors),
          boxShadow: onTap == null ? null : [BoxShadow(color: colors.first.withValues(alpha: 0.45), blurRadius: 18)],
        ),
        child: Icon(icon, color: Palette.ink, size: 24),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Message message;
  final Color color;
  final String label;
  final bool thinking, streaming;
  const _Bubble({required this.message, required this.color, required this.label, required this.thinking, required this.streaming});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final user = message.fromUser;
    final Widget body = thinking
        ? BrailleSpinner(color: c.dark ? color : HSLColor.fromColor(color).withLightness(0.35).toColor())
        : Text.rich(TextSpan(children: [
            TextSpan(
                text: message.text,
                style: TextStyle(
                    color: user ? Palette.ink : (message.error ? Palette.danger : c.text),
                    fontWeight: user ? FontWeight.w500 : FontWeight.w400,
                    fontSize: 15.5,
                    height: 1.45)),
            if (streaming && !user) WidgetSpan(alignment: PlaceholderAlignment.middle, child: DecodingTail(color: color)),
          ]));
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      decoration: BoxDecoration(
        gradient: user ? LinearGradient(colors: [color, Palette.cyan], begin: Alignment.topLeft, end: Alignment.bottomRight) : null,
        color: user ? null : c.glass,
        border: user ? null : Border.all(color: color.withValues(alpha: c.dark ? 0.25 : 0.4)),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(20),
          topRight: const Radius.circular(20),
          bottomLeft: Radius.circular(user ? 20 : 6),
          bottomRight: Radius.circular(user ? 6 : 20),
        ),
        boxShadow: c.dark ? null : [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 12, offset: const Offset(0, 3))],
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
              if (!user) ...[ModelIcon(size: 30, color: color, label: label, thinking: streaming), const SizedBox(width: 8)],
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
              padding: const EdgeInsets.only(left: 40, top: 4),
              child: Text('// ${message.meta!}', style: mono.copyWith(color: c.muted, fontSize: 10.5)),
            ),
        ]),
      ),
    );
  }
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
    final c = context.c;
    final items = widget.store.items;
    return Drawer(
      backgroundColor: c.surface,
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
            child: Row(children: [
              ModelIcon(size: 38, color: widget.catalog.latest.color, label: 'L'),
              const SizedBox(width: 10),
              Text('lennart_', style: mono.copyWith(color: c.text, fontSize: 20, fontWeight: FontWeight.w800)),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                    backgroundColor: c.accent,
                    foregroundColor: c.dark ? Palette.ink : Colors.white,
                    padding: const EdgeInsets.all(14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                onPressed: widget.onNew,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Nytt samtal', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 6),
            child: Text('// tidigare samtal', style: mono.copyWith(color: c.muted, fontSize: 12)),
          ),
          Expanded(
            child: items.isEmpty
                ? Padding(padding: const EdgeInsets.all(18), child: Text('Dina samtal sparas här.', style: Theme.of(context).textTheme.bodySmall))
                : ListView.builder(
                    itemCount: items.length,
                    itemBuilder: (_, i) {
                      final conv = items[i];
                      final m = widget.catalog.models.where((x) => x.id == conv.modelId).firstOrNull;
                      return Dismissible(
                        key: ValueKey(conv.id),
                        direction: DismissDirection.endToStart,
                        background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 20),
                            color: Palette.danger.withValues(alpha: 0.2),
                            child: const Icon(Icons.delete_outline_rounded, color: Palette.danger)),
                        onDismissed: (_) => setState(() => widget.store.delete(conv)),
                        child: ListTile(
                          leading: ModelIcon(size: 28, color: m?.color ?? Palette.green, label: ModelIcon.labelFor(m?.name ?? '1')),
                          title: Text(conv.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.text)),
                          subtitle: Text(m?.name ?? conv.modelId, style: mono.copyWith(color: c.muted, fontSize: 11)),
                          onTap: () => widget.onOpen(conv),
                        ),
                      );
                    },
                  ),
          ),
          const Padding(padding: EdgeInsets.fromLTRB(14, 0, 14, 8), child: AppearancePicker()),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
            child: Text('Allt körs lokalt på telefonen.\nModeller från AI Control Center.', style: Theme.of(context).textTheme.bodySmall),
          ),
        ]),
      ),
    );
  }
}

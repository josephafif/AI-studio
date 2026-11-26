import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/catalog.dart';
import '../core/chats.dart';
import '../core/engine.dart';
import '../core/prefs.dart';
import '../core/tokenizer.dart';
import 'ascii.dart';
import 'glass.dart';
import 'sheets.dart';
import 'theme.dart';

class ChatScreen extends StatefulWidget {
  final Catalog catalog;
  final ChatStore store;
  final LennartEngine? engine; // kan bytas ut i tester
  const ChatScreen({super.key, required this.catalog, required this.store, this.engine});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  late final LennartEngine _engine = widget.engine ?? LennartEngine();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();
  late ModelInfo _model =
      widget.catalog.models.where((m) => m.id == Prefs.modelId).firstOrNull ?? widget.catalog.latest;
  late GenSettings _settings = _defaults(_model);
  late Conversation _chat = Conversation.empty(_model.id);
  bool _loading = false, _busy = false;
  int _draftTotal = 0, _draftIndex = 0;
  StreamSubscription<GenEvent>? _sub;

  GenSettings _defaults(ModelInfo m) =>
      GenSettings(temperature: m.temperature, maxTokens: m.maxTokens, topK: m.topK, effort: Prefs.effort);
  Color get _color => _model.color;
  String _label(ModelInfo m) => ModelIcon.labelFor(m.name);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
    _input.addListener(() => setState(() {}));
    _loadModel(_model);
  }

  Future<void> _loadModel(ModelInfo m) async {
    setState(() {
      _model = m;
      _settings = _defaults(m);
      _loading = true;
    });
    Prefs.modelId = m.id;
    try {
      await _engine.load(m.id, widget.catalog.modelPath(m), widget.catalog.tokenizerPath(m));
    } catch (e) {
      _toast('Kunde inte läsa in ${m.name}: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  void _toast(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  void _scrollDown({bool jump = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final end = _scroll.position.maxScrollExtent;
      if (jump) {
        _scroll.jumpTo(end);
      } else {
        _scroll.animateTo(end, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      }
    });
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _busy || _loading) return;
    HapticFeedback.lightImpact();
    _input.clear();
    setState(() {
      _chat.modelId = _model.id;
      _chat.messages.add(Message(true, text));
    });
    _generate();
  }

  /// Skriver ett nytt svar på det sista användarmeddelandet.
  void _regenerate() {
    if (_busy || _loading || _chat.messages.isEmpty || _chat.messages.last.fromUser) return;
    HapticFeedback.selectionClick();
    setState(() => _chat.messages.removeLast());
    _generate();
  }

  void _generate() {
    final reply = Message(false, '');
    final turns = [
      for (final m in _chat.messages)
        if (!m.error && m.text.isNotEmpty) ChatTurn(m.fromUser, m.text)
    ];
    final effort = _settings.effort;
    setState(() {
      _chat.messages.add(reply);
      _busy = true;
      _draftTotal = effort.drafts;
      _draftIndex = 0;
    });
    _scrollDown();
    _sub = _engine.generate(turns, _settings).listen((e) {
      switch (e) {
        case GenToken(:final text):
          setState(() => reply.text += text);
          _scrollDown(jump: true);
        case GenDraft(:final index, :final total, :final text):
          setState(() {
            while (reply.drafts.length <= index) {
              reply.drafts.add(Draft(''));
            }
            reply.drafts[index].text += text;
            _draftIndex = index;
            _draftTotal = total;
          });
        case GenDraftEnd(:final index, :final score, :final pruned):
          if (index < reply.drafts.length) {
            setState(() => reply.drafts[index]
              ..score = score
              ..pruned = pruned);
          }
        case GenChosen(:final index, :final text):
          setState(() {
            reply
              ..chosen = index
              ..text = text.trim()
              ..reveal = true;
          });
          _scrollDown();
        case GenDone():
          setState(() {
            if (reply.text.trim().isEmpty) reply.text = '…';
            if (reply.drafts.isNotEmpty) reply.thoughtSeconds = e.seconds;
            reply.uncertain = e.uncertain;
            reply.meta = '${_model.name} · ${effort.label.toLowerCase()} · ${e.tokens} tok · ${e.tokensPerSecond.toStringAsFixed(1)} tok/s';
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
    _scrollDown(jump: true);
  }

  Future<void> _pickModel() async {
    if (_busy) return;
    final pick = await pickModel(context,
        models: widget.catalog.models,
        currentId: _model.id,
        effort: _settings.effort,
        onEffort: (e) {
          Prefs.effort = e;
          setState(() => _settings = _settings.copyWith(effort: e));
        });
    switch (pick) {
      case PickModel(:final model) when model.id != _model.id:
        _loadModel(model);
      case PickImport():
        await _importModel();
      default:
    }
  }

  Future<void> _plus() async {
    switch (await plusMenu(context)) {
      case PlusAction.importModel:
        await _importModel();
      case PlusAction.settings:
        if (!mounted) return;
        final s = await editSettings(context, _settings, _model);
        if (s != null) setState(() => _settings = s);
      case PlusAction.newChat:
        _newChat();
      case null:
    }
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
            const AsciiSphere(size: 140, color: Palette.violet, thinking: true),
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
    final empty = _chat.messages.isEmpty;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      drawer: _HistoryDrawer(store: widget.store, catalog: widget.catalog, onOpen: _openChat, onNew: () {
        Navigator.pop(context);
        _newChat();
      }),
      body: Stack(children: [
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: empty ? 1.0 : 0.45),
            duration: const Duration(milliseconds: 600),
            builder: (_, v, __) => AsciiRain(color: _color, intensity: v),
          ),
        ),
        SafeArea(
          child: Column(children: [
            _topBar(),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: empty ? _empty() : _messages(),
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
    final title = _chat.messages.isEmpty ? '' : _chat.title == 'Nytt samtal' ? _chat.messages.first.text : _chat.title;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(children: [
        Builder(
            builder: (ctx) => IconButton(
                icon: Icon(Icons.notes_rounded, color: c.text, size: 26), onPressed: () => Scaffold.of(ctx).openDrawer())),
        Expanded(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 250),
            opacity: title.isEmpty ? 0 : 1,
            child: Text(title.replaceAll('\n', ' '),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ),
        IconButton(icon: Icon(Icons.edit_square, color: c.text, size: 22), onPressed: _busy ? null : _newChat),
      ]),
    );
  }

  /// Hälsning efter tid på dygnet – lite kaxig, som Lennart.
  String get _greeting {
    final h = DateTime.now().hour;
    final options = h < 5
        ? ['Sent ute, nattuggla?', 'Klockan är mycket. Vad skaver?']
        : h < 10
            ? ['God morgon. Kaffe först?', 'God morgon. Vad ska vi lösa?']
            : h < 17
                ? ['Vad har du på hjärtat?', 'Hit med frågan.']
                : h < 22
                    ? ['God kväll. Vad funderar du på?', 'Kvällspass? Jag är med.']
                    : ['Sent ute, nattuggla?', 'En sen nattlig fråga?'];
    return options[_chat.id.hashCode.abs() % options.length];
  }

  Widget _empty() {
    final c = context.c;
    return LayoutBuilder(
      key: ValueKey('empty-${_model.id}'),
      builder: (_, box) {
        final size = math.min(box.maxWidth * 0.78, box.maxHeight * 0.58).clamp(140.0, 320.0);
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              AsciiSphere(size: size, color: _color, thinking: _loading),
              const SizedBox(height: 4),
              ScrambleText(_loading ? 'Väcker ${_model.name} …' : _greeting,
                  style: serif.copyWith(fontSize: 29, color: c.text, fontWeight: FontWeight.w500, letterSpacing: -0.4, height: 1.2)),
            ]),
          ),
        );
      },
    );
  }

  Widget _messages() {
    final model = widget.catalog.models.where((x) => x.id == _chat.modelId).firstOrNull ?? _model;
    return ListView.builder(
      key: ValueKey('list-${_chat.id}'),
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      itemCount: _chat.messages.length,
      itemBuilder: (_, i) {
        final m = _chat.messages[i];
        final last = i == _chat.messages.length - 1;
        if (m.fromUser) return _UserBubble(message: m);
        return _Answer(
          message: m,
          color: model.color,
          live: last && _busy,
          draftIndex: _draftIndex,
          draftTotal: _draftTotal,
          canRegenerate: last && !_busy && !_loading,
          onRegenerate: _regenerate,
          onRevealed: () => setState(() => m.reveal = false),
          onGrow: () => _scrollDown(jump: true),
        );
      },
    );
  }

  Widget _composer() {
    final c = context.c;
    final canSend = _input.text.trim().isNotEmpty && !_loading;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        decoration: BoxDecoration(
          color: c.surface.withValues(alpha: c.dark ? 0.92 : 0.97),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: _focus.hasFocus ? _color.withValues(alpha: 0.45) : c.stroke),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: c.dark ? 0.35 : 0.07), blurRadius: 24, offset: const Offset(0, 6))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 16, 0),
            child: TextField(
              controller: _input,
              focusNode: _focus,
              minLines: 1,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              style: TextStyle(color: c.text, fontSize: 16.5, height: 1.35),
              cursorColor: _color,
              decoration: InputDecoration(
                hintText: _loading ? 'Läser in ${_model.name} …' : 'Fråga ${_model.name}',
                hintStyle: TextStyle(color: c.muted, fontSize: 16.5),
                border: InputBorder.none,
              ),
              onSubmitted: (_) => _send(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Row(children: [
              _CircleButton(icon: Icons.add_rounded, onTap: _plus, filled: false),
              const SizedBox(width: 8),
              Expanded(child: Align(alignment: Alignment.centerLeft, child: _modelChip())),
              const SizedBox(width: 8),
              _busy
                  ? _CircleButton(icon: Icons.stop_rounded, onTap: _stop, filled: true)
                  : _CircleButton(icon: Icons.arrow_upward_rounded, onTap: canSend ? _send : null, filled: true),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _modelChip() {
    final c = context.c;
    return Material(
      color: c.bubble,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: _busy ? null : _pickModel,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            ModelIcon(size: 26, color: _color, label: _label(_model), thinking: _busy || _loading),
            const SizedBox(width: 8),
            Flexible(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: _model.name, style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
                  TextSpan(text: '  ${_settings.effort.label}', style: TextStyle(color: c.muted)),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14.5),
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: c.muted),
          ]),
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final bool filled;
  const _CircleButton({required this.icon, required this.onTap, required this.filled});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final enabled = onTap != null;
    final bg = filled ? (enabled ? c.text : c.stroke) : Colors.transparent;
    final fg = filled ? (enabled ? c.bg : c.muted) : c.text;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: bg,
          border: filled ? null : Border.all(color: c.stroke),
        ),
        child: Icon(icon, color: fg, size: 22),
      ),
    );
  }
}

class _UserBubble extends StatelessWidget {
  final Message message;
  const _UserBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return _FadeIn(
      child: Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Align(
          alignment: Alignment.centerRight,
          child: GestureDetector(
            onLongPress: () => _copy(context, message.text),
            child: Container(
              constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
              decoration: BoxDecoration(color: c.bubble, borderRadius: BorderRadius.circular(22)),
              child: Text(message.text, style: TextStyle(color: c.text, fontSize: 16, height: 1.4)),
            ),
          ),
        ),
      ),
    );
  }
}

void _copy(BuildContext context, String text) {
  Clipboard.setData(ClipboardData(text: text));
  HapticFeedback.mediumImpact();
  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kopierat')));
}

class _FadeIn extends StatelessWidget {
  final Widget child;
  const _FadeIn({required this.child});
  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        builder: (_, v, child) => Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 10 * (1 - v)), child: child)),
        child: child,
      );
}

/// Lennarts svar: tankeblock (utkasten), själva svaret och en rad med åtgärder – utan bubbla, som i Claude.
class _Answer extends StatelessWidget {
  final Message message;
  final Color color;
  final bool live, canRegenerate;
  final int draftIndex, draftTotal;
  final VoidCallback onRegenerate, onRevealed, onGrow;
  const _Answer({
    required this.message,
    required this.color,
    required this.live,
    required this.draftIndex,
    required this.draftTotal,
    required this.canRegenerate,
    required this.onRegenerate,
    required this.onRevealed,
    required this.onGrow,
  });

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final accent = c.dark ? color : HSLColor.fromColor(color).withLightness(0.36).toColor();
    final thinking = message.drafts.isNotEmpty || (live && draftTotal > 1 && message.text.isEmpty);
    final style = TextStyle(color: message.error ? Palette.danger : c.text, fontSize: 16, height: 1.5);
    Widget? body;
    if (message.text.isNotEmpty) {
      body = message.reveal
          ? _Reveal(text: message.text, style: style, onDone: onRevealed, onGrow: onGrow)
          : Text.rich(TextSpan(children: [
              TextSpan(text: message.text, style: style),
              if (live) WidgetSpan(alignment: PlaceholderAlignment.middle, child: DecodingTail(color: accent)),
            ]));
    } else if (live && !thinking) {
      body = Row(children: [ThinkingStar(color: accent), const SizedBox(width: 6), Text('Skriver …', style: TextStyle(color: c.muted))]);
    }
    return _FadeIn(
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (thinking)
            _ThinkingBlock(
              message: message,
              live: live && message.text.isEmpty,
              index: draftIndex,
              total: draftTotal,
              accent: accent,
            ),
          if (body != null) GestureDetector(onLongPress: () => _copy(context, message.text), child: body),
          if (!live && message.uncertain && !message.error) const _UncertainChip(),
          if (!live && message.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(children: [
                _Action(icon: Icons.copy_rounded, onTap: () => _copy(context, message.text)),
                if (canRegenerate) _Action(icon: Icons.refresh_rounded, onTap: onRegenerate),
                const SizedBox(width: 4),
                if (message.meta != null)
                  Expanded(
                    child: Text(message.meta!,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.muted, fontSize: 11.5)),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }
}

/// Lennart är osäker på svaret (låg egen säkerhet) – en diskret varning.
class _UncertainChip extends StatelessWidget {
  const _UncertainChip();
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    const amber = Color(0xFFE0A030);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: amber.withValues(alpha: c.dark ? 0.12 : 0.14),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: amber.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.help_outline_rounded, size: 15, color: c.dark ? amber : const Color(0xFF9A6400)),
          const SizedBox(width: 6),
          Text('Osäker – dubbelkolla gärna',
              style: TextStyle(color: c.dark ? amber : const Color(0xFF9A6400), fontSize: 12.5, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _Action({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 34,
        height: 34,
        child: IconButton(
          padding: EdgeInsets.zero,
          iconSize: 18,
          icon: Icon(icon, color: context.c.muted),
          onPressed: onTap,
        ),
      );
}

/// "Tänker · utkast 2 av 3" medan Lennart skriver utkast, sedan "Tänkte i 6 s". Tryck för att se utkasten.
class _ThinkingBlock extends StatefulWidget {
  final Message message;
  final bool live;
  final int index, total;
  final Color accent;
  const _ThinkingBlock({required this.message, required this.live, required this.index, required this.total, required this.accent});
  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = widget.message;
    final n = m.drafts.length;
    final header = widget.live
        ? 'Tänker · utkast ${widget.index + 1} av ${widget.total}'
        : 'Tänkte i ${(m.thoughtSeconds ?? 0).toStringAsFixed((m.thoughtSeconds ?? 0) < 10 ? 1 : 0)} s · $n utkast';
    final current = n == 0 ? '' : m.drafts[math.min(widget.index, n - 1)].text.replaceAll('\n', ' ');
    final tail = current.length > 140 ? '…${current.substring(current.length - 140)}' : current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              ThinkingStar(color: widget.accent, animate: widget.live),
              const SizedBox(width: 8),
              Flexible(child: Text(header, style: TextStyle(color: c.muted, fontSize: 14, fontWeight: FontWeight.w500))),
              AnimatedRotation(
                turns: _open ? 0.25 : 0,
                duration: const Duration(milliseconds: 200),
                child: Icon(Icons.chevron_right_rounded, size: 18, color: c.muted),
              ),
            ]),
          ),
        ),
        if (widget.live && !_open && tail.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 26, top: 2, right: 8),
            child: ShaderMask(
              shaderCallback: (r) => LinearGradient(colors: [Colors.transparent, c.muted, c.muted]).createShader(r),
              child: Text(tail, maxLines: 2, overflow: TextOverflow.clip, style: mono.copyWith(color: Colors.white, fontSize: 12, height: 1.4)),
            ),
          ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Container(
                  margin: const EdgeInsets.only(left: 7, top: 6),
                  padding: const EdgeInsets.only(left: 16),
                  decoration: BoxDecoration(border: Border(left: BorderSide(color: c.stroke, width: 2))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (var i = 0; i < n; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(
                            'Utkast ${i + 1}${i == m.chosen ? ' · valt' : m.drafts[i].pruned ? ' · sållat tidigt' : ''}'
                            '${m.drafts[i].score != null && !m.drafts[i].pruned ? '  (${m.drafts[i].score!.toStringAsFixed(2)})' : ''}',
                            style: mono.copyWith(
                                color: i == m.chosen ? widget.accent : c.muted, fontSize: 11.5, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(m.drafts[i].text.trim().isEmpty ? '…' : m.drafts[i].text.trim(),
                              style: TextStyle(color: c.muted, fontSize: 13.5, height: 1.4)),
                        ]),
                      ),
                  ]),
                ),
        ),
      ]),
    );
  }
}

/// Skriver fram ett färdigt svar snabbt, som om det strömmade.
class _Reveal extends StatefulWidget {
  final String text;
  final TextStyle style;
  final VoidCallback onDone, onGrow;
  const _Reveal({required this.text, required this.style, required this.onDone, required this.onGrow});
  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
      vsync: this, duration: Duration(milliseconds: (widget.text.length * 9).clamp(250, 1600)))
    ..addListener(() {
      setState(() {});
      widget.onGrow();
    })
    ..addStatusListener((s) {
      if (s == AnimationStatus.completed) widget.onDone();
    })
    ..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = (widget.text.length * Curves.easeOut.transform(_c.value)).round();
    return Text.rich(TextSpan(children: [
      TextSpan(text: widget.text.substring(0, n), style: widget.style),
      TextSpan(text: widget.text.substring(n), style: widget.style.copyWith(color: Colors.transparent)),
    ]));
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
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Row(children: [
              ModelIcon(size: 34, color: widget.catalog.latest.color, label: 'L'),
              const SizedBox(width: 12),
              Text('Lennart', style: serif.copyWith(color: c.text, fontSize: 24, fontWeight: FontWeight.w600)),
            ]),
          ),
          ListTile(
            leading: Icon(Icons.edit_square, color: c.text, size: 22),
            title: Text('Nytt samtal', style: TextStyle(color: c.text, fontWeight: FontWeight.w600)),
            onTap: widget.onNew,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
            child: Text('Senaste', style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600)),
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
                          dense: true,
                          title: Text(conv.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.text, fontSize: 15)),
                          subtitle: Text(m?.name ?? conv.modelId, style: TextStyle(color: c.muted, fontSize: 12)),
                          onTap: () => widget.onOpen(conv),
                        ),
                      );
                    },
                  ),
          ),
          const Padding(padding: EdgeInsets.fromLTRB(14, 0, 14, 8), child: AppearancePicker()),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 4, 18, 14),
            child: Text('Allt körs lokalt på telefonen.', style: Theme.of(context).textTheme.bodySmall),
          ),
        ]),
      ),
    );
  }
}

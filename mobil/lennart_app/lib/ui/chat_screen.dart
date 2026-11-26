import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../agent/agent.dart';
import '../agent/verktyg.dart';
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
  late final _focus = FocusNode(onKeyEvent: _onComposerKey);

  /// Datorn: Enter skickar, Shift+Enter ger ny rad.
  KeyEventResult _onComposerKey(FocusNode node, KeyEvent e) {
    if (!Catalog.isDesktop || e is! KeyDownEvent) return KeyEventResult.ignored;
    if ((e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.numpadEnter) &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _send();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Bred skärm (dator, surfplatta på tvären): fast sidopanel och dialoger i stället för ark.
  bool get _wide => MediaQuery.sizeOf(context).width >= 860;
  late ModelInfo _model = widget.catalog.models.where((m) => m.id == Prefs.modelId).firstOrNull ?? widget.catalog.latest;
  late GenSettings _settings = _defaults(_model);
  late Conversation _chat = Conversation.empty(_model.id);
  bool _loading = false, _busy = false;
  int _draftTotal = 0, _draftIndex = 0, _segment = -1;
  StreamSubscription<GenEvent>? _sub;

  GenSettings _defaults(ModelInfo m) => GenSettings(temperature: m.temperature, maxTokens: m.maxTokens, topK: m.topK, effort: Prefs.effort);
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
      // Under övergången mellan två samtal är båda listorna kopplade en kort stund – rulla den nyaste.
      final pos = _scroll.positions.last;
      final end = pos.maxScrollExtent;
      if (jump) {
        pos.jumpTo(end);
      } else {
        pos.animateTo(end, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      }
    });
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _busy || _loading) return;
    HapticFeedback.lightImpact();
    _input.clear();
    _agentSteps = 0;
    setState(() {
      _chat.modelId = _model.id;
      _chat.messages.add(Message(true, text));
    });
    if (Prefs.agent && text.startsWith('/')) {
      _command(text);
      return;
    }
    _generate();
  }

  // ───────────────────────────── agentläge
  int _agentSteps = 0;
  static const _maxAgentSteps = 6;

  Agent _agent() => Agent(
    verktyg: standardVerktyg(),
    miljo: AgentMiljo(arbetsmapp: Prefs.arbetsmapp == null ? null : Directory(Prefs.arbetsmapp!)),
    generera: (_) async => '',
    godkann: _approve,
  );

  /// Frågar användaren innan ett verktyg som ändrar något körs.
  Future<bool> _approve(VerktygsAnrop a, Verktyg v) async {
    if (!mounted) return false;
    final c = context.c;
    final preview = const JsonEncoder.withIndent('  ').convert(a.argument);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        title: Text('Tillåta ${v.namn}?', style: TextStyle(color: c.text)),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460, maxHeight: 320),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(v.beskrivning, style: TextStyle(color: c.muted)),
                const SizedBox(height: 10),
                Text(
                  preview.length > 1500 ? '${preview.substring(0, 1500)} …' : preview,
                  style: mono.copyWith(color: c.text, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Neka')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Tillåt')),
        ],
      ),
    );
    return ok == true;
  }

  /// Kör ett verktyg och lägger resultatet i samtalet. [thenContinue] låter modellen svara vidare.
  Future<void> _runTool(VerktygsAnrop a, {required bool thenContinue}) async {
    setState(() => _busy = true);
    final r = await _agent().korAnrop(a);
    if (!mounted) return;
    setState(() {
      _chat.messages.add(Message(true, resultatText(a.namn, r.resultat, fel: r.fel || r.nekad), kind: 'resultat'));
      _busy = false;
    });
    _scrollDown();
    widget.store.save(_chat);
    if (thenContinue && !r.nekad) _generate();
  }

  /// Kommandon som kör verktygen direkt: /klocka, /räkna 12*7, /lista, /läs fil, /sök text, /skriv fil + text.
  void _command(String text) {
    final first = text.split(RegExp(r'\s+')).first.toLowerCase();
    final rest = text.substring(first.length).trim();
    VerktygsAnrop call(String namn, Map<String, dynamic> arg) => VerktygsAnrop(namn, arg, anropsText(namn, arg), '');
    final a = switch (first) {
      '/klocka' || '/tid' => call('klocka', {}),
      '/räkna' || '/rakna' => call('raknare', {'uttryck': rest}),
      '/lista' => call('lista_mapp', {'mapp': rest}),
      '/läs' || '/las' => call('las_fil', {'fil': rest}),
      '/sök' || '/sok' => call('sok_i_filer', {'text': rest}),
      '/skriv' => () {
        final lines = rest.split('\n');
        return call('skriv_fil', {'fil': lines.first.trim(), 'innehall': lines.skip(1).join('\n')});
      }(),
      _ => null,
    };
    if (a == null) {
      setState(
        () => _chat.messages.add(
          Message(
            false,
            'Kommandon i agentläget:\n/klocka – datum och tid\n/räkna 12*7 – räknare\n/lista [mapp] – filer i arbetsmappen\n'
            '/läs fil.txt – läs en textfil\n/sök ord – sök i arbetsmappen\n/skriv fil.txt (ny rad) text – skriv en fil, efter ditt godkännande',
            meta: 'agentläge',
          ),
        ),
      );
      return;
    }
    _runTool(a, thenContinue: false);
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
        if (!m.error && m.text.isNotEmpty && !(m.fromUser && m.kind == null && m.text.startsWith('/') && Prefs.agent))
          ChatTurn(m.fromUser, m.text),
    ];
    // En modell som är tränad på verktyg (Lennart 4) får veta vilka som finns.
    if (Prefs.agent && _model.json['verktyg'] == true) turns.insert(0, ChatTurn(true, verktygsBeskrivning(standardVerktyg())));
    final effort = _settings.effort;
    setState(() {
      _chat.messages.add(reply);
      _busy = true;
      _draftTotal = effort.drafts;
      _draftIndex = 0;
      _segment = effort.sentenceWise ? 0 : -1;
    });
    _scrollDown();
    _sub = _engine.generate(turns, _settings).listen((e) {
      switch (e) {
        case GenToken(:final text):
          setState(() => reply.text += text);
          _scrollDown(jump: true);
        case GenDraft(:final index, :final total, :final text, :final segment):
          setState(() {
            while (reply.drafts.length <= index) {
              reply.drafts.add(Draft(''));
            }
            reply.drafts[index]
              ..text += text
              ..segment = segment;
            _draftIndex = index;
            _draftTotal = total;
            _segment = segment;
          });
        case GenSegment(:final index, :final text):
          setState(() {
            if (index < reply.drafts.length) reply.drafts[index].picked = true;
            reply.text = (reply.text + text).trimLeft();
          });
          _scrollDown(jump: true);
        case GenDraftEnd(:final index, :final score, :final pruned):
          if (index < reply.drafts.length) {
            setState(
              () => reply.drafts[index]
                ..score = score
                ..pruned = pruned,
            );
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
            reply.text = reply.text.trim();
            if (reply.text.isEmpty) reply.text = '…';
            if (reply.drafts.isNotEmpty) reply.thoughtSeconds = e.seconds;
            reply.uncertain = e.uncertain;
            reply.meta = '${_model.name} · ${effort.label.toLowerCase()} · ${e.tokens} tok · ${e.tokensPerSecond.toStringAsFixed(1)} tok/s';
            _busy = false;
          });
          widget.store.save(_chat);
          // Agentläge: om modellen svarade med ett verktygsanrop körs det, och modellen får fortsätta.
          final call = Prefs.agent ? hittaAnrop(reply.text) : null;
          if (call != null && _agentSteps < _maxAgentSteps) {
            _agentSteps++;
            setState(() => reply.kind = 'anrop');
            _runTool(call, thenContinue: true);
          }
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

  Future<void> _openChat(Conversation c, {bool fromDrawer = true}) async {
    if (fromDrawer) Navigator.pop(context);
    if (_busy) return;
    setState(() => _chat = c);
    final m = widget.catalog.models.where((x) => x.id == c.modelId).firstOrNull;
    if (m != null && m.id != _model.id) await _loadModel(m);
    _scrollDown(jump: true);
  }

  Future<void> _pickModel() async {
    if (_busy) return;
    final pick = await pickModel(
      context,
      models: widget.catalog.models,
      currentId: _model.id,
      effort: _settings.effort,
      onEffort: (e) {
        Prefs.effort = e;
        setState(() => _settings = _settings.copyWith(effort: e));
      },
    );
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
      case PlusAction.agent:
        if (!mounted) return;
        await agentSettings(context);
        setState(() {});
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AsciiSphere(size: 140, color: Palette.violet, thinking: true),
              const SizedBox(height: 10),
              Material(
                color: Colors.transparent,
                child: BrailleSpinner(color: ctx.c.accent, text: 'installerar modellen'),
              ),
            ],
          ),
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
      // Telefonen kopierar filen till cachen – ta bort kopian. På datorn är det användarens egen fil.
      if (!Catalog.isDesktop) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
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
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: c.bg,
        statusBarIconBrightness: c.dark ? Brightness.light : Brightness.dark,
        systemNavigationBarIconBrightness: c.dark ? Brightness.light : Brightness.dark,
      ),
    );
    final empty = _chat.messages.isEmpty;
    final wide = _wide;
    final main = Stack(
      children: [
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: empty ? 1.0 : 0.45),
            duration: const Duration(milliseconds: 600),
            builder: (_, v, __) => AsciiRain(color: _color, intensity: v),
          ),
        ),
        SafeArea(
          child: Column(
            children: [
              _topBar(wide: wide),
              Expanded(
                child: AnimatedSwitcher(duration: const Duration(milliseconds: 350), child: empty ? _empty() : _messages()),
              ),
              Center(
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 820), child: _composer()),
              ),
              if (wide)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Enter skickar · Shift+Enter ny rad · Ctrl+N nytt samtal · Esc stoppar',
                    style: TextStyle(color: c.muted, fontSize: 11.5),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
    final shortcuts = <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyN, control: true): _newChat,
      const SingleActivator(LogicalKeyboardKey.escape): () {
        if (_busy) _stop();
      },
    };
    if (wide) {
      return CallbackShortcuts(
        bindings: shortcuts,
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: Row(
              children: [
                SizedBox(
                  width: 284,
                  child: _HistoryDrawer(
                    docked: true,
                    store: widget.store,
                    catalog: widget.catalog,
                    currentId: _chat.id,
                    onOpen: (c) => _openChat(c, fromDrawer: false),
                    onNew: _newChat,
                  ),
                ),
                VerticalDivider(width: 1, thickness: 1, color: c.stroke),
                Expanded(child: main),
              ],
            ),
          ),
        ),
      );
    }
    return CallbackShortcuts(
      bindings: shortcuts,
      child: Scaffold(
        resizeToAvoidBottomInset: true,
        drawer: _HistoryDrawer(
          store: widget.store,
          catalog: widget.catalog,
          onOpen: _openChat,
          onNew: () {
            Navigator.pop(context);
            _newChat();
          },
        ),
        body: main,
      ),
    );
  }

  Widget _topBar({bool wide = false}) {
    final c = context.c;
    final title = _chat.messages.isEmpty
        ? ''
        : _chat.title == 'Nytt samtal'
        ? _chat.messages.first.text
        : _chat.title;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          if (wide)
            const SizedBox(width: 48)
          else
            Builder(
              builder: (ctx) => IconButton(
                icon: Icon(Icons.notes_rounded, color: c.text, size: 26),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
          Expanded(
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 250),
              opacity: title.isEmpty ? 0 : 1,
              child: Text(
                title.replaceAll('\n', ' '),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.text, fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Nytt samtal (Ctrl+N)',
            icon: Icon(Icons.edit_square, color: c.text, size: 22),
            onPressed: _busy ? null : _newChat,
          ),
        ],
      ),
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
        final size = math.min(box.maxWidth * 0.78, box.maxHeight * 0.58).clamp(140.0, 380.0);
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AsciiSphere(size: size, color: _color, thinking: _loading),
                const SizedBox(height: 4),
                ScrambleText(
                  _loading ? 'Väcker ${_model.name} …' : _greeting,
                  style: serif.copyWith(fontSize: 29, color: c.text, fontWeight: FontWeight.w500, letterSpacing: -0.4, height: 1.2),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _messages() {
    final model = widget.catalog.models.where((x) => x.id == _chat.modelId).firstOrNull ?? _model;
    final w = MediaQuery.sizeOf(context).width - (_wide ? 285 : 0);
    final side = w > 860 ? (w - 820) / 2 + 16 : 16.0; // samma bredd som inmatningsfältet
    return ListView.builder(
      key: ValueKey('list-${_chat.id}'),
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(side, 8, side, 16),
      itemCount: _chat.messages.length,
      itemBuilder: (_, i) {
        final m = _chat.messages[i];
        final last = i == _chat.messages.length - 1;
        if (m.kind == 'resultat') return _ToolResult(message: m);
        if (m.kind == 'anrop') return _ToolCall(message: m, color: model.color);
        if (m.fromUser) return _UserBubble(message: m);
        return _Answer(
          message: m,
          color: model.color,
          live: last && _busy,
          draftIndex: _draftIndex,
          draftTotal: _draftTotal,
          segment: _segment,
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
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: c.dark ? 0.35 : 0.07),
              blurRadius: 24,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
              child: Row(
                children: [
                  _CircleButton(icon: Icons.add_rounded, onTap: _plus, filled: false),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: _modelChip()),
                  ),
                  const SizedBox(width: 8),
                  _busy
                      ? _CircleButton(icon: Icons.stop_rounded, onTap: _stop, filled: true)
                      : _CircleButton(icon: Icons.arrow_upward_rounded, onTap: canSend ? _send : null, filled: true),
                ],
              ),
            ),
          ],
        ),
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ModelIcon(size: 26, color: _color, label: _label(_model), thinking: _busy || _loading),
              const SizedBox(width: 8),
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _model.name,
                        style: TextStyle(color: c.text, fontWeight: FontWeight.w600),
                      ),
                      TextSpan(
                        text: '  ${_settings.effort.label}',
                        style: TextStyle(color: c.muted),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5),
                ),
              ),
              Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lennart anropar ett verktyg.
class _ToolCall extends StatelessWidget {
  final Message message;
  final Color color;
  const _ToolCall({required this.message, required this.color});
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final a = hittaAnrop(message.text);
    return _FadeIn(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Icon(Icons.handyman_outlined, size: 16, color: c.muted),
            const SizedBox(width: 8),
            Flexible(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Använder ',
                      style: TextStyle(color: c.muted),
                    ),
                    TextSpan(
                      text: a?.namn ?? 'verktyg',
                      style: TextStyle(color: c.text, fontWeight: FontWeight.w600),
                    ),
                    if (a != null && a.argument.isNotEmpty)
                      TextSpan(
                        text: '  ${jsonEncode(a.argument)}',
                        style: mono.copyWith(color: c.muted, fontSize: 12),
                      ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ett verktygs svar, som ett utfällbart kort.
class _ToolResult extends StatefulWidget {
  final Message message;
  const _ToolResult({required this.message});
  @override
  State<_ToolResult> createState() => _ToolResultState();
}

class _ToolResultState extends State<_ToolResult> {
  bool _open = false;
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final m = RegExp(r'^<resultat namn="([^"]+)"( fel="ja")?>(.*)</resultat>$', dotAll: true).firstMatch(widget.message.text);
    final namn = m?.group(1) ?? 'verktyg';
    final fel = m?.group(2) != null;
    final body = (m?.group(3) ?? widget.message.text).trim();
    final lines = body.split('\n');
    final short = lines.length <= 6 && body.length < 400;
    return _FadeIn(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: c.bubble.withValues(alpha: 0.7),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: fel ? Palette.danger.withValues(alpha: 0.5) : c.stroke),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    fel ? Icons.error_outline_rounded : Icons.check_circle_outline_rounded,
                    size: 16,
                    color: fel ? Palette.danger : c.accent,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      namn,
                      style: mono.copyWith(color: c.text, fontWeight: FontWeight.w700, fontSize: 12.5),
                    ),
                  ),
                  if (!short)
                    InkWell(
                      onTap: () => setState(() => _open = !_open),
                      child: Text(_open ? 'Visa mindre' : 'Visa allt', style: TextStyle(color: c.accent, fontSize: 12.5)),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              SelectableText(
                short || _open ? body : '${lines.take(6).join('\n')}\n…',
                style: mono.copyWith(color: fel ? Palette.danger : c.text, fontSize: 13, height: 1.45),
              ),
            ],
          ),
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
    builder: (_, v, child) => Opacity(
      opacity: v,
      child: Transform.translate(offset: Offset(0, 10 * (1 - v)), child: child),
    ),
    child: child,
  );
}

/// Lennarts svar: tankeblock (utkasten), själva svaret och en rad med åtgärder – utan bubbla, som i Claude.
class _Answer extends StatelessWidget {
  final Message message;
  final Color color;
  final bool live, canRegenerate;
  final int draftIndex, draftTotal, segment;
  final VoidCallback onRegenerate, onRevealed, onGrow;
  const _Answer({
    required this.message,
    required this.color,
    required this.live,
    required this.draftIndex,
    required this.draftTotal,
    required this.segment,
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
          : Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: message.text, style: style),
                  if (live)
                    WidgetSpan(
                      alignment: PlaceholderAlignment.middle,
                      child: DecodingTail(color: accent),
                    ),
                ],
              ),
            );
    } else if (live && !thinking) {
      body = Row(
        children: [
          ThinkingStar(color: accent),
          const SizedBox(width: 6),
          Text('Skriver …', style: TextStyle(color: c.muted)),
        ],
      );
    }
    return _FadeIn(
      child: Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thinking)
              _ThinkingBlock(
                message: message,
                // Djup+ fortsätter tänka medan svaret växer mening för mening
                live: live && (message.text.isEmpty || segment >= 0),
                index: draftIndex,
                total: draftTotal,
                segment: segment,
                accent: accent,
              ),
            if (body != null) GestureDetector(onLongPress: () => _copy(context, message.text), child: body),
            if (!live && message.uncertain && !message.error) const _UncertainChip(),
            if (!live && message.text.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  children: [
                    _Action(icon: Icons.copy_rounded, onTap: () => _copy(context, message.text)),
                    if (canRegenerate) _Action(icon: Icons.refresh_rounded, onTap: onRegenerate),
                    const SizedBox(width: 4),
                    if (message.meta != null)
                      Expanded(
                        child: Text(
                          message.meta!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.muted, fontSize: 11.5),
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.help_outline_rounded, size: 15, color: c.dark ? amber : const Color(0xFF9A6400)),
            const SizedBox(width: 6),
            Text(
              'Osäker – dubbelkolla gärna',
              style: TextStyle(color: c.dark ? amber : const Color(0xFF9A6400), fontSize: 12.5, fontWeight: FontWeight.w600),
            ),
          ],
        ),
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
  final int index, total, segment;
  final Color accent;
  const _ThinkingBlock({
    required this.message,
    required this.live,
    required this.index,
    required this.total,
    this.segment = -1,
    required this.accent,
  });
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
    final plus = m.drafts.any((d) => d.segment >= 0) || widget.segment >= 0;
    final sentences = m.drafts.where((d) => d.picked).length;
    final secs = (m.thoughtSeconds ?? 0).toStringAsFixed((m.thoughtSeconds ?? 0) < 10 ? 1 : 0);
    final header = widget.live
        ? (plus
              ? 'Tänker · mening ${widget.segment + 1} · utkast ${widget.index + 1} av högst ${widget.total}'
              : 'Tänker · utkast ${widget.index + 1} av ${widget.total}')
        : (plus ? 'Tänkte i $secs s · $n utkast · $sentences meningar' : 'Tänkte i $secs s · $n utkast');
    final current = n == 0 ? '' : m.drafts[math.min(widget.index, n - 1)].text.replaceAll('\n', ' ');
    final tail = current.length > 140 ? '…${current.substring(current.length - 140)}' : current;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ThinkingStar(color: widget.accent, animate: widget.live),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      header,
                      style: TextStyle(color: c.muted, fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(Icons.chevron_right_rounded, size: 18, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
          if (widget.live && !_open && tail.isNotEmpty && !plus)
            Padding(
              padding: const EdgeInsets.only(left: 26, top: 2, right: 8),
              child: ShaderMask(
                shaderCallback: (r) => LinearGradient(colors: [Colors.transparent, c.muted, c.muted]).createShader(r),
                child: Text(
                  tail,
                  maxLines: 2,
                  overflow: TextOverflow.clip,
                  style: mono.copyWith(color: Colors.white, fontSize: 12, height: 1.4),
                ),
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
                    decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: c.stroke, width: 2)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (plus) ..._segments(context, m),
                        if (!plus)
                          for (var i = 0; i < n; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Utkast ${i + 1}${i == m.chosen
                                        ? ' · valt'
                                        : m.drafts[i].pruned
                                        ? ' · sållat tidigt'
                                        : ''}'
                                    '${m.drafts[i].score != null && !m.drafts[i].pruned ? '  (${m.drafts[i].score!.toStringAsFixed(2)})' : ''}',
                                    style: mono.copyWith(
                                      color: i == m.chosen ? widget.accent : c.muted,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    m.drafts[i].text.trim().isEmpty ? '…' : m.drafts[i].text.trim(),
                                    style: TextStyle(color: c.muted, fontSize: 13.5, height: 1.4),
                                  ),
                                ],
                              ),
                            ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Djup+: utkasten grupperade per mening, med den valda meningen markerad.
List<Widget> _segments(BuildContext context, Message m) {
  final c = context.c;
  final segs = <int, List<Draft>>{};
  for (final d in m.drafts) {
    (segs[d.segment] ??= []).add(d);
  }
  final keys = segs.keys.toList()..sort();
  return [
    for (final g in keys)
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Mening ${g + 1} · ${segs[g]!.length} utkast',
              style: mono.copyWith(color: c.muted, fontSize: 11.5, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            for (final d in segs[g]!)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 18,
                      child: d.picked
                          ? Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Icon(Icons.check_rounded, size: 14, color: c.accent),
                            )
                          : Text(
                              '·',
                              style: TextStyle(color: c.muted, fontWeight: FontWeight.w700, fontSize: 13),
                            ),
                    ),
                    Expanded(
                      child: Text(
                        d.text.trim().isEmpty ? '(slut på svaret)' : d.text.trim(),
                        style: TextStyle(
                          color: d.picked ? c.text : c.muted,
                          fontSize: 13.5,
                          height: 1.4,
                          fontWeight: d.picked ? FontWeight.w500 : FontWeight.w400,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
  ];
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
  late final AnimationController _c =
      AnimationController(
          vsync: this,
          duration: Duration(milliseconds: (widget.text.length * 9).clamp(250, 1600)),
        )
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
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: widget.text.substring(0, n), style: widget.style),
          TextSpan(
            text: widget.text.substring(n),
            style: widget.style.copyWith(color: Colors.transparent),
          ),
        ],
      ),
    );
  }
}

class _HistoryDrawer extends StatefulWidget {
  final ChatStore store;
  final Catalog catalog;
  final void Function(Conversation) onOpen;
  final VoidCallback onNew;
  final bool docked; // datorn: fast sidopanel i stället för utdragbar meny
  final String? currentId;
  const _HistoryDrawer({
    required this.store,
    required this.catalog,
    required this.onOpen,
    required this.onNew,
    this.docked = false,
    this.currentId,
  });
  @override
  State<_HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<_HistoryDrawer> {
  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final items = widget.store.items;
    final content = SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
            child: Row(
              children: [
                ModelIcon(size: 34, color: widget.catalog.latest.color, label: 'L'),
                const SizedBox(width: 12),
                Text(
                  'Lennart',
                  style: serif.copyWith(color: c.text, fontSize: 24, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          ListTile(
            leading: Icon(Icons.edit_square, color: c.text, size: 22),
            title: Text(
              'Nytt samtal',
              style: TextStyle(color: c.text, fontWeight: FontWeight.w600),
            ),
            onTap: widget.onNew,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
            child: Text(
              'Senaste',
              style: TextStyle(color: c.muted, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(18),
                    child: Text('Dina samtal sparas här.', style: Theme.of(context).textTheme.bodySmall),
                  )
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
                          child: const Icon(Icons.delete_outline_rounded, color: Palette.danger),
                        ),
                        onDismissed: (_) => setState(() => widget.store.delete(conv)),
                        child: ListTile(
                          dense: true,
                          selected: conv.id == widget.currentId,
                          selectedTileColor: c.bubble,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          trailing: widget.docked
                              ? IconButton(
                                  tooltip: 'Ta bort samtalet',
                                  icon: Icon(Icons.delete_outline_rounded, size: 18, color: c.muted),
                                  onPressed: () => setState(() => widget.store.delete(conv)),
                                )
                              : null,
                          title: Text(
                            conv.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: c.text, fontSize: 15),
                          ),
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
            child: Text(
              Catalog.isDesktop ? 'Allt körs lokalt på datorn.' : 'Allt körs lokalt på telefonen.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
    if (widget.docked) return Material(color: c.surface, child: content);
    return Drawer(backgroundColor: c.surface, child: content);
  }
}

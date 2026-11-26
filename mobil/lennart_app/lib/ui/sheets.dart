import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/engine.dart';
import 'ascii.dart';
import 'glass.dart';
import 'theme.dart';

Widget _sheet(BuildContext context, {String? title, required List<Widget> children}) {
  final c = context.c;
  return Container(
    margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
    padding: EdgeInsets.fromLTRB(8, 10, 8, 12 + MediaQuery.of(context).padding.bottom),
    decoration: BoxDecoration(
      color: c.surface,
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: c.stroke),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: c.dark ? 0.45 : 0.14), blurRadius: 30)],
    ),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Container(width: 36, height: 4, decoration: BoxDecoration(color: c.stroke, borderRadius: BorderRadius.circular(4)))),
      if (title != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 16, 12, 6),
          child: Text(title, style: TextStyle(color: c.text, fontSize: 17, fontWeight: FontWeight.w700)),
        )
      else
        const SizedBox(height: 8),
      ...children,
    ]),
  );
}

Widget _section(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 4),
      child: Text(text.toUpperCase(),
          style: TextStyle(color: context.c.muted, fontSize: 11.5, fontWeight: FontWeight.w700, letterSpacing: 0.8)),
    );

/// Resultat från modellväljaren.
sealed class ModelPick {}

class PickModel extends ModelPick {
  final ModelInfo model;
  PickModel(this.model);
}

class PickImport extends ModelPick {}

/// Modellväljaren i inmatningsfältet (som i Claude-appen): modeller överst, tänkande under.
/// Effortnivån ändras direkt via [onEffort]; att välja en modell stänger arket.
Future<ModelPick?> pickModel(BuildContext context,
    {required List<ModelInfo> models,
    required String currentId,
    required Effort effort,
    required void Function(Effort) onEffort}) {
  var current = effort;
  return showModalBottomSheet<ModelPick>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) {
        final c = ctx.c;
        return _sheet(ctx, children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                _section(ctx, 'Modell'),
                for (final m in models.reversed)
                  _Row(
                    leading: ModelIcon(size: 36, color: m.color, label: ModelIcon.labelFor(m.name)),
                    title: m.name,
                    badge: m == models.last ? 'nyast' : null,
                    subtitle: '${m.paramsLabel} parametrar · ${m.description}',
                    selected: m.id == currentId,
                    onTap: () => Navigator.pop(ctx, PickModel(m)),
                  ),
                _section(ctx, 'Tänkande'),
                for (final e in Effort.values)
                  _Row(
                    leading: _EffortBars(level: e.index, color: c.accent),
                    title: e.label,
                    subtitle: e.description,
                    selected: e == current,
                    onTap: () {
                      setState(() => current = e);
                      onEffort(e);
                    },
                  ),
                Divider(color: c.stroke, height: 20, indent: 14, endIndent: 14),
                _Row(
                  leading: Icon(Icons.add_rounded, color: c.text),
                  title: 'Lägg till modell från fil',
                  subtitle: 'Ett .lennart-paket, t.ex. från Kaggle',
                  onTap: () => Navigator.pop(ctx, PickImport()),
                ),
              ]),
            ),
          ),
        ]);
      },
    ),
  );
}

/// Tre staplar som visar hur mycket modellen tänker.
class _EffortBars extends StatelessWidget {
  final int level;
  final Color color;
  const _EffortBars({required this.level, required this.color});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: 36,
        height: 36,
        child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (var i = 0; i < 4; i++)
            Container(
              width: 4.5,
              height: 7.0 + i * 5,
              margin: const EdgeInsets.symmetric(horizontal: 1.3, vertical: 7),
              decoration: BoxDecoration(
                color: i <= level ? color : context.c.stroke,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ]),
      );
}

class _Row extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? subtitle, badge;
  final bool selected;
  final VoidCallback onTap;
  const _Row({required this.leading, required this.title, this.subtitle, this.badge, this.selected = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(children: [
          SizedBox(width: 40, child: Center(child: leading)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(title, style: TextStyle(color: c.text, fontSize: 15.5, fontWeight: FontWeight.w600))),
                if (badge != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(color: c.accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(6)),
                    child: Text(badge!, style: TextStyle(color: c.accent, fontSize: 11, fontWeight: FontWeight.w700)),
                  ),
                ],
              ]),
              if (subtitle != null)
                Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: c.muted, fontSize: 12.5)),
            ]),
          ),
          SizedBox(
            width: 28,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 180),
              opacity: selected ? 1 : 0,
              child: Icon(Icons.check_rounded, color: c.accent, size: 22),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Vad plusknappen i inmatningsfältet kan göra.
enum PlusAction { importModel, settings, newChat }

Future<PlusAction?> plusMenu(BuildContext context) => showModalBottomSheet<PlusAction>(
      context: context,
      builder: (ctx) {
        final c = ctx.c;
        return _sheet(ctx, children: [
          _Row(
            leading: Icon(Icons.download_rounded, color: c.text),
            title: 'Importera modell',
            subtitle: 'Installera ett .lennart-paket',
            onTap: () => Navigator.pop(ctx, PlusAction.importModel),
          ),
          _Row(
            leading: Icon(Icons.tune_rounded, color: c.text),
            title: 'Inställningar',
            subtitle: 'Temperatur, svarslängd och utseende',
            onTap: () => Navigator.pop(ctx, PlusAction.settings),
          ),
          _Row(
            leading: Icon(Icons.edit_outlined, color: c.text),
            title: 'Nytt samtal',
            onTap: () => Navigator.pop(ctx, PlusAction.newChat),
          ),
        ]);
      },
    );

/// Temperatur, längd, top-k – och utseende.
Future<GenSettings?> editSettings(BuildContext context, GenSettings current, ModelInfo model) {
  var s = current;
  return showModalBottomSheet<GenSettings>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => _sheet(ctx, title: 'Inställningar', children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(children: [
            _slider(ctx, 'Temperatur', s.temperature.toStringAsFixed(2), 'Lågt = säkra, upprepande svar. Högt = mer variation.',
                Slider(value: s.temperature, min: 0, max: 1.5, divisions: 30, onChanged: (v) => setState(() => s = s.copyWith(temperature: v)))),
            _slider(ctx, 'Max längd', '${s.maxTokens} tokens', 'Hur långt svaret högst får bli.',
                Slider(value: s.maxTokens.toDouble(), min: 20, max: 500, divisions: 48, onChanged: (v) => setState(() => s = s.copyWith(maxTokens: v.round())))),
            _slider(ctx, 'Top-k', s.topK == 0 ? 'av' : '${s.topK}', 'Väljer bara bland de k mest sannolika orden.',
                Slider(value: s.topK.toDouble(), min: 0, max: 100, divisions: 20, onChanged: (v) => setState(() => s = s.copyWith(topK: v.round())))),
            const SizedBox(height: 4),
            const AppearancePicker(),
            const SizedBox(height: 8),
            Row(children: [
              TextButton(
                  onPressed: () => setState(() =>
                      s = GenSettings(temperature: model.temperature, maxTokens: model.maxTokens, topK: model.topK, effort: s.effort)),
                  child: const Text('Återställ')),
              const Spacer(),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: ctx.c.text, foregroundColor: ctx.c.bg),
                onPressed: () => Navigator.pop(ctx, s),
                child: const Text('Klar'),
              ),
            ]),
          ]),
        ),
      ]),
    ),
  );
}

Widget _slider(BuildContext ctx, String label, String value, String hint, Widget slider) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label, style: TextStyle(fontWeight: FontWeight.w600, color: ctx.c.text)),
            const Spacer(),
            Text(value, style: mono.copyWith(color: ctx.c.accent, fontWeight: FontWeight.w700)),
          ]),
          Text(hint, style: Theme.of(ctx).textTheme.bodySmall),
          slider,
        ]),
      ),
    );

/// System / Ljust / Mörkt.
class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appearance,
      builder: (ctx, mode, _) => Glass(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Utseende', style: TextStyle(fontWeight: FontWeight.w600, color: ctx.c.text)),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_rounded, size: 18), label: Text('System')),
                ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_rounded, size: 18), label: Text('Ljust')),
                ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_rounded, size: 18), label: Text('Mörkt')),
              ],
              selected: {mode},
              onSelectionChanged: (v) => appearance.set(v.first),
            ),
          ),
        ]),
      ),
    );
  }
}

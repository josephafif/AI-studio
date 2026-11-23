import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/engine.dart';
import 'ascii.dart';
import 'glass.dart';
import 'theme.dart';

Widget _sheet(BuildContext context, {required String title, required List<Widget> children}) {
  final c = context.c;
  return Container(
    margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
    padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + MediaQuery.of(context).padding.bottom),
    decoration: BoxDecoration(
      color: c.surface.withValues(alpha: 0.98),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: c.stroke),
      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: c.dark ? 0.4 : 0.12), blurRadius: 30)],
    ),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(color: c.stroke, borderRadius: BorderRadius.circular(4)))),
      const SizedBox(height: 14),
      Text('> $title', style: mono.copyWith(color: c.text, fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 12),
      ...children,
    ]),
  );
}

/// Returnerar vald modell, eller strängen 'importera' om användaren vill lägga till en modell från fil.
Future<Object?> pickModel(BuildContext context, List<ModelInfo> models, String currentId) {
  return showModalBottomSheet<Object>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _sheet(ctx, title: 'välj_modell', children: [
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.66),
        child: ListView(shrinkWrap: true, children: [
          for (final m in models.reversed) _ModelCard(model: m, selected: m.id == currentId, latest: m == models.last),
        ]),
      ),
      const SizedBox(height: 4),
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            foregroundColor: ctx.c.text,
            side: BorderSide(color: ctx.c.stroke),
            padding: const EdgeInsets.all(14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          ),
          onPressed: () => Navigator.pop(ctx, 'importera'),
          icon: Icon(Icons.add_circle_outline_rounded, color: ctx.c.accent),
          label: const Text('Lägg till modell från fil (.lennart)'),
        ),
      ),
    ]),
  );
}

class _ModelCard extends StatelessWidget {
  final ModelInfo model;
  final bool selected, latest;
  const _ModelCard({required this.model, required this.selected, required this.latest});

  @override
  Widget build(BuildContext context) {
    final color = model.color, c = context.c;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => Navigator.pop(context, model),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: selected ? color.withValues(alpha: 0.10) : c.glass,
            border: Border.all(color: selected ? color.withValues(alpha: 0.7) : c.stroke, width: selected ? 1.4 : 1),
            boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.22), blurRadius: 24)] : null,
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ModelIcon(size: 56, color: color, label: ModelIcon.labelFor(model.name), thinking: selected),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(model.name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17)),
                  if (latest) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Palette.green, Palette.cyan]), borderRadius: BorderRadius.circular(6)),
                      child: Text('NYAST', style: mono.copyWith(fontSize: 10, fontWeight: FontWeight.w800, color: Palette.ink)),
                    ),
                  ],
                  const Spacer(),
                  if (selected) Icon(Icons.check_circle_rounded, color: color, size: 20),
                ]),
                const SizedBox(height: 4),
                Text(model.description, maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  _chip(context, '${model.paramsLabel} param', color),
                  if (model.steps > 0) _chip(context, '${_thousands(model.steps)} steg', color),
                  _chip(context, 'ctx ${model.context}', color),
                  _chip(context, model.quant == 'int8' ? 'int8' : 'fp32', color),
                ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

String _thousands(int n) => n.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ' ');

Widget _chip(BuildContext context, String text, Color color) {
  final hsl = HSLColor.fromColor(color);
  final fg = context.c.dark ? color : hsl.withLightness(0.32).toColor();
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(7), border: Border.all(color: color.withValues(alpha: 0.3))),
    child: Text(text, style: mono.copyWith(fontSize: 10.5, color: fg, fontWeight: FontWeight.w600)),
  );
}

/// Temperatur, längd, top-k – och utseende.
Future<GenSettings?> editSettings(BuildContext context, GenSettings current, ModelInfo model) {
  var s = current;
  return showModalBottomSheet<GenSettings>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => _sheet(ctx, title: 'inställningar', children: [
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
              onPressed: () => setState(() => s = GenSettings(temperature: model.temperature, maxTokens: model.maxTokens, topK: model.topK)),
              child: const Text('Återställ')),
          const Spacer(),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: ctx.c.accent, foregroundColor: ctx.c.dark ? Palette.ink : Colors.white),
            onPressed: () => Navigator.pop(ctx, s),
            child: const Text('Klar'),
          ),
        ]),
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

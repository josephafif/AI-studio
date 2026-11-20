import 'package:flutter/material.dart';

import '../core/catalog.dart';
import '../core/engine.dart';
import 'aurora.dart';
import 'orb.dart';
import 'theme.dart';

Widget _sheet(BuildContext context, {required String title, required List<Widget> children}) {
  return Container(
    margin: const EdgeInsets.fromLTRB(10, 0, 10, 10),
    padding: EdgeInsets.fromLTRB(18, 10, 18, 18 + MediaQuery.of(context).padding.bottom),
    decoration: BoxDecoration(
      color: Palette.surface.withValues(alpha: 0.97),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: Palette.stroke),
    ),
    child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(
          child: Container(
              width: 38, height: 4, decoration: BoxDecoration(color: Palette.stroke, borderRadius: BorderRadius.circular(4)))),
      const SizedBox(height: 14),
      Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 18)),
      const SizedBox(height: 12),
      ...children,
    ]),
  );
}

/// Välj vilken Lennart du pratar med.
Future<ModelInfo?> pickModel(BuildContext context, List<ModelInfo> models, String currentId) {
  return showModalBottomSheet<ModelInfo>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => _sheet(ctx, title: 'Välj modell', children: [
      ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          for (final m in models.reversed) _ModelCard(model: m, selected: m.id == currentId),
        ]),
      ),
    ]),
  );
}

class _ModelCard extends StatelessWidget {
  final ModelInfo model;
  final bool selected;
  const _ModelCard({required this.model, required this.selected});

  @override
  Widget build(BuildContext context) {
    final color = Palette.model(model.index);
    final latest = model.index == 3;
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
            color: selected ? color.withValues(alpha: 0.10) : Palette.glass,
            border: Border.all(color: selected ? color.withValues(alpha: 0.7) : Palette.stroke, width: selected ? 1.4 : 1),
            boxShadow: selected ? [BoxShadow(color: color.withValues(alpha: 0.25), blurRadius: 24)] : null,
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Orb(size: 54, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text(model.name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontSize: 17)),
                  if (latest) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                          gradient: const LinearGradient(colors: [Palette.green, Palette.cyan]),
                          borderRadius: BorderRadius.circular(20)),
                      child: const Text('NYAST',
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF03140C))),
                    ),
                  ],
                  const Spacer(),
                  if (selected) Icon(Icons.check_circle_rounded, color: color, size: 20),
                ]),
                const SizedBox(height: 4),
                Text(model.description,
                    maxLines: 3, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  _chip('${model.paramsLabel} parametrar', color),
                  if (model.steps > 0) _chip('${_thousands(model.steps)} steg', color),
                  _chip('kontext ${model.context}', color),
                  _chip(model.quant == 'int8' ? 'int8' : 'full precision', color),
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

Widget _chip(String text, Color color) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.25))),
      child: Text(text, style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.95), fontWeight: FontWeight.w500)),
    );

/// Temperatur, längd och top-k.
Future<GenSettings?> editSettings(BuildContext context, GenSettings current, ModelInfo model) {
  var s = current;
  return showModalBottomSheet<GenSettings>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => _sheet(ctx, title: 'Inställningar för ${model.name}', children: [
        _slider(ctx, 'Temperatur', s.temperature.toStringAsFixed(2), 'Lågt = säkra, upprepande svar. Högt = mer variation.',
            Slider(value: s.temperature, min: 0, max: 1.5, divisions: 30, onChanged: (v) => setState(() => s = s.copyWith(temperature: v)))),
        _slider(ctx, 'Max längd', '${s.maxTokens} tokens', 'Hur långt svaret högst får bli.',
            Slider(value: s.maxTokens.toDouble(), min: 20, max: 500, divisions: 48, onChanged: (v) => setState(() => s = s.copyWith(maxTokens: v.round())))),
        _slider(ctx, 'Top-k', s.topK == 0 ? 'av' : '${s.topK}', 'Väljer bara bland de k mest sannolika orden.',
            Slider(value: s.topK.toDouble(), min: 0, max: 100, divisions: 20, onChanged: (v) => setState(() => s = s.copyWith(topK: v.round())))),
        const SizedBox(height: 6),
        Row(children: [
          TextButton(
              onPressed: () => setState(() => s = GenSettings(temperature: model.temperature, maxTokens: model.maxTokens, topK: model.topK)),
              child: const Text('Återställ')),
          const Spacer(),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Palette.green, foregroundColor: const Color(0xFF03140C)),
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
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            Text(value, style: const TextStyle(color: Palette.green, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
          ]),
          Text(hint, style: Theme.of(ctx).textTheme.bodySmall),
          slider,
        ]),
      ),
    );

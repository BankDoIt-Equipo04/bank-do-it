import 'dart:convert';

import 'package:flutter/material.dart';

import 'api_apuestas.dart';

class Estadisticas extends StatefulWidget {
  const Estadisticas({super.key, required this.api, required this.partidos});
  final ApiApuestas api;
  final List<Partido> partidos;

  @override
  State<Estadisticas> createState() => _EstadisticasState();
}

class _EstadisticasState extends State<Estadisticas> {
  bool global = false;
  Future<Json>? consulta;

  void cargar(bool globales) {
    setState(() {
      global = globales;
      consulta = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          child: Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Mis resultados')),
                  ButtonSegment(value: true, label: Text('Globales')),
                ],
                selected: {global},
                onSelectionChanged: (s) => cargar(s.single),
              ),
              IconButton(
                tooltip: 'Actualizar estadísticas',
                onPressed: () => cargar(global),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        Expanded(
          child: FutureBuilder<Json>(
            future: consulta ??= global
                ? widget.api.resultadosGlobales()
                : widget.api.misResultados(),
            builder: (context, estado) {
              if (estado.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (estado.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        estado.error.toString(),
                        textAlign: TextAlign.center,
                      ),
                      TextButton(
                        onPressed: () => cargar(global),
                        child: const Text('Reintentar'),
                      ),
                    ],
                  ),
                );
              }
              final datos = estado.requireData;
              final corte = DateTime.tryParse(datos['corte_utc'] ?? '')
                  ?.toLocal();
              final formato = MaterialLocalizations.of(context);
              final fecha = corte == null
                  ? null
                  : '${formato.formatMediumDate(corte)} · ${formato.formatTimeOfDay(TimeOfDay.fromDateTime(corte))}';
              final encabezado = Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  fecha == null
                      ? 'Sin corte publicado'
                      : 'Hora de corte (local): $fecha',
                ),
              );
              if (global) {
                final deportes = datos['por_deporte'] as List;
                final encuentros = datos['por_partido'] as List;
                final nombres = {
                  for (final p in widget.partidos) p.id.toString(): p.nombre,
                };
                final filas = <Widget>[
                  encabezado,
                  Text(
                    'Apuestas registradas: ${datos['total_apuestas']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  if (deportes.isEmpty && encuentros.isEmpty)
                    const Text('Sin datos'),
                  if (deportes.isNotEmpty) const _Titulo('Por deporte'),
                  for (final d in deportes)
                    ListTile(
                      title: Text(d['deporte']),
                      trailing: Text('${d['apuestas']}'),
                    ),
                  if (encuentros.isNotEmpty) const _Titulo('Por partido'),
                ];
                return ListView.builder(
                  key: const PageStorageKey('globales'),
                  padding: const EdgeInsets.all(16),
                  itemCount: filas.length + encuentros.length,
                  itemBuilder: (_, i) {
                    if (i < filas.length) return filas[i];
                    final p = encuentros[i - filas.length];
                    return ListTile(
                      title: Text(
                        nombres['${p['partido_id']}'] ??
                            'Partido ${p['partido_id']}',
                      ),
                      trailing: Text('${p['apuestas']}'),
                    );
                  },
                );
              }
              final imagenes = datos['graficas'] as Json;
              final rachas = datos['rachas'] as Json;
              final roi = datos['roi_por_deporte'] as List;
              return ListView(
                key: const PageStorageKey('personales'),
                padding: const EdgeInsets.all(16),
                children: [
                  encabezado,
                  _Grafica(
                    'Evolución del bankroll y ganancia neta',
                    imagenes['evolucion'],
                    'Ganancia neta: ${dinero(datos['ganancia_neta'])}',
                  ),
                  _Grafica(
                    'ROI por deporte',
                    imagenes['roi'],
                    roi
                        .map((d) => "${d['deporte']}: ${d['roi_porcentaje']} %")
                        .join(' · '),
                  ),
                  _Grafica(
                    'Rachas de apuestas',
                    imagenes['rachas'],
                    'Mayor racha ganadora: ${rachas['maxima_ganadora']} · Mayor racha perdedora: ${rachas['maxima_perdedora']}',
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Titulo extends StatelessWidget {
  const _Titulo(this.texto);
  final String texto;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 6),
    child: Text(texto, style: Theme.of(context).textTheme.titleMedium),
  );
}

class _Grafica extends StatelessWidget {
  const _Grafica(this.titulo, this.imagen, this.resumen);
  final String titulo, resumen;
  final String? imagen;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Titulo(titulo),
          if (imagen == null)
            const Text('Sin datos')
          else ...[
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 650),
                child: Image.memory(
                  base64Decode(imagen!),
                  semanticLabel: titulo,
                ),
              ),
            ),
            Text(resumen),
          ],
        ],
      ),
    ),
  );
}

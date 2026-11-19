import 'api_apuestas.dart';
import 'editar_apuesta.dart';

import 'package:flutter/material.dart';

const titulo = TextStyle(fontSize: 28, fontWeight: FontWeight.bold);
const estados = {
  'pendiente': 'En curso',
  'ganada': 'Ganadas',
  'perdida': 'Perdidas',
  'anulada': 'Anuladas',
};

class Resumen extends StatelessWidget {
  const Resumen({required this.historial, super.key});
  final Historial historial;
  @override
  Widget build(BuildContext context) {
    final cifras = Row(
      children: [
        Expanded(
          child: _Importe('Saldo disponible', dinero(historial.disponible)),
        ),
        Expanded(child: _Importe('En juego', dinero(historial.enJuego))),
      ],
    );
    final limite = historial.limite;
    final presupuesto = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Presupuesto semanal',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(
          limite == null
              ? 'Sin límite semanal'
              : '${dinero(decimal(historial.usado))} de ${dinero(decimal(limite))}',
        ),
        SizedBox(height: 6),
        if (limite != null && limite > 0)
          LinearProgressIndicator(
            value: (historial.usado / limite).clamp(0, 1),
            color: Colors.grey,
            backgroundColor: Color(0xffdddddd),
          ),
      ],
    );
    Widget panel(Widget child) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xfff1f1f1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: child,
    );
    return LayoutBuilder(
      builder: (_, size) => size.maxWidth < 520
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                panel(cifras),
                const SizedBox(height: 16),
                presupuesto,
              ],
            )
          : panel(
              Row(
                children: [
                  Expanded(flex: 2, child: cifras),
                  Expanded(child: presupuesto),
                ],
              ),
            ),
    );
  }
}

class _Importe extends StatelessWidget {
  const _Importe(this.nombre, this.valor);
  final String nombre, valor;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(nombre),
      Text(valor, style: titulo),
    ],
  );
}

class MisApuestas extends StatefulWidget {
  const MisApuestas({
    required this.movil,
    required this.api,
    required this.historial,
    required this.actualizar,
    super.key,
  });
  final bool movil;
  final ApiApuestas api;
  final Historial historial;
  final VoidCallback actualizar;
  @override
  State<MisApuestas> createState() => _MisApuestasState();
}

class _MisApuestasState extends State<MisApuestas> {
  int seleccion = 0;

  Future<void> abrir(Widget pagina) async {
    final cambio = await Navigator.of(context)
        .push<bool>(MaterialPageRoute(builder: (_) => pagina));
    if (cambio == true && mounted) widget.actualizar();
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.historial;
    final filtros = estados.entries.toList();
    final visibles = h.apuestas.where(
      (a) => a['estado'] == filtros[seleccion].key,
    );
    final registrar = FilledButton(
      onPressed: () => abrir(Registro(api: widget.api, historial: h)),
      child: const Text('+ Registrar apuesta'),
    );
    void detalle(Json a) =>
        abrir(Detalle(api: widget.api, apuesta: a, partido: h.encuentro(a)));
    return LayoutBuilder(
      builder: (context, limites) {
        final estrecho = limites.maxWidth < 520;
        final botonAlPie = widget.movil || estrecho;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.all(estrecho ? 16 : 28),
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text('Mis apuestas', style: titulo),
                      ),
                      IconButton(
                        onPressed: widget.actualizar,
                        tooltip: 'Actualizar historial',
                        icon: const Icon(Icons.refresh),
                      ),
                      if (!botonAlPie) registrar,
                    ],
                  ),
                  const SizedBox(height: 20),
                  Resumen(historial: h),
                  const SizedBox(height: 20),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final (i, filtro) in filtros.indexed)
                          Semantics(
                            selected: seleccion == i,
                            child: TextButton(
                              onPressed: () => setState(() => seleccion = i),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      width: 2,
                                      color: seleccion == i
                                          ? Colors.black
                                          : Colors.transparent,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  '${filtro.value} (${h.apuestas.where((a) => a["estado"] == filtro.key).length})',
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  const SizedBox(height: 16),
                  if (visibles.isEmpty)
                    Text(
                      seleccion == 0
                          ? 'Sin apuestas en curso.'
                          : 'Sin apuestas ${filtros[seleccion].value.toLowerCase()}.',
                    )
                  else if (widget.movil)
                    for (final a in visibles)
                      Card.outlined(
                        child: ListTile(
                          onTap: () => detalle(a),
                          title: Text(
                            h.encuentro(a),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            'Selección: ${a["seleccion"]} · Monto: ${dinero(a["monto"])} · Cuota: ${a["cuota"]}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                        ),
                      )
                  else
                    LayoutBuilder(
                      builder: (_, area) => SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ConstrainedBox(
                          constraints: BoxConstraints(minWidth: area.maxWidth),
                          child: DataTable(
                            columnSpacing: 18,
                            horizontalMargin: 12,
                            headingRowColor: const WidgetStatePropertyAll(
                              Color(0xffeeeeee),
                            ),
                            columns: [
                              for (final col in [
                                'Partido',
                                'Selección',
                                'Monto',
                                'Cuota',
                                '',
                              ])
                                DataColumn(label: Text(col)),
                            ],
                            rows: [
                              for (final a in visibles)
                                DataRow(
                                  cells: [
                                    DataCell(Text(h.encuentro(a))),
                                    DataCell(Text(a['seleccion'])),
                                    DataCell(Text(dinero(a['monto']))),
                                    DataCell(Text(a['cuota'])),
                                    DataCell(
                                      TextButton(
                                        onPressed: () => detalle(a),
                                        child: const Text('Ver detalle'),
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (botonAlPie)
              Padding(padding: const EdgeInsets.all(16), child: registrar),
          ],
        );
      },
    );
  }
}

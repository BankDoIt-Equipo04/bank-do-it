import 'package:flutter/material.dart';

import 'api_apuestas.dart';
import 'mis_apuestas.dart';

enum Operacion {
  aportacion('Aportación'),
  retiro('Retiro'),
  limite('Límite semanal');

  const Operacion(this.nombre);
  final String nombre;
}

class PantallaBankroll extends StatefulWidget {
  const PantallaBankroll({
    super.key,
    required this.api,
    required this.historial,
    required this.visible,
    required this.actualizarSaldo,
  });
  final ApiApuestas api;
  final Historial historial;
  final bool visible;
  final VoidCallback actualizarSaldo;
  @override
  State<PantallaBankroll> createState() => _PantallaBankrollState();
}

class _PantallaBankrollState extends State<PantallaBankroll> {
  Future<List<Json>>? movimientos;
  final monto = TextEditingController();
  Operacion? operacion;
  String? aviso, clave;
  bool enviando = false, incierta = false;

  @override
  void initState() {
    super.initState();
    if (widget.visible) movimientos = widget.api.movimientos();
  }

  @override
  void didUpdateWidget(PantallaBankroll anterior) {
    super.didUpdateWidget(anterior);
    if (widget.visible && !anterior.visible) {
      movimientos = widget.api.movimientos();
    }
  }

  @override
  void dispose() {
    monto.dispose();
    super.dispose();
  }

  void seleccionar(Operacion op) {
    setState(() {
      operacion = op;
      aviso = null;
      clave = ApiApuestas.nuevaClave();
      final limite = widget.historial.limite;
      monto.text = op == Operacion.limite && limite != null
          ? decimal(limite)
          : '';
    });
  }

  Future<void> guardar() async {
    final op = operacion;
    if (enviando || op == null) return;
    final valor = centavos(monto.text);
    if (valor == null || (op != Operacion.limite && valor == 0)) {
      setState(
        () => aviso = op == Operacion.limite
            ? 'Escribe un límite de cero o mayor, con hasta dos decimales.'
            : 'Escribe un monto positivo con hasta dos decimales.',
      );
      return;
    }
    setState(() {
      enviando = true;
      aviso = null;
    });
    try {
      if (op == Operacion.limite) {
        await widget.api.cambiarLimite(decimal(valor));
      } else {
        await widget.api.moverSaldo(op.name, decimal(valor), clave!);
      }
      if (!mounted) return;
      setState(() {
        operacion = null;
        incierta = false;
        aviso = op == Operacion.limite
            ? 'Límite semanal actualizado.'
            : 'Movimiento registrado.';
        movimientos = widget.api.movimientos();
      });
      widget.actualizarSaldo();
    } on FalloApi catch (e) {
      if (!mounted) return;
      setState(() {
        incierta = e.reintentar;
        aviso = incierta
            ? 'La API no confirmó la operación. Reintenta con el mismo importe.'
            : e.mensaje;
        if (!incierta) clave = ApiApuestas.nuevaClave();
      });
    } finally {
      if (mounted) setState(() => enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final op = operacion;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text('Bankroll', style: titulo),
        const SizedBox(height: 16),
        Resumen(historial: widget.historial),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final opcion in Operacion.values)
              OutlinedButton(
                onPressed: enviando || incierta
                    ? null
                    : () => seleccionar(opcion),
                child: Text(opcion.nombre),
              ),
          ],
        ),
        if (op != null) ...[
          const SizedBox(height: 12),
          TextField(
            key: ValueKey(op),
            controller: monto,
            readOnly: enviando || incierta,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: op == Operacion.limite
                  ? 'Nuevo límite semanal'
                  : 'Monto de ${op.nombre.toLowerCase()}',
            ),
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: enviando ? null : guardar,
                child: Text(incierta ? 'Reintentar' : 'Guardar'),
              ),
              if (!incierta)
                TextButton(
                  onPressed: enviando
                      ? null
                      : () => setState(() {
                          operacion = null;
                          aviso = null;
                        }),
                  child: const Text('Cancelar'),
                ),
            ],
          ),
        ],
        if (aviso != null) Semantics(liveRegion: true, child: Text(aviso!)),
        const Divider(height: 32),
        Row(
          children: [
            Expanded(
              child: Text(
                'Movimientos',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
            IconButton(
              tooltip: 'Actualizar movimientos',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                setState(() {
                  movimientos = widget.api.movimientos();
                });
                widget.actualizarSaldo();
              },
            ),
          ],
        ),
        FutureBuilder<List<Json>>(
          future: movimientos,
          builder: (context, estado) {
            if (estado.hasError) return Text(estado.error.toString());
            if (!estado.hasData) {
              return widget.visible
                  ? const LinearProgressIndicator()
                  : const SizedBox.shrink();
            }
            final filas = estado.requireData;
            if (filas.isEmpty) return const Text('Aún no hay movimientos.');
            return Column(
              children: [
                for (final fila in filas)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(switch (fila['tipo']) {
                      'aportacion' => 'Aportación simulada',
                      'retiro' => 'Retiro simulado',
                      'saldo_inicial' => 'Saldo inicial',
                      'reserva' => 'Reserva de apuesta',
                      'liquidacion' => 'Liquidación de apuesta',
                      _ => 'Movimiento',
                    }),
                    subtitle: Text(fila['fecha'].toString()),
                    trailing: Text(dinero(fila['cambio_disponible'])),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

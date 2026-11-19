import 'package:flutter/material.dart';

import 'api_apuestas.dart';
import 'recuerdo.dart';
import 'borradores.dart';

class Registro extends StatefulWidget {
  const Registro({
    super.key,
    required this.borradores,
    required this.historial,
  });
  final Borradores borradores;
  final Historial historial;
  @override
  State<Registro> createState() => _RegistroState();
}

class _RegistroState extends State<Registro> {
  final form = GlobalKey<FormState>();
  final seleccion = TextEditingController(),
      monto = TextEditingController(),
      cuota = TextEditingController();
  String busqueda = '', clave = ApiApuestas.nuevaClave();
  Partido? elegido;
  bool enviando = false;

  String? error;

  @override
  void dispose() {
    seleccion.dispose();
    monto.dispose();
    cuota.dispose();
    super.dispose();
  }

  Future<bool> confirmar(int exceso) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Presupuesto semanal'),
          content: Text(
            'Con esta apuesta superarías tu presupuesto por ${dinero(decimal(exceso))}.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirmar'),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> guardar() async {
    if (enviando || !form.currentState!.validate()) return;
    setState(() {
      enviando = true;
      error = null;
    });
    try {
      final importe = centavos(monto.text)!;
      final limite = widget.historial.limite;
      final datos = <String, dynamic>{
        'partido_id': elegido!.id,
        'seleccion': seleccion.text.trim(),
        'monto': decimal(importe),
        'cuota': decimal(centavos(cuota.text)!),
        'exceso_aceptado': '0.00',
      };
      if (limite != null) {
        final exceso = widget.historial.usado + importe - limite;
        if (exceso > 0) {
          if (!await confirmar(exceso)) return;
          datos['exceso_aceptado'] = decimal(exceso);
        }
      }
      while (mounted) {
        try {
          final b = {
            'clave': clave,
            'datos': datos,
            'creado': DateTime.now().toUtc().toIso8601String(),
          };
          await widget.borradores.guardar(b);
          await widget.borradores.enviar(b);
          if (mounted) Navigator.pop(context, true);
          return;
        } on FalloApi catch (e) {
          if (!mounted) return;
          if (e.reintentar) {
            Navigator.pop(context, true);
            return;
          }
          await widget.borradores.quitar(clave);
          if (!mounted) return;
          final exceso = e.exceso;
          if (exceso == null) {
            setState(() => error = e.mensaje);
            return;
          }
          if (!await confirmar(exceso)) return;
          datos['exceso_aceptado'] = decimal(exceso);
        }
      }
    } finally {
      if (mounted) setState(() => enviando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = !enviando;
    final partidos = widget.historial.partidos
        .where((p) => p.nombre.toLowerCase().contains(busqueda.toLowerCase()))
        .toList();
    return PopScope<bool>(
      canPop: !enviando,
      child: Scaffold(
        appBar: AppBar(title: const Text('Registrar apuesta')),
        body: SafeArea(
          child: Form(
            key: form,
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                TextFormField(
                  enabled: editable,
                  decoration: const InputDecoration(labelText: 'Buscar equipo'),
                  onChanged: (v) => setState(() {
                    busqueda = v.trim();
                    if (elegido != null &&
                        !elegido!.nombre.toLowerCase().contains(
                          busqueda.toLowerCase(),
                        )) {
                      elegido = null;
                    }
                  }),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<Partido>(
                  key: ValueKey(elegido?.id),
                  initialValue: elegido,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Partido',
                    helperText: partidos.isEmpty
                        ? 'Sin coincidencias'
                        : elegido?.deporte,
                  ),
                  items: [
                    for (final p in partidos)
                      DropdownMenuItem(value: p, child: Text(p.nombre)),
                  ],
                  onChanged: editable
                      ? (v) => setState(() => elegido = v)
                      : null,
                  validator: (v) => v == null ? 'Elige un partido.' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  enabled: editable,
                  controller: seleccion,
                  maxLength: 180,
                  decoration: const InputDecoration(labelText: 'Selección'),
                  validator: (v) =>
                      (v ?? '').trim().isEmpty ? 'Escribe tu selección.' : null,
                ),
                for (final (campo, control) in [
                  ('Monto', monto),
                  ('Cuota', cuota),
                ]) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    enabled: editable,
                    controller: control,
                    decoration: InputDecoration(labelText: campo),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    validator: (v) {
                      final n = centavos(v ?? '');
                      if (n == null) {
                        return 'Usa un número con hasta dos decimales.';
                      }
                      if (campo == 'Monto' && n <= 0) {
                        return 'El monto debe ser positivo.';
                      }
                      if (campo == 'Cuota' && (n <= 100 || n > 999999)) {
                        return 'Usa una cuota mayor que 1 y de hasta 9999.99.';
                      }
                      return null;
                    },
                  ),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(error!),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: enviando ? null : guardar,
                  child: Text('Guardar apuesta'),
                ),
                TextButton(
                  onPressed: enviando
                      ? null
                      : () => Navigator.pop(context, false),
                  child: const Text('Cancelar'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class Detalle extends StatefulWidget {
  const Detalle({
    super.key,
    required this.api,
    required this.apuesta,
    required this.partido,
  });
  final ApiApuestas api;
  final Json apuesta;
  final String partido;
  @override
  State<Detalle> createState() => _DetalleState();
}

class _DetalleState extends State<Detalle> {
  bool guardando = false;
  String? error;
  Future<void> resolver(String resultado) async {
    if (guardando) return;
    setState(() {
      guardando = true;
      error = null;
    });
    try {
      await widget.api.resolver(widget.apuesta['id'], resultado);
      if (mounted) Navigator.pop(context, true);
    } on FalloApi catch (e) {
      if (mounted) setState(() => error = e.mensaje);
    } finally {
      if (mounted) setState(() => guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.apuesta;
    return PopScope<bool>(
      canPop: !guardando,
      child: Scaffold(
        appBar: AppBar(title: const Text('Detalle de apuesta')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              widget.partido,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            for (final (nombre, valor) in [
              ('Selección', a['seleccion']),
              ('Monto', dinero(a['monto'])),
              ('Cuota', a['cuota']),
              ('Estado', a['estado']),
            ])
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(nombre),
                subtitle: Text(valor),
              ),
            if (a['estado'] == 'pendiente')
              Wrap(
                spacing: 8,
                children: [
                  for (final resultado in ['ganada', 'perdida', 'anulada'])
                    OutlinedButton(
                      onPressed: guardando ? null : () => resolver(resultado),
                      child: Text('Marcar como $resultado'),
                    ),
                ],
              ),
            if (error != null) Text(error!),
            Recuerdo(api: widget.api, apuestaId: a["id"]),
          ],
        ),
      ),
    );
  }
}

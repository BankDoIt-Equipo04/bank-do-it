import 'package:flutter/material.dart';

import 'api_apuestas.dart';

class Administracion extends StatefulWidget {
  const Administracion({super.key, required this.api});
  final ApiApuestas api;
  @override
  State<Administracion> createState() => _AdministracionState();
}

class _AdministracionState extends State<Administracion> {
  late Future<List<Json>> cuentas = widget.api.cuentasAdministradas();
  late Future<List<Json>> equipos = widget.api.catalogoEquipos();
  int? local, visitante, deporte;
  TimeOfDay hora = const TimeOfDay(hour: 12, minute: 0);
  final form = GlobalKey<FormState>();

  DateTime fecha = DateUtils.dateOnly(DateTime.now());
  String? aviso;
  String clave = ApiApuestas.nuevaClave();
  bool guardando = false, reintento = false;
  Future<void> guardar(int deporteId) async {
    if (guardando || !form.currentState!.validate()) return;
    setState(() {
      guardando = true;
      aviso = null;
    });
    try {
      await widget.api.crearPartido({
        'deporte_id': deporteId,
        'fecha_hora': DateTime(
          fecha.year,
          fecha.month,
          fecha.day,
          hora.hour,
          hora.minute,
        ).toUtc().toIso8601String(),
        'equipo_local_id': local,
        'equipo_visitante_id': visitante,
      }, clave);
      if (!mounted) return;
      local = visitante = null;
      setState(() {
        aviso = 'Partido guardado.';
        reintento = false;
        clave = ApiApuestas.nuevaClave();
      });
    } on FalloApi catch (e) {
      if (mounted) {
        setState(() {
          aviso = e.mensaje;
          reintento = e.reintentar;
          if (!reintento) clave = ApiApuestas.nuevaClave();
        });
      }
    } finally {
      if (mounted) setState(() => guardando = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editable = !guardando && !reintento;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Administración'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Cuentas'),
              Tab(text: 'Jornadas'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            FutureBuilder<List<Json>>(
              future: cuentas,
              builder: (context, estado) {
                if (estado.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(estado.error.toString()),
                        TextButton(
                          onPressed: () {
                            setState(() {
                              cuentas = widget.api.cuentasAdministradas();
                            });
                          },
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  );
                }
                if (!estado.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final lista = estado.requireData;
                if (lista.isEmpty) {
                  return const Center(child: Text('Sin cuentas registradas.'));
                }
                return ListView.builder(
                  itemCount: lista.length,
                  itemBuilder: (_, i) => ListTile(
                    title: Text(lista[i]['alias']),
                    subtitle: Text(lista[i]['estado']),
                  ),
                );
              },
            ),
            FutureBuilder<List<Json>>(
              future: equipos,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(snapshot.error.toString()),
                        TextButton(
                          onPressed: () => setState(() {
                            equipos = widget.api.catalogoEquipos();
                          }),
                          child: const Text('Reintentar'),
                        ),
                      ],
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final catalogo = snapshot.requireData;
                if (catalogo.isEmpty) {
                  return const Center(
                    child: Text('Sin equipos en el catálogo.'),
                  );
                }
                final deportes = {
                  for (final e in catalogo)
                    e['deporte_id'] as int: e['deporte'] as String,
                };
                final seleccionado = deporte ?? deportes.keys.first;
                final opciones = catalogo.where(
                  (e) => e['deporte_id'] == seleccionado,
                );
                return Form(
                  key: form,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      DropdownButtonFormField<int>(
                        initialValue: seleccionado,
                        decoration: const InputDecoration(labelText: 'Deporte'),
                        items: [
                          for (final d in deportes.entries)
                            DropdownMenuItem(
                              value: d.key,
                              child: Text(d.value),
                            ),
                        ],
                        onChanged: editable
                            ? (id) => setState(() {
                                deporte = id;
                                local = visitante = null;
                              })
                            : null,
                      ),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Fecha de la jornada'),
                        subtitle: Text(
                          MaterialLocalizations.of(context)
                              .formatMediumDate(fecha),
                        ),
                        trailing: const Icon(Icons.calendar_today),
                        onTap: !editable
                            ? null
                            : () async {
                                final dia = await showDatePicker(
                                  context: context,
                                  initialDate: fecha,
                                  firstDate: DateTime(2000),
                                  lastDate: DateTime(2100),
                                );
                                if (mounted && dia != null) {
                                  setState(() => fecha = dia);
                                }
                              },
                      ),
                      ListTile(
                        title: const Text('Hora local del partido'),
                        subtitle: Text(hora.format(context)),
                        onTap: !editable
                            ? null
                            : () async {
                                final nueva = await showTimePicker(
                                  context: context,
                                  initialTime: hora,
                                );
                                if (mounted && nueva != null) {
                                  setState(() => hora = nueva);
                                }
                              },
                      ),
                      for (final esLocal in [true, false])
                        DropdownButtonFormField<int>(
                          key: ValueKey((esLocal, seleccionado, clave)),
                          initialValue: esLocal ? local : visitante,
                          decoration: InputDecoration(
                            labelText: esLocal
                                ? 'Equipo local'
                                : 'Equipo visitante',
                          ),
                          items: [
                            for (final e in opciones)
                              DropdownMenuItem(
                                value: e['equipo_id'] as int,
                                child: Text(e['nombre'] as String),
                              ),
                          ],
                          onChanged: editable
                              ? (id) => setState(() {
                                  if (esLocal) {
                                    local = id;
                                  } else {
                                    visitante = id;
                                  }
                                })
                              : null,
                          validator: (id) {
                            if (id == null) return 'Selecciona un equipo.';
                            if (!esLocal && id == local) {
                              return 'Elige dos equipos distintos.';
                            }
                            return null;
                          },
                        ),
                      FilledButton(
                        onPressed: guardando
                            ? null
                            : () => guardar(seleccionado),
                        child: Text(
                          reintento
                              ? 'Reintentar guardado'
                              : 'Guardar y agregar otro',
                        ),
                      ),
                      if (aviso != null)
                        Semantics(liveRegion: true, child: Text(aviso!)),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

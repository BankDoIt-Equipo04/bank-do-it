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
  final local = TextEditingController(), visitante = TextEditingController();
  final form = GlobalKey<FormState>();
  String deporte = 'Fútbol';
  DateTime fecha = DateUtils.dateOnly(DateTime.now());
  String? aviso;
  String clave = ApiApuestas.nuevaClave();
  bool guardando = false, reintento = false;
  @override
  void dispose() {
    local.dispose();
    visitante.dispose();
    super.dispose();
  }

  Future<void> guardar() async {
    if (guardando || !form.currentState!.validate()) return;
    setState(() {
      guardando = true;
      aviso = null;
    });
    try {
      await widget.api.crearPartido({
        'deporte': deporte,
        'fecha': fecha.toIso8601String().split('T').first,
        'local': local.text.trim(),
        'visitante': visitante.text.trim(),
      }, clave);
      if (!mounted) return;
      local.clear();
      visitante.clear();
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
            Form(
              key: form,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: deporte,
                    decoration: const InputDecoration(labelText: 'Deporte'),
                    items: [
                      for (final d in ['Fútbol', 'Fútbol americano'])
                        DropdownMenuItem(value: d, child: Text(d)),
                    ],
                    onChanged: editable
                        ? (d) => setState(() => deporte = d!)
                        : null,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Fecha de la jornada'),
                    subtitle: Text(
                      MaterialLocalizations.of(context).formatMediumDate(fecha),
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
                  for (final (control, etiqueta) in [
                    (local, 'Equipo local'),
                    (visitante, 'Equipo visitante'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: TextFormField(
                        controller: control,
                        enabled: editable,
                        decoration: InputDecoration(labelText: etiqueta),
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) {
                            return 'Escribe el nombre del equipo.';
                          }
                          if (control == visitante &&
                              v.trim().toLowerCase() ==
                                  local.text.trim().toLowerCase()) {
                            return 'Elige dos equipos distintos.';
                          }
                          return null;
                        },
                      ),
                    ),
                  FilledButton(
                    onPressed: guardando ? null : guardar,
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
            ),
          ],
        ),
      ),
    );
  }
}

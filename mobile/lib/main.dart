import 'dart:async';

import 'borradores.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'mis_apuestas.dart';
import 'api_apuestas.dart';

void main() => runApp(const BankDoItApp());

class BankDoItApp extends StatelessWidget {
  const BankDoItApp({this.api, super.key});
  final ApiApuestas? api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BANKDOIT',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.grey,
          primary: const Color(0xff303030),
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: Colors.white,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: Principal(api: api),
    );
  }
}

enum Seccion {
  apuestas('Apuestas', Icons.confirmation_number_outlined),
  bankroll('Bankroll', Icons.account_balance_wallet_outlined),
  estadisticas('Estadísticas', Icons.bar_chart_outlined);

  const Seccion(this.nombre, this.icono);
  final String nombre;
  final IconData icono;
}

class Marca extends StatelessWidget {
  const Marca({super.key});
  @override
  Widget build(BuildContext context) => const Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        'B',
        style: TextStyle(
          fontSize: 29,
          fontWeight: FontWeight.w900,
          fontStyle: FontStyle.italic,
          color: Color(0xff007985),
        ),
      ),
      SizedBox(width: 5),
      Text('BANKDOIT', style: TextStyle(fontWeight: FontWeight.bold)),
    ],
  );
}

class Principal extends StatefulWidget {
  const Principal({required this.api, super.key});
  final ApiApuestas? api;
  @override
  State<Principal> createState() => _PrincipalState();
}

class _PrincipalState extends State<Principal> {
  late final api = widget.api ?? ApiApuestas();
  late final borradores = Borradores(api);
  late Future<Historial> carga;
  Timer? reintento;
  bool ocupado = false, abierto = false;
  @override
  void initState() {
    super.initState();
    carga = iniciar();
    reintento = Timer.periodic(const Duration(seconds: 10), (_) {
      if (abierto &&
          !ocupado &&
          ModalRoute.of(context)?.isCurrent == true &&
          (borradores.saldoPorActualizar ||
              borradores.lista.any((b) => b['error'] == null))) {
        actualizar();
      }
    });
  }

  Future<Historial> iniciar() async {
    await borradores.abrir();
    abierto = true;
    return consultar();
  }

  Future<Historial> consultar() async {
    ocupado = true;
    try {
      return await borradores.actualizar();
    } finally {
      ocupado = false;
    }
  }

  void actualizar() {
    if (!ocupado) setState(() => carga = abierto ? consultar() : iniciar());
  }

  @override
  void dispose() {
    reintento?.cancel();
    if (widget.api == null) api.cliente.close();
    super.dispose();
  }

  Seccion actual = Seccion.apuestas;

  @override
  Widget build(BuildContext context) {
    final movil =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    final secciones = Seccion.values;
    void seleccionar(int i) => setState(() => actual = secciones[i]);
    final contenido = FutureBuilder<Historial>(
      future: carga,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(snapshot.error.toString(), textAlign: TextAlign.center),
                OutlinedButton(
                  onPressed: actualizar,
                  child: const Text('Reintentar'),
                ),
              ],
            ),
          );
        }
        final historial = snapshot.requireData;
        return IndexedStack(
          index: actual.index,
          children: [
            MisApuestas(
              borradores: borradores,
              movil: movil,
              api: api,
              historial: historial,
              actualizar: actualizar,
            ),
            ListViewBankroll(historial: historial),
            Padding(
              padding: EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Estadísticas', style: titulo),
                  const SizedBox(height: 20),
                  Text(
                    historial.apuestas.every((a) => a['estado'] == 'pendiente')
                        ? 'Aún no hay apuestas resueltas.'
                        : 'Apuestas resueltas: ${historial.apuestas.where((a) => a["estado"] != "pendiente").length}.',
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
    final superior = kIsWeb || movil;
    return Scaffold(
      appBar: superior
          ? AppBar(
              backgroundColor: Colors.white,
              surfaceTintColor: Colors.transparent,
              title: kIsWeb
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          const Marca(),
                          const SizedBox(width: 20),
                          for (final s in secciones)
                            TextButton(
                              onPressed: () => seleccionar(s.index),
                              style: TextButton.styleFrom(
                                shape: const RoundedRectangleBorder(),
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    bottom: BorderSide(
                                      color: actual == s
                                          ? Colors.black
                                          : Colors.transparent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                child: Text(s.nombre),
                              ),
                            ),
                        ],
                      ),
                    )
                  : const Marca(),
            )
          : null,
      bottomNavigationBar: movil
          ? BottomNavigationBar(
              currentIndex: actual.index,
              onTap: seleccionar,
              items: [
                for (final s in secciones)
                  BottomNavigationBarItem(icon: Icon(s.icono), label: s.nombre),
              ],
            )
          : null,
      body: SafeArea(
        child: superior
            ? contenido
            : Row(
                children: [
                  NavigationRail(
                    leading: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Marca(),
                    ),
                    labelType: NavigationRailLabelType.all,
                    selectedIndex: actual.index,
                    onDestinationSelected: seleccionar,
                    destinations: [
                      for (final s in secciones)
                        NavigationRailDestination(
                          icon: Icon(s.icono),
                          label: Text(s.nombre),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1),
                  Expanded(child: contenido),
                ],
              ),
      ),
    );
  }
}

class ListViewBankroll extends StatelessWidget {
  const ListViewBankroll({required this.historial, super.key});
  final Historial historial;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(24),
    children: [
      const Text('Bankroll', style: titulo),
      SizedBox(height: 16),
      Resumen(historial: historial),
    ],
  );
}

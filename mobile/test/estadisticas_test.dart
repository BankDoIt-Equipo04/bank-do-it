import 'dart:convert';

import 'package:bankdoit/api_apuestas.dart';
import 'package:bankdoit/estadisticas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('Globales distingue un servicio caído de un corte vacío', (
    tester,
  ) async {
    var globales = 0;
    final cliente = MockClient((req) async {
      expect(req.headers['Authorization'], 'Bearer prueba');
      if (req.url.path == '/usuarios/3/resultados') {
        expect(req.url.queryParameters['graficas'], 'true');
        return http.Response(
          jsonEncode({
            'corte_utc': '2026-11-27T15:00:00Z',
            'graficas': {'evolucion': null, 'roi': null, 'rachas': null},
            'ganancia_neta': '0.00',
            'roi_por_deporte': [],
            'rachas': {'maxima_ganadora': 0, 'maxima_perdedora': 0},
          }),
          200,
        );
      }
      expect(req.url.path, '/resultados/globales');
      globales++;
      if (globales == 1) return http.Response('{}', 503);
      return http.Response(
        jsonEncode({
          'corte_utc': null,
          'total_apuestas': 0,
          'por_deporte': [],
          'por_partido': [],
        }),
        200,
      );
    });
    final api = ApiApuestas(
      cliente: cliente,
      sesion: const Sesion(3, 'demo', 'prueba'),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Estadisticas(api: api, partidos: const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Sin datos'), findsWidgets);
    expect(find.textContaining('Hora de corte'), findsOneWidget);
    await tester.tap(find.text('Globales'));
    await tester.pumpAndSettle();
    expect(find.text('Sin datos'), findsNothing);
    await tester.tap(find.text('Reintentar'));
    await tester.pumpAndSettle();
    expect(find.text('Sin datos'), findsOneWidget);
    expect(find.text('Sin corte publicado'), findsOneWidget);
  });
}

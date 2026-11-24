import 'dart:convert';

import 'package:bankdoit/api_apuestas.dart';
import 'package:bankdoit/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'Bankroll consulta, aporta, retira, explica el rechazo y actualiza el límite',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1050, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      int disponible = 10000, limite = 50000;
      final filas = <Json>[];
      final claves = <String>{};
      String? respuestaPerdida;
      final cliente = MockClient((req) async {
        expect(req.headers['Authorization'], 'Bearer prueba');
        final ruta = req.url.path;
        if (ruta == '/usuarios/8/historial') {
          return http.Response(
            jsonEncode({
              'bankroll': {
                'disponible': decimal(disponible),
                'en_juego': '0.00',
              },
              'presupuesto': {'limite_centavos': limite, 'usado_centavos': 0},
              'apuestas': [],
              'partidos': [],
            }),
            200,
          );
        }
        if (ruta == '/usuarios/8/presupuesto' && req.method == 'PUT') {
          limite = centavos(jsonDecode(req.body)['limite'])!;
          return http.Response('', 204);
        }
        expect(ruta, '/usuarios/8/bankroll/movimientos');
        if (req.method == 'GET') {
          return http.Response(jsonEncode({'movimientos': filas}), 200);
        }
        expect(req.method, 'POST');
        final b = jsonDecode(req.body);
        final clave = req.headers['Idempotency-Key']!;
        final monto = centavos(b['monto'])!;
        final retiro = b['tipo'] == 'retiro';
        if (retiro && monto > disponible) {
          return http.Response('{"detail":"saldo_insuficiente"}', 409);
        }
        if (claves.add(clave)) {
          disponible += retiro ? -monto : monto;
          filas.add({
            'tipo': b['tipo'],
            'cambio_disponible': retiro ? '-${b['monto']}' : b['monto'],
            'fecha': '2026-11-24',
          });
          if (!retiro && respuestaPerdida == null) {
            respuestaPerdida = clave;
            throw http.ClientException('Respuesta perdida');
          }
        }
        return http.Response('{}', 200);
      });
      await tester.pumpWidget(
        BankDoItApp(
          api: ApiApuestas(
            cliente: cliente,
            sesion: const Sesion(8, 'raul', 'prueba'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      Future<void> tocar(String texto) async {
        await tester.tap(find.text(texto).first);
        await tester.pumpAndSettle();
      }

      Future<void> registrar(String op, String monto) async {
        await tocar(op);
        await tester.enterText(find.byType(TextField), monto);
        await tocar('Guardar');
      }

      await tocar('Bankroll');
      expect(find.text('Aún no hay movimientos.'), findsOneWidget);
      await registrar('Aportación', '50');
      await tocar('Reintentar');
      expect(claves, {respuestaPerdida});
      expect(find.text(r'$150'), findsOneWidget);
      expect(find.text('Aportación simulada'), findsOneWidget);
      await registrar('Retiro', '160');
      expect(find.text('Saldo insuficiente.'), findsOneWidget);
      expect(disponible, 15000);
      await tester.enterText(find.byType(TextField), '30');
      await tocar('Guardar');
      expect(find.text(r'$120'), findsOneWidget);
      expect(find.text('Retiro simulado'), findsOneWidget);
      await registrar('Límite semanal', '250');
      expect(find.text(r'$0 de $250'), findsOneWidget);
      await tocar('Apuestas');
      expect(find.text(r'$120'), findsOneWidget);
      expect(find.text(r'$0 de $250'), findsOneWidget);
    },
  );
}

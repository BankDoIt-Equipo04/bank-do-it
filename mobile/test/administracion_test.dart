import 'dart:convert';

import 'package:bankdoit/administracion.dart';
import 'package:bankdoit/api_apuestas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets(
    'El administrador consulta cuentas y conserva la jornada entre dos partidos',
    (tester) async {
      final enviados = <Json>[];
      final claves = <String>{};
      final cliente = MockClient((req) async {
        if (req.url.path == '/auth/login') {
          return http.Response(
            jsonEncode({
              'usuario_id': 8,
              'alias': 'prueba',
              'access_token': 'prueba',
              'rol': 'administrador',
            }),
            200,
          );
        }
        expect(req.headers['Authorization'], 'Bearer prueba');
        if (req.url.path == '/admin/cuentas') {
          return http.Response(
            '{"cuentas":[{"alias":"raul","estado":"activo"}]}',
            200,
          );
        }
        expect(req.url.path, '/admin/partidos');
        claves.add(req.headers['Idempotency-Key']!);
        enviados.add(jsonDecode(req.body));
        return http.Response('{}', 201);
      });
      final api = await ApiApuestas(cliente: cliente)
          .ingresar('prueba', 'prueba');
      expect(api.sesion!.administrador, isTrue);
      await tester.pumpWidget(MaterialApp(home: Administracion(api: api)));
      await tester.pumpAndSettle();
      expect(find.text('raul'), findsOneWidget);
      expect(find.text('activo'), findsOneWidget);
      await tester.tap(find.text('Jornadas'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Fútbol americano').last);
      await tester.pumpAndSettle();
      for (final n in [1, 2]) {
        await tester.enterText(find.byType(TextFormField).first, 'Local $n');
        await tester.enterText(find.byType(TextFormField).last, 'Visitante $n');
        final guardar = find.text('Guardar y agregar otro');
        await tester.ensureVisible(guardar);
        await tester.tap(guardar);
        await tester.pumpAndSettle();
        expect(find.text('Partido guardado.'), findsOneWidget);
        expect(
          tester
              .widget<TextFormField>(find.byType(TextFormField).first)
              .controller!
              .text,
          isEmpty,
        );
      }
      expect(
        enviados.map((j) => j['deporte']),
        everyElement('Fútbol americano'),
      );
      expect(enviados.first['fecha'], enviados.last['fecha']);
      expect(enviados.last['local'], 'Local 2');
      expect(claves.length, 2);
    },
  );
}

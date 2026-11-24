import 'dart:convert';

import 'package:bankdoit/api_apuestas.dart';
import 'package:bankdoit/borradores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const real = bool.fromEnvironment('PRUEBA_API_TEMPORAL');
  test('Una respuesta perdida y un reinicio conservan la clave y descuentan una sola vez', () async {
    SharedPreferences.setMockInitialValues({});
    final red = http.Client();
    addTearDown(red.close);
    final claves = <String>[];
    final cuerpos = <String>[];
    final codigos = <int>[];
    bool sinRed = false;
    final cliente = MockClient((req) async {
      if (sinRed) throw http.ClientException('Sin red');
      final post = req.method == 'POST';
      if (post) {
        claves.add(req.headers['Idempotency-Key']!);
        cuerpos.add(req.body);
      }
      late http.Response res;
      if (real) {
        expect(ApiApuestas.servidor, 'http://127.0.0.1:18810');
        res = post
            ? await red.post(req.url, headers: req.headers, body: req.body)
            : await red.get(req.url, headers: req.headers);
      } else {
        final apuesta = {'id': 1, 'seleccion': 'Chiefs'};
        final saldo = {
          'disponible': claves.isEmpty ? '1000.00' : '900.00',
          'en_juego': claves.isEmpty ? '0.00' : '100.00',
        };
        res = http.Response(
          jsonEncode(
            post
                ? {'apuesta': apuesta, 'bankroll': saldo}
                : {
                    'bankroll': saldo,
                    'presupuesto': {'usado_centavos': 0},
                    'partidos': [],
                    'apuestas': [if (claves.isNotEmpty) apuesta],
                  },
          ),
          post && claves.length == 1 ? 201 : 200,
        );
      }
      if (post) {
        codigos.add(res.statusCode);
        if (claves.length == 1) {
          sinRed = true;
          throw http.ClientException('Respuesta perdida después de guardar');
        }
      }
      return res;
    });
    var sesion = const Sesion(3, 'prueba', 'prueba');
    if (real) {
      expect(ApiApuestas.servidor, 'http://127.0.0.1:18810');
      final acceso = ApiApuestas(cliente: red);
      final alias = ApiApuestas.nuevaClave();
      final clave = ApiApuestas.nuevaClave();
      await acceso.crearCuenta(alias, clave, '1000.00');
      sesion = (await acceso.ingresar(alias, clave)).sesion!;
    }
    final api = ApiApuestas(sesion: sesion, cliente: cliente);
    final inicial = Borradores(api);
    await inicial.abrir();
    expect((await inicial.actualizar()).disponible, '1000.00');
    final fecha = inicial.ultimaConsulta;
    final b = {
      'clave': ApiApuestas.nuevaClave(),
      'creado': DateTime.now().toIso8601String(),
      'datos': {
        'partido_id': 202,
        'seleccion': 'Chiefs',
        'monto': '100.00',
        'cuota': '2.00',
        'exceso_aceptado': '0.00',
      },
    };
    await inicial.guardar(b);
    await expectLater(inicial.enviar(b), throwsA(isA<FalloApi>()));
    final reinicio = Borradores(api);
    await reinicio.abrir();
    expect((await reinicio.actualizar()).disponible, '1000.00');
    expect(reinicio.lista.single, b);
    expect(reinicio.ultimaConsulta, fecha);
    sinRed = false;
    final confirmado = await reinicio.actualizar();
    expect(claves, [b['clave'], b['clave']]);
    expect(cuerpos.first, cuerpos.last);
    expect(codigos, [201, 200]);
    expect(confirmado.apuestas.single['seleccion'], 'Chiefs');
    expect(confirmado.disponible, '900.00');
    expect(confirmado.enJuego, '100.00');
    expect(reinicio.lista, isEmpty);
  });
}

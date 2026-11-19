import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

typedef Json = Map<String, dynamic>;

String dinero(String valor) =>
    '\$${valor.endsWith('.00') ? valor.substring(0, valor.length - 3) : valor}';
String decimal(int centavos) =>
    '${centavos ~/ 100}.${(centavos % 100).toString().padLeft(2, '0')}';
int? centavos(String valor) {
  final partes = valor.trim().replaceAll(',', '.');
  if (!RegExp(r'^\d{1,8}(\.\d{1,2})?$').hasMatch(partes)) return null;
  final numero = partes.split('.');
  return int.parse(numero.first) * 100 +
      (numero.length == 1 ? 0 : int.parse(numero.last.padRight(2, '0')));
}

class Partido {
  Partido(Json j)
    : id = j['id'],
      local = j['local'],
      visitante = j['visitante'],
      deporte = j['deporte'];
  final int id;
  final String local, visitante, deporte;
  String get nombre => '$local vs. $visitante';
}

class Historial {
  final Json datos;
  Historial(Json j)
    : datos = j,
      disponible = j['bankroll']['disponible'],
      enJuego = j['bankroll']['en_juego'],
      usado = j['presupuesto']['usado_centavos'],
      limite = j['presupuesto']['limite_centavos'],
      partidos = [for (final p in j['partidos']) Partido(p)],
      apuestas = List<Json>.from(j['apuestas']);
  final String disponible, enJuego;
  final int usado;
  final int? limite;
  final List<Partido> partidos;
  final List<Json> apuestas;
  String encuentro(Json a) =>
      partidos.where((p) => p.id == a['partido_id']).firstOrNull?.nombre ??
      'Partido ${a["partido_id"]}';
}

class FalloApi implements Exception {
  FalloApi(this.mensaje, {this.exceso, this.reintentar = false});
  final String mensaje;
  final int? exceso;
  final bool reintentar;
  @override
  String toString() => mensaje;
}

class ApiApuestas {
  ApiApuestas({http.Client? cliente}) : cliente = cliente ?? http.Client();
  final http.Client cliente;
  static const servidor = String.fromEnvironment(
    'API_URL',
    defaultValue: 'http://127.0.0.1:8000',
  );
  static const usuario = int.fromEnvironment('USUARIO_ID', defaultValue: 3);
  static String nuevaClave() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  Future<Json> _enviar(
    String metodo,
    String ruta, {
    Json? datos,
    String? clave,
  }) async {
    final req = http.Request(
      metodo,
      Uri.parse('$servidor/usuarios/$usuario/$ruta'),
    );
    if (datos != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(datos);
    }
    if (clave != null) req.headers['Idempotency-Key'] = clave;
    try {
      final res = await cliente
          .send(req)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 500 ||
          res.statusCode == 408 ||
          res.statusCode == 429) {
        throw FalloApi(
          'La API no pudo confirmar la operación. Reintenta.',
          reintentar: true,
        );
      }
      final j = jsonDecode(utf8.decode(res.bodyBytes)) as Json;
      if (res.statusCode >= 400) {
        final detalle = j['detail'];
        if (detalle is Map && detalle['exceso_centavos'] is int) {
          throw FalloApi(
            'Presupuesto actualizado',
            exceso: detalle['exceso_centavos'],
          );
        }
        throw FalloApi(switch (detalle) {
          'saldo_insuficiente' => 'Saldo insuficiente.',
          'resultado_en_conflicto' => 'La apuesta ya tiene otro resultado. Vuelve al historial y actualiza.',
          _ => detalle is String ? detalle : 'Revisa los datos de la apuesta.',
        });
      }
      return j;
    } on http.ClientException {
      throw FalloApi(
        'No se pudo conectar con la API. Comprueba la conexión y reintenta.',
        reintentar: true,
      );
    } on TimeoutException {
      throw FalloApi(
        'La API tardó en responder. Reintenta con los mismos datos.',
        reintentar: true,
      );
    } on FormatException {
      throw FalloApi(
        'La API devolvió una respuesta inesperada.',
        reintentar: true,
      );
    }
  }

  Future<Uint8List?> foto(int id, {Uint8List? contenido}) async {
    final uri = Uri.parse('$servidor/usuarios/$usuario/apuestas/$id/recuerdo');
    try {
      final respuesta =
          await (contenido == null
                  ? cliente.get(uri)
                  : cliente.put(
                      uri,
                      headers: {'Content-Type': 'application/octet-stream'},
                      body: contenido,
                    ))
              .timeout(const Duration(seconds: 30));
      if (respuesta.statusCode == 204) return null;
      if (respuesta.statusCode == 200 && contenido == null) {
        return respuesta.bodyBytes;
      }
      throw FalloApi(switch (respuesta.statusCode) {
        413 => 'La imagen excede el límite de 10 MB o 32 megapíxeles.',
        415 => 'Elige una imagen JPEG, PNG o WebP válida.',
        404 => 'No se encontró la apuesta.',
        _ => 'No se pudo acceder al recuerdo. Inténtalo de nuevo.',
      });
    } on http.ClientException {
      throw FalloApi('Comprueba la conexión con la API.');
    } on TimeoutException {
      throw FalloApi('La API tardó en responder. Inténtalo de nuevo.');
    }
  }

  Future<Historial> cargar() async =>
      Historial(await _enviar('GET', 'historial'));
  Future<Json> registrar(Json datos, String clave) =>
      _enviar('POST', 'apuestas', datos: datos, clave: clave);

  Future<void> resolver(int id, String resultado) async {
    await _enviar(
      'PUT',
      'apuestas/$id/resultado',
      datos: {'resultado': resultado},
    );
  }
}

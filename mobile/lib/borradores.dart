import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'api_apuestas.dart';

class Borradores {
  Borradores(this.api);
  final ApiApuestas api;
  String get _prefijo => 'bankdoit.${ApiApuestas.servidor}.${api.usuario}.';
  late SharedPreferences _local;
  String get _cola => '${_prefijo}borrador.';
  DateTime? ultimaConsulta;
  Historial? historial;
  String? aviso;
  bool saldoPorActualizar = false;
  final Map<String, Future<void>> _enCurso = {};

  Future<void> abrir() async {
    _local = await SharedPreferences.getInstance();
    final copia = _local.getString('${_prefijo}historial');
    if (copia != null) {
      final j = jsonDecode(copia);
      historial = Historial(j['historial']);
      ultimaConsulta = DateTime.parse(j['fecha']).toLocal();
    }
  }

  List<Json> get lista => [
    for (final k in _local.getKeys().where((k) => k.startsWith(_cola)))
      jsonDecode(_local.getString(k)!) as Json,
  ]..sort((a, b) => (a['creado'] as String).compareTo(b['creado']));

  Future<void> guardar(Json b) async {
    if (!await _local.setString('$_cola${b['clave']}', jsonEncode(b))) {
      throw FalloApi('No se pudo conservar el borrador en este dispositivo.');
    }
  }

  Future<void> quitar(String clave) async {
    if (!await _local.remove('$_cola$clave')) {
      throw FalloApi('No se pudo actualizar el borrador local.');
    }
  }

  Future<void> enviar(Json b) {
    final clave = b['clave'] as String;
    return _enCurso.putIfAbsent(
      clave,
      () => _enviar(b, clave).whenComplete(() {
        _enCurso.remove(clave);
      }),
    );
  }

  Future<void> _enviar(Json b, String clave) async {
    late final Json res;
    try {
      res = await api.registrar(b['datos'], clave);
    } on FalloApi catch (e) {
      if (!e.reintentar) {
        await guardar({...b, 'error': e.mensaje, 'exceso': e.exceso});
      }
      rethrow;
    }
    aviso =
        'Apuesta #${res['apuesta']['id']} confirmada. Saldo disponible: ${dinero(res['bankroll']['disponible'])}.';
    await quitar(clave);
  }

  Future<Historial> actualizar() async {
    for (final b in lista.where((b) => b['error'] == null)) {
      try {
        await enviar(b);
      } on FalloApi catch (e) {
        if (e.reintentar) break;
      }
    }
    try {
      final h = await api.cargar();
      final ahora = DateTime.now();
      await _local.setString(
        '${_prefijo}historial',
        jsonEncode({
          'historial': h.datos,
          'fecha': ahora.toUtc().toIso8601String(),
        }),
      );
      saldoPorActualizar = false;
      historial = h;
      ultimaConsulta = ahora;
      return h;
    } on FalloApi catch (e) {
      saldoPorActualizar = e.reintentar;
      if (!e.reintentar || historial == null) rethrow;
      return historial!;
    }
  }
}
